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
    let editorSessionID = UUID()
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
    // Byte ceiling, not an entry-count limit. Saves must remain loadable.
    static let maximumFileBytes = 64 * 1024 * 1024

    let fileURL: URL

    // Copies share one FIFO operation queue and its codecs. Queue admission
    // orders submitted snapshots, including overlapping callers; a later save
    // cannot replace an earlier one until its replacement and permissions finish.
    private let operationQueue = DispatchQueue(label: "com.orbitagent.task-ledger-json")
    private let replaceAndFinalize: @Sendable (Data, URL) throws -> Void
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

    init(
        fileURL: URL? = nil,
        replaceAndFinalize: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try PrivateDurableFile.replace(data, at: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: AgentTaskLedgerStore.filePermissions],
                ofItemAtPath: url.path
            )
        }
    ) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.replaceAndFinalize = replaceAndFinalize
    }

    static func defaultFileURL(
        fileManager: FileManager = .default
    ) -> URL {
        GeminiAPIKeyStore.defaultFileURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent(fileName)
    }

    /// Reclaims only private task scratch directories whose process-bound lease
    /// is unlocked and whose recorded process birth identity is confirmed gone.
    /// User output paths are outside this directory and are never enumerated.
    func cleanupAbandonedTemporaryResources() {
        let scratchRoot = fileURL.deletingLastPathComponent()
            .appendingPathComponent(TaskTemporaryResourceLedger.directoryName, isDirectory: true)
        _ = TaskTemporaryResourceLedger.reclaimAbandoned(root: scratchRoot)
    }

    func load(
        read: (Int32, Int) throws -> Data = PrivateRuntimeMetadata.readChunk
    ) throws -> AgentTaskLedgerSnapshot {
        let telemetry = BackendTelemetry.current
        return try telemetry.measure(.persistenceRead) { span in
            try operationQueue.sync {
                let data: Data
                do {
                    data = try PrivateRuntimeMetadata.checkedData(fileURL, maximum: Self.maximumFileBytes, read: read)
                } catch PrivateRuntimeMetadata.Failure.missing {
                    span.record(inputBytes: 0)
                    return AgentTaskLedgerSnapshot()
                }
                span.record(inputBytes: data.count)
                return try telemetry.measure(.jsonDecoding, inputBytes: data.count) { _ in
                    _ = try PrivateRuntimeMetadata.parse(data)
                    return try decoder.decode(AgentTaskLedgerSnapshot.self, from: data)
                }
            }
        }
    }

    func save(
        queue: [QueuedAgentTask],
        history: [AgentTaskHistoryEntry],
        activeTask: AgentTaskAuthorization? = nil
    ) throws {
        let telemetry = BackendTelemetry.current
        try telemetry.measure(.persistenceWrite, items: queue.count + history.count) { span in
            try operationQueue.sync {
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

                let data = try telemetry.measure(.jsonEncoding) { encoding in
                    for entry in history {
                        if let metrics = entry.requestMetrics {
                            try BackendTelemetry.DiagnosticSchema.validateRequestMetrics(metrics)
                        }
                    }
                    let data = try encoder.encode(AgentTaskLedgerSnapshot(queue: queue, history: history, activeTask: activeTask))
                    encoding.record(outputBytes: data.count)
                    return data
                }
                guard data.count <= Self.maximumFileBytes else { throw PrivateRuntimeMetadata.Failure.size }
                try replaceAndFinalize(data, fileURL)
                span.record(outputBytes: data.count)
            }
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
    struct WorkCounts: Equatable {
        var sourceEntriesSorted = 0
        var sourceSorts = 0
        var dateComponentReads = 0
        var dayBoundaryReads = 0
        var groupedEntryAppends = 0
        var dayEntryBucketArraysCreated = 0
        var perDaySorts = 0
        var perDaySortedEntries = 0
    }

    private final class DayBuilder {
        let dayStart: Date
        var entries: [AgentTaskHistoryEntry] = []
        init(dayStart: Date) { self.dayStart = dayStart }
    }

    private final class MonthBuilder {
        let month: Int
        var dayBuilders: [Date: DayBuilder] = [:]
        var days: [DayBuilder] = []
        init(month: Int) { self.month = month }
    }

    private final class YearBuilder {
        let year: Int
        var monthBuilders: [Int: MonthBuilder] = [:]
        var months: [MonthBuilder] = []
        init(year: Int) { self.year = year }
    }

    static func years(
        from entries: [AgentTaskHistoryEntry],
        calendar: Calendar = .current
    ) -> [AgentTaskHistoryYearGroup] {
        var workCounts: WorkCounts?
        return buildYears(from: entries, calendar: calendar, workCounts: &workCounts)
    }

    /// Operation counts support deterministic allocation/work comparisons in
    /// offline tests. The normal history view passes no counter and stores none.
    static func measuredYears(
        from entries: [AgentTaskHistoryEntry],
        calendar: Calendar = .current
    ) -> (groups: [AgentTaskHistoryYearGroup], work: WorkCounts) {
        var work: WorkCounts? = WorkCounts()
        let groups = buildYears(from: entries, calendar: calendar, workCounts: &work)
        return (groups, work ?? WorkCounts())
    }

    private static func buildYears(
        from entries: [AgentTaskHistoryEntry],
        calendar: Calendar,
        workCounts: inout WorkCounts?
    ) -> [AgentTaskHistoryYearGroup] {
        let sorted = entries.enumerated().sorted { lhs, rhs in
            if lhs.element.finishedAt == rhs.element.finishedAt { return lhs.offset < rhs.offset }
            return lhs.element.finishedAt > rhs.element.finishedAt
        }
        workCounts?.sourceEntriesSorted = sorted.count
        workCounts?.sourceSorts = sorted.isEmpty ? 0 : 1

        var years: [YearBuilder] = []
        var yearBuilders: [Int: YearBuilder] = [:]
        for (_, entry) in sorted {
            let finishedAt = entry.finishedAt
            let components = calendar.dateComponents([.year, .month, .day], from: finishedAt)
            guard let year = components.year, let month = components.month else { continue }
            let dayStart = calendar.startOfDay(for: finishedAt)
            workCounts?.dateComponentReads += 1
            workCounts?.dayBoundaryReads += 1

            let yearBuilder: YearBuilder
            if let existing = yearBuilders[year] {
                yearBuilder = existing
            } else {
                let inserted = YearBuilder(year: year)
                let index = insertionIndex(in: years) { $0.year > year }
                years.insert(inserted, at: index)
                yearBuilders[year] = inserted
                yearBuilder = inserted
            }

            let monthBuilder: MonthBuilder
            if let existing = yearBuilder.monthBuilders[month] {
                monthBuilder = existing
            } else {
                let inserted = MonthBuilder(month: month)
                let index = insertionIndex(in: yearBuilder.months) { $0.month > month }
                yearBuilder.months.insert(inserted, at: index)
                yearBuilder.monthBuilders[month] = inserted
                monthBuilder = inserted
            }

            let dayBuilder: DayBuilder
            if let existing = monthBuilder.dayBuilders[dayStart] {
                dayBuilder = existing
            } else {
                let inserted = DayBuilder(dayStart: dayStart)
                let index = insertionIndex(in: monthBuilder.days) { $0.dayStart > dayStart }
                monthBuilder.days.insert(inserted, at: index)
                monthBuilder.dayBuilders[dayStart] = inserted
                dayBuilder = inserted
                workCounts?.dayEntryBucketArraysCreated += 1
            }
            dayBuilder.entries.append(entry)
            workCounts?.groupedEntryAppends += 1
        }

        return years.map { year in
            AgentTaskHistoryYearGroup(year: year.year, months: year.months.map { month in
                AgentTaskHistoryMonthGroup(year: year.year, month: month.month,
                    days: month.days.map { day in
                    AgentTaskHistoryDayGroup(dayStart: day.dayStart, entries: day.entries)
                })
            })
        }
    }

    /// Finds where a new descending key belongs. Existing groups are reused
    /// through their lookup dictionaries, so insertion is only done once per key.
    private static func insertionIndex<Element>(in values: [Element], before: (Element) -> Bool) -> Int {
        var lower = 0
        var upper = values.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if before(values[middle]) { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }
}
