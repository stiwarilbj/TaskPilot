import Foundation

struct TaskInstructionCorrection: Codable, Equatable, Identifiable {
    let id: UUID
    let revision: UInt64
    let request: String
    let exactInputReferences: [AgentTaskInputReference]
    let roleAmendment: AgentTaskInputRoleAmendment?
    var applied: Bool

    init(id: UUID = UUID(), revision: UInt64, submission: AgentTaskSubmission, applied: Bool = false,
         roleAmendment: AgentTaskInputRoleAmendment? = nil) {
        self.id = id
        self.revision = revision
        request = submission.request
        exactInputReferences = submission.exactInputReferences
        self.roleAmendment = roleAmendment
        self.applied = applied
    }

    var submission: AgentTaskSubmission {
        AgentTaskSubmission(request: request, exactInputReferences: exactInputReferences)
    }

    var wireValue: [String: Any] {
        var result: [String: Any] = ["version": 1, "correction_id": id.uuidString.lowercased(), "instruction_revision": revision,
         "request": request, "exact_input_references": exactInputReferences.map(\.wireValue)]
        if let roleAmendment { result["role_amendment"] = roleAmendment.wireValue }
        return result
    }

    var displaySummary: String {
        guard let roleAmendment else { return request }
        let purpose = roleAmendment.role?.title ?? "Automatic"
        return "Used an exact input as \(purpose)"
    }
}

enum TaskCorrectionEditorState: Equatable {
    case editing
    case pending
    case finished
}

struct PendingTaskInputRoleCorrection: Equatable {
    let generationID: String
    let occurrenceID: String
    let desiredRole: AgentTaskInputRole?
}

struct TaskCorrectionSession: Equatable, Identifiable {
    let generationID: String
    var draft: TaskComposerDraft
    var state: TaskCorrectionEditorState = .editing
    var correctionID: UUID?
    var revision: UInt64?
    var errorMessage: String?
    var notice: String?

    var id: String { generationID }
}

struct AgentRequestMetrics: Codable, Equatable {
    let planning: Int
    let verification: Int
    let retries: Int
    let modelSwitches: Int
    let cacheHits: Int
    let reconnects: Int
    let promptCalls: Int?
    let providerRetries: Int?
    let actionDeliveries: Int?
    let actionRejections: Int?
    let unconfirmedActions: Int?
    let repairs: Int?
    var evidenceChecks: Int? = nil
    var coverageRejections: Int? = nil
    var requirementsProven: Int? = nil
    var dependencyChecks: Int? = nil
    var dependencyRejections: Int? = nil
    var conflictInspections: Int? = nil
    var evidenceConflicts: Int? = nil
    var recoveryCycles: Int? = nil
    var cycleSuppressions: Int? = nil
    var receiptQueries: Int? = nil
    var receiptRecoveries: Int? = nil
    var effectChecks: Int? = nil
    var verifiedEffects: Int? = nil
    var unconfirmedEffects: Int? = nil
    var receiptUnresolved: Int? = nil
    var localNotifications: Int? = nil
    var localTargetedChecks: Int? = nil
    var localPollWakeups: Int? = nil
    var commandInspections: Int? = nil
    var commandProbes: Int? = nil
    var commandProbeCacheHits: Int? = nil
    var commandPreflightRejections: Int? = nil

    var summary: String {
        "\(promptCalls ?? planning + verification) TaskPilot calls · \(planning) planning · \(verification) verification · \(retries) retries · \(modelSwitches) switches · \(cacheHits) reused · \(reconnects) reconnects" +
            (providerRetries.map { " · \($0) provider retries" } ?? " · provider retry count unavailable")
    }
}

struct QueuedAgentTask: Codable, Equatable, Identifiable {
    let id: UUID
    let request: String
    let exactInputReferences: [AgentTaskInputReference]?
    let queuedAt: Date

    init(
        id: UUID = UUID(),
        request: String,
        exactInputReferences: [AgentTaskInputReference] = [],
        queuedAt: Date = Date()
    ) {
        self.id = id
        self.request = request
        self.exactInputReferences = exactInputReferences.isEmpty ? nil : exactInputReferences
        self.queuedAt = queuedAt
    }
}

enum AgentTaskHistoryOutcome: String, Codable, Equatable {
    case completed
    case failed
    case stopped

    var displayName: String {
        switch self {
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }
}

struct AgentTaskHistoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let request: String
    let exactInputReferences: [AgentTaskInputReference]?
    let responseTitle: String
    let response: String
    let outcome: AgentTaskHistoryOutcome
    let startedAt: Date
    let finishedAt: Date
    let wasQueued: Bool
    let requestMetrics: AgentRequestMetrics?
    var corrections: [TaskInstructionCorrection]? = nil

    init(
        id: UUID = UUID(),
        request: String,
        exactInputReferences: [AgentTaskInputReference] = [],
        responseTitle: String,
        response: String,
        outcome: AgentTaskHistoryOutcome,
        startedAt: Date,
        finishedAt: Date = Date(),
        wasQueued: Bool,
        requestMetrics: AgentRequestMetrics? = nil,
        corrections: [TaskInstructionCorrection] = []
    ) {
        self.id = id
        self.request = request
        self.exactInputReferences = exactInputReferences.isEmpty ? nil : exactInputReferences
        self.responseTitle = responseTitle
        self.response = response
        self.outcome = outcome
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.wasQueued = wasQueued
        self.requestMetrics = requestMetrics
        self.corrections = corrections.isEmpty ? nil : corrections
    }

    var effectiveSubmission: AgentTaskSubmission {
        AgentTaskSubmission(request: request, exactInputReferences: exactInputReferences ?? [])
            .includingCorrections((corrections ?? []).filter(\.applied))
    }
}

/// The original authorization is saved with the existing private task ledger,
/// never copied into the content-free receipt journal or model-generated data.
struct AgentTaskAuthorization: Codable, Equatable {
    var id = UUID()
    let request: String
    var exactInputReferences: [AgentTaskInputReference]? = nil
    var startedAt = Date()
    let wasQueued: Bool
    var queuedTaskID: UUID? = nil
    var corrections: [TaskInstructionCorrection]? = nil

    var effectiveSubmission: AgentTaskSubmission {
        AgentTaskSubmission(request: request, exactInputReferences: exactInputReferences ?? [])
            .includingCorrections((corrections ?? []).filter(\.applied))
    }
}

struct AgentTaskLedgerSnapshot: Codable, Equatable {
    var queue: [QueuedAgentTask] = []
    var history: [AgentTaskHistoryEntry] = []
    var activeTask: AgentTaskAuthorization? = nil

    /// Recovery records interruption exactly once; it never queues a retry,
    /// restores a lease, replays actions, or translates receipts into evidence.
    mutating func recoverInterruptedTask(journal: ActionRecoveryJournal) throws -> String? {
        guard let activeTask else { return nil }
        guard journal.matches(activeTask) else { throw ActionRecoveryJournal.unavailable }
        let summary = journal.summary(task: activeTask.id)
        let message = summary.uncertain > 0
            ? "TaskPilot restarted during an action. Its effects remain uncertain and must be inspected before considering another execution. Nothing was automatically replayed or marked complete."
            : "TaskPilot restarted before this task finished. Saved receipt states do not prove task completion. Nothing was automatically replayed."
        if !history.contains(where: { $0.id == activeTask.id }) {
            history.append(AgentTaskHistoryEntry(id: activeTask.id, request: activeTask.request,
                exactInputReferences: activeTask.exactInputReferences ?? [],
                responseTitle: "Task interrupted", response: message, outcome: .stopped,
                startedAt: activeTask.startedAt, wasQueued: activeTask.wasQueued,
                corrections: activeTask.corrections ?? []))
        }
        // Queue removal and active authorization were committed together before
        // launch; this also handles a recovered older duplicate queue record.
        if let id = activeTask.queuedTaskID { queue.removeAll { $0.id == id } }
        self.activeTask = nil
        return message
    }
}

enum AgentTaskQueueOrdering {
    static func moving(
        _ tasks: [QueuedAgentTask],
        id: UUID,
        offset: Int
    ) -> [QueuedAgentTask] {
        guard let source = tasks.firstIndex(where: { $0.id == id }) else {
            return tasks
        }
        let destination = source + offset
        guard tasks.indices.contains(destination) else { return tasks }
        var reordered = tasks
        reordered.swapAt(source, destination)
        return reordered
    }
}

struct AgentTaskLedgerStore: Sendable {
    static let fileName = "task-ledger.json"
    static let directoryPermissions = 0o700
    static let filePermissions = 0o600

    let fileURL: URL

    // Copies of this Sendable store share the queue as well as its codecs.
    // Configuration is fixed before publication; all coding uses this queue.
    private let codingQueue = DispatchQueue(label: "com.orbitagent.task-ledger-json")
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    static func defaultFileURL(
        fileManager: FileManager = .default
    ) -> URL {
        GeminiAPIKeyStore.defaultFileURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent(fileName)
    }

    func load() throws -> AgentTaskLedgerSnapshot {
        try BackendTelemetry.current.measure(.persistenceRead) { span in
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                span.record(inputBytes: 0)
                return AgentTaskLedgerSnapshot()
            }
            let data = try Data(contentsOf: fileURL)
            span.record(inputBytes: data.count)
            let telemetry = BackendTelemetry.current
            return try codingQueue.sync {
                try telemetry.measure(.jsonDecoding, inputBytes: data.count) { _ in
                    try decoder.decode(AgentTaskLedgerSnapshot.self, from: data)
                }
            }
        }
    }

    func save(
        queue: [QueuedAgentTask],
        history: [AgentTaskHistoryEntry],
        activeTask: AgentTaskAuthorization? = nil
    ) throws {
        try BackendTelemetry.current.measure(.persistenceWrite, items: queue.count + history.count) { span in
            let fileManager = FileManager.default
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: Self.directoryPermissions]
            )
            try fileManager.setAttributes(
                [.posixPermissions: Self.directoryPermissions],
                ofItemAtPath: directory.path
            )

            let telemetry = BackendTelemetry.current
            let data = try codingQueue.sync {
                try telemetry.measure(.jsonEncoding) { encoding in
                    let data = try encoder.encode(AgentTaskLedgerSnapshot(queue: queue, history: history, activeTask: activeTask))
                    encoding.record(outputBytes: data.count)
                    return data
                }
            }
            try PrivateDurableFile.replace(data, at: fileURL)
            try fileManager.setAttributes(
                [.posixPermissions: Self.filePermissions],
                ofItemAtPath: fileURL.path
            )
            span.record(outputBytes: data.count)
        }
    }
}

struct AgentTaskHistoryDayGroup: Equatable, Identifiable {
    let dayStart: Date
    let entries: [AgentTaskHistoryEntry]

    var id: Date { dayStart }
}

struct AgentTaskHistoryMonthGroup: Equatable, Identifiable {
    let year: Int
    let month: Int
    let days: [AgentTaskHistoryDayGroup]

    var id: String { "\(year)-\(month)" }
}

struct AgentTaskHistoryYearGroup: Equatable, Identifiable {
    let year: Int
    let months: [AgentTaskHistoryMonthGroup]

    var id: Int { year }
}

enum AgentTaskHistoryGrouping {
    static func years(
        from entries: [AgentTaskHistoryEntry],
        calendar: Calendar = .current
    ) -> [AgentTaskHistoryYearGroup] {
        let sorted = entries.sorted { $0.finishedAt > $1.finishedAt }
        let yearBuckets = Dictionary(grouping: sorted) {
            calendar.component(.year, from: $0.finishedAt)
        }

        return yearBuckets.keys.sorted(by: >).map { year in
            let yearEntries = yearBuckets[year] ?? []
            let monthBuckets = Dictionary(grouping: yearEntries) {
                calendar.component(.month, from: $0.finishedAt)
            }
            let months = monthBuckets.keys.sorted(by: >).map { month in
                let monthEntries = monthBuckets[month] ?? []
                let dayBuckets = Dictionary(grouping: monthEntries) {
                    calendar.startOfDay(for: $0.finishedAt)
                }
                let days = dayBuckets.keys.sorted(by: >).map { dayStart in
                    AgentTaskHistoryDayGroup(
                        dayStart: dayStart,
                        entries: (dayBuckets[dayStart] ?? []).sorted {
                            $0.finishedAt > $1.finishedAt
                        }
                    )
                }
                return AgentTaskHistoryMonthGroup(
                    year: year,
                    month: month,
                    days: days
                )
            }
            return AgentTaskHistoryYearGroup(year: year, months: months)
        }
    }
}
