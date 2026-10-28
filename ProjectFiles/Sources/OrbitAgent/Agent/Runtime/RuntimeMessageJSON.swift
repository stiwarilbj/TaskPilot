import Foundation

/// Check keys before Foundation collapses objects into dictionaries. Rejecting
/// all duplicate fields also protects nested action and evidence envelopes.
enum RuntimeMessageJSON {
    enum Failure: Error { case malformed, duplicateField }

    static func decode(_ data: Data) throws -> [String: Any] {
        guard let message = try decodeValue(data) as? [String: Any] else {
            throw Failure.malformed
        }
        return message
    }

    static func decodeValue(_ data: Data) throws -> Any {
        try rejectDuplicateFields(data)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func rejectDuplicateFields(_ data: Data) throws {
        // Frames are UTF-8. Foundation also autodetects UTF-16/32; their raw
        // NULs must not let a different encoding bypass this byte-level check.
        guard !data.contains(0) else { throw Failure.malformed }
        try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            // nil denotes an array; each object has its own key namespace.
            var scopes: [Set<String>?] = []
            var index = 0
            func whitespace(_ byte: UInt8) -> Bool { [0x20, 0x09, 0x0a, 0x0d].contains(byte) }
            while index < bytes.count {
                switch bytes[index] {
                case 0x7b, 0x5b: // { [
                    guard scopes.count < 512 else { throw Failure.malformed }
                    scopes.append(bytes[index] == 0x7b ? Set<String>() : nil)
                case 0x7d, 0x5d: // } ]
                    guard !scopes.isEmpty else { throw Failure.malformed }
                    scopes.removeLast()
                case 0x22:
                    let start = index
                    var escaped = false
                    index += 1
                    while index < bytes.count, bytes[index] != 0x22 {
                        if bytes[index] == 0x5c { escaped = true; index += 1 }
                        index += 1
                    }
                    guard index < bytes.count else { throw Failure.malformed }
                    let end = index
                    var next = end + 1
                    while next < bytes.count, whitespace(bytes[next]) { next += 1 }
                    if next < bytes.count, bytes[next] == 0x3a { // Only object keys precede ':' in valid JSON.
                        guard let scope = scopes.indices.last, scopes[scope] != nil else { throw Failure.malformed }
                        let key: String
                        if escaped {
                            let token = Data(bytes[start...end])
                            guard let decoded = try JSONSerialization.jsonObject(with: token, options: .fragmentsAllowed) as? String else {
                                throw Failure.malformed
                            }
                            key = decoded
                        } else {
                            guard let decoded = String(bytes: bytes[(start + 1)..<end], encoding: .utf8) else {
                                throw Failure.malformed
                            }
                            key = decoded
                        }
                        guard scopes[scope]!.insert(key).inserted else { throw Failure.duplicateField }
                    }
                default: break
                }
                index += 1
            }
            guard scopes.isEmpty else { throw Failure.malformed }
            // Foundation remains responsible for the full JSON grammar.
        }
    }
}
