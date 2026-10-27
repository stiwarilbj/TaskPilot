import Darwin
import Foundation
import ProcessSupport

/// Narrow checks for explicitly known TaskPilot directories, never recursive.
enum PrivateDirectoryPermissions {
    enum Failure: String, LocalizedError {
        case ownership = "private_directory_ownership"
        case symlink = "private_directory_symlink"
        case permissions = "private_directory_permissions"
        case acl = "private_directory_acl"
        case flags = "private_directory_flags"
        case changed = "private_directory_changed"
        case unavailable = "private_directory_unavailable"
        var errorDescription: String? {
            "\(rawValue): TaskPilot’s private storage needs attention. Verify its ownership and permissions; unrelated directories were not changed."
        }
    }
    private static let repairLock = NSLock()
    static func check(_ directory: URL, repair: Bool = false) throws {
        try repairLock.withLock {
            var before = stat()
            guard lstat(directory.path, &before) == 0 else { throw Failure.unavailable }
            guard (before.st_mode & S_IFMT) != S_IFLNK else { throw Failure.symlink }
            guard (before.st_mode & S_IFMT) == S_IFDIR else { throw Failure.unavailable }
            guard before.st_uid == getuid() else { throw Failure.ownership }
            let fd = open(directory.path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw (errno == EACCES || errno == EPERM) ? Failure.permissions : Failure.unavailable }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_dev == before.st_dev, opened.st_ino == before.st_ino,
                  opened.st_uid == getuid() else { throw Failure.changed }
            let permittedFlags = UInt32(UF_HIDDEN | UF_NODUMP)
            if UInt32(opened.st_flags) & ~permittedFlags != 0 { throw Failure.flags }
            let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED)
            if let extendedACL = acl {
                defer { acl_free(UnsafeMutableRawPointer(extendedACL)) }
                var entry: acl_entry_t?
                var result = acl_get_entry(extendedACL, 0, &entry)
                var entryCount = 0
                while result == 0 {
                    entryCount += 1
                    guard entryCount <= 169 else { throw Failure.acl }
                    result = acl_get_entry(extendedACL, -1, &entry)
                }
                guard errno == EINVAL else { throw Failure.acl }
                guard entryCount == 0 else { throw Failure.acl }
            } else if errno != ENOENT {
                throw Failure.acl
            }
            if opened.st_mode & 0o7777 != 0o700 {
                guard repair else { throw Failure.permissions }
                guard fchmod(fd, 0o700) == 0 else { throw Failure.permissions }
            }
            var after = stat(), named = stat()
            guard fstat(fd, &after) == 0, lstat(directory.path, &named) == 0,
                  named.st_dev == after.st_dev, named.st_ino == after.st_ino,
                  (named.st_mode & S_IFMT) == S_IFDIR, after.st_uid == getuid(), named.st_uid == getuid(),
                  after.st_mode & 0o7777 == 0o700, named.st_mode & 0o7777 == 0o700 else { throw Failure.changed }
        }
    }
}

/// Private directories for task-owned runtime scratch only. User-selected output
/// destinations never enter this root or its cleanup path.
enum TaskTemporaryResourceLedger {
    static let directoryName = "TaskScratch"
    static let ownerFileName = ".owner-lease"
    static let directoryPermissions: mode_t = 0o700
    static let filePermissions: mode_t = 0o600
    private static let maximumOwnerBytes = 4_096

    private struct OwnerRecord: Codable {
        let version: Int
        let directoryID: String
        let leaseID: String
        let processID: Int32
        let processStartSeconds: UInt64
        let processStartMicroseconds: UInt64
        var captureDirectory: DirectoryIdentity? = nil
    }

    fileprivate struct DirectoryIdentity: Codable, Equatable {
        let device: Int32
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanoseconds: Int64
        init(_ status: stat) {
            device = status.st_dev; inode = status.st_ino
            birthSeconds = Int64(status.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(status.st_birthtimespec.tv_nsec)
        }
    }

    static var defaultRoot: URL {
        GeminiAPIKeyStore.defaultFileURL().deletingLastPathComponent()
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func makeLease(root: URL = defaultRoot, descriptorOwner: BackendDescriptors.Owner? = TaskOwnership.current?.descriptorOwner) throws -> TaskTemporaryResourceLease {
        let rootDescriptor = try openRoot(root, create: true)
        defer { close(rootDescriptor) }

        var process = TPProcessIdentity()
        guard tp_process_identity(getpid(), &process) == 1,
              process.pid == getpid(), process.zombie == 0 else {
            throw TaskTemporaryResourceError.ownerIdentityUnavailable
        }

        let directoryID = UUID().uuidString.lowercased()
        let leaseID = UUID().uuidString.lowercased()
        let directory = root.appendingPathComponent(directoryID, isDirectory: true)
        guard mkdirat(rootDescriptor, directoryID, directoryPermissions) == 0 else {
            throw TaskTemporaryResourceError.unavailable
        }

        var directoryDescriptor: Int32 = -1
        var leaseDescriptor: Int32 = -1
        var transferredLease = false
        defer {
            if leaseDescriptor >= 0 && !transferredLease {
                flock(leaseDescriptor, LOCK_UN)
                close(leaseDescriptor)
            }
            if !transferredLease, directoryDescriptor >= 0 {
                var opened = stat(), current = stat()
                if fstat(directoryDescriptor, &opened) == 0,
                   fstatat(rootDescriptor, directoryID, &current, AT_SYMLINK_NOFOLLOW) == 0,
                   DirectoryIdentity(opened) == DirectoryIdentity(current),
                   removeContents(directoryDescriptor, preserving: nil) {
                    _ = unlinkat(rootDescriptor, directoryID, AT_REMOVEDIR)
                }
                close(directoryDescriptor)
            }
        }

        directoryDescriptor = openat(rootDescriptor, directoryID,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw TaskTemporaryResourceError.unavailable }
        try validatePrivateDirectory(directoryDescriptor)
        var directoryStatus = stat()
        guard fstat(directoryDescriptor, &directoryStatus) == 0 else { throw TaskTemporaryResourceError.unavailable }

        leaseDescriptor = openat(directoryDescriptor, ownerFileName,
            O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, filePermissions)
        guard leaseDescriptor >= 0 else { throw TaskTemporaryResourceError.unavailable }
        try validatePrivateFile(leaseDescriptor, maximumBytes: maximumOwnerBytes)
        guard flock(leaseDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw TaskTemporaryResourceError.unavailable
        }

        let record = OwnerRecord(version: 1, directoryID: directoryID, leaseID: leaseID,
            processID: process.pid, processStartSeconds: process.seconds,
            processStartMicroseconds: process.microseconds)
        let data = try JSONEncoder().encode(record)
        guard data.count <= maximumOwnerBytes else { throw TaskTemporaryResourceError.unavailable }
        try writeFully(data, to: leaseDescriptor)
        guard fsync(leaseDescriptor) == 0, fsync(directoryDescriptor) == 0,
              fsync(rootDescriptor) == 0 else { throw TaskTemporaryResourceError.unavailable }

        transferredLease = true
        return TaskTemporaryResourceLease(root: root, directory: directory, leaseDescriptor: leaseDescriptor,
            directoryDescriptor: directoryDescriptor,
            device: directoryStatus.st_dev, inode: directoryStatus.st_ino, descriptorOwner: descriptorOwner)
    }

    /// Reclaims only UUID-named private directories whose lease is available
    /// and whose recorded process birth identity is no longer running. Unknown
    /// metadata, inaccessible processes, and live leases are always retained.
    @discardableResult
    static func reclaimAbandoned(root: URL = defaultRoot) -> Int {
        guard let rootDescriptor = try? openRoot(root, create: false) else { return 0 }
        defer { close(rootDescriptor) }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return 0 }
        var removed = 0
        for name in names {
            guard let uuid = UUID(uuidString: name), uuid.uuidString.lowercased() == name.lowercased(),
                  let directoryDescriptor = openat(rootDescriptor, name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC).nonnegative else { continue }
            defer { close(directoryDescriptor) }
            guard (try? validatePrivateDirectory(directoryDescriptor)) != nil,
                  let leaseDescriptor = openat(directoryDescriptor, ownerFileName,
                    O_RDWR | O_NOFOLLOW | O_CLOEXEC).nonnegative else { continue }
            defer { close(leaseDescriptor) }
            guard (try? validatePrivateFile(leaseDescriptor, maximumBytes: maximumOwnerBytes)) != nil,
                  flock(leaseDescriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
            defer { flock(leaseDescriptor, LOCK_UN) }
            guard let record = readOwnerRecord(leaseDescriptor),
                  record.version == 1, record.directoryID == name.lowercased(),
                  UUID(uuidString: record.leaseID) != nil, record.processID > 0,
                  ownerIsGone(record) else { continue }

            // Confirm the root entry still refers to the directory inspected
            // via openat. Remove its contents through descriptors, never by
            // traversing a path that could escape through a replaced symlink.
            var opened = stat()
            guard fstat(directoryDescriptor, &opened) == 0,
                  removeDirectoryEntry(rootDescriptor, directoryDescriptor, leaseDescriptor,
                    name: name, expectedDevice: opened.st_dev, expectedInode: opened.st_ino) else { continue }
            removed += 1
        }
        return removed
    }

    fileprivate static func removeOwnedDirectory(root: URL, directory: URL, leaseDescriptor: Int32, directoryDescriptor: Int32,
                                                  device: dev_t, inode: ino_t) {
        guard directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              UUID(uuidString: directory.lastPathComponent) != nil,
              let rootDescriptor = try? openRoot(root, create: false) else { return }
        defer { close(rootDescriptor) }
        let name = directory.lastPathComponent
        _ = removeDirectoryEntry(rootDescriptor, directoryDescriptor, leaseDescriptor, name: name,
                                 expectedDevice: device, expectedInode: inode)
    }

    private static func removeDirectoryEntry(_ rootDescriptor: Int32, _ directoryDescriptor: Int32,
                                             _ leaseDescriptor: Int32, name: String,
                                             expectedDevice: dev_t, expectedInode: ino_t) -> Bool {
        var opened = stat(), current = stat(), lease = stat(), leaseEntry = stat()
        guard fstat(directoryDescriptor, &opened) == 0,
              opened.st_dev == expectedDevice, opened.st_ino == expectedInode,
              fstatat(rootDescriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              current.st_dev == opened.st_dev, current.st_ino == opened.st_ino,
              fstat(leaseDescriptor, &lease) == 0,
              fstatat(directoryDescriptor, ownerFileName, &leaseEntry, AT_SYMLINK_NOFOLLOW) == 0,
              lease.st_dev == leaseEntry.st_dev, lease.st_ino == leaseEntry.st_ino,
              let record = readOwnerRecord(leaseDescriptor),
              captureDirectoryMatches(record.captureDirectory, in: directoryDescriptor),
              removeContents(directoryDescriptor, preserving: ownerFileName,
                             captureIdentity: record.captureDirectory) else { return false }
        guard unlinkat(directoryDescriptor, ownerFileName, 0) == 0,
              unlinkat(rootDescriptor, name, AT_REMOVEDIR) == 0,
              fsync(rootDescriptor) == 0 else { return false }
        return true
    }

    /// Recursively removes a scratch directory without following symlinks. The
    /// owner lease is preserved until every other entry is gone so an
    /// interrupted cleanup remains verifiable on the next startup.
    private static func removeContents(_ descriptor: Int32, preserving preservedName: String?,
                                       captureIdentity: DirectoryIdentity? = nil) -> Bool {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            return false
        }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self,
                    capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                        String(cString: $0)
                    }
            }
            guard name != ".", name != "..", name != preservedName else { continue }
            var initial = stat()
            guard fstatat(descriptor, name, &initial, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                return false
            }
            if name == "capture", let captureIdentity {
                guard (initial.st_mode & S_IFMT) == S_IFDIR,
                      DirectoryIdentity(initial) == captureIdentity else { return false }
            }
            if (initial.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) {
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { return false }
                var opened = stat()
                guard fstat(child, &opened) == 0, DirectoryIdentity(opened) == DirectoryIdentity(initial) else {
                    close(child); return false
                }
                if name == "capture", captureIdentity != nil {
                    var conflict = stat()
                    let foundConflict = fstatat(child, TaskCaptureDirectory.conflictMarker, &conflict, AT_SYMLINK_NOFOLLOW) == 0
                    guard !foundConflict, errno == ENOENT else { close(child); return false }
                }
                let removed = removeContents(child, preserving: nil)
                close(child)
                guard removed else { return false }
                var current = stat()
                guard fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      current.st_dev == initial.st_dev, current.st_ino == initial.st_ino,
                      unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else { return false }
            } else if unlinkat(descriptor, name, 0) != 0 && errno != ENOENT {
                return false
            }
        }
        return true
    }

    private static func captureDirectoryMatches(_ expected: DirectoryIdentity?, in descriptor: Int32) -> Bool {
        guard let expected else { return true } // Existing leases remain readable.
        var current = stat()
        if fstatat(descriptor, "capture", &current, AT_SYMLINK_NOFOLLOW) != 0 { return errno == ENOENT }
        return (current.st_mode & S_IFMT) == S_IFDIR && DirectoryIdentity(current) == expected
    }

    fileprivate static func recordCaptureDirectory(_ status: stat, leaseDescriptor: Int32) throws {
        guard var record = readOwnerRecord(leaseDescriptor) else { throw TaskTemporaryResourceError.unavailable }
        let identity = DirectoryIdentity(status)
        if let recorded = record.captureDirectory, recorded != identity { throw TaskTemporaryResourceError.unavailable }
        if record.captureDirectory == identity { return }
        record.captureDirectory = identity
        let data = try JSONEncoder().encode(record)
        guard data.count <= maximumOwnerBytes, lseek(leaseDescriptor, 0, SEEK_SET) == 0 else {
            throw TaskTemporaryResourceError.unavailable
        }
        // The live lease lock excludes recovery readers. A torn write is
        // deliberately retained as unverifiable metadata after a crash.
        try writeFully(data, to: leaseDescriptor)
        guard ftruncate(leaseDescriptor, off_t(data.count)) == 0, fsync(leaseDescriptor) == 0 else {
            throw TaskTemporaryResourceError.unavailable
        }
    }

    private static func ownerIsGone(_ record: OwnerRecord) -> Bool {
        var current = TPProcessIdentity()
        if tp_process_identity(pid_t(record.processID), &current) == 1 {
            guard current.pid == record.processID else { return false }
            if current.zombie != 0 { return true }
            return current.seconds != record.processStartSeconds ||
                current.microseconds != record.processStartMicroseconds
        }
        if kill(pid_t(record.processID), 0) == 0 { return false }
        return errno == ESRCH
    }

    private static func readOwnerRecord(_ descriptor: Int32) -> OwnerRecord? {
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_size > 0,
              status.st_size <= maximumOwnerBytes else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(status.st_size))
        let count = bytes.withUnsafeMutableBytes {
            pread(descriptor, $0.baseAddress, $0.count, 0)
        }
        guard count == bytes.count else { return nil }
        return try? JSONDecoder().decode(OwnerRecord.self, from: Data(bytes))
    }

    /// Called by lifecycle startup and reused by scratch allocation. Only this
    /// known root is created/repaired; foreign ownership and links are rejected.
    static func prepareStartup(root: URL = defaultRoot) throws {
        var info = stat()
        if lstat(root.path, &info) != 0 {
            guard errno == ENOENT else { throw PrivateDirectoryPermissions.Failure.unavailable }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: directoryPermissions)])
        }
        try PrivateDirectoryPermissions.check(root, repair: true)
    }

    private static func openRoot(_ root: URL, create: Bool) throws -> Int32 {
        if create { try prepareStartup(root: root) }
        else { try PrivateDirectoryPermissions.check(root) }
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw TaskTemporaryResourceError.unavailable }
        do { try validatePrivateDirectory(descriptor) }
        catch { close(descriptor); throw error }
        return descriptor
    }

    fileprivate static func validatePrivateDirectory(_ descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              status.st_uid == getuid() else {
            throw TaskTemporaryResourceError.unavailable
        }
        if status.st_mode & 0o7777 != directoryPermissions {
            guard fchmod(descriptor, directoryPermissions) == 0, fstat(descriptor, &status) == 0,
                  status.st_mode & 0o7777 == directoryPermissions else { throw TaskTemporaryResourceError.unavailable }
        }
    }

    private static func validatePrivateFile(_ descriptor: Int32, maximumBytes: Int) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              status.st_uid == getuid(), status.st_nlink == 1,
              status.st_size <= maximumBytes,
              fchmod(descriptor, filePermissions) == 0 else {
            throw TaskTemporaryResourceError.unavailable
        }
    }

    private static func writeFully(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TaskTemporaryResourceError.unavailable }
                offset += count
            }
        }
    }
}

/// The retained directory, rather than its mutable pathname, is the authority
/// for PNG metadata and cleanup. It never follows an entry's symbolic link.
final class TaskCaptureDirectory: @unchecked Sendable {
    static let conflictMarker = ".cleanup-conflict"
    struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let bytes: Int64
        let owner: uid_t
        let mode: mode_t
        let birth: timespec
        let modified: timespec
        init(_ status: stat) {
            device = status.st_dev; inode = status.st_ino; bytes = status.st_size
            owner = status.st_uid; mode = status.st_mode
            birth = status.st_birthtimespec; modified = status.st_mtimespec
        }
        /// Object identity excludes size, modification time, mode and owner.
        /// This is for accounting only; full equality still gates execution and cleanup.
        func isSameObject(as other: Self) -> Bool {
            device == other.device && inode == other.inode &&
                birth.tv_sec == other.birth.tv_sec && birth.tv_nsec == other.birth.tv_nsec
        }
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.bytes == rhs.bytes &&
                lhs.owner == rhs.owner && lhs.mode == rhs.mode &&
                lhs.birth.tv_sec == rhs.birth.tv_sec && lhs.birth.tv_nsec == rhs.birth.tv_nsec &&
                lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
        }
    }
    let directoryURL: URL
    private let descriptor: Int32
    private let descriptorTicket: BackendDescriptors.Ticket
    private let identity: TaskTemporaryResourceLedger.DirectoryIdentity
    private let conflictLock = NSLock()
    private var removalConflict = false
    var hasRemovalConflict: Bool { conflictLock.withLock { removalConflict } }
    fileprivate init(directoryURL: URL, descriptor: Int32, status: stat, descriptorOwner: BackendDescriptors.Owner?) {
        descriptorTicket = BackendDescriptors.shared.opened(.capture, owner: descriptorOwner, retention: .retainedResource)
        self.directoryURL = directoryURL; self.descriptor = descriptor
        identity = .init(status)
    }
    deinit { close(descriptor); descriptorTicket.finish() }

    func filename(for url: URL) -> String? {
        guard url.isFileURL, url.pathExtension == "png",
              url.standardizedFileURL.deletingLastPathComponent() == directoryURL.standardizedFileURL else { return nil }
        return url.standardizedFileURL.lastPathComponent
    }
    func pathIsCurrent() -> Bool {
        var current = stat()
        return lstat(directoryURL.path, &current) == 0 && (current.st_mode & S_IFMT) == S_IFDIR &&
            TaskTemporaryResourceLedger.DirectoryIdentity(current) == identity
    }
    func requireDiskHeadroom(_ requiredBytes: UInt64) throws {
        guard pathIsCurrent() else { throw CaptureDiskHeadroom.Failure.unavailable }
        try CaptureDiskHeadroom.check(descriptor: descriptor, requiredBytes: requiredBytes)
    }
    func status(named name: String) throws -> stat? {
        guard name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw TaskTemporaryResourceError.unavailable
        }
        var current = stat()
        guard fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw TaskTemporaryResourceError.unavailable
        }
        return current
    }
    /// Rename within the pinned directory, then recheck identity before unlink.
    /// A replacement racing the initial check is restored without overwriting
    /// a newer entry; it is never accepted as the expired capture.
    func removeFile(named name: String, expected: FileIdentity,
                    beforeRemoval: (() throws -> Void)? = nil,
                    afterQuarantine: (() throws -> Void)? = nil) throws -> Bool {
        guard let current = try status(named: name) else { return true }
        guard (current.st_mode & S_IFMT) == S_IFREG, FileIdentity(current) == expected else { return false }
        try beforeRemoval?()
        let temporary = ".discard-\(UUID().uuidString).png"
        guard renameatx_np(descriptor, name, descriptor, temporary, UInt32(RENAME_EXCL)) == 0 else {
            return errno == ENOENT
        }
        var removed = false
        defer {
            if !removed, renameatx_np(descriptor, temporary, descriptor, name, UInt32(RENAME_EXCL)) != 0, errno != ENOENT {
                // Never overwrite a newer entry to restore a raced replacement.
                // Preserve the quarantined file through retirement and recovery.
                conflictLock.withLock { removalConflict = true }
                let marker = openat(descriptor, Self.conflictMarker, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
                if marker >= 0 { _ = fsync(marker); close(marker); _ = fsync(descriptor) }
            }
        }
        try afterQuarantine?()
        guard let moved = try status(named: temporary), (moved.st_mode & S_IFMT) == S_IFREG,
              FileIdentity(moved) == expected, unlinkat(descriptor, temporary, 0) == 0 else { return false }
        removed = true
        return true
    }
}

final class TaskTemporaryResourceLease: @unchecked Sendable {
    let directoryURL: URL
    private let rootURL: URL
    private let device: dev_t
    private let inode: ino_t
    private let lock = NSLock()
    private var descriptor: Int32
    private var directoryDescriptor: Int32
    private let descriptorOwner: BackendDescriptors.Owner?
    private let directoryTicket: BackendDescriptors.Ticket
    private let leaseTicket: BackendDescriptors.Ticket
    private var captureStorage: TaskCaptureDirectory?
    private var removed = false

    fileprivate init(root: URL, directory: URL, leaseDescriptor: Int32, directoryDescriptor: Int32,
                     device: dev_t, inode: ino_t, descriptorOwner: BackendDescriptors.Owner?) {
        self.descriptorOwner = descriptorOwner
        directoryTicket = BackendDescriptors.shared.opened(.capture, owner: descriptorOwner, retention: .retainedResource)
        leaseTicket = BackendDescriptors.shared.opened(.capture, owner: descriptorOwner, retention: .retainedResource)
        rootURL = root; directoryURL = directory; descriptor = leaseDescriptor
        self.directoryDescriptor = directoryDescriptor
        self.device = device; self.inode = inode
    }

    func captureDirectory() throws -> TaskCaptureDirectory {
        lock.lock(); defer { lock.unlock() }
        guard !removed, descriptor >= 0, directoryDescriptor >= 0 else { throw TaskTemporaryResourceError.unavailable }
        if let captureStorage {
            guard captureStorage.pathIsCurrent() else { throw TaskTemporaryResourceError.unavailable }
            return captureStorage
        }
        var current = stat()
        guard lstat(directoryURL.path, &current) == 0, (current.st_mode & S_IFMT) == S_IFDIR,
              current.st_dev == device, current.st_ino == inode else { throw TaskTemporaryResourceError.unavailable }
        if mkdirat(directoryDescriptor, "capture", TaskTemporaryResourceLedger.directoryPermissions) != 0 && errno != EEXIST {
            throw TaskTemporaryResourceError.unavailable
        }
        let child = openat(directoryDescriptor, "capture", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw TaskTemporaryResourceError.unavailable }
        var transferred = false
        defer { if !transferred { close(child) } }
        try TaskTemporaryResourceLedger.validatePrivateDirectory(child)
        guard fstat(child, &current) == 0, fsync(directoryDescriptor) == 0 else { throw TaskTemporaryResourceError.unavailable }
        try TaskTemporaryResourceLedger.recordCaptureDirectory(current, leaseDescriptor: descriptor)
        let capture = TaskCaptureDirectory(directoryURL: directoryURL.appendingPathComponent("capture", isDirectory: true),
                                           descriptor: child, status: current, descriptorOwner: descriptorOwner)
        transferred = true
        guard capture.pathIsCurrent() else { throw TaskTemporaryResourceError.unavailable }
        captureStorage = capture
        return capture
    }

    /// Graceful retirement removes only this UUID directory while its process
    /// lease remains held. If deletion fails, startup recovery can retry later.
    func removeDirectory() {
        lock.lock()
        guard !removed else { lock.unlock(); return }
        removed = true
        let leaseDescriptor = descriptor
        let directoryDescriptor = self.directoryDescriptor
        lock.unlock()

        if captureStorage?.hasRemovalConflict != true {
            TaskTemporaryResourceLedger.removeOwnedDirectory(root: rootURL, directory: directoryURL,
                leaseDescriptor: leaseDescriptor, directoryDescriptor: directoryDescriptor, device: device, inode: inode)
        }
        release(leaseDescriptor)
    }

    private func release(_ leaseDescriptor: Int32) {
        guard leaseDescriptor >= 0 else { return }
        lock.lock(); descriptor = -1
        let directory = directoryDescriptor; directoryDescriptor = -1; captureStorage = nil
        lock.unlock()
        if directory >= 0 { close(directory); directoryTicket.finish() }
        flock(leaseDescriptor, LOCK_UN)
        close(leaseDescriptor); leaseTicket.finish()
    }

    deinit {
        lock.lock(); let leaseDescriptor = descriptor; descriptor = -1
        let directory = directoryDescriptor; directoryDescriptor = -1; lock.unlock()
        if directory >= 0 { close(directory); directoryTicket.finish() }
        if leaseDescriptor >= 0 { flock(leaseDescriptor, LOCK_UN); close(leaseDescriptor); leaseTicket.finish() }
    }
}

/// Advisory only: another writer can consume space after either check. ImageIO
/// failures still drain through the encoder's normal partial-file cleanup.
enum CaptureDiskHeadroom {
    static let reserveBytes: UInt64 = 16 * 1024 * 1024
    static let encodingOverheadBytes: UInt64 = 1024 * 1024
    enum Failure: LocalizedError {
        case insufficientSpace, unavailable
        var errorDescription: String? {
            switch self {
            case .insufficientSpace: return "There is not enough available disk space for the temporary capture. Free some disk space and try again."
            case .unavailable: return "TaskPilot could not check available disk space for the temporary capture."
            }
        }
    }
    static func requiredBytes(pixelBytes: UInt64) throws -> UInt64 {
        let (encoded, multipliedOverflow) = pixelBytes.multipliedReportingOverflow(by: 2)
        let (required, addedOverflow) = encoded.addingReportingOverflow(reserveBytes + encodingOverheadBytes)
        guard !multipliedOverflow, !addedOverflow else { throw Failure.unavailable }
        return required
    }
    static func availableBytes(descriptor: Int32) throws -> UInt64 {
        var info = statfs()
        guard fstatfs(descriptor, &info) == 0, info.f_bsize > 0 else { throw Failure.unavailable }
        let (bytes, overflow) = UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_bsize))
        guard !overflow else { throw Failure.unavailable }
        return bytes
    }
    static func check(descriptor: Int32, requiredBytes: UInt64,
                      readAvailable: (Int32) throws -> UInt64 = availableBytes) throws {
        guard try readAvailable(descriptor) >= requiredBytes else { throw Failure.insufficientSpace }
    }
    /// Non-task captures may not have created their output directory yet. Read
    /// the nearest existing ancestor without creating any payload or directory.
    static func check(directory: URL, requiredBytes: UInt64) throws {
        guard directory.isFileURL else { throw Failure.unavailable }
        var current = directory.standardizedFileURL
        while true {
            let descriptor = open(current.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor >= 0 {
                defer { close(descriptor) }
                try check(descriptor: descriptor, requiredBytes: requiredBytes)
                return
            }
            guard errno == ENOENT else { throw Failure.unavailable }
            let parent = current.deletingLastPathComponent()
            guard parent != current else { throw Failure.unavailable }
            current = parent
        }
    }
}

private enum TaskTemporaryResourceError: LocalizedError {
    case unavailable
    case ownerIdentityUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: return "TaskPilot could not prepare private temporary storage."
        case .ownerIdentityUnavailable: return "TaskPilot could not verify ownership of private temporary storage."
        }
    }
}

private extension Int32 {
    var nonnegative: Int32? { self >= 0 ? self : nil }
}
