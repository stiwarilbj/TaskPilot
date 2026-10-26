import CoreFoundation
import Darwin
import Foundation

/// One immutable capability for a task. Revocation is serialized with native
/// commits; cancellation is only a wake-up mechanism, never authorization.
final class TaskLease: @unchecked Sendable {
    enum State { case running, paused, draining, retired }
    let id: String
    let actionReceipts: ActionReceiptStore
    private let lock = NSRecursiveLock()
    private var value: State = .running
    private var discarded = 0
    private var suspensions = 0
    struct CaptureArtifactUsage: Equatable { let fileCount: Int; let totalBytes: Int64 }
    enum CaptureArtifactError: LocalizedError {
        case invalidArtifact, retentionLimit
        var errorDescription: String? {
            switch self {
            case .invalidArtifact: return "The private capture artifact is unavailable or has changed"
            case .retentionLimit: return "The task's retained capture files have reached their bounded capacity"
            }
        }
    }
    private struct CaptureArtifact {
        let bytes: Int64
        let identity: TaskCaptureDirectory.FileIdentity
        var references = 0
        var expired = false
    }
    private var artifacts: [URL: CaptureArtifact] = [:]
    private var artifactBytes: Int64 = 0
    private var captureEncoders = 0
    private let captureFileLimit: Int
    private let captureByteLimit: Int64
    private let scratchRoot: URL
    private var scratchLease: TaskTemporaryResourceLease?
    private var captureStorage: TaskCaptureDirectory?
    private var screenText: (revision: String, suspension: Int, snapshot: ScreenTextSnapshot)?
    private var revocationObservers: [UUID: @Sendable () -> Void] = [:]
    private var pauseWaiters: [UUID: @Sendable () -> Void] = [:]
    private var pauseRegistrations = 0
    private var instructionRevision: UInt64 = 0
    private var pendingCorrection: (id: String, revision: UInt64)?
    private var appliedCorrections: [String: UInt64] = [:]
    private var boundaryRequest: String
    private var boundaryReferences: [AgentTaskInputReference]
    private var stopBeforeBoundaries: [StopBoundaryRecord]
    private var workingDocumentRevision: UInt64 = 0
    private var pendingWorkingDocument: (id: String, revision: UInt64)?
    private var appliedWorkingDocumentUpdates: [String: UInt64] = [:]
    private var targetBindingRevision: UInt64 = 0
    private var pendingTargetChoice: (id: String, instructionRevision: UInt64, workingDocumentRevision: UInt64,
                                      revision: UInt64, candidateIDs: Set<String>, reference: String,
                                      requirementID: String, scope: String)?
    private var appliedTargetChoices: [String: UInt64] = [:]
    private var appliedTargetChoiceInstructionRevisions: [String: UInt64] = [:]
    private var appliedTargetChoiceWorkingDocumentRevisions: [String: UInt64] = [:]
    private var appliedTargetChoiceFingerprints: [String: Data] = [:]
    private var appliedTargetChoiceDocuments: [String: [String: Any]] = [:]
    private var appliedTargetChoiceOrder: [String] = []
    private var targetBindings: [[String: Any]] = []
    private var completionClaimed = false
    let permitsPersistentProcesses: Bool
    private var closePersistentProcesses: Bool
    private var persistentProcesses: [SubprocessSupervisor] = []
    private var processCleanupStarted = false
    init(id: String = UUID().uuidString, taskRequest: String = "",
         exactInputReferences: [AgentTaskInputReference] = [], closePersistentProcesses: Bool = true,
         recoveryJournal: ActionRecoveryJournal? = nil, recoveryTask: UUID? = nil,
         scratchRoot: URL = TaskTemporaryResourceLedger.defaultRoot,
         captureFileLimit: Int = 128, captureByteLimit: Int64 = 256 * 1024 * 1024) {
        self.id = id; self.actionReceipts = ActionReceiptStore(generation: id, journal: recoveryJournal, recoveryTask: recoveryTask)
        self.closePersistentProcesses = closePersistentProcesses
        self.scratchRoot = scratchRoot
        self.captureFileLimit = max(0, captureFileLimit)
        self.captureByteLimit = max(0, captureByteLimit)
        boundaryRequest = taskRequest
        boundaryReferences = exactInputReferences
        stopBeforeBoundaries = StopBoundaryPolicy.detect(in: taskRequest, exactInputReferences: exactInputReferences)
        // Conservative authorization from the original user request, never a
        // model response or command's background operator alone.
        let text = taskRequest.lowercased()
        permitsPersistentProcesses = text.range(of: "do not|don't|never|^(explain|describe|how|what|show me how)\\b", options: .regularExpression) == nil &&
            text.range(of: #"\b(start|launch|run)\b[^.!?\n]*\b(in (the )?background|background service)\b|\bkeep\b[^.!?\n]*\b(server|service|process)\b[^.!?\n]*\b(running|alive)\b|\b(start|launch|run)\b[^.!?\n]*\b(server|service)\b[^.!?\n]*\bkeep (it )?running\b"#, options: .regularExpression) != nil
    }
    deinit { scratchLease?.removeDirectory() }
    func setProcessCleanup(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        if !processCleanupStarted { closePersistentProcesses = enabled }
    }
    func ownPersistentProcess(_ process: SubprocessSupervisor) throws {
        try commit {
            guard permitsPersistentProcesses, !processCleanupStarted else { throw CancellationError() }
            persistentProcesses.append(process)
        }
    }
    /// Called before task handoff; retained services are exempt only from the
    /// cleanup the user disabled, never accidentally forgotten at shell exit.
    func drainPersistentProcesses() -> Bool {
        lock.lock()
        let processes = persistentProcesses
        let close = closePersistentProcesses
        let start = !processCleanupStarted; processCleanupStarted = true
        if !close { persistentProcesses.removeAll() }
        lock.unlock()
        if start {
            for process in processes {
                if close { process.beginTeardown() }
                else { PersistentProcessResources.shared.retain(process) }
            }
        }
        return !close || processes.allSatisfy { $0.snapshot.treeFinished }
    }
    var state: State { lock.lock(); defer { lock.unlock() }; return value }
    var staleWorkCount: Int { lock.lock(); defer { lock.unlock() }; return discarded }
    var suspensionRevision: Int { lock.lock(); defer { lock.unlock() }; return suspensions }
    // Private counts also let offline tests distinguish parking from polling.
    var pauseWaiterCount: Int { lock.lock(); defer { lock.unlock() }; return pauseWaiters.count }
    var pauseWaitRegistrationCount: Int { lock.lock(); defer { lock.unlock() }; return pauseRegistrations }
    var currentInstructionRevision: UInt64 { lock.lock(); defer { lock.unlock() }; return instructionRevision }
    var activeStopBoundaries: [StopBoundaryRecord] { lock.lock(); defer { lock.unlock() }; return stopBeforeBoundaries }
    var hasPendingInstructionCorrection: Bool { lock.lock(); defer { lock.unlock() }; return pendingCorrection != nil }
    var currentWorkingDocumentRevision: UInt64 { lock.lock(); defer { lock.unlock() }; return workingDocumentRevision }
    var currentTargetBindingRevision: UInt64 { lock.lock(); defer { lock.unlock() }; return targetBindingRevision }
    var hasPendingTargetChoice: Bool { lock.lock(); defer { lock.unlock() }; return pendingTargetChoice != nil }
    var hasPendingWorkingDocumentUpdate: Bool { lock.lock(); defer { lock.unlock() }; return pendingWorkingDocument != nil }
    func appliedWorkingDocumentRevision(id: String) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return appliedWorkingDocumentUpdates[id.lowercased()]
    }

    func beginWorkingDocumentUpdate(id: String, revision: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        guard (value == .running || value == .paused), pendingWorkingDocument == nil,
              pendingCorrection == nil, !completionClaimed,
              revision == workingDocumentRevision + 1, UUID(uuidString: id) != nil else {
            throw WorkingDocumentUpdateError.stale
        }
        // A newer explicit document selection supersedes the pending question
        // immediately, but retain the existing document binding until the
        // selected window has passed native validation and is installed.
        pendingTargetChoice = nil
        pendingWorkingDocument = (id.lowercased(), revision)
    }

    func cancelWorkingDocumentUpdate(id: String) {
        lock.lock(); defer { lock.unlock() }
        guard pendingWorkingDocument?.id == id.lowercased() else { return }
        pendingWorkingDocument = nil
    }

    func applyWorkingDocumentUpdate(id: String, revision: UInt64, install: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        let normalizedID = id.lowercased()
        if appliedWorkingDocumentUpdates[normalizedID] == revision { return }
        guard (value == .running || value == .paused),
              pendingWorkingDocument?.id == normalizedID,
              pendingWorkingDocument?.revision == revision,
              revision == workingDocumentRevision + 1 else { throw WorkingDocumentUpdateError.stale }
        try install()
        workingDocumentRevision = revision
        pendingWorkingDocument = nil
        targetBindings.removeAll { $0["scope"] as? String == "document" }
        appliedWorkingDocumentUpdates[normalizedID] = revision
    }

    func validateWorkingDocumentRevision(_ revision: UInt64, allowDispatchedReceipt: Bool = false,
                                         allowPendingUpdate: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        guard value == .running || value == .paused else { throw CancellationError() }
        if allowDispatchedReceipt, revision <= workingDocumentRevision { return }
        if allowPendingUpdate, pendingWorkingDocument?.revision == revision { return }
        guard pendingWorkingDocument == nil, revision == workingDocumentRevision else {
            throw WorkingDocumentUpdateError.superseded
        }
    }

    func beginInstructionCorrection(id: String, revision: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        guard (value == .running || value == .paused), pendingCorrection == nil,
              pendingWorkingDocument == nil,
              !completionClaimed, revision == instructionRevision + 1, UUID(uuidString: id) != nil else {
            throw TaskInstructionCorrectionError.stale
        }
        // Keep the current question and bindings intact until persistence and
        // correction acknowledgement succeed. The pending-correction barrier
        // already prevents target selections and action delivery.
        pendingCorrection = (id.lowercased(), revision)
    }

    func cancelInstructionCorrection(id: String) {
        lock.lock(); defer { lock.unlock() }
        guard pendingCorrection?.id == id.lowercased() else { return }
        pendingCorrection = nil
    }

    func applyInstructionCorrection(id: String, revision: UInt64,
                                    correction: TaskInstructionCorrection? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let normalizedID = id.lowercased()
        if appliedCorrections[normalizedID] == revision { return }
        guard (value == .running || value == .paused), pendingWorkingDocument == nil,
              pendingCorrection?.id == normalizedID, pendingCorrection?.revision == revision,
              revision == instructionRevision + 1 else { throw TaskInstructionCorrectionError.stale }
        if let correction {
            guard correction.id.uuidString.lowercased() == normalizedID,
                  correction.revision == revision else { throw TaskInstructionCorrectionError.stale }
            try correction.submission.validateExactInputReferences()
            if let amendment = correction.roleAmendment {
                guard let index = boundaryReferences.firstIndex(where: { $0.id == amendment.occurrenceID &&
                    $0.kind == amendment.kind && $0.utf8Start == amendment.utf8Start &&
                    $0.utf8Length == amendment.utf8Length && $0.value == amendment.value }) else {
                    throw TaskInstructionCorrectionError.stale
                }
                let reference = boundaryReferences[index]
                boundaryReferences[index] = AgentTaskInputReference(kind: reference.kind,
                    utf8Start: reference.utf8Start, utf8Length: reference.utf8Length,
                    value: reference.value, userRole: amendment.role)
            }
            if !correction.request.isEmpty || !correction.exactInputReferences.isEmpty {
                let header = "\n\nUser correction: "
                let start = boundaryRequest.utf8.count + header.utf8.count
                boundaryRequest += header + correction.request
                boundaryReferences.append(contentsOf: correction.exactInputReferences.map {
                    AgentTaskInputReference(version: $0.version, kind: $0.kind,
                        utf8Start: start + $0.utf8Start, utf8Length: $0.utf8Length, value: $0.value,
                        userRole: $0.userRole)
                })
            }
            stopBeforeBoundaries = StopBoundaryPolicy.detect(in: boundaryRequest,
                                                              exactInputReferences: boundaryReferences)
        }
        instructionRevision = revision
        pendingCorrection = nil
        pendingTargetChoice = nil
        targetBindings.removeAll()
        appliedCorrections[normalizedID] = revision
    }

    func beginTargetChoice(id: String, instructionRevision: UInt64, workingDocumentRevision: UInt64,
                           revision: UInt64, candidateIDs: Set<String>, reference: String,
                           requirementID: String, scope: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard (value == .running || value == .paused), pendingCorrection == nil,
              pendingWorkingDocument == nil, pendingTargetChoice == nil, !completionClaimed,
              instructionRevision == self.instructionRevision,
              workingDocumentRevision == self.workingDocumentRevision,
              revision == targetBindingRevision + 1,
              UUID(uuidString: id)?.uuidString.lowercased() == id.lowercased(),
              (2...8).contains(candidateIDs.count),
              !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reference.utf8.count <= 240,
              requirementID.range(of: #"^r[1-9][0-9]{0,3}$"#, options: .regularExpression) != nil,
              ["source", "destination", "document"].contains(scope) else {
            throw TargetChoiceError.stale
        }
        pendingTargetChoice = (id.lowercased(), instructionRevision, workingDocumentRevision,
                               revision, candidateIDs, reference, requirementID, scope)
    }

    @discardableResult
    func cancelTargetChoice(id: String, revision: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pendingTargetChoice?.id == id.lowercased(), pendingTargetChoice?.revision == revision else { return false }
        pendingTargetChoice = nil
        return true
    }

    func applyTargetChoice(id: String, candidateID: String, instructionRevision: UInt64,
                           workingDocumentRevision: UInt64, revision: UInt64,
                           bindingRecord: [String: Any],
                           install: (UInt64) throws -> [String: Any]?) throws -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        let normalizedID = id.lowercased()
        guard let fingerprint = Self.canonicalJSON(["candidate_id": candidateID, "binding": bindingRecord]) else {
            throw TargetChoiceError.stale
        }
        if let appliedRevision = appliedTargetChoices[normalizedID] {
            guard appliedRevision == revision,
                  appliedTargetChoiceInstructionRevisions[normalizedID] == instructionRevision,
                  appliedTargetChoiceWorkingDocumentRevisions[normalizedID] == workingDocumentRevision,
                  appliedTargetChoiceFingerprints[normalizedID] == fingerprint else {
                throw TargetChoiceError.stale
            }
            return appliedTargetChoiceDocuments[normalizedID]
        }
        guard (value == .running || value == .paused), !completionClaimed,
              pendingCorrection == nil, pendingWorkingDocument == nil,
              let pending = pendingTargetChoice, pending.id == normalizedID,
              pending.instructionRevision == instructionRevision,
              pending.workingDocumentRevision == workingDocumentRevision,
              pending.revision == revision, pending.candidateIDs.contains(candidateID),
              pending.reference == (bindingRecord["reference"] as? String),
              pending.requirementID == (bindingRecord["requirement_id"] as? String),
              pending.scope == (bindingRecord["scope"] as? String),
              instructionRevision == self.instructionRevision,
              workingDocumentRevision == self.workingDocumentRevision,
              revision == targetBindingRevision + 1 else { throw TargetChoiceError.stale }
        guard bindingRecord["candidate_id"] as? String == candidateID,
              bindingRecord["reference"] as? String != nil,
              bindingRecord["requirement_id"] as? String != nil,
              let scope = bindingRecord["scope"] as? String,
              ["source", "destination", "document"].contains(scope),
              let kind = bindingRecord["kind"] as? String,
              ["file", "folder", "document"].contains(kind),
              Self.integer(bindingRecord["binding_revision"]) == Int64(revision),
              bindingRecord["binding"] is [String: Any],
              let label = bindingRecord["label"] as? String,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              label.utf8.count <= 160,
              let detail = bindingRecord["detail"] as? String,
              detail.utf8.count <= 480 else { throw TargetChoiceError.stale }
        if (scope == "document" && kind != "document") ||
            (scope == "destination" && !["file", "folder"].contains(kind)) ||
            (scope == "source" && kind == "document") { throw TargetChoiceError.stale }
        if kind == "file" || kind == "folder" {
            guard Self.fileIdentityMatches(bindingRecord["binding"] as? [String: Any] ?? [:], kind: kind) else {
                throw TargetChoiceError.stale
            }
        }
        let installedDocumentRevision = bindingRecord["scope"] as? String == "document"
            ? workingDocumentRevision + 1 : workingDocumentRevision
        let installedDocument = try install(installedDocumentRevision)
        if bindingRecord["scope"] as? String == "document" {
            guard installedDocument?["state"] as? String == "active",
                  installedDocument?["revision"] as? Int == Int(installedDocumentRevision) else {
                throw WorkingDocumentUpdateError.unavailable
            }
            self.workingDocumentRevision = installedDocumentRevision
            appliedWorkingDocumentUpdates[normalizedID] = installedDocumentRevision
        }
        targetBindings.removeAll {
            $0["scope"] as? String == bindingRecord["scope"] as? String &&
            $0["reference"] as? String == bindingRecord["reference"] as? String &&
            $0["requirement_id"] as? String == bindingRecord["requirement_id"] as? String
        }
        targetBindings.append(bindingRecord)
        targetBindingRevision = revision
        pendingTargetChoice = nil
        if appliedTargetChoices[normalizedID] == nil { appliedTargetChoiceOrder.append(normalizedID) }
        appliedTargetChoices[normalizedID] = revision
        appliedTargetChoiceInstructionRevisions[normalizedID] = instructionRevision
        appliedTargetChoiceWorkingDocumentRevisions[normalizedID] = workingDocumentRevision
        appliedTargetChoiceFingerprints[normalizedID] = fingerprint
        if let installedDocument { appliedTargetChoiceDocuments[normalizedID] = installedDocument }
        while appliedTargetChoiceOrder.count > 64 {
            let oldest = appliedTargetChoiceOrder.removeFirst()
            appliedTargetChoices.removeValue(forKey: oldest)
            appliedTargetChoiceInstructionRevisions.removeValue(forKey: oldest)
            appliedTargetChoiceWorkingDocumentRevisions.removeValue(forKey: oldest)
            appliedTargetChoiceFingerprints.removeValue(forKey: oldest)
            appliedTargetChoiceDocuments.removeValue(forKey: oldest)
        }
        return installedDocument
    }

    func appliedTargetChoiceRevision(id: String) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return appliedTargetChoices[id.lowercased()]
    }

    /// Check the exact choice projection and its current filesystem identity at
    /// the same serialized boundary as native action dispatch.
    func validateTargetBindings(revision: UInt64, supplied: [[String: Any]],
                                action: [String: Any], requirementIDs: [String],
                                intendedTarget: String?) throws {
        lock.lock(); defer { lock.unlock() }
        guard value == .running || value == .paused else { throw CancellationError() }
        guard pendingTargetChoice == nil, pendingCorrection == nil, pendingWorkingDocument == nil,
              revision == targetBindingRevision,
              let expected = Self.canonicalJSON(targetBindings),
              let actual = Self.canonicalJSON(supplied), expected == actual else {
            throw TargetChoiceError.superseded
        }
        guard requirementIDs.count <= 32,
              Set(requirementIDs).count == requirementIDs.count,
              requirementIDs.allSatisfy({ $0.range(of: #"^r[1-9][0-9]{0,3}$"#, options: .regularExpression) != nil }) else {
            throw TargetChoiceError.conflict
        }
        if !targetBindings.isEmpty && requirementIDs.isEmpty {
            throw TargetChoiceError.conflict
        }
        for record in targetBindings where requirementIDs.contains(record["requirement_id"] as? String ?? "") {
            let scope = record["scope"] as? String ?? ""
            let kind = record["kind"] as? String ?? ""
            let binding = record["binding"] as? [String: Any] ?? [:]
            let path = binding["path"] as? String
            let operands = Self.actionPathOperands(action, scope: scope)
            if !operands.isEmpty, let path,
               !operands.contains(where: { Self.pathMatches($0, candidate: path, kind: kind, scope: scope) }) {
                throw TargetChoiceError.conflict
            }
            let labels = [record["label"] as? String, record["reference"] as? String]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            let target = intendedTarget?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard !target.isEmpty, labels.contains(where: { target.contains($0) }) else {
                throw TargetChoiceError.conflict
            }
            if kind == "file" || kind == "folder" {
                guard Self.fileIdentityMatches(binding, kind: kind) else { throw TargetChoiceError.stale }
                if action["type"] as? String == "run_command" {
                    // Arbitrary shell source/argv cannot be proven to use the
                    // selected operand. Only typed deterministic operations
                    // participate in a file/folder binding.
                    guard let operation = action["operation"] as? [String: Any] else {
                        throw TargetChoiceError.opaqueCommand
                    }
                    let commandOperands = Self.actionPathOperands(operation, scope: scope)
                    guard !commandOperands.isEmpty else { throw TargetChoiceError.opaqueCommand }
                    let path = binding["path"] as? String ?? ""
                    guard commandOperands.contains(where: { Self.pathMatches($0, candidate: path, kind: kind, scope: scope) }) else {
                        throw TargetChoiceError.conflict
                    }
                }
            } else if kind == "document" {
                if action["type"] as? String == "run_command" {
                    throw TargetChoiceError.opaqueCommand
                }
                // A document binding identifies a window, not an arbitrary
                // filesystem operand. Such operands need their own grounded
                // file/folder binding and may not silently redirect the work.
                if !operands.isEmpty { throw TargetChoiceError.conflict }
            }
        }
    }

    private static func canonicalJSON(_ value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }

    private static func actionPathOperands(_ action: [String: Any], scope: String) -> [String] {
        let keys: Set<String> = scope == "destination"
            ? ["path", "destination", "output_path"]
            : ["path", "source", "input_path"]
        var values: [String] = []
        for key in keys {
            if let value = action[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { values.append(value) }
        }
        return values
    }

    private static func pathMatches(_ operand: String, candidate: String, kind: String, scope: String) -> Bool {
        let expanded = (operand as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return false }
        let operandURL = URL(fileURLWithPath: expanded).standardizedFileURL
        let candidateURL = URL(fileURLWithPath: candidate).standardizedFileURL
        if scope == "destination" {
            if kind == "file" { return operandURL.path == candidateURL.path }
            let parent = operandURL.deletingLastPathComponent().path
            return parent == candidateURL.path || parent.hasPrefix(candidateURL.path.hasSuffix("/") ? candidateURL.path : candidateURL.path + "/")
        }
        if operandURL.path == candidateURL.path { return true }
        return kind == "folder" && operandURL.path.hasPrefix(candidateURL.path.hasSuffix("/") ? candidateURL.path : candidateURL.path + "/")
    }

    private static func fileIdentityMatches(_ binding: [String: Any], kind: String) -> Bool {
        guard let rawPath = binding["path"] as? String, rawPath.hasPrefix("/"),
              let identity = binding["identity"] as? [String: Any],
              let expectedDevice = integer(identity["device"]),
              let expectedInode = integer(identity["inode"]),
              let expectedMode = integer(identity["mode"]) else { return false }
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        var metadata = stat()
        guard Darwin.lstat(path, &metadata) == 0,
              metadata.st_mode & S_IFMT == mode_t(expectedMode),
              (kind == "folder" ? metadata.st_mode & S_IFMT == S_IFDIR : metadata.st_mode & S_IFMT == S_IFREG),
              Int64(metadata.st_dev) == expectedDevice, Int64(metadata.st_ino) == expectedInode else { return false }
        if kind == "file" {
            guard let expectedSize = integer(identity["size"]), let expectedModified = integer(identity["mtime_ns"]) else { return false }
            let actualModified = Int64(metadata.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(metadata.st_mtimespec.tv_nsec)
            return Int64(metadata.st_size) == expectedSize && actualModified == expectedModified
        }
        return true
    }

    static func isCurrentFileChoice(binding: [String: Any], kind: String) -> Bool {
        fileIdentityMatches(binding, kind: kind)
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return Int64(number.stringValue)
    }

    func stopBoundaries(for revision: UInt64) throws -> [StopBoundaryRecord] {
        lock.lock(); defer { lock.unlock() }
        guard (value == .running || value == .paused), pendingCorrection == nil,
              revision == instructionRevision else { throw TaskInstructionCorrectionError.superseded }
        return stopBeforeBoundaries
    }

    func validateInstructionRevision(_ revision: UInt64, allowDispatchedReceipt: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        guard value == .running || value == .paused else { throw CancellationError() }
        if completionClaimed && !(allowDispatchedReceipt && revision == instructionRevision) {
            throw TaskInstructionCorrectionError.superseded
        }
        // Once an operation crossed the dispatched receipt boundary it owns
        // its original revision through terminal reconciliation, even after
        // the correction has been acknowledged and the barrier is lifted.
        if allowDispatchedReceipt, revision <= instructionRevision { return }
        guard pendingCorrection == nil, revision == instructionRevision else {
            throw TaskInstructionCorrectionError.superseded
        }
    }

    func claimCompletion(instructionRevision revision: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if completionClaimed { return revision == instructionRevision }
        guard (value == .running || value == .paused), pendingCorrection == nil,
              pendingWorkingDocument == nil, pendingTargetChoice == nil,
              revision == instructionRevision, !completionClaimed else { return false }
        completionClaimed = true
        return true
    }

    /// Completion and correction acceptance share one lock. Returning the
    /// pending state from this same critical section prevents a rollback from
    /// being mistaken for a permanently rejected completion.
    func claimCompletionGate(instructionRevision revision: UInt64)
        -> (accepted: Bool, pendingCorrection: Bool, pendingWorkingDocument: Bool, pendingTargetChoice: Bool) {
        lock.lock(); defer { lock.unlock() }
        if completionClaimed { return (revision == instructionRevision, false, false, false) }
        guard value == .running || value == .paused else { return (false, false, false, false) }
        if pendingCorrection != nil || pendingWorkingDocument != nil || pendingTargetChoice != nil {
            return (false, pendingCorrection != nil, pendingWorkingDocument != nil, pendingTargetChoice != nil)
        }
        guard revision == instructionRevision else { return (false, false, false, false) }
        completionClaimed = true
        return (true, false, false, false)
    }
    func pause() { lock.lock(); defer { lock.unlock() }; if value == .running { value = .paused; suspensions += 1 } }
    func resume() {
        lock.lock()
        guard value == .paused else { lock.unlock(); return }
        value = .running
        let waiters = Array(pauseWaiters.values); pauseWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter() }
    }
    func revoke() {
        lock.lock()
        if value != .retired { value = .draining }
        let observers = Array(revocationObservers.values); revocationObservers.removeAll()
        let waiters = Array(pauseWaiters.values); pauseWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter() }
        for observer in observers { observer() }
    }
    /// Returns this task's private scratch directory, creating a process-bound
    /// durable lease on first use. User output paths are never registered here.
    func scratchDirectory() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard value == .running || value == .paused else { throw CancellationError() }
        if let scratchLease { return scratchLease.directoryURL }
        let lease = try TaskTemporaryResourceLedger.makeLease(root: scratchRoot)
        scratchLease = lease
        return lease.directoryURL
    }
    func observeRevocation(_ observer: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        let revoked = value == .draining || value == .retired
        if !revoked { revocationObservers[token] = observer }
        lock.unlock()
        if revoked { observer() }
        return token
    }
    func removeRevocationObserver(_ token: UUID) {
        lock.lock(); revocationObservers.removeValue(forKey: token); lock.unlock()
    }
    /// Only PNGs in this owner's private capture directory enter the ledger.
    /// A snapshot's lifetime expires on explicit discard or drained retirement.
    private func boundCaptureDirectory() throws -> TaskCaptureDirectory {
        if let captureStorage { return captureStorage }
        guard let scratchLease else { throw CaptureArtifactError.invalidArtifact }
        let capture = try scratchLease.captureDirectory()
        captureStorage = capture
        return capture
    }
    /// Metadata only: no directory scan, image read, or user output tracking.
    private func pruneCaptureArtifacts() {
        for url in Array(artifacts.keys) {
            guard let entry = artifacts[url], entry.references == 0 else { continue }
            guard let captureStorage, let name = captureStorage.filename(for: url) else { continue }
            let current: stat?
            // An unreadable descriptor is not proof that a retained file is gone.
            do { current = try captureStorage.status(named: name) } catch { continue }
            let matches = current.map { ($0.st_mode & S_IFMT) == S_IFREG &&
                TaskCaptureDirectory.FileIdentity($0) == entry.identity } ?? false
            if entry.expired && matches {
                guard (try? captureStorage.removeFile(named: name, expected: entry.identity)) == true else { continue }
            } else if matches { continue }
            artifacts.removeValue(forKey: url)
            artifactBytes -= entry.bytes
        }
        // Retirement occurs after normal drainage; explicit encoder/reader holds
        // also protect early retirement and delayed native image consumers.
        if value == .retired && artifacts.isEmpty && captureEncoders == 0 {
            let scratch = scratchLease; scratchLease = nil
            captureStorage = nil
            scratch?.removeDirectory()
        }
    }
    var captureArtifactUsage: CaptureArtifactUsage {
        lock.lock(); defer { lock.unlock() }
        pruneCaptureArtifacts()
        return .init(fileCount: artifacts.count, totalBytes: artifactBytes)
    }
    func requireCaptureDiskHeadroom(_ requiredBytes: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        try check()
        try boundCaptureDirectory().requireDiskHeadroom(requiredBytes)
    }
    func beginCaptureEncoding() throws -> CaptureArtifactHold {
        lock.lock(); defer { lock.unlock() }
        try check()
        _ = try scratchDirectory()
        _ = try boundCaptureDirectory()
        captureEncoders += 1
        return CaptureArtifactHold { [self] in
            lock.lock(); defer { lock.unlock() }
            captureEncoders -= 1; pruneCaptureArtifacts()
        }
    }
    func retainCaptureArtifact(_ url: URL) throws -> CaptureArtifactHold {
        lock.lock(); defer { lock.unlock() }
        try check()
        let url = url.standardizedFileURL
        let capture = try boundCaptureDirectory()
        guard var entry = artifacts[url], !entry.expired,
              capture.pathIsCurrent(), let name = capture.filename(for: url),
              let info = try capture.status(named: name), TaskCaptureDirectory.FileIdentity(info) == entry.identity else {
            throw CaptureArtifactError.invalidArtifact
        }
        entry.references += 1; artifacts[url] = entry
        return CaptureArtifactHold { [self] in
            lock.lock(); defer { lock.unlock() }
            if var entry = artifacts[url] { entry.references -= 1; artifacts[url] = entry }
            pruneCaptureArtifacts()
        }
    }
    func ownArtifact(_ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        let url = url.standardizedFileURL
        try check()
        let capture = try boundCaptureDirectory()
        guard capture.pathIsCurrent(), let name = capture.filename(for: url),
              let info = try capture.status(named: name), (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_size >= 0 else { throw CaptureArtifactError.invalidArtifact }
        pruneCaptureArtifacts()
        if let existing = artifacts[url] {
            guard existing.identity == TaskCaptureDirectory.FileIdentity(info) else { throw CaptureArtifactError.invalidArtifact }
            return
        }
        guard artifacts.count < captureFileLimit,
              info.st_size <= captureByteLimit - artifactBytes else { throw CaptureArtifactError.retentionLimit }
        artifacts[url] = CaptureArtifact(bytes: info.st_size, identity: .init(info))
        artifactBytes += info.st_size
    }
    func discardArtifact(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        let url = url.standardizedFileURL
        guard let capture = try? boundCaptureDirectory(), let name = capture.filename(for: url) else { return }
        if var entry = artifacts[url] {
            entry.expired = true; artifacts[url] = entry
            pruneCaptureArtifacts()
        } else if let info = try? capture.status(named: name), (info.st_mode & S_IFMT) == S_IFREG {
            // Failed/partial compression has not yet entered the ledger. Only
            // the encoder's private, unique destination may be removed here.
            _ = try? capture.removeFile(named: name, expected: .init(info))
        }
    }
    func bindScreenText(_ snapshot: ScreenTextSnapshot?, revision: String = "") throws {
        try commit { screenText = snapshot.map { (revision, suspensions, $0) } }
    }
    func screenTextSnapshot(revision: String) throws -> ScreenTextSnapshot? {
        lock.lock(); defer { lock.unlock() }
        try check()
        guard screenText?.revision == revision else { return nil }
        guard screenText?.suspension == suspensions else { throw AccessibilityActionError.staleObservation }
        return screenText?.snapshot
    }
    func retire() {
        lock.lock(); value = .retired; screenText = nil
        for url in Array(artifacts.keys) { artifacts[url]?.expired = true }
        pruneCaptureArtifacts()
        let observers = Array(revocationObservers.values); revocationObservers.removeAll()
        let waiters = Array(pauseWaiters.values); pauseWaiters.removeAll(); lock.unlock()
        for waiter in waiters { waiter() }
        for observer in observers { observer() }
        _ = drainPersistentProcesses()
        lock.lock(); persistentProcesses.removeAll(); lock.unlock()
        actionReceipts.discard()
    }
    func accepts(_ id: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let allowed = id == self.id && (value == .running || value == .paused)
        if !allowed { discarded += 1 }
        return allowed
    }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        guard value == .running || value == .paused else { throw CancellationError() }
    }
    func checkpoint() async throws {
        while state == .paused {
            try Task.checkCancellation()
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    // Registration and state changes share the ownership lock.
                    // Cancellation before registration must not strand a wait.
                    if value == .paused, !Task.isCancelled {
                        pauseWaiters[id] = { continuation.resume() }
                        pauseRegistrations += 1
                        lock.unlock()
                    } else {
                        lock.unlock(); continuation.resume()
                    }
                }
            } onCancel: { self.wakePauseWaiter(id) }
        }
        try check(); try Task.checkCancellation()
    }

    private func wakePauseWaiter(_ id: UUID) {
        lock.lock(); let waiter = pauseWaiters.removeValue(forKey: id); lock.unlock()
        waiter?()
    }

    /// Async entry points install a cancellation handler for synchronous native
    /// commits. Waking a wait never grants authority: every worker rechecks its
    /// own cancellation and the lease under the commit lock.
    func wakePausedWorkers() {
        lock.lock(); let waiters = Array(pauseWaiters.values); pauseWaiters.removeAll(); lock.unlock()
        for waiter in waiters { waiter() }
    }

    // Assigned before runtime startup; fixture/manual paths do not acquire it.
    var managedRuntimeRoot: URL?

    func commit<T>(_ operation: () throws -> T) throws -> T {
        // Native workers may wait through Pause; never block the main run loop.
        while true {
            try Task.checkCancellation()
            lock.lock()
            if value == .paused, !Thread.isMainThread {
                if Task.isCancelled { lock.unlock(); throw CancellationError() }
                let wake = DispatchSemaphore(value: 0)
                pauseWaiters[UUID()] = { wake.signal() }
                pauseRegistrations += 1
                lock.unlock()
                wake.wait()
                continue
            }
            defer { lock.unlock() }
            guard value == .running else { discarded += 1; throw CancellationError() }
            try Task.checkCancellation()
            let permit = try managedRuntimeRoot.map { try ManagedRuntimePermit(root:$0, repairing:false) }
            defer { withExtendedLifetime(permit) {} }
            return try operation()
        }
    }
}

enum TaskOwnership {
    @TaskLocal static var current: TaskLease?
    @TaskLocal static var actionReceipt: ActionReceiptStore.Token?
    @TaskLocal static var instructionRevision: UInt64?
    @TaskLocal static var workingDocumentRevision: UInt64?
    /// Narrow permission derived from the user's effective request. It lets
    /// native preflight admit standard Save/Export controls while a selection
    /// scope is active; it is never supplied by the model.
    @TaskLocal static var allowWorkingSelectionSaveExport = false
    @TaskLocal static var stopBoundaryPreflight: (([String: Any], [StopBoundaryRecord]) throws -> Void)?
    @TaskLocal static var targetChoicePreflight: (([String: Any]) throws -> Void)?
    static func check() throws { try current?.check(); try LocalOperationBudget.check(); try Task.checkCancellation() }
    static func checkpoint() async throws {
        try LocalOperationBudget.check(); try await current?.checkpoint(); try LocalOperationBudget.check()
    }
    static func withCancellationWakeup<T>(_ operation: () async throws -> T) async rethrows -> T {
        let lease = current
        return try await withTaskCancellationHandler(operation: operation, onCancel: { lease?.wakePausedWorkers() })
    }
    static func commit<T>(_ operation: () throws -> T) throws -> T {
        if let current {
            return try current.commit {
                try LocalOperationBudget.check()
                if let actionReceipt {
                    guard actionReceipt.generation == current.id else { throw CancellationError() }
                    let alreadyDispatched = actionReceipt.receipt["state"] as? String == "dispatched"
                    if let revision = instructionRevision {
                        try current.validateInstructionRevision(revision,
                            allowDispatchedReceipt: alreadyDispatched)
                    }
                    if let revision = workingDocumentRevision {
                        try current.validateWorkingDocumentRevision(revision,
                            allowDispatchedReceipt: alreadyDispatched)
                    }
                    // The policy is a dispatch barrier. An operation that has
                    // already crossed the receipt boundary must finish and be
                    // reconciled under its originating instruction revision.
                    if !alreadyDispatched, let stopBoundaryPreflight {
                        let revision = instructionRevision ?? current.currentInstructionRevision
                        let boundaries = try current.stopBoundaries(for: revision)
                        if !boundaries.isEmpty {
                            guard let action = actionReceipt.action else {
                                throw StopBoundaryViolation.uncertain(boundaries[0].label)
                            }
                            try stopBoundaryPreflight(action, boundaries)
                        }
                    }
                    if !alreadyDispatched, let targetChoicePreflight, let action = actionReceipt.action {
                        try targetChoicePreflight(action)
                    }
                    // Receipt dispatch and delivery share the lease's atomic
                    // boundary. Failed delivery after this point is uncertain.
                    try actionReceipt.dispatched()
                }
                return try operation()
            }
        }
        try LocalOperationBudget.check()
        return try operation() // Explicit user/manual and teardown paths.
    }
    static func permitted<T>(_ fallback: T, _ operation: () -> T) -> T {
        (try? commit(operation)) ?? fallback
    }
    static func callback(_ lease: TaskLease?, _ operation: () -> Void) {
        if let lease { _ = try? lease.commit { $current.withValue(lease, operation: operation) } } else { operation() }
    }
}

enum TaskInstructionCorrectionError: LocalizedError {
    case stale
    case superseded
    var errorDescription: String? {
        switch self {
        case .stale: "This correction is no longer current."
        case .superseded: "This action was planned before the latest instruction update."
        }
    }
}

enum TargetChoiceError: LocalizedError {
    case stale
    case superseded
    case conflict
    case opaqueCommand

    var code: String {
        switch self {
        case .stale: "target_choice_stale"
        case .superseded: "instruction_superseded"
        case .conflict: "target_choice_conflict"
        case .opaqueCommand: "target_choice_opaque_command"
        }
    }

    var errorDescription: String? {
        switch self {
        case .stale:
            return "The selected target changed. Inspect again before continuing."
        case .superseded:
            return "The target choice was superseded by a newer task instruction or document selection."
        case .conflict:
            return "This action conflicts with the target selected for its requirement. Inspect the operands and reconsider."
        case .opaqueCommand:
            return "This command cannot be tied to the selected target safely. Use an inspectable operation or reconsider the target."
        }
    }
}

enum WorkingDocumentUpdateError: LocalizedError {
    case stale
    case superseded
    case unavailable
    var errorDescription: String? {
        switch self {
        case .stale: "This working document selection is no longer current."
        case .superseded: "This action was planned before the working document changed."
        case .unavailable: "The working document is no longer available; choose it again from Live View."
        }
    }
}

/// A local operation owns one monotonic allowance. Child bounds may shorten it,
/// never renew it. Expiry revokes additional work, not already-delivered effects.
final class LocalOperationBudget: @unchecked Sendable {
    struct Exhausted: LocalizedError {
        let phase: String
        var errorDescription: String? { "The local operation budget was consumed during \(phase); any delivered effect still requires reconciliation" }
    }
    @TaskLocal static var current: LocalOperationBudget?
    let deadline: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var phase: String
    init(seconds: TimeInterval, phase: String, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now; self.deadline = now() + max(0, seconds); self.phase = phase
    }
    var remaining: TimeInterval { max(0, deadline - now()) }
    func check(phase next: String? = nil) throws {
        try Task.checkCancellation()
        try checkDeadline(phase: next)
    }
    /// Queues check their stored caller deadline independently of whichever
    /// task happens to pump them; cancellation is owned by that item's token.
    func checkDeadline(phase next: String? = nil) throws {
        try lock.withLock {
            guard now() < deadline else { throw Exhausted(phase: phase) }
            if let next { phase = next }
        }
    }
    static func check(_ phase: String? = nil) throws { try current?.check(phase: phase); try Task.checkCancellation() }
    static func allowance(_ seconds: TimeInterval) -> TimeInterval { min(max(0, seconds), current?.remaining ?? max(0, seconds)) }
    static func sleep(_ seconds: TimeInterval, phase: String) async throws {
        try TaskOwnership.check(); try check(phase)
        try await Task.sleep(for: .seconds(allowance(seconds)))
        try TaskOwnership.check()
    }
    /// Queue waits are cancellable. In-flight native work must still drain;
    /// this timer never releases its slot or declares a mutation unsuccessful.
    static func bounded<T: Sendable>(phase: String, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let budget = current else { return try await operation() }
        try budget.check(phase: phase)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(budget.remaining))
                try budget.check()
                throw Exhausted(phase: phase)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

/// Explicit native consumer/encoder hold. Contains no pixels; releasing the
/// last hold permits expired artifacts and drained scratch to be reclaimed.
final class CaptureArtifactHold: @unchecked Sendable {
    private let release: @Sendable () -> Void
    init(_ release: @escaping @Sendable () -> Void) { self.release = release }
    deinit { release() }
}
