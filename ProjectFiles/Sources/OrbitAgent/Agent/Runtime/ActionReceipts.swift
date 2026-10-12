import CryptoKit
import Foundation

/// Task-local receipts retain terminal replies, never persisted payloads. IDs
/// describe caller intent: identical parameters with a new ID are new work.
final class ActionReceiptStore: @unchecked Sendable {
    struct ReceiptError: LocalizedError {
        let code: String
        let message: String
        var errorDescription: String? { message }
    }
    final class Token: @unchecked Sendable {
        let id: String
        let generation: String
        private let store: ActionReceiptStore
        fileprivate init(id: String, store: ActionReceiptStore) {
            self.id = id; self.generation = store.generation; self.store = store
        }
        func dispatched() throws { try store.dispatched(id) }
        func complete(_ result: [String: Any]) { store.complete(id, result: result) }
        func fail(_ error: Error, code: String) { store.fail(id, error: error, code: code) }
        var receipt: [String: Any] { store.lookup(id) }
    }
    enum Claim { case new(Token), existing([String: Any]) }
    private struct Entry {
        let fingerprint: String
        var state = "pending"
        var terminal = false
        var result: [String: Any]?
        var error: String?
        var errorCode: String?
    }
    let generation: String
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var duplicates = 0
    var duplicateCount: Int { lock.lock(); defer { lock.unlock() }; return duplicates }
    init(generation: String) { self.generation = generation }

    static func validateID(_ id: String?) throws -> String {
        guard let id, let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id.lowercased() else {
            throw ReceiptError(code: "invalid_action", message: "A native action requires a valid action ID")
        }
        return uuid.uuidString.lowercased()
    }

    func begin(id: String, payload: [String: Any]) throws -> Claim {
        let id = try Self.validateID(id)
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        lock.lock(); defer { lock.unlock() }
        if let previous = entries[id] {
            guard previous.fingerprint == fingerprint else {
                throw ReceiptError(code: "receipt_conflict", message: "The same action ID cannot be used for different work")
            }
            duplicates += 1
            return .existing(snapshot(id, previous))
        }
        entries[id] = Entry(fingerprint: fingerprint)
        return .new(Token(id: id, store: self))
    }

    func lookup(_ id: String) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[id.lowercased()] else {
            return ["action_id": id.lowercased(), "state": "unknown", "terminal": false]
        }
        return snapshot(id.lowercased(), entry)
    }
    func discard() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }
    private func snapshot(_ id: String, _ entry: Entry) -> [String: Any] {
        var value: [String: Any] = ["action_id": id, "state": entry.state, "terminal": entry.terminal]
        if let result = entry.result { value["result"] = result }
        if let error = entry.error { value["error"] = error }
        if let code = entry.errorCode { value["error_code"] = code }
        return value
    }
    private func dispatched(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[id], !entry.terminal else { throw CancellationError() }
        entry.state = "dispatched"; entries[id] = entry
    }
    private func complete(_ id: String, result: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[id], !entry.terminal else { return }
        entry.terminal = true; entry.result = result
        entry.state = result["outcome"] as? String == "delivered_unconfirmed" ? "unconfirmed" : "confirmed"
        entries[id] = entry
    }
    private func fail(_ id: String, error: Error, code: String) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[id], !entry.terminal else { return }
        let uncertain = entry.state == "dispatched" || code == "delivery_uncertain"
        entry.terminal = true; entry.state = uncertain ? "unconfirmed" : "rejected"
        entry.error = error.localizedDescription
        entry.errorCode = uncertain && !["cancelled", "permission_denied", "protected_target", "secure_input"].contains(code)
            ? "delivery_uncertain" : code
        entries[id] = entry
    }
}
