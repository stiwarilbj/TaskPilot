import Foundation

struct QueuedAgentTask: Codable, Equatable, Identifiable {
    let id: UUID
    let request: String
    let queuedAt: Date

    init(
        id: UUID = UUID(),
        request: String,
        queuedAt: Date = Date()
    ) {
        self.id = id
        self.request = request
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
    let responseTitle: String
    let response: String
    let outcome: AgentTaskHistoryOutcome
    let startedAt: Date
    let finishedAt: Date
    let wasQueued: Bool

    init(
        id: UUID = UUID(),
        request: String,
        responseTitle: String,
        response: String,
        outcome: AgentTaskHistoryOutcome,
        startedAt: Date,
        finishedAt: Date = Date(),
        wasQueued: Bool
    ) {
        self.id = id
        self.request = request
        self.responseTitle = responseTitle
        self.response = response
        self.outcome = outcome
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.wasQueued = wasQueued
    }
}

struct AgentTaskLedgerSnapshot: Codable, Equatable {
    var queue: [QueuedAgentTask] = []
    var history: [AgentTaskHistoryEntry] = []
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
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return AgentTaskLedgerSnapshot()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(
            AgentTaskLedgerSnapshot.self,
            from: Data(contentsOf: fileURL)
        )
    }

    func save(
        queue: [QueuedAgentTask],
        history: [AgentTaskHistoryEntry]
    ) throws {
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

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            AgentTaskLedgerSnapshot(queue: queue, history: history)
        )
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: Self.filePermissions],
            ofItemAtPath: fileURL.path
        )
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
