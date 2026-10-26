import CryptoKit
import Darwin
import Foundation

/// Private crash barriers, not an execution log or evidence store. No payloads,
/// native replies, targets, or task text are encoded here. Every mutation is
/// first appended as an authenticated, fully synchronized frame. Snapshots are
/// compacted periodically and never authorize delivery by themselves.
final class ActionRecoveryJournal: @unchecked Sendable {
    enum Phase: String, Codable { case prepared, dispatched, terminal }
    enum Terminal: String, Codable { case confirmed, unconfirmed, rejected }
    struct Record: Codable, Equatable {
        let task: UUID
        let action: UUID
        let fingerprint: String
        var phase: Phase
        var terminal: Terminal?
    }
    private struct Authorization: Codable {
        let task: UUID
        let fingerprint: String
        var closed = false
        var compactedConfirmed = 0
        var compactedRejected = 0

        private enum CodingKeys: String, CodingKey {
            case task, fingerprint, closed, compactedConfirmed, compactedRejected
        }
        init(task: UUID, fingerprint: String, closed: Bool = false,
             compactedConfirmed: Int = 0, compactedRejected: Int = 0) {
            self.task = task; self.fingerprint = fingerprint; self.closed = closed
            self.compactedConfirmed = compactedConfirmed; self.compactedRejected = compactedRejected
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            task = try values.decode(UUID.self, forKey: .task)
            fingerprint = try values.decode(String.self, forKey: .fingerprint)
            closed = try values.decode(Bool.self, forKey: .closed)
            compactedConfirmed = try values.decodeIfPresent(Int.self, forKey: .compactedConfirmed) ?? 0
            compactedRejected = try values.decodeIfPresent(Int.self, forKey: .compactedRejected) ?? 0
        }
    }
    private struct Snapshot: Codable {
        var version = 2
        var sequence: UInt64 = 0
        var authorizations: [Authorization] = []
        var records: [Record] = []
        var lineage = Data()
        var lineageCount: UInt64 = 0
        // A v2 snapshot must carry all its framing fields. Version 1 is migrated
        // from the previous authenticated single-file format.
        var hasV2Fields = true

        private enum CodingKeys: String, CodingKey {
            case version, sequence, authorizations, records, lineage, lineageCount
        }
        init() { lineage = Data(repeating: 0, count: ActionRecoveryJournal.lineageBytes) }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            sequence = try values.decodeIfPresent(UInt64.self, forKey: .sequence) ?? 0
            authorizations = try values.decode([Authorization].self, forKey: .authorizations)
            records = try values.decode([Record].self, forKey: .records)
            let storedLineage = try values.decodeIfPresent(Data.self, forKey: .lineage) ?? Data()
            lineage = version == 2 ? try ActionRecoveryJournal.decodeLineage(storedLineage) : storedLineage
            lineageCount = try values.decodeIfPresent(UInt64.self, forKey: .lineageCount) ?? 0
            hasV2Fields = values.contains(.sequence) && values.contains(.lineage) && values.contains(.lineageCount)
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(version, forKey: .version)
            try values.encode(sequence, forKey: .sequence)
            try values.encode(authorizations, forKey: .authorizations)
            try values.encode(records, forKey: .records)
            try values.encode(ActionRecoveryJournal.encodeLineage(lineage), forKey: .lineage)
            try values.encode(lineageCount, forKey: .lineageCount)
        }
    }
    private struct Envelope: Codable { let data: Data; let authentication: Data }
    private enum EventKind: String, Codable { case register, prepare, transition, close, seal }
    private struct Event: Codable {
        let sequence: UInt64
        let kind: EventKind
        var authorization: Authorization? = nil
        var record: Record? = nil
        var task: UUID? = nil
        var action: UUID? = nil
        var phase: Phase? = nil
        var terminal: Terminal? = nil
    }
    private struct WALRead {
        var snapshot: Snapshot
        var validBytes: Int
        var frames: Int
        var hasIncompleteTail: Bool
    }
    struct Summary: Equatable {
        let prepared: Int
        let uncertain: Int
        let terminal: Int
        var count: Int {
            let (first, overflow1) = prepared.addingReportingOverflow(uncertain)
            let (total, overflow2) = first.addingReportingOverflow(terminal)
            return overflow1 || overflow2 ? Int.max : total
        }
    }
    enum Boundary { case prepared, dispatched, terminal }

    static let maximumRecords = 4096
    static let maximumTasks = 256
    static let maximumBytes = 4 * 1024 * 1024
    static let maximumWALBytes = 2 * 1024 * 1024
    private static let maximumRetainedTerminalRecords = 128
    private static let maximumEventBytes = 16 * 1024
    private static let compactionFrameInterval = 128
    private static let compactionByteThreshold = 128 * 1024
    private static let lineageBytes = 1024 * 1024
    private static let sparseLineageTag: UInt8 = 1
    private static let denseLineageTag: UInt8 = 0
    private static let lineageHashCount = 7
    private static let frameHeaderBytes = 4
    private static let frameAuthenticationBytes = 32

    static let unavailable = ActionReceiptStore.ReceiptError(code: "protocol_error",
        message: "The private action recovery journal is unavailable or inconsistent. TaskPilot stopped without repeating work; interrupted effects require inspection.")

    private let directory: URL
    private let key: SymmetricKey
    private let fileLock: Int32
    private let lock = NSLock()
    private var snapshot: Snapshot
    private var walByteCount = 0
    private var walFrameCount = 0
    private var failed = false
    // Offline crash/failure injection occurs only after the durable barrier.
    private let barrier: ((Boundary) throws -> Void)?

    static var defaultDirectory: URL {
        AgentTaskLedgerStore.defaultFileURL().deletingLastPathComponent()
            .appendingPathComponent("ActionRecovery", isDirectory: true)
    }

    init(directory: URL = ActionRecoveryJournal.defaultDirectory,
         barrier: ((Boundary) throws -> Void)? = nil) throws {
        self.directory = directory; self.barrier = barrier
        try PrivateDurableFile.prepareDirectory(directory)
        let fd = Darwin.open(directory.appendingPathComponent("owner.lock").path,
                             O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.unavailable }
        do {
            try PrivateDurableFile.validate(fd)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Self.unavailable }
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path)
                where name.hasPrefix(".recovery-") && name.hasSuffix(".tmp") &&
                      UUID(uuidString: String(name.dropFirst(10).dropLast(4))) != nil {
                guard unlink(directory.appendingPathComponent(name).path) == 0 else { throw Self.unavailable }
            }

            let keyURL = directory.appendingPathComponent("key")
            let journalURL = directory.appendingPathComponent("receipts.json")
            let walURL = directory.appendingPathComponent("receipts.wal")
            let bytes: Data
            let newKey: Bool
            if let existing = try PrivateDurableFile.read(keyURL, maximum: 32) {
                guard existing.count == 32 else { throw Self.unavailable }
                bytes = existing; newKey = false
            } else {
                // Losing a key must never make a snapshot or WAL look empty.
                guard try PrivateDurableFile.read(journalURL, maximum: Self.maximumBytes) == nil,
                      try PrivateDurableFile.read(walURL, maximum: Self.maximumWALBytes) == nil else {
                    throw Self.unavailable
                }
                bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                try PrivateDurableFile.replace(bytes, at: keyURL)
                newKey = true
            }
            let key = SymmetricKey(data: bytes)
            var stored: Snapshot
            let migrated: Bool
            if let data = try PrivateDurableFile.read(journalURL, maximum: Self.maximumBytes) {
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                guard HMAC<SHA256>.isValidAuthenticationCode(envelope.authentication,
                    authenticating: envelope.data, using: key) else { throw Self.unavailable }
                stored = try JSONDecoder().decode(Snapshot.self, from: envelope.data)
                switch stored.version {
                case 1:
                    // A prior release had no WAL. Do not combine a legacy
                    // snapshot with an unexplained journal file.
                    let legacyWAL = try PrivateDurableFile.read(walURL, maximum: Self.maximumWALBytes)
                    guard legacyWAL == nil || legacyWAL?.isEmpty == true else { throw Self.unavailable }
                    stored.version = 2; stored.sequence = 0
                    stored.lineage = Data(repeating: 0, count: Self.lineageBytes)
                    stored.lineageCount = 0; stored.hasV2Fields = true
                    migrated = true
                case 2:
                    guard stored.hasV2Fields else { throw Self.unavailable }
                    migrated = false
                default: throw Self.unavailable
                }
                guard Self.valid(stored) else { throw Self.unavailable }
            } else {
                // Missing files cannot silently reset receipt protection. Even
                // an interrupted first bootstrap fails closed on next startup.
                guard newKey else { throw Self.unavailable }
                stored = Snapshot(); migrated = true
            }

            let storedWAL = try PrivateDurableFile.read(walURL, maximum: Self.maximumWALBytes)
            if migrated {
                guard storedWAL == nil || storedWAL?.isEmpty == true else { throw Self.unavailable }
            } else {
                // A v2 snapshot is only a checkpoint. Its WAL file must remain
                // present even when empty, so removing it cannot silently hide
                // a durable transition written since the last checkpoint.
                guard storedWAL != nil else { throw Self.unavailable }
            }
            let walData = storedWAL ?? Data()
            guard stored.version == 2 else { throw Self.unavailable }
            let loaded = try Self.replay(walData, from: stored, key: key)
            if loaded.hasIncompleteTail {
                try PrivateDurableFile.replace(walData.prefix(loaded.validBytes), at: walURL)
            }
            if migrated {
                try PrivateDurableFile.replace(Data(), at: walURL)
                try Self.writeSnapshot(loaded.snapshot, key: key, directory: directory)
                self.walByteCount = 0; self.walFrameCount = 0
            } else {
                self.walByteCount = loaded.validBytes
                self.walFrameCount = loaded.frames
            }
            self.key = key; self.snapshot = loaded.snapshot; self.fileLock = fd
        } catch {
            flock(fd, LOCK_UN); Darwin.close(fd)
            throw Self.unavailable
        }
    }
    deinit { flock(fileLock, LOCK_UN); Darwin.close(fileLock) }

    func register(_ authorization: AgentTaskAuthorization) throws {
        lock.lock(); defer { lock.unlock() }
        guard !failed else { throw Self.unavailable }
        let fingerprint = authorizationFingerprint(authorization)
        if let old = snapshot.authorizations.first(where: { $0.task == authorization.id }) {
            guard old.fingerprint == fingerprint, !old.closed else { throw Self.unavailable }
            return
        }
        try append(Event(sequence: nextSequence(), kind: .register,
            authorization: Authorization(task: authorization.id, fingerprint: fingerprint)))
    }

    func matches(_ authorization: AgentTaskAuthorization) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !failed && snapshot.authorizations.contains {
            $0.task == authorization.id && !$0.closed && $0.fingerprint == authorizationFingerprint(authorization)
        }
    }

    private func authorizationFingerprint(_ authorization: AgentTaskAuthorization) -> String {
        let references = authorization.exactInputReferences ?? []
        guard !references.isEmpty else {
            return digest(Data(authorization.request.utf8), domain: "authorization:\(authorization.id)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = (try? encoder.encode(AgentTaskSubmission(request: authorization.request,
            exactInputReferences: references))) ?? Data()
        return digest(payload, domain: "authorization-v2:\(authorization.id)")
    }

    func prepare(task: UUID, action: String, payload: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard !failed, let action = UUID(uuidString: action),
              snapshot.authorizations.contains(where: { $0.task == task && !$0.closed }) else {
            throw Self.unavailable
        }
        // Exact recent records and the keyed Bloom lineage both reject an old
        // action ID. False positives only fail closed; no false negative can
        // restore replay authority after terminal compaction.
        guard !snapshot.records.contains(where: { $0.action == action }),
              !Self.lineageContains(action, in: snapshot.lineage, key: key) else {
            throw ActionReceiptStore.ReceiptError(code: "protocol_error", message:
                "This action belongs to an earlier controller invocation. Inspect its outcome through the original task; the journal cannot authorize replay or completion.")
        }
        let liveCount = snapshot.records.filter { !$0.isCompactableTerminal }.count
        guard liveCount < Self.maximumRecords else { throw Self.unavailable }
        let record = Record(task: task, action: action,
            fingerprint: digest(payload, domain: "action:\(task):\(action)"), phase: .prepared)
        try append(Event(sequence: nextSequence(), kind: .prepare, record: record), boundary: .prepared)
    }

    func transition(task: UUID, action: String, phase: Phase, terminal: Terminal? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard !failed, let action = UUID(uuidString: action),
              let old = snapshot.records.first(where: { $0.task == task && $0.action == action }) else {
            throw Self.unavailable
        }
        guard old.phase != .terminal, phase != .prepared,
              (phase == .terminal) == (terminal != nil) else { throw Self.unavailable }
        if old.phase == .dispatched && phase == .dispatched { return }
        let event = Event(sequence: try nextSequence(), kind: .transition,
            task: task, action: action, phase: phase, terminal: terminal)
        try append(event, boundary: phase == .dispatched ? .dispatched : .terminal)
    }

    func summary(task: UUID? = nil) -> Summary {
        lock.lock(); defer { lock.unlock() }
        let authorizations = snapshot.authorizations.filter { task == nil || $0.task == task }
        let records = snapshot.records.filter { task == nil || $0.task == task }
        let compactedTerminal = authorizations.reduce(0) { $0 + $1.compactedConfirmed + $1.compactedRejected }
        return Summary(prepared: records.filter { $0.phase == .prepared }.count,
                       uncertain: records.filter { $0.phase == .dispatched || $0.terminal == .unconfirmed }.count,
                       terminal: compactedTerminal + records.filter { $0.phase == .terminal && $0.terminal != .unconfirmed }.count)
    }

    /// Called only after owned work drains. Never erase unresolved effects.
    func close(task: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard !failed else { throw Self.unavailable }
        guard snapshot.authorizations.contains(where: { $0.task == task }) else { return }
        try append(Event(sequence: nextSequence(), kind: .close, task: task))
    }

    /// Startup holds the exclusive controller lock. Orphaned authorizations
    /// cannot remain executable or consume the bounded task table forever.
    func sealAfterRestart() throws {
        lock.lock(); defer { lock.unlock() }
        guard !failed else { throw Self.unavailable }
        guard snapshot.authorizations.contains(where: { !$0.closed }) else { return }
        try append(Event(sequence: nextSequence(), kind: .seal))
    }

    private func nextSequence() throws -> UInt64 {
        let (value, overflow) = snapshot.sequence.addingReportingOverflow(1)
        guard !overflow else { throw Self.unavailable }
        return value
    }

    /// Append first, publish in-memory state second. Each returned prepared or
    /// dispatched barrier has reached full file and directory synchronization.
    private func append(_ event: Event, boundary: Boundary? = nil) throws {
        guard !failed else { throw Self.unavailable }
        var next = snapshot
        do { try Self.apply(event, to: &next, key: key) }
        catch { throw Self.unavailable }
        let payload: Data
        do { payload = try JSONEncoder().encode(event) }
        catch { throw Self.unavailable }
        guard payload.count <= Self.maximumEventBytes else { throw Self.unavailable }
        let frame = Self.frame(payload, key: key)
        if walByteCount + frame.count > Self.maximumWALBytes {
            do { try compactJournal() } catch { throw Self.unavailable }
        }
        guard walByteCount + frame.count <= Self.maximumWALBytes else { throw Self.unavailable }
        do {
            try PrivateDurableFile.append(frame, at: directory.appendingPathComponent("receipts.wal"),
                                          maximum: Self.maximumWALBytes)
        } catch {
            // A failed append may have left a complete but unacknowledged frame.
            // Stop this controller; startup will validate or discard its tail.
            failed = true
            throw Self.unavailable
        }
        snapshot = next
        walByteCount += frame.count; walFrameCount += 1
        if walFrameCount >= Self.compactionFrameInterval || walByteCount >= Self.compactionByteThreshold {
            // The already synchronized WAL is authoritative. A compaction
            // failure cannot turn a durable transition into a failed barrier.
            try? compactJournal()
        }
        if let boundary { try cross(boundary) }
    }

    private func compactJournal() throws {
        try Self.writeSnapshot(snapshot, key: key, directory: directory)
        try PrivateDurableFile.replace(Data(), at: directory.appendingPathComponent("receipts.wal"))
        walByteCount = 0; walFrameCount = 0
    }

    private func digest(_ bytes: Data, domain: String) -> String {
        var input = Data(("TaskPilot recovery v1\0" + domain + "\0").utf8); input.append(bytes)
        return HMAC<SHA256>.authenticationCode(for: input, using: key).map { String(format: "%02x", $0) }.joined()
    }
    private func cross(_ boundary: Boundary) throws {
        do { try barrier?(boundary) } catch { failed = true; throw Self.unavailable }
    }

    private static func valid(_ snapshot: Snapshot) -> Bool {
        let authorizationIDs = Set(snapshot.authorizations.map(\.task))
        guard snapshot.version == 2, snapshot.lineage.count == lineageBytes,
              snapshot.authorizations.count <= maximumTasks,
              snapshot.records.count <= maximumRecords + maximumRetainedTerminalRecords,
              authorizationIDs.count == snapshot.authorizations.count,
              Set(snapshot.records.map(\.action)).count == snapshot.records.count,
              snapshot.authorizations.allSatisfy({ $0.fingerprint.count == 64 && $0.compactedConfirmed >= 0 && $0.compactedRejected >= 0 }),
              snapshot.records.allSatisfy({ authorizationIDs.contains($0.task) &&
                  ($0.phase == .terminal) == ($0.terminal != nil) && $0.fingerprint.count == 64 }) else { return false }
        return snapshot.records.filter { !$0.isCompactableTerminal }.count <= maximumRecords
    }

    private static func apply(_ event: Event, to snapshot: inout Snapshot, key: SymmetricKey) throws {
        guard event.sequence == snapshot.sequence + 1 else { throw Self.unavailable }
        switch event.kind {
        case .register:
            guard let authorization = event.authorization, event.record == nil,
                  event.task == nil, event.action == nil, event.phase == nil, event.terminal == nil,
                  !snapshot.authorizations.contains(where: { $0.task == authorization.task }),
                  authorization.fingerprint.count == 64 else { throw Self.unavailable }
            compactTerminals(&snapshot, key: key)
            pruneRetiredAuthorizations(&snapshot, reserving: true, key: key)
            guard snapshot.authorizations.count < maximumTasks else { throw Self.unavailable }
            snapshot.authorizations.append(authorization)
        case .prepare:
            guard let record = event.record, event.authorization == nil, event.task == nil,
                  event.action == nil, event.phase == nil, event.terminal == nil,
                  record.phase == .prepared, record.terminal == nil, record.fingerprint.count == 64,
                  snapshot.authorizations.contains(where: { $0.task == record.task && !$0.closed }),
                  !snapshot.records.contains(where: { $0.action == record.action }),
                  !lineageContains(record.action, in: snapshot.lineage, key: key),
                  snapshot.records.filter({ !$0.isCompactableTerminal }).count < maximumRecords else { throw Self.unavailable }
            snapshot.records.append(record)
        case .transition:
            guard event.authorization == nil, event.record == nil, let task = event.task,
                  let action = event.action, let phase = event.phase, phase != .prepared,
                  let index = snapshot.records.firstIndex(where: { $0.task == task && $0.action == action }),
                  snapshot.records[index].phase != .terminal,
                  (phase == .terminal) == (event.terminal != nil),
                  !(snapshot.records[index].phase == .dispatched && phase == .dispatched) else { throw Self.unavailable }
            snapshot.records[index].phase = phase
            snapshot.records[index].terminal = event.terminal
        case .close:
            guard event.authorization == nil, event.record == nil, let task = event.task,
                  event.action == nil, event.phase == nil, event.terminal == nil,
                  let authIndex = snapshot.authorizations.firstIndex(where: { $0.task == task }) else { throw Self.unavailable }
            snapshot.authorizations[authIndex].closed = true
            for index in snapshot.records.indices where snapshot.records[index].task == task && snapshot.records[index].phase == .prepared {
                snapshot.records[index].phase = .terminal; snapshot.records[index].terminal = .rejected
            }
        case .seal:
            guard event.authorization == nil, event.record == nil, event.task == nil,
                  event.action == nil, event.phase == nil, event.terminal == nil else { throw Self.unavailable }
            for index in snapshot.authorizations.indices { snapshot.authorizations[index].closed = true }
            for index in snapshot.records.indices where snapshot.records[index].phase == .prepared {
                snapshot.records[index].phase = .terminal; snapshot.records[index].terminal = .rejected
            }
        }
        snapshot.sequence = event.sequence
        compactTerminals(&snapshot, key: key)
        guard valid(snapshot) else { throw Self.unavailable }
    }

    private static func compactTerminals(_ snapshot: inout Snapshot, key: SymmetricKey) {
        let safe = snapshot.records.filter(\.isCompactableTerminal)
        guard safe.count > maximumRetainedTerminalRecords else { return }
        let removed = Set(safe.prefix(safe.count - maximumRetainedTerminalRecords).map(\.action))
        for record in snapshot.records where removed.contains(record.action) {
            addLineage(record.action, to: &snapshot.lineage, count: &snapshot.lineageCount, key: key)
            guard let index = snapshot.authorizations.firstIndex(where: { $0.task == record.task }) else { continue }
            if record.terminal == .confirmed {
                snapshot.authorizations[index].compactedConfirmed = increment(snapshot.authorizations[index].compactedConfirmed)
            } else {
                snapshot.authorizations[index].compactedRejected = increment(snapshot.authorizations[index].compactedRejected)
            }
        }
        snapshot.records.removeAll { removed.contains($0.action) }
    }

    private static func pruneRetiredAuthorizations(_ snapshot: inout Snapshot, reserving: Bool, key: SymmetricKey) {
        while reserving && snapshot.authorizations.count >= maximumTasks {
            guard let index = snapshot.authorizations.firstIndex(where: { authorization in
                authorization.closed && snapshot.records.filter { $0.task == authorization.task }
                    .allSatisfy(\.isCompactableTerminal)
            }) else { return }
            let task = snapshot.authorizations[index].task
            let records = snapshot.records.filter { $0.task == task }
            for record in records {
                addLineage(record.action, to: &snapshot.lineage, count: &snapshot.lineageCount, key: key)
                if record.terminal == .confirmed {
                    snapshot.authorizations[index].compactedConfirmed = increment(snapshot.authorizations[index].compactedConfirmed)
                } else {
                    snapshot.authorizations[index].compactedRejected = increment(snapshot.authorizations[index].compactedRejected)
                }
            }
            snapshot.records.removeAll { $0.task == task }
            snapshot.authorizations.remove(at: index)
        }
    }

    private static func increment(_ value: Int) -> Int { value == Int.max ? value : value + 1 }

    private static func lineageIndices(_ action: UUID, key: SymmetricKey) -> [Int] {
        let input = Data(("TaskPilot receipt lineage v1\0" + action.uuidString.lowercased()).utf8)
        let bytes = Array(HMAC<SHA256>.authenticationCode(for: input, using: key))
        func word(_ offset: Int) -> UInt64 {
            bytes[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        let first = word(0), stride = word(8) | 1
        let bitCount = UInt64(lineageBytes * 8)
        return (0..<lineageHashCount).map { Int((first &+ UInt64($0) &* stride) % bitCount) }
    }
    private static func lineageContains(_ action: UUID, in bits: Data, key: SymmetricKey) -> Bool {
        guard bits.count == lineageBytes else { return false }
        return lineageIndices(action, key: key).allSatisfy { index in
            bits[index >> 3] & UInt8(1 << (index & 7)) != 0
        }
    }
    private static func addLineage(_ action: UUID, to bits: inout Data, count: inout UInt64, key: SymmetricKey) {
        guard bits.count == lineageBytes else { return }
        for index in lineageIndices(action, key: key) { bits[index >> 3] |= UInt8(1 << (index & 7)) }
        if count < UInt64.max { count += 1 }
    }

    /// Sparse, sorted nonzero runs keep a fresh/low-volume Bloom filter small;
    /// dense filters switch to a fixed-size byte representation. Both forms
    /// decode to the same bounded bitset used for membership checks.
    private static func encodeLineage(_ bits: Data) -> Data {
        guard bits.count == lineageBytes else { return Data() }
        var sparse = Data([sparseLineageTag])
        var index = 0
        while index < bits.count {
            while index < bits.count && bits[index] == 0 { index += 1 }
            guard index < bits.count else { break }
            let start = index
            while index < bits.count && bits[index] != 0 { index += 1 }
            appendUInt32(UInt32(start), to: &sparse)
            appendUInt32(UInt32(index - start), to: &sparse)
            sparse.append(bits[start..<index])
        }
        guard sparse.count < lineageBytes + 1 else { return Data([denseLineageTag]) + bits }
        return sparse
    }

    private static func decodeLineage(_ encoded: Data) throws -> Data {
        guard let tag = encoded.first else { throw Self.unavailable }
        if tag == denseLineageTag {
            guard encoded.count == lineageBytes + 1 else { throw Self.unavailable }
            return Data(encoded.dropFirst())
        }
        guard tag == sparseLineageTag else { throw Self.unavailable }
        var bits = Data(repeating: 0, count: lineageBytes)
        var offset = 1, previousEnd = 0
        while offset < encoded.count {
            guard encoded.count - offset >= 8 else { throw Self.unavailable }
            let start = Int(readUInt32(encoded, at: offset)); offset += 4
            let length = Int(readUInt32(encoded, at: offset)); offset += 4
            guard length > 0, start >= previousEnd, start <= lineageBytes,
                  length <= lineageBytes - start, encoded.count - offset >= length else {
                throw Self.unavailable
            }
            let end = start + length
            for byte in encoded[offset..<(offset + length)] where byte == 0 { throw Self.unavailable }
            bits.replaceSubrange(start..<end, with: encoded[offset..<(offset + length)])
            previousEnd = end; offset += length
        }
        return bits
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func frame(_ payload: Data, key: SymmetricKey) -> Data {
        let length = UInt32(payload.count).bigEndian
        var result = withUnsafeBytes(of: length) { Data($0) }
        let authenticated = Data("TaskPilot action journal WAL v1\0".utf8) + payload
        result.append(Data(HMAC<SHA256>.authenticationCode(for: authenticated, using: key)))
        result.append(payload)
        return result
    }

    private static func replay(_ data: Data, from initial: Snapshot, key: SymmetricKey) throws -> WALRead {
        var state = initial
        var offset = 0, frameCount = 0, incomplete = false
        var expected = state.sequence == UInt64.max ? UInt64.max : state.sequence + 1
        while offset < data.count {
            let frameStart = offset
            guard data.count - offset >= frameHeaderBytes else { incomplete = true; break }
            let length = data[offset..<(offset + frameHeaderBytes)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, length <= maximumEventBytes else { throw Self.unavailable }
            offset += frameHeaderBytes
            let required = frameAuthenticationBytes + Int(length)
            guard data.count - offset >= required else { incomplete = true; offset = frameStart; break }
            let authentication = data[offset..<(offset + frameAuthenticationBytes)]
            offset += frameAuthenticationBytes
            let payload = data[offset..<(offset + Int(length))]
            offset += Int(length); frameCount += 1
            let authenticated = Data("TaskPilot action journal WAL v1\0".utf8) + payload
            guard HMAC<SHA256>.isValidAuthenticationCode(Data(authentication), authenticating: authenticated, using: key) else {
                throw Self.unavailable
            }
            let event = try JSONDecoder().decode(Event.self, from: Data(payload))
            if event.sequence <= initial.sequence { continue }
            guard event.sequence == expected else { throw Self.unavailable }
            try apply(event, to: &state, key: key)
            guard expected < UInt64.max else { throw Self.unavailable }
            expected += 1
        }
        return WALRead(snapshot: state, validBytes: incomplete ? offset : data.count,
                       frames: frameCount, hasIncompleteTail: incomplete)
    }

    private static func writeSnapshot(_ snapshot: Snapshot, key: SymmetricKey, directory: URL) throws {
        guard valid(snapshot) else { throw Self.unavailable }
        let bytes = try JSONEncoder().encode(snapshot)
        let authentication = Data(HMAC<SHA256>.authenticationCode(for: bytes, using: key))
        let data = try JSONEncoder().encode(Envelope(data: bytes, authentication: authentication))
        guard data.count <= maximumBytes else { throw Self.unavailable }
        try PrivateDurableFile.replace(data, at: directory.appendingPathComponent("receipts.json"))
    }
}

private extension ActionRecoveryJournal.Record {
    var isCompactableTerminal: Bool {
        phase == .terminal && (terminal == .confirmed || terminal == .rejected)
    }
}

/// Write, synchronize, rename, synchronize directory. Private from creation,
/// including temporary files; symlinks and nonregular/hardlinked files reject.
enum PrivateDurableFile {
    static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ActionRecoveryJournal.unavailable }
        defer { Darwin.close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_uid == getuid(), fchmod(fd, 0o700) == 0 else { throw ActionRecoveryJournal.unavailable }
    }
    static func validate(_ fd: Int32) throws {
        var status = stat()
        guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(), status.st_nlink == 1, fchmod(fd, 0o600) == 0 else { throw ActionRecoveryJournal.unavailable }
    }
    static func read(_ url: URL, maximum: Int) throws -> Data? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw ActionRecoveryJournal.unavailable }
        defer { Darwin.close(fd) }
        try validate(fd)
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_size <= maximum else { throw ActionRecoveryJournal.unavailable }
        let bytes = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: maximum + 1) ?? Data()
        guard bytes.count <= maximum else { throw ActionRecoveryJournal.unavailable }
        return bytes
    }
    static func append(_ data: Data, at url: URL, maximum: Int) throws {
        let directory = Darwin.open(url.deletingLastPathComponent().path,
                                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ActionRecoveryJournal.unavailable }
        defer { Darwin.close(directory) }
        let fd = openat(directory, url.lastPathComponent,
                        O_CREAT | O_APPEND | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ActionRecoveryJournal.unavailable }
        defer { Darwin.close(fd) }
        try validate(fd)
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_size >= 0,
              status.st_size <= maximum, data.count <= maximum - Int(status.st_size) else {
            throw ActionRecoveryJournal.unavailable
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ActionRecoveryJournal.unavailable }
                offset += count
            }
        }
        if fcntl(fd, F_FULLFSYNC) != 0 {
            guard errno == ENOTSUP || errno == EINVAL, fsync(fd) == 0 else { throw ActionRecoveryJournal.unavailable }
        }
        guard fsync(directory) == 0 else { throw ActionRecoveryJournal.unavailable }
    }
    static func replace(_ data: Data, at url: URL) throws {
        try prepareDirectory(url.deletingLastPathComponent())
        let directory = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ActionRecoveryJournal.unavailable }
        defer { Darwin.close(directory) }
        let name = ".recovery-\(UUID().uuidString).tmp"
        let fd = openat(directory, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ActionRecoveryJournal.unavailable }
        defer { Darwin.close(fd); unlinkat(directory, name, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ActionRecoveryJournal.unavailable }
                offset += count
            }
        }
        if fcntl(fd, F_FULLFSYNC) != 0 {
            guard errno == ENOTSUP || errno == EINVAL, fsync(fd) == 0 else { throw ActionRecoveryJournal.unavailable }
        }
        guard renameat(directory, name, directory, url.lastPathComponent) == 0,
              fsync(directory) == 0 else { throw ActionRecoveryJournal.unavailable }
    }
}
