import Darwin
import Foundation

/// File checks precede allocation/parsing. No contents or paths enter errors.
enum PrivateRuntimeMetadata {
    static let requestBytes = 4096
    static let recordBytes = 65536
    static let descriptorBytes = 131072
    static let configurationBytes = 4 * 1024 * 1024
    static let processListBytes = 8 * 1024 * 1024
    static let integrityBytes = 64 * 1024 * 1024

    enum Failure: Error { case missing, unavailable, symlink, ownership, size, changed, invalidJSON }
    struct Document { let data: Data; let value: Any }
    private struct Identity: Equatable {
        let device: dev_t; let inode: ino_t; let mode: mode_t; let uid: uid_t; let gid: gid_t
        let links: nlink_t; let size: off_t
        let modifiedSeconds: Int; let modifiedNanos: Int; let changedSeconds: Int; let changedNanos: Int
        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; mode = info.st_mode; uid = info.st_uid; gid = info.st_gid
            links = info.st_nlink; size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        }
    }
    static func parse(_ data: Data) throws -> Any {
        guard !data.starts(with: [0xef, 0xbb, 0xbf]), String(data: data, encoding: .utf8) != nil else {
            throw Failure.invalidJSON
        }
        let value = try RuntimeMessageJSON.decodeValue(data)
        func finite(_ value: Any) throws {
            if let number = value as? NSNumber, !number.doubleValue.isFinite { throw Failure.invalidJSON }
            if let object = value as? [String: Any] { for item in object.values { try finite(item) } }
            else if let items = value as? [Any] { for item in items { try finite(item) } }
        }
        try finite(value)
        return value
    }
    static func readChunk(_ fd: Int32, _ maximum: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: maximum)
        while true {
            let count = Darwin.read(fd, &bytes, maximum)
            if count < 0 { if errno == EINTR { continue }; throw Failure.unavailable }
            return Data(bytes.prefix(count))
        }
    }
    static func document(_ url: URL, maximum: Int = recordBytes,
                         read: (Int32, Int) throws -> Data = readChunk) throws -> Document {
        guard maximum > 0, maximum <= integrityBytes else { throw Failure.size }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { throw Failure.missing }
            if errno == ELOOP { throw Failure.symlink }
            throw Failure.unavailable
        }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw Failure.unavailable }
        guard before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(), before.st_nlink == 1 else {
            throw Failure.ownership
        }
        guard before.st_size >= 0, before.st_size <= maximum else { throw Failure.size }
        var data = Data()
        while data.count < maximum {
            let allowance = min(65536, maximum - data.count)
            let chunk = try read(fd, allowance)
            guard chunk.count <= allowance else { throw Failure.size }
            if chunk.isEmpty { break }
            data.append(chunk)
            guard data.count <= maximum else { throw Failure.size }
        }
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &named) == 0,
              Identity(before) == Identity(after), Identity(after) == Identity(named), data.count == after.st_size else {
            throw Failure.changed
        }
        return Document(data: data, value: try parse(data))
    }
    static func object(_ url: URL, maximum: Int = recordBytes) throws -> [String: Any] {
        guard let value = try document(url, maximum: maximum).value as? [String: Any] else { throw Failure.invalidJSON }
        return value
    }
    static func decode<T: Decodable>(_ type: T.Type, from url: URL, maximum: Int = recordBytes) throws -> T {
        try JSONDecoder().decode(type, from: document(url, maximum: maximum).data)
    }
    static func decodeIfPresent<T: Decodable>(_ type: T.Type, from url: URL, maximum: Int = recordBytes) throws -> T? {
        do { return try decode(type, from: url, maximum: maximum) }
        catch Failure.missing { return nil }
    }
}
