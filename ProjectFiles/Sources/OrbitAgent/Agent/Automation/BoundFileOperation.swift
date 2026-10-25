import CryptoKit
import Darwin
import Foundation

/// Descriptor-relative inspection and replacement. These are race detectors,
/// not locks on other applications. No pathname readback can prove a commit.
final class BoundFileOperation {
    struct Conflict: LocalizedError {
        let delivered: Bool
        let detail: String
        var errorDescription: String? { "Filesystem conflict: \(detail). Inspect the destination before retrying." }
    }
    struct Identity: Equatable {
        let info: stat
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.object == rhs.object && lhs.version == rhs.version
        }
        var object: String { digest("\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)") }
        var version: String { digest("\(object):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(info.st_mode)") }
        var regular: Bool { info.st_mode & S_IFMT == S_IFREG }
    }
    struct Snapshot {
        let data: Data
        let identity: Identity
        let parent: Identity
        var fields: [String: Any] { ["file_identity": identity.object, "file_version": identity.version, "parent_identity": parent.object] }
    }
    struct TextEditSnapshot {
        let beforeData: Data?
        let afterData: Data
        let beforeVersion: String?
        let beforeSHA256: String?
        let fileIdentity: String
        let fileVersion: String
        let parentIdentity: String
        let created: Bool
    }
    enum Boundary { case bound, staged, beforeCommit, delivering, committed, inspected }
    typealias Hook = (Boundary) throws -> Void
    let input: URL
    let parentURL: URL
    let name: String
    private let parent: Int32
    private let parentIdentity: Identity
    private let hook: Hook

    init(_ input: URL, createParents: Bool = false, hook: @escaping Hook = { _ in }) throws {
        self.input = input
        self.hook = hook
        name = input.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { throw TaskToolError.invalidAction("A file name is required") }
        // Resolve directory aliases once (including macOS /tmp and /var).
        parentURL = try Self.canonicalDirectory(input.deletingLastPathComponent(), allowMissing: createParents)
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Self.systemError("open parent") }
        do {
            for component in parentURL.pathComponents where component != "/" {
                try TaskOwnership.check()
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, createParents {
                    try TaskOwnership.commit {
                        guard mkdirat(fd, component, 0o755) == 0 || errno == EEXIST else { throw Self.systemError("create parent") }
                    }
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw Self.systemError("bind parent") }
                close(fd); fd = next
            }
            parentIdentity = try Self.identity(fd)
            parent = fd
        } catch { close(fd); throw error }
    }
    deinit { close(parent) }
    private static func canonicalDirectory(_ url: URL, allowMissing: Bool = false) throws -> URL {
        if let resolved = realpath(url.path, nil) {
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved))
        }
        if allowMissing, errno == ENOENT, url.path != "/" {
            return try canonicalDirectory(url.deletingLastPathComponent(), allowMissing: true)
                .appendingPathComponent(url.lastPathComponent)
        }
        throw Conflict(delivered: false, detail: "the parent directory cannot be resolved")
    }
    private static func systemError(_ operation: String) -> Error {
        TaskToolError.operationFailed("File operation could not \(operation): \(String(cString: strerror(errno)))")
    }
    private static func identity(_ fd: Int32) throws -> Identity {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw systemError("inspect object") }
        return Identity(info: info)
    }
    private func entry(_ name: String) throws -> Identity? {
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return Identity(info: info) }
        if errno == ENOENT { return nil }
        throw Self.systemError("inspect directory entry")
    }
    private func conflict(_ detail: String, delivered: Bool = false) -> Conflict { Conflict(delivered: delivered, detail: detail) }
    private func checkParent(delivered: Bool = false) throws {
        try TaskOwnership.check()
        let now = try Self.canonicalDirectory(input.deletingLastPathComponent())
        let fd = Darwin.open(now.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw conflict("the parent directory disappeared", delivered: delivered) }
        defer { close(fd) }
        guard now.path == parentURL.path, try Self.identity(fd).object == parentIdentity.object else {
            throw conflict("the parent directory changed", delivered: delivered)
        }
    }
    private func openTarget() throws -> (Int32, Identity) {
        guard let expected = try entry(name), expected.regular else {
            throw conflict("the target is missing, a symbolic link, or not a regular file")
        }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw conflict("the target could not be bound") }
        do {
            let actual = try Self.identity(fd)
            guard actual == expected, actual.regular else { throw conflict("the target changed while opening") }
            return (fd, actual)
        } catch { close(fd); throw error }
    }
    private static func read(_ fd: Int32, offset: Int64, count: Int) throws -> Data {
        var output = Data(count: count)
        let got = output.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
        if got < 0 { throw systemError("read bound file") }
        output.count = got
        return output
    }
    private static func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try TaskOwnership.check()
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw systemError("stage bytes") }
                offset += count
            }
        }
    }
    private static func copyAndHash(_ fd: Int32, to destination: Int32? = nil) throws -> String {
        var unused: Data?
        return try copyAndHash(fd, to: destination, capture: &unused)
    }
    private static func copyAndHash(_ fd: Int32, to destination: Int32?, capture: inout Data?) throws -> String {
        var hash = SHA256(), offset: Int64 = 0
        let size = try identity(fd).info.st_size
        while offset < size {
            try TaskOwnership.check()
            let bytes = try read(fd, offset: offset, count: Int(min(65536, size - offset)))
            guard !bytes.isEmpty else { throw Conflict(delivered: false, detail: "the file shrank during inspection") }
            hash.update(data: bytes)
            if let destination { try write(destination, bytes) }
            if capture != nil { capture!.append(bytes) }
            offset += Int64(bytes.count)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func read(limit: Int) throws -> Snapshot {
        try checkParent()
        let (fd, expected) = try openTarget()
        defer { close(fd) }
        try hook(.bound)
        var data = Data()
        while data.count < limit {
            try TaskOwnership.check()
            let part = try Self.read(fd, offset: Int64(data.count), count: min(65536, limit - data.count))
            if part.isEmpty { break }
            data.append(part)
        }
        try hook(.inspected)
        try checkParent()
        guard try Self.identity(fd) == expected, try entry(name) == expected else { throw conflict("the file changed during inspection") }
        return Snapshot(data: data, identity: expected, parent: parentIdentity)
    }
    func inspect(kind: String, expected: Data?) throws -> (Bool, [String: Any]) {
        try checkParent()
        if kind == "path_absent" {
            let absent = try entry(name) == nil
            try hook(.inspected); try checkParent()
            let stillAbsent = try entry(name) == nil
            return (absent && stillAbsent, ["parent_identity": parentIdentity.object])
        }
        if kind == "directory_exists" {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return (false, [:]) }
            defer { close(fd) }
            let identity = try Self.identity(fd)
            try hook(.inspected); try checkParent()
            guard try entry(name) == identity else { throw conflict("the directory changed during inspection") }
            return (true, Snapshot(data: Data(), identity: identity, parent: parentIdentity).fields)
        }
        let snapshot = try read(limit: kind == "file_contents" ? expected!.count + 1 : 0)
        return (kind != "file_contents" || snapshot.data == expected!, snapshot.fields)
    }
    func replace(with data: Data, append: Bool, mustBeAbsent: Bool) throws -> (Int, [String: Any]) {
        let result = try replaceInternal(with: data, append: append, mustBeAbsent: mustBeAbsent,
                                         captureText: false)
        return (result.size, result.fields)
    }

    func replaceCapturingText(with data: Data, append: Bool, mustBeAbsent: Bool)
        throws -> (Int, [String: Any], TextEditSnapshot?) {
        let result = try replaceInternal(with: data, append: append, mustBeAbsent: mustBeAbsent,
                                         captureText: true)
        return (result.size, result.fields, result.textSnapshot)
    }

    private func replaceInternal(with data: Data, append: Bool, mustBeAbsent: Bool, captureText: Bool)
        throws -> (size: Int, fields: [String: Any], textSnapshot: TextEditSnapshot?) {
        try checkParent()
        let initial = try entry(name)
        guard !mustBeAbsent || initial == nil else { throw conflict("the destination must still be absent") }
        guard initial == nil || initial!.regular else { throw conflict("the destination is not a regular file") }
        let original: Int32?
        if initial != nil { original = try openTarget().0 } else { original = nil }
        defer { if let original { close(original) } }
        try hook(.bound)
        let temporary = ".taskpilot-stage-" + UUID().uuidString
        let staged = openat(parent, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard staged >= 0 else { throw Self.systemError("create staged file") }
        var retainDisplaced = false
        var cleanupObject: String?, cleanupVersion: String?
        defer {
            close(staged)
            // Never remove another process's replacement of a staging entry,
            // or a displaced object edited after its final inspection.
            if !retainDisplaced, let actual = try? entry(temporary),
               actual.object == cleanupObject, cleanupVersion == nil || actual.version == cleanupVersion {
                unlinkat(parent, temporary, 0)
            }
        }
        cleanupObject = try Self.identity(staged).object
        var originalHash: String?
        let maximumTextBytes = 128 * 1024
        let expectedFinalSize = (append ? (initial?.info.st_size ?? 0) : 0) + Int64(data.count)
        let maximumTextSize = Int64(maximumTextBytes)
        let canCaptureText = captureText && expectedFinalSize <= maximumTextSize &&
            (initial == nil || (initial?.info.st_size ?? (maximumTextSize + 1)) <= maximumTextSize)
        var originalBytes: Data? = canCaptureText && initial != nil ? Data() : nil
        if let original {
            originalHash = try Self.copyAndHash(original, to: append ? staged : nil, capture: &originalBytes)
            guard try Self.identity(original) == initial else { throw conflict("the original file changed while staging") }
            guard fcopyfile(original, staged, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR)) == 0 else { throw Self.systemError("preserve file metadata") }
            guard fchmod(staged, initial!.info.st_mode & 0o777) == 0 else { throw Self.systemError("preserve permissions") }
        }
        try Self.write(staged, data)
        guard fsync(staged) == 0 else { throw Self.systemError("flush staged file") }
        let stagedHash = try Self.copyAndHash(staged)
        let stagedIdentity = try Self.identity(staged)
        try hook(.staged)
        try hook(.beforeCommit)
        try checkParent()
        guard try Self.identity(staged) == stagedIdentity else { throw conflict("the staged object changed") }
        guard try entry(name) == initial else { throw conflict("the destination changed before commit") }
        if let original { guard try Self.identity(original) == initial else { throw conflict("the original object changed before commit") } }
        var delivered = false
        do {
            try TaskOwnership.commit {
                // Pause can suspend acquisition of delivery authority after
                // the outer checks. Recheck both entries under that authority.
                guard try entry(name) == initial, try entry(temporary) == stagedIdentity,
                      try Self.identity(staged) == stagedIdentity else {
                    throw conflict("the destination or staged object changed before delivery")
                }
                try hook(.delivering)
                let flags = initial == nil ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)
                guard renameatx_np(parent, temporary, parent, name, flags) == 0 else { throw conflict("the conditional replacement was rejected") }
                delivered = true
                // An exchange retains the displaced object, allowing detection
                // of a replacement between the last check and the syscall.
                retainDisplaced = initial != nil
            }
            try hook(.committed)
            try checkParent(delivered: true)
            if let initial {
                let displaced = openat(parent, temporary, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard displaced >= 0 else { throw conflict("the displaced object cannot be inspected", delivered: true) }
                defer { close(displaced) }
                let before = try Self.identity(displaced)
                cleanupObject = before.object; cleanupVersion = before.version
                guard before.regular, before.object == initial.object,
                      before.info.st_size == initial.info.st_size, before.info.st_mode == initial.info.st_mode,
                      before.info.st_mtimespec.tv_sec == initial.info.st_mtimespec.tv_sec,
                      before.info.st_mtimespec.tv_nsec == initial.info.st_mtimespec.tv_nsec,
                      before.info.st_flags == initial.info.st_flags,
                      try Self.copyAndHash(displaced) == originalHash,
                      try Self.identity(displaced) == before,
                      try entry(temporary) == before else {
                    throw conflict("a concurrent replacement was detected; displaced data is retained at \(parentURL.appendingPathComponent(temporary).path)", delivered: true)
                }
            }
            let committed = try Self.identity(staged)
            guard committed.object == stagedIdentity.object,
                  try Self.copyAndHash(staged) == stagedHash,
                  try Self.identity(staged) == committed,
                  try entry(name) == committed else { throw conflict("the committed object changed before verification", delivered: true) }
            try hook(.inspected)
            try checkParent(delivered: true)
            guard try Self.identity(staged) == committed, try entry(name) == committed else { throw conflict("the committed destination changed", delivered: true) }
            // Only discard the displaced original after all verification has
            // succeeded. A post-delivery conflict preserves it for inspection.
            retainDisplaced = false
            var textSnapshot: TextEditSnapshot?
            if canCaptureText {
                let afterBytes: Data?
                if append, let originalBytes {
                    var combined = originalBytes
                    combined.append(data)
                    afterBytes = combined
                } else if initial == nil || !append {
                    afterBytes = data
                } else {
                    afterBytes = nil
                }
                if let afterBytes, afterBytes.count <= maximumTextBytes,
                   SHA256.hash(data: afterBytes).map({ String(format: "%02x", $0) }).joined() == stagedHash,
                   let afterText = String(data: afterBytes, encoding: .utf8),
                   !afterText.unicodeScalars.contains(where: { $0.value == 0 }),
                   (initial == nil || (originalBytes.flatMap { String(data: $0, encoding: .utf8) } != nil)) {
                    textSnapshot = TextEditSnapshot(
                        beforeData: originalBytes,
                        afterData: afterBytes,
                        beforeVersion: initial?.version,
                        beforeSHA256: originalHash,
                        fileIdentity: committed.object,
                        fileVersion: committed.version,
                        parentIdentity: parentIdentity.object,
                        created: initial == nil
                    )
                }
            }
            let fields = Snapshot(data: Data(), identity: committed, parent: parentIdentity).fields
                .merging(["file_sha256": stagedHash]) { _, new in new }
            return (Int(committed.info.st_size), fields, textSnapshot)
        } catch {
            if error is CancellationError { throw error }
            if delivered { throw conflict(error.localizedDescription + (retainDisplaced ? " Displaced data remains at \(parentURL.appendingPathComponent(temporary).path)" : ""), delivered: true) }
            throw error
        }
    }
}

private func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}
