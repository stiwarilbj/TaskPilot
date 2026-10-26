import Darwin
import Foundation
import ProcessSupport

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
    }

    static var defaultRoot: URL {
        GeminiAPIKeyStore.defaultFileURL().deletingLastPathComponent()
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func makeLease(root: URL = defaultRoot) throws -> TaskTemporaryResourceLease {
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
            if directoryDescriptor >= 0 { close(directoryDescriptor) }
            if leaseDescriptor >= 0 && !transferredLease {
                flock(leaseDescriptor, LOCK_UN)
                close(leaseDescriptor)
            }
            if !transferredLease { try? FileManager.default.removeItem(at: directory) }
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
            device: directoryStatus.st_dev, inode: directoryStatus.st_ino)
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

    fileprivate static func removeOwnedDirectory(root: URL, directory: URL, leaseDescriptor: Int32,
                                                  device: dev_t, inode: ino_t) {
        guard directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              UUID(uuidString: directory.lastPathComponent) != nil,
              let rootDescriptor = try? openRoot(root, create: false) else { return }
        defer { close(rootDescriptor) }
        let name = directory.lastPathComponent
        guard let directoryDescriptor = openat(rootDescriptor, name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC).nonnegative else { return }
        defer { close(directoryDescriptor) }
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
              removeContents(directoryDescriptor, preserving: ownerFileName) else { return false }
        guard unlinkat(directoryDescriptor, ownerFileName, 0) == 0,
              unlinkat(rootDescriptor, name, AT_REMOVEDIR) == 0,
              fsync(rootDescriptor) == 0 else { return false }
        return true
    }

    /// Recursively removes a scratch directory without following symlinks. The
    /// owner lease is preserved until every other entry is gone so an
    /// interrupted cleanup remains verifiable on the next startup.
    private static func removeContents(_ descriptor: Int32, preserving preservedName: String?) -> Bool {
        let duplicate = dup(descriptor)
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
            if (initial.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) {
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { return false }
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

    private static func openRoot(_ root: URL, create: Bool) throws -> Int32 {
        if create {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: directoryPermissions)])
        }
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw TaskTemporaryResourceError.unavailable }
        do { try validatePrivateDirectory(descriptor) }
        catch { close(descriptor); throw error }
        return descriptor
    }

    private static func validatePrivateDirectory(_ descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              status.st_uid == getuid(), fchmod(descriptor, directoryPermissions) == 0 else {
            throw TaskTemporaryResourceError.unavailable
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

final class TaskTemporaryResourceLease: @unchecked Sendable {
    let directoryURL: URL
    private let rootURL: URL
    private let device: dev_t
    private let inode: ino_t
    private let lock = NSLock()
    private var descriptor: Int32
    private var removed = false

    fileprivate init(root: URL, directory: URL, leaseDescriptor: Int32, device: dev_t, inode: ino_t) {
        rootURL = root; directoryURL = directory; descriptor = leaseDescriptor
        self.device = device; self.inode = inode
    }

    /// Graceful retirement removes only this UUID directory while its process
    /// lease remains held. If deletion fails, startup recovery can retry later.
    func removeDirectory() {
        lock.lock()
        guard !removed else { lock.unlock(); return }
        removed = true
        let leaseDescriptor = descriptor
        lock.unlock()

        TaskTemporaryResourceLedger.removeOwnedDirectory(root: rootURL, directory: directoryURL,
            leaseDescriptor: leaseDescriptor, device: device, inode: inode)
        release(leaseDescriptor)
    }

    private func release(_ leaseDescriptor: Int32) {
        guard leaseDescriptor >= 0 else { return }
        lock.lock(); descriptor = -1; lock.unlock()
        flock(leaseDescriptor, LOCK_UN)
        close(leaseDescriptor)
    }

    deinit {
        lock.lock(); let leaseDescriptor = descriptor; descriptor = -1; lock.unlock()
        if leaseDescriptor >= 0 { flock(leaseDescriptor, LOCK_UN); close(leaseDescriptor) }
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
