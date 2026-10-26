import CoreGraphics
import Foundation

/// Cancellation can arrive before actor registration or while native work is
/// already running. It revokes publication, not the capacity of in-flight work.
final class CaptureCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}

/// One serial acquisition lane, two owned evidence frames, one preview frame,
/// at most eight waiting evidence requests and one replaceable preview request.
/// Waiting requests contain metadata/continuations, never acquired pixel buffers.
actor CaptureAcquisitionQueue {
    enum Kind { case evidence, preview }
    struct Statistics { let evidenceFrames: Int; let previewFrames: Int; let waitingEvidence: Int; let waitingPreview: Int; let acquiring: Bool }
    final class Reservation: @unchecked Sendable {
        let id: UUID
        let cancellation: CaptureCancellation
        let owner: TaskLease?
        let epoch: Int?
        private let queue: CaptureAcquisitionQueue
        init(id: UUID, cancellation: CaptureCancellation, owner: TaskLease?, epoch: Int?, queue: CaptureAcquisitionQueue) {
            self.id = id; self.cancellation = cancellation; self.owner = owner
            self.epoch = epoch; self.queue = queue
        }
        func checkAuthority() throws {
            try cancellation.check()
            if let owner { guard owner.state == .running, owner.suspensionRevision == epoch else { throw CancellationError() } }
        }
        func check() throws { try Task.checkCancellation(); try checkAuthority() }
        deinit { let id = id, queue = queue; Task { await queue.release(id) } }
    }
    private struct Request {
        let id: UUID
        let kind: Kind
        let cancellation: CaptureCancellation
        let owner: TaskLease?
        let epoch: Int?
        let observer: UUID?
        let waitTicket: BackendTelemetry.QueueTicket
        let budget: LocalOperationBudget?
        let continuation: CheckedContinuation<Reservation, Error>
        func rejection() -> Error? {
            do {
                try cancellation.check()
                if let owner { guard owner.state == .running, owner.suspensionRevision == epoch else { throw CancellationError() } }
                try budget?.checkDeadline(phase: "capture_queue")
                return nil
            } catch { return error }
        }
        func removeObserver() { if let observer { owner?.removeRevocationObserver(observer) } }
    }
    private var evidence: [Request] = []
    private var preview: Request?
    private var active: Request?
    private var frames: [UUID: Kind] = [:]
    private let maximumWaitingEvidence: Int
    init(maximumWaitingEvidence: Int = 8) { self.maximumWaitingEvidence = max(1, maximumWaitingEvidence) }
    var statistics: Statistics {
        .init(evidenceFrames: frames.values.filter { $0 == .evidence }.count,
              previewFrames: frames.values.filter { $0 == .preview }.count,
              waitingEvidence: evidence.count, waitingPreview: preview == nil ? 0 : 1, acquiring: active != nil)
    }
    func acquire(_ kind: Kind, owner: TaskLease? = nil,
                 waitTicket suppliedTicket: BackendTelemetry.QueueTicket? = nil) async throws -> Reservation {
        let waitTicket = suppliedTicket ?? BackendTelemetry.current.beginQueueWait(kind == .evidence ? .captureEvidence : .capturePreview)
        let budget = LocalOperationBudget.current
        do { try LocalOperationBudget.check("capture_queue") }
        catch { waitTicket.discard(error is CancellationError ? .cancelled : .rejected); throw error }
        let id = UUID(), cancellation = CaptureCancellation(), epoch = owner?.suspensionRevision
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let observer = owner?.observeRevocation { [weak self] in
                    cancellation.cancel(); Task { await self?.cancel(id) }
                }
                let request = Request(id: id, kind: kind, cancellation: cancellation, owner: owner,
                    epoch: epoch, observer: observer, waitTicket: waitTicket, budget: budget, continuation: continuation)
                if let error = Task.isCancelled ? CancellationError() : request.rejection() {
                    waitTicket.discard(error is CancellationError ? .cancelled : .rejected)
                    request.removeObserver(); continuation.resume(throwing: error); return
                }
                if kind == .evidence {
                    guard evidence.count < maximumWaitingEvidence else {
                        waitTicket.discard(.rejected)
                        request.removeObserver(); continuation.resume(throwing: ScreenCaptureError.pipelineBusy); return
                    }
                    evidence.append(request)
                } else {
                    // Never retain a chain of obsolete viewer requests.
                    if let previous = preview {
                        previous.waitTicket.discard(.coalesced)
                        previous.cancellation.cancel(); previous.removeObserver()
                        previous.continuation.resume(throwing: CancellationError())
                    }
                    if active?.kind == .preview { active?.cancellation.cancel() }
                    preview = request
                }
                pump()
            }
        } onCancel: { cancellation.cancel(); Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        if let index = evidence.firstIndex(where: { $0.id == id }) {
            let request = evidence.remove(at: index); request.waitTicket.discard(.cancelled); request.removeObserver()
            request.continuation.resume(throwing: CancellationError())
        } else if preview?.id == id, let request = preview {
            preview = nil; request.waitTicket.discard(.cancelled); request.removeObserver(); request.continuation.resume(throwing: CancellationError())
        }
        // An active native acquisition must drain before another starts.
        if active?.id == id { active?.cancellation.cancel() }
        pump()
    }
    private func pump() {
        guard active == nil else { return }
        // Reject stopped/paused epochs even if their cancellation callback has
        // not reached this actor. Every continuation settles exactly once.
        while let first = evidence.first, let error = first.rejection() {
            evidence.removeFirst(); first.waitTicket.discard(error is CancellationError ? .cancelled : .rejected)
            first.removeObserver(); first.continuation.resume(throwing: error)
        }
        if let request = preview, let error = request.rejection() {
            preview = nil; request.waitTicket.discard(error is CancellationError ? .cancelled : .rejected)
            request.removeObserver(); request.continuation.resume(throwing: error)
        }
        let request: Request
        if !evidence.isEmpty, frames.values.filter({ $0 == .evidence }).count < 2 {
            request = evidence.removeFirst()
        } else if let next = preview {
            guard !frames.values.contains(.preview) else { return }
            request = next; preview = nil
        } else { return }
        request.waitTicket.start()
        active = request; frames[request.id] = request.kind
        request.continuation.resume(returning: Reservation(id: request.id, cancellation: request.cancellation, owner: request.owner, epoch: request.epoch, queue: self))
    }
    func acquired(_ reservation: Reservation) {
        guard active?.id == reservation.id else { return }
        active?.removeObserver(); active = nil; pump()
    }
    private func release(_ id: UUID) {
        if active?.id == id { active?.removeObserver(); active = nil }
        frames.removeValue(forKey: id); pump()
    }
}

/// Immutable pixels and mapping from a single acquisition. Holding this object
/// owns a raw-frame slot; discarding another frame cannot invalidate this one.
final class CapturedFrame: @unchecked Sendable {
    let id = UUID()
    let image: CGImage
    /// Estimated resident pixel storage, including row padding.
    let imageStorageBytes: Int
    let coordinates: ScreenCoordinateMapping
    let reservation: CaptureAcquisitionQueue.Reservation
    init(image: CGImage, imageStorageBytes: Int, coordinates: ScreenCoordinateMapping,
         reservation: CaptureAcquisitionQueue.Reservation) {
        self.image = image; self.imageStorageBytes = max(0, imageStorageBytes)
        self.coordinates = coordinates; self.reservation = reservation
    }
    func check() throws {
        try reservation.check()
        if let caller = TaskOwnership.current, caller !== reservation.owner { throw CancellationError() }
    }
}

/// One compression worker, at most one queued frame. ImageIO never runs on the
/// capture actor. Running compression drains on cancellation; queued work drops
/// its frame immediately. No job can look up or substitute a newer capture.
actor CapturePNGEncoder {
    typealias Writer = @Sendable (CGImage, URL) throws -> Void
    private struct Job {
        let id: UUID
        let frame: CapturedFrame
        let directory: URL
        let url: URL
        let cancellation: CaptureCancellation
        let observer: UUID?
        let telemetry: BackendTelemetry
        let waitTicket: BackendTelemetry.QueueTicket
        let queuedMemory: BackendTelemetry.MemoryTicket
        let budget: LocalOperationBudget?
        let continuation: CheckedContinuation<URL, Error>
        func checkAdmission() throws {
            try cancellation.check(); try frame.reservation.checkAuthority()
            try budget?.checkDeadline(phase: "capture_encoding")
        }
        func removeObserver() { if let observer { frame.reservation.owner?.removeRevocationObserver(observer) } }
    }
    private let writer: Writer
    private let directory: URL
    private var waiting: [Job] = []
    private var active: Job?
    private var activeMemory: BackendTelemetry.MemoryTicket?
    private var frameIDs: Set<UUID> = []
    private var worker: Task<Void, Never>?
    init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitAgent", isDirectory: true),
         writer: @escaping Writer = { try ScreenCaptureService.writePNG($0, to: $1) }) {
        self.directory = directory; self.writer = writer
    }
    var pendingCount: Int { waiting.count }
    var activeCount: Int { active == nil ? 0 : 1 }
    func encode(_ frame: CapturedFrame, telemetry suppliedTelemetry: BackendTelemetry? = nil,
                waitTicket suppliedTicket: BackendTelemetry.QueueTicket? = nil) async throws -> URL {
        let waitTicket = suppliedTicket ?? BackendTelemetry.current.beginQueueWait(.pngCompression)
        let budget = LocalOperationBudget.current
        do { try frame.check(); try budget?.check(phase: "capture_encoding") }
        catch { waitTicket.discard(error is CancellationError ? .cancelled : .rejected); throw error }
        let outputDirectory: URL
        var encodingHold: CaptureArtifactHold?
        defer { withExtendedLifetime(encodingHold) {} }
        do {
            encodingHold = try frame.reservation.owner?.beginCaptureEncoding()
            outputDirectory = try frame.reservation.owner?.scratchDirectory()
                .appendingPathComponent("capture", isDirectory: true) ?? directory
        } catch {
            waitTicket.discard(error is CancellationError ? .cancelled : .rejected)
            throw error
        }
        let id = UUID(), cancellation = CaptureCancellation()
        let telemetry = suppliedTelemetry ?? BackendTelemetry.current
        let url: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do { try frame.check(); try budget?.check(phase: "capture_encoding") }
                catch { waitTicket.discard(error is CancellationError ? .cancelled : .rejected); continuation.resume(throwing: error); return }
                guard frameIDs.count < 2, !frameIDs.contains(frame.id) else {
                    waitTicket.discard(.rejected)
                    continuation.resume(throwing: ScreenCaptureError.pipelineBusy); return
                }
                let observer = frame.reservation.owner?.observeRevocation { [weak self] in
                    cancellation.cancel(); Task { await self?.cancel(id) }
                }
                let job = Job(id: id, frame: frame, directory: outputDirectory,
                    url: outputDirectory.appendingPathComponent("screen-\(UUID().uuidString).png"),
                    cancellation: cancellation, observer: observer, telemetry: telemetry, waitTicket: waitTicket,
                    queuedMemory: telemetry.beginMemory(.queuedCaptureFrames, bytes: frame.imageStorageBytes),
                    budget: budget, continuation: continuation)
                frameIDs.insert(frame.id); waiting.append(job); pump()
            }
        } onCancel: { cancellation.cancel(); Task { await self.cancel(id) } }
        do { try frame.check(); try cancellation.check() }
        catch { discard(url, owner: frame.reservation.owner); throw error }
        return url
    }
    private func cancel(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            let job = waiting.remove(at: index); job.waitTicket.discard(.cancelled)
            job.queuedMemory.finish(); frameIDs.remove(job.frame.id); job.removeObserver()
            job.continuation.resume(throwing: CancellationError())
        }
        if active?.id == id {
            active?.cancellation.cancel(); worker?.cancel()
            active?.frame.reservation.owner?.wakePausedWorkers()
        }
    }
    private func pump() {
        guard active == nil, !waiting.isEmpty else { return }
        let job = waiting.removeFirst()
        job.queuedMemory.finish()
        do { try job.checkAdmission() }
        catch {
            job.waitTicket.discard(error is CancellationError ? .cancelled : .rejected)
            frameIDs.remove(job.frame.id); job.removeObserver(); job.continuation.resume(throwing: error)
            pump(); return
        }
        activeMemory = job.telemetry.beginMemory(.activeCaptureEncodes, bytes: job.frame.imageStorageBytes)
        active = job
        let writer = writer, directory = job.directory
        worker = Task.detached(priority: .userInitiated) {
            do { try job.cancellation.check(); try job.frame.check(); try job.budget?.check(phase: "capture_encoding") }
            catch {
                job.waitTicket.discard(error is CancellationError ? .cancelled : .rejected)
                await self.finished(job, result: .failure(error)); return
            }
            job.waitTicket.start()
            let result: Result<URL, Error> = Result {
                try LocalOperationBudget.$current.withValue(job.budget) {
                    try BackendTelemetry.$current.withValue(job.telemetry) {
                        try autoreleasepool {
                            try job.cancellation.check(); try job.frame.check(); try LocalOperationBudget.check("capture_encoding")
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                            try writer(job.frame.image, job.url)
                            try job.cancellation.check(); try job.frame.check(); try LocalOperationBudget.check("capture_encoding")
                            // The file becomes evidence only for its original task,
                            // after compression, under a short ownership check.
                            if let owner = job.frame.reservation.owner {
                                try owner.commit {
                                    try job.cancellation.check(); try job.frame.check(); try LocalOperationBudget.check("capture_encoding")
                                    try owner.ownArtifact(job.url)
                                }
                            }
                            return job.url
                        }
                    }
                }
            }
            await self.finished(job, result: result)
        }
    }
    private func discard(_ url: URL, owner: TaskLease?) {
        if let owner { owner.discardArtifact(url) }
        else { try? FileManager.default.removeItem(at: url) }
    }
    private func finished(_ job: Job, result: Result<URL, Error>) {
        guard active?.id == job.id else { return }
        active = nil; activeMemory?.finish(); activeMemory = nil
        worker = nil; frameIDs.remove(job.frame.id); job.removeObserver()
        do {
            try job.cancellation.check(); try job.frame.check(); try job.budget?.check(phase: "capture_encoding")
            let url = try result.get(); job.continuation.resume(returning: url)
        } catch {
            discard(job.url, owner: job.frame.reservation.owner)
            job.continuation.resume(throwing: error)
        }
        pump()
    }
}
