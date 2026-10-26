import Foundation
import OSLog

/// Local numeric measurements only. This API cannot accept content, paths,
/// commands, error messages, or task identifiers as telemetry metadata.
final class BackendTelemetry: @unchecked Sendable {
    static let shared = BackendTelemetry()
    @TaskLocal static var current: BackendTelemetry = .shared

    enum Phase: String, CaseIterable, Codable {
        case startup, capture, previewCapture, axCollection, pngEncoding
        case jsonEncoding, jsonDecoding, ipcReceive, ipcSend, ipcBridge
        case commandLaunch, persistenceRead, persistenceWrite
        var name: StaticString {
            switch self {
            case .startup: return "Runtime Startup"
            case .capture: return "Task Capture"
            case .previewCapture: return "Preview Capture"
            case .axCollection: return "AX Collection"
            case .pngEncoding: return "PNG Encoding"
            case .jsonEncoding: return "JSON Encoding"
            case .jsonDecoding: return "JSON Decoding"
            case .ipcReceive: return "IPC Receive"
            case .ipcSend: return "IPC Send"
            case .ipcBridge: return "IPC Bridge"
            case .commandLaunch: return "Command Launch"
            case .persistenceRead: return "Persistence Read"
            case .persistenceWrite: return "Persistence Write"
            }
        }
    }
    enum Outcome: Int, Codable { case succeeded, failed, cancelled, abandoned }
    /// Fixed queue names keep aggregate diagnostics independent of task and
    /// application content. Queue waits end when work first becomes runnable.
    enum Queue: String, CaseIterable, Codable {
        case runtimeIO, bridgeTask, observationTask, eventDelivery
        case captureEvidence, capturePreview, pngCompression, pipeFirstWrite
        var name: StaticString {
            switch self {
            case .runtimeIO: return "Wait Runtime I/O Queue"
            case .bridgeTask: return "Wait Bridge Task"
            case .observationTask: return "Wait Observation Task"
            case .eventDelivery: return "Wait Main Event Queue"
            case .captureEvidence: return "Wait Evidence Capture Queue"
            case .capturePreview: return "Wait Preview Capture Queue"
            case .pngCompression: return "Wait PNG Compression Queue"
            case .pipeFirstWrite: return "Wait Pipe First Write"
            }
        }
    }
    enum QueueDisposition: Int, CaseIterable, Codable { case started, cancelled, rejected, coalesced, abandoned }
    struct QueueWaitHistogram: Codable {
        let queue: Queue
        /// Upper bounds in milliseconds, followed by an overflow bucket.
        let upperBoundsMilliseconds: [Double]
        let countsByDisposition: [QueueDisposition: [UInt64]]
        let maximumMilliseconds: Double
    }
    struct Sample: Codable {
        let phase: Phase
        let outcome: Outcome
        let seconds: Double
        let inputBytes: Int?
        let outputBytes: Int?
        let items: Int?
    }
    struct Summary: Codable {
        let phase: Phase
        let samples: Int
        let medianMilliseconds: Double
        let p95Milliseconds: Double
        let maximumMilliseconds: Double
    }
    private struct Ring {
        var values: [Sample] = []
        var next = 0
        mutating func append(_ value: Sample, capacity: Int) {
            if values.count < capacity { values.append(value) }
            else { values[next] = value; next = (next + 1) % capacity }
        }
    }
    private struct QueueCounts {
        var byDisposition: [QueueDisposition: [UInt64]] = [:]
        var maximumMilliseconds = 0.0
        mutating func record(_ disposition: QueueDisposition, milliseconds: Double, bucketCount: Int) {
            var buckets = byDisposition[disposition] ?? Array(repeating: 0, count: bucketCount)
            let index = BackendTelemetry.bucketIndex(milliseconds)
            if buckets[index] < UInt64.max { buckets[index] += 1 }
            byDisposition[disposition] = buckets
            maximumMilliseconds = max(maximumMilliseconds, milliseconds)
        }
    }
    final class QueueTicket: @unchecked Sendable {
        private let owner: BackendTelemetry
        private let queue: Queue
        private let state: OSSignpostIntervalState
        private let enqueued: TimeInterval
        private let lock = NSLock()
        private var settled = false
        fileprivate init(_ owner: BackendTelemetry, _ queue: Queue) {
            self.owner = owner; self.queue = queue; enqueued = owner.now()
            state = owner.signposter.beginInterval(queue.name, id: owner.signposter.makeSignpostID())
        }
        @discardableResult func start() -> Bool { settle(.started) }
        func discard(_ disposition: QueueDisposition) {
            guard disposition != .started else { return }
            _ = settle(disposition)
        }
        private func settle(_ disposition: QueueDisposition) -> Bool {
            let result: (Bool, Double)? = lock.withLock {
                guard !settled else { return nil }
                settled = true
                return (disposition == .started, max(0, owner.now() - enqueued) * 1000)
            }
            guard let (started, milliseconds) = result else { return false }
            owner.signposter.endInterval(queue.name, state,
                "disposition=\(disposition.rawValue, privacy: .public) wait_ms=\(milliseconds, privacy: .public)")
            owner.recordQueueWait(queue, disposition: disposition, milliseconds: milliseconds)
            return started
        }
        deinit { discard(.abandoned) }
    }
    final class Span: @unchecked Sendable {
        private let owner: BackendTelemetry
        private let phase: Phase
        private let state: OSSignpostIntervalState
        private let started: TimeInterval
        private let lock = NSLock()
        private var ended = false
        private var inputBytes: Int?
        private var outputBytes: Int?
        private var items: Int?
        fileprivate init(_ owner: BackendTelemetry, _ phase: Phase, inputBytes: Int?, items: Int?) {
            self.owner = owner; self.phase = phase
            self.inputBytes = inputBytes.flatMap { $0 >= 0 ? $0 : nil }
            self.items = items.flatMap { $0 >= 0 ? $0 : nil }
            started = owner.now()
            state = owner.signposter.beginInterval(phase.name, id: owner.signposter.makeSignpostID())
        }
        func record(inputBytes: Int? = nil, outputBytes: Int? = nil, items: Int? = nil) {
            lock.withLock {
                guard !ended else { return }
                if let inputBytes, inputBytes >= 0 { self.inputBytes = inputBytes }
                if let outputBytes, outputBytes >= 0 { self.outputBytes = outputBytes }
                if let items, items >= 0 { self.items = items }
            }
        }
        func finish(_ outcome: Outcome) {
            let sample: Sample? = lock.withLock {
                guard !ended else { return nil }
                ended = true
                return Sample(phase: phase, outcome: outcome, seconds: max(0, owner.now() - started),
                    inputBytes: inputBytes, outputBytes: outputBytes, items: items)
            }
            guard let sample else { return }
            // Presence bits distinguish absent sizes from measured zero without
            // negative sentinels (some Instruments views format them unsigned).
            let fields = (sample.inputBytes == nil ? 0 : 1) | (sample.outputBytes == nil ? 0 : 2) | (sample.items == nil ? 0 : 4)
            owner.signposter.endInterval(phase.name, state,
                "outcome=\(outcome.rawValue, privacy: .public) duration_ms=\(sample.seconds * 1000, privacy: .public) input_bytes=\(sample.inputBytes ?? 0, privacy: .public) output_bytes=\(sample.outputBytes ?? 0, privacy: .public) items=\(sample.items ?? 0, privacy: .public) fields=\(fields, privacy: .public)")
            owner.append(sample)
        }
        deinit { finish(.abandoned) }
    }
    private let signposter = OSSignposter(subsystem: "com.orbitagent.controller", category: "BackendPhases")
    private let lock = NSLock()
    private let capacity: Int
    private let now: @Sendable () -> TimeInterval
    private var rings: [Phase: Ring] = [:]
    private var queueCounts: [Queue: QueueCounts] = [:]
    private static let waitUpperBoundsMilliseconds: [Double] = [0.1, 1, 5, 10, 50, 100, 500, 1_000, 5_000]
    init(capacity: Int = 128, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.capacity = max(1, min(1024, capacity)); self.now = now
    }
    func begin(_ phase: Phase, inputBytes: Int? = nil, items: Int? = nil) -> Span {
        Span(self, phase, inputBytes: inputBytes, items: items)
    }
    func beginQueueWait(_ queue: Queue) -> QueueTicket { QueueTicket(self, queue) }
    func measure<T>(_ phase: Phase, inputBytes: Int? = nil, items: Int? = nil, _ body: (Span) throws -> T) rethrows -> T {
        let span = begin(phase, inputBytes: inputBytes, items: items)
        do { let result = try body(span); span.finish(.succeeded); return result }
        catch { span.finish(error is CancellationError ? .cancelled : .failed); throw error }
    }
    func encodeJSON(_ value: Any, recordSize: Bool = true) throws -> Data {
        try measure(.jsonEncoding) { span in
            let data = try JSONSerialization.data(withJSONObject: value)
            if recordSize { span.record(outputBytes: data.count) }
            return data
        }
    }
    private func append(_ sample: Sample) { lock.withLock { rings[sample.phase, default: Ring()].append(sample, capacity: capacity) } }
    private static func bucketIndex(_ milliseconds: Double) -> Int {
        waitUpperBoundsMilliseconds.firstIndex(where: { milliseconds <= $0 }) ?? waitUpperBoundsMilliseconds.count
    }
    private func recordQueueWait(_ queue: Queue, disposition: QueueDisposition, milliseconds: Double) {
        lock.withLock {
            queueCounts[queue, default: QueueCounts()].record(disposition, milliseconds: milliseconds,
                bucketCount: Self.waitUpperBoundsMilliseconds.count + 1)
        }
    }
    func queueWaitHistograms() -> [QueueWaitHistogram] {
        lock.withLock {
            Queue.allCases.compactMap { queue in
                guard let counts = queueCounts[queue] else { return nil }
                return QueueWaitHistogram(queue: queue, upperBoundsMilliseconds: Self.waitUpperBoundsMilliseconds,
                    countsByDisposition: counts.byDisposition, maximumMilliseconds: counts.maximumMilliseconds)
            }
        }
    }
    func samples() -> [Sample] { lock.withLock { Phase.allCases.flatMap { rings[$0]?.values ?? [] } } }
    func summaries() -> [Summary] {
        let samples = samples()
        return Phase.allCases.compactMap { phase in
            let values = samples.filter { $0.phase == phase && $0.outcome == .succeeded }.map { $0.seconds * 1000 }.sorted()
            guard !values.isEmpty else { return nil }
            func percentile(_ fraction: Double) -> Double { values[max(0, Int(ceil(Double(values.count) * fraction)) - 1)] }
            return Summary(phase: phase, samples: values.count, medianMilliseconds: percentile(0.5),
                           p95Milliseconds: percentile(0.95), maximumMilliseconds: values.last!)
        }
    }
}
