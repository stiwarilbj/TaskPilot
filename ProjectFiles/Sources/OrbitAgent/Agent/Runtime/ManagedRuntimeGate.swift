import Darwin
import Foundation

/// Cross-process exclusion between offline repair and task delivery. The host
/// takes an exclusive permit only after all in-flight native actions settle.
/// Acquisition is nonblocking on native execution queues; Stop never waits on it.
final class ManagedRuntimePermit {
    private let descriptor: Int32
    init(root: URL, repairing: Bool, requireHealth: Bool = true) throws {
        descriptor = open(root.appendingPathComponent("execution-repair.lock").path,
                          O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ManagedRuntimeGateError.recovering }
        guard flock(descriptor, (repairing ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            close(descriptor); throw ManagedRuntimeGateError.recovering
        }
        if !repairing && requireHealth {
            guard let instance = try? ManagedOpenClawDescriptor.load(from:root.appendingPathComponent("runtime.json")),
                  let data = try? Data(contentsOf:root.appendingPathComponent("health.json")),
                  let record = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  instance.acceptsHealth(record) else {
                flock(descriptor, LOCK_UN); close(descriptor)
                throw ManagedRuntimeGateError.recovering
            }
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

enum ManagedRuntimeGateError: LocalizedError {
    case recovering
    var errorDescription: String? { "TaskPilot’s private runtime is recovering; inspect the current outcome before continuing." }
}

extension ManagedOpenClawDescriptor {
    func acceptsHealth(_ record: [String:Any], now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard record["version"] as? Int == 1, record["state"] as? String == "healthy",
              record["instance_id"] as? String == instanceID,
              record["installation_fingerprint"] as? String == installationFingerprint,
              record["configuration_fingerprint"] as? String == configurationFingerprint,
              let checked = record["checked_at"] as? Double, now >= checked, now - checked < 45 else { return false }
        return ["host_identity", "gateway_identity"].allSatisfy { key in
            guard let value = record[key], let data = try? JSONSerialization.data(withJSONObject:value),
                  let identity = try? JSONDecoder().decode(ManagedProcessIdentity.self,from:data) else { return false }
            return identity.alive
        }
    }
}
