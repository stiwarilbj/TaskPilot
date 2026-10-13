import CryptoKit
import Foundation

enum ControlDeliveryMethod: String, Codable, CaseIterable {
    case accessibility, accessibility_value, accessibility_selected_text, process_event, session_event, hid

    func permits(_ action: ActionKind) -> Bool {
        switch action {
        case .press: return [.accessibility, .session_event, .hid].contains(self)
        case .focus: return self == .accessibility
        case .set_value: return [.accessibility_value, .accessibility_selected_text, .process_event].contains(self)
        case .type_text: return [.accessibility_selected_text, .process_event].contains(self)
        case .click, .double_click: return [.session_event, .hid].contains(self)
        case .scroll: return self == .session_event
        case .key: return self == .process_event
        default: return false
        }
    }

    static func delivered(action: ActionKind, coordinatePress: Bool, hid: Bool) -> ControlDeliveryMethod? {
        switch action {
        case .press: return coordinatePress ? (hid ? .hid : .session_event) : .accessibility
        case .focus: return .accessibility
        case .click, .double_click: return hid ? .hid : .session_event
        case .scroll: return .session_event
        case .key: return .process_event
        default: return nil
        }
    }
}

/// Hints about methods, never target authority or task-completion evidence.
/// The only persistent identifiers are hashes of app/version/role metadata.
final class ControlCompatibilityProfiles {
    static let policyVersion = 1
    static let maximumProfiles = 128
    static let maximumFileBytes = 256 * 1024
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    enum Evidence: String, Codable { case supported, verified, unsupported, unconfirmed }
    struct Key: Equatable {
        let subject: String
        let revision: String
        let environment: String
        let action: ActionKind
        let pressAdvertised: Bool

        init(appID: String, bundlePath: String, version: String, build: String, executableRevision: String,
             role: String, subrole: String, action: ActionKind, capabilities: [String: Bool],
             hid: Bool, mainDisplay: Bool, environment: String) {
            // Both hashes belong to this synchronous key-construction invocation.
            let encoder = JSONEncoder()
            subject = ControlCompatibilityProfiles.fingerprint([appID, bundlePath, role, subrole, action.rawValue], encoder: encoder)
            revision = ControlCompatibilityProfiles.fingerprint([version, build, executableRevision,
                capabilities.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","),
                String(hid), String(mainDisplay), environment], encoder: encoder)
            self.environment = environment; self.action = action
            pressAdvertised = capabilities["press"] == true
        }
    }
    private struct MethodRecord: Codable { let evidence: Evidence; let observedAt: TimeInterval }
    private struct Profile: Codable {
        let revision: String
        var methods: [String: MethodRecord]
        var lastUsed: TimeInterval
    }
    private struct Archive: Codable { let version: Int; let environment: String; let profiles: [String: Profile] }
    private let lock = NSLock()
    private let codingQueue = DispatchQueue(label: "com.orbitagent.control-compatibility-json")
    private let archiveEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let fileURL: URL?
    private let now: () -> Date
    private var environment: String
    private var profiles: [String: Profile] = [:]

    init(fileURL: URL? = nil, environment: String, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL; self.environment = environment; self.now = now
        if let fileURL,
           let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           attributes[.type] as? FileAttributeType == .typeRegular,
           ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= Self.maximumFileBytes,
           let handle = try? FileHandle(forReadingFrom: fileURL) {
            defer { try? handle.close() }
            if let bytes = try? handle.read(upToCount: Self.maximumFileBytes + 1), bytes.count <= Self.maximumFileBytes,
               let archive = try? JSONDecoder().decode(Archive.self, from: bytes),
               archive.version == Self.policyVersion, archive.environment == environment,
               archive.profiles.count <= Self.maximumProfiles {
                profiles = archive.profiles.filter { subject, profile in
                    Self.isFingerprint(subject) && Self.isFingerprint(profile.revision)
                        && profile.methods.count <= ControlDeliveryMethod.allCases.count
                        && profile.methods.keys.allSatisfy { ControlDeliveryMethod(rawValue: $0) != nil }
                }
            }
        }
        prune()
    }

    static func fingerprint(_ metadata: [String]) -> String {
        fingerprint(metadata, encoder: JSONEncoder())
    }
    private static func fingerprint(_ metadata: [String], encoder: JSONEncoder) -> String {
        let bytes = try! encoder.encode(metadata)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func owned<T>(_ operation: () throws -> T) throws -> T {
        try TaskOwnership.check()
        // Metadata updates share the lifecycle gate, but do not dispatch an
        // action receipt: choosing or recording a hint delivers no input.
        if let lease = TaskOwnership.current { return try lease.commit(operation) }
        return try operation()
    }
    private static func isFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskPilot/ControlCompatibility.json")
    }

    func prepare(environment: String) {
        lock.lock(); defer { lock.unlock() }
        guard self.environment != environment else { prune(); return }
        self.environment = environment; profiles.removeAll(); save()
    }

    /// Only methods already permitted by the caller's live safety checks are
    /// eligible. Unknown/unconfirmed support never outranks a default method.
    func preferred(for key: Key, permitted: [ControlDeliveryMethod]) -> ControlDeliveryMethod? {
        lock.lock(); defer { lock.unlock() }
        guard key.environment == environment else { return nil }
        prune()
        if profiles[key.subject]?.revision != key.revision {
            profiles[key.subject] = Profile(revision: key.revision, methods: [:], lastUsed: now().timeIntervalSince1970)
        }
        profiles[key.subject]?.lastUsed = now().timeIntervalSince1970
        let candidates = permitted.filter { $0.permits(key.action) }
        let preferred = candidates.first { profiles[key.subject]?.methods[$0.rawValue]?.evidence == .verified }
        prune()
        return preferred ?? candidates.first
    }

    func evidence(for key: Key, method: ControlDeliveryMethod) -> Evidence? {
        lock.lock(); defer { lock.unlock() }
        prune()
        guard key.environment == environment, profiles[key.subject]?.revision == key.revision else { return nil }
        return profiles[key.subject]?.methods[method.rawValue]?.evidence
    }

    /// A late result cannot resurrect a replaced app/capability/environment
    /// revision. Native callers also guard this update with task ownership.
    func record(_ evidence: Evidence, method: ControlDeliveryMethod, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        guard key.environment == environment, method.permits(key.action),
              profiles[key.subject]?.revision == key.revision else { return }
        let timestamp = now().timeIntervalSince1970
        profiles[key.subject]?.methods[method.rawValue] = MethodRecord(evidence: evidence, observedAt: timestamp)
        profiles[key.subject]?.lastUsed = timestamp
        prune(); save()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; prune(); return profiles.count }

    private func prune() {
        let timestamp = now().timeIntervalSince1970
        for subject in Array(profiles.keys) {
            var profile = profiles[subject]!
            profile.methods = profile.methods.filter {
                $0.value.observedAt.isFinite && $0.value.observedAt >= timestamp - Self.lifetime
                    && $0.value.observedAt <= timestamp + 300
            }
            if profile.lastUsed.isFinite { profiles[subject] = profile }
            else { profiles.removeValue(forKey: subject) }
        }
        let overflow = profiles.count - Self.maximumProfiles
        if overflow > 0 {
            for subject in profiles.sorted(by: {
                $0.value.lastUsed == $1.value.lastUsed ? $0.key < $1.key : $0.value.lastUsed < $1.value.lastUsed
            }).prefix(overflow).map(\.key) { profiles.removeValue(forKey: subject) }
        }
    }

    private func save() {
        guard let fileURL else { return }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           attributes[.type] as? FileAttributeType != .typeRegular { return }
        let archive = Archive(version: Self.policyVersion, environment: environment,
                              profiles: profiles.filter { !$0.value.methods.isEmpty })
        guard let bytes = try? codingQueue.sync(execute: { try archiveEncoder.encode(archive) }),
              bytes.count <= Self.maximumFileBytes else { return }
        // Cache failure only discards a hint; it never fails a desktop action.
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try bytes.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch { }
    }
}

/// Only a change attributable to the bound control can verify a pointer
/// method. A changed screen, label, window or unrelated field cannot do so.
struct ControlInteractionState: Equatable {
    var selected: Bool?
    var expanded: Bool?
    var toggle: Bool?
    var editableFocused: Bool?

    func verifies(_ after: ControlInteractionState) -> Bool {
        (selected == false && after.selected == true)
            || (expanded == false && after.expanded == true)
            || (toggle != nil && after.toggle != nil && toggle != after.toggle)
            || (editableFocused == false && after.editableFocused == true)
    }
}
