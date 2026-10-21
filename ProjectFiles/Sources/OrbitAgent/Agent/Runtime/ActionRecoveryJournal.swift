import CryptoKit
import Darwin
import Foundation

/// Private crash barriers, not an execution log or evidence store. No payloads,
/// native replies, targets, or task text are encoded here.
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
    }
    private struct Snapshot: Codable {
        var version = 1
        var authorizations: [Authorization] = []
        var records: [Record] = []
    }
    private struct Envelope: Codable { let data: Data; let authentication: Data }
    struct Summary: Equatable {
        let prepared: Int
        let uncertain: Int
        let terminal: Int
        var count: Int { prepared + uncertain + terminal }
    }
    enum Boundary { case prepared, dispatched, terminal }
    static let maximumRecords = 4096
    static let maximumTasks = 256
    static let maximumBytes = 2 * 1024 * 1024
    static let unavailable = ActionReceiptStore.ReceiptError(code: "protocol_error",
        message: "The private action recovery journal is unavailable or inconsistent. TaskPilot stopped without repeating work; interrupted effects require inspection.")

    private let directory: URL
    private let key: SymmetricKey
    private let fileLock: Int32
    private let lock = NSLock()
    private var snapshot: Snapshot
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
            // Only this controller can be writing here. Interrupted atomic
            // writes never become records and must not accumulate on disk.
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path)
                where name.hasPrefix(".recovery-") && name.hasSuffix(".tmp") &&
                      UUID(uuidString: String(name.dropFirst(10).dropLast(4))) != nil {
                guard unlink(directory.appendingPathComponent(name).path) == 0 else { throw Self.unavailable }
            }
            let keyURL = directory.appendingPathComponent("key")
            let journalURL = directory.appendingPathComponent("receipts.json")
            let bytes: Data
            let newKey: Bool
            if let existing = try PrivateDurableFile.read(keyURL, maximum: 32) {
                guard existing.count == 32 else { throw Self.unavailable }
                bytes = existing
                newKey = false
            } else {
                // Losing a key must never make an old journal look empty.
                guard try PrivateDurableFile.read(journalURL, maximum: Self.maximumBytes) == nil else { throw Self.unavailable }
                bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                try PrivateDurableFile.replace(bytes, at: keyURL)
                newKey = true
            }
            let key = SymmetricKey(data: bytes)
            let stored: Snapshot
            if let data = try PrivateDurableFile.read(journalURL, maximum: Self.maximumBytes) {
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                guard HMAC<SHA256>.isValidAuthenticationCode(envelope.authentication, authenticating: envelope.data, using: key) else { throw Self.unavailable }
                stored = try JSONDecoder().decode(Snapshot.self, from: envelope.data)
                guard stored.version == 1, stored.records.count <= Self.maximumRecords,
                      stored.authorizations.count <= Self.maximumTasks,
                      Set(stored.authorizations.map(\.task)).count == stored.authorizations.count,
                      Set(stored.records.map(\.action)).count == stored.records.count,
                      stored.records.allSatisfy({ record in
                          stored.authorizations.contains { $0.task == record.task } &&
                          (record.phase == .terminal) == (record.terminal != nil) && record.fingerprint.count == 64
                      }) else { throw Self.unavailable }
            } else {
                // Missing files cannot silently reset receipt protection. Even
                // an interrupted first bootstrap fails closed on next startup.
                guard newKey else { throw Self.unavailable }
                stored = Snapshot()
                let data = try JSONEncoder().encode(stored)
                try PrivateDurableFile.replace(try JSONEncoder().encode(Envelope(data: data,
                    authentication: Data(HMAC<SHA256>.authenticationCode(for: data, using: key)))), at: journalURL)
            }
            self.key = key; self.snapshot = stored; self.fileLock = fd
        } catch {
            Darwin.close(fd)
            throw Self.unavailable
        }
    }
    deinit { flock(fileLock, LOCK_UN); Darwin.close(fileLock) }

    func register(_ authorization: AgentTaskAuthorization) throws {
        lock.lock(); defer { lock.unlock() }
        guard !failed else { throw Self.unavailable }
        let fingerprint = digest(Data(authorization.request.utf8), domain: "authorization:\(authorization.id)")
        if let old = snapshot.authorizations.first(where: { $0.task == authorization.id }) {
            guard old.fingerprint == fingerprint, !old.closed else { throw Self.unavailable }
            return
        }
        var next = snapshot
        compact(&next, reservingTask: true)
        guard next.authorizations.count < Self.maximumTasks else { throw Self.unavailable }
        next.authorizations.append(Authorization(task: authorization.id, fingerprint: fingerprint))
        try persist(next)
    }

    func matches(_ authorization: AgentTaskAuthorization) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !failed && snapshot.authorizations.contains {
            $0.task == authorization.id && $0.fingerprint == digest(Data(authorization.request.utf8), domain: "authorization:\(authorization.id)")
        }
    }

    func prepare(task: UUID, action: String, payload: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard let action = UUID(uuidString: action), snapshot.authorizations.contains(where: { $0.task == task && !$0.closed }) else { throw Self.unavailable }
        // Even a restored terminal record is not a native response or proof.
        // No restored ID can obtain a token capable of delivering side effects.
        guard !snapshot.records.contains(where: { $0.action == action }) else {
            throw ActionReceiptStore.ReceiptError(code: "protocol_error", message:
                "This action belongs to an earlier controller invocation. Inspect its outcome through the original task; the journal cannot authorize replay or completion.")
        }
        var next = snapshot
        compact(&next, reservingRecord: true)
        guard next.records.count < Self.maximumRecords else { throw Self.unavailable }
        next.records.append(Record(task: task, action: action,
            fingerprint: digest(payload, domain: "action:\(task):\(action)"), phase: .prepared))
        try persist(next)
        try cross(.prepared)
    }

    func transition(task: UUID, action: String, phase: Phase, terminal: Terminal? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard !failed else { throw Self.unavailable }
        guard let action = UUID(uuidString: action), let index = snapshot.records.firstIndex(where: { $0.task == task && $0.action == action }) else { throw Self.unavailable }
        let old = snapshot.records[index]
        guard old.phase != .terminal, phase != .prepared, (phase == .terminal) == (terminal != nil) else { throw Self.unavailable }
        if old.phase == .dispatched && phase == .dispatched { return }
        var next = snapshot
        next.records[index].phase = phase; next.records[index].terminal = terminal
        try persist(next)
        try cross(phase == .dispatched ? .dispatched : .terminal)
    }

    func summary(task: UUID? = nil) -> Summary {
        lock.lock(); defer { lock.unlock() }
        let records = snapshot.records.filter { task == nil || $0.task == task }
        return Summary(prepared: records.filter { $0.phase == .prepared }.count,
                       uncertain: records.filter { $0.phase == .dispatched || $0.terminal == .unconfirmed }.count,
                       terminal: records.filter { $0.phase == .terminal && $0.terminal != .unconfirmed }.count)
    }

    /// Called only after owned work drains. Never erase unresolved effects.
    func close(task: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var next = snapshot
        guard let index = next.authorizations.firstIndex(where: { $0.task == task }) else { return }
        next.authorizations[index].closed = true
        for index in next.records.indices where next.records[index].task == task && next.records[index].phase == .prepared {
            next.records[index].phase = .terminal; next.records[index].terminal = .rejected
        }
        compact(&next)
        try persist(next)
    }

    /// Startup holds the exclusive controller lock. Orphaned authorizations
    /// (including a crash between registration and ledger save) cannot remain
    /// executable or consume the bounded task table forever.
    func sealAfterRestart() throws {
        lock.lock(); defer { lock.unlock() }
        guard snapshot.authorizations.contains(where: { !$0.closed }) else { return }
        var next = snapshot
        for index in next.authorizations.indices { next.authorizations[index].closed = true }
        for index in next.records.indices where next.records[index].phase == .prepared {
            next.records[index].phase = .terminal; next.records[index].terminal = .rejected
        }
        compact(&next)
        try persist(next)
    }

    private func compact(_ next: inout Snapshot, reservingTask: Bool = false, reservingRecord: Bool = false) {
        let closed = Set(next.authorizations.filter(\.closed).map(\.task))
        let disposable = next.records.filter { closed.contains($0.task) && $0.phase == .terminal && $0.terminal != .unconfirmed }
        let remove = Set(disposable.dropLast(128).map(\.action))
        next.records.removeAll { remove.contains($0.action) }
        let tasks = Set(next.records.map(\.task))
        next.authorizations.removeAll { $0.closed && !tasks.contains($0.task) }
        // Recent terminal metadata is disposable too when capacity is needed.
        // Never evict current-task records or any uncertain effect.
        while (reservingTask && next.authorizations.count >= Self.maximumTasks) ||
              (reservingRecord && next.records.count >= Self.maximumRecords) {
            guard let index = next.records.firstIndex(where: {
                closed.contains($0.task) && $0.phase == .terminal && $0.terminal != .unconfirmed
            }) else { break }
            let task = next.records.remove(at: index).task
            if !next.records.contains(where: { $0.task == task }) {
                next.authorizations.removeAll { $0.task == task }
            }
        }
    }
    private func digest(_ bytes: Data, domain: String) -> String {
        var input = Data(("TaskPilot recovery v1\0" + domain + "\0").utf8); input.append(bytes)
        return HMAC<SHA256>.authenticationCode(for: input, using: key).map { String(format: "%02x", $0) }.joined()
    }
    private func cross(_ boundary: Boundary) throws {
        do { try barrier?(boundary) } catch { failed = true; throw Self.unavailable }
    }
    private func persist(_ next: Snapshot) throws {
        guard !failed else { throw Self.unavailable }
        do {
            let bytes = try JSONEncoder().encode(next)
            let authentication = Data(HMAC<SHA256>.authenticationCode(for: bytes, using: key))
            let data = try JSONEncoder().encode(Envelope(data: bytes, authentication: authentication))
            guard data.count <= Self.maximumBytes else { throw Self.unavailable }
            try PrivateDurableFile.replace(data, at: directory.appendingPathComponent("receipts.json"))
            snapshot = next
        } catch { failed = true; throw Self.unavailable }
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
        // Full synchronization on macOS includes the drive's write cache.
        if fcntl(fd, F_FULLFSYNC) != 0 {
            guard errno == ENOTSUP || errno == EINVAL, fsync(fd) == 0 else { throw ActionRecoveryJournal.unavailable }
        }
        guard renameat(directory, name, directory, url.lastPathComponent) == 0,
              fsync(directory) == 0 else { throw ActionRecoveryJournal.unavailable }
    }
}
