import Darwin
import Foundation
import ProcessSupport

/// Coalesces filesystem and process lifecycle events for the Gateway host.
/// Directory notifications are hints; the host timeout remains the fallback.
final class ManagedGatewayWake {
    private struct Identity: Equatable {
        let device: dev_t; let inode: ino_t; let type: mode_t
    }
    private struct Metadata: Equatable {
        let device: dev_t; let inode: ino_t; let mode: mode_t; let size: off_t
        let modifiedSeconds: Int; let modifiedNanoseconds: Int
        let changedSeconds: Int; let changedNanoseconds: Int
        var identity: Identity { Identity(device: device, inode: inode, type: mode & S_IFMT) }
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; mode = value.st_mode; size = value.st_size
            modifiedSeconds = Int(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int(value.st_mtimespec.tv_nsec)
            changedSeconds = Int(value.st_ctimespec.tv_sec); changedNanoseconds = Int(value.st_ctimespec.tv_nsec)
        }
    }
    private struct Snapshot: Equatable {
        let clients: Metadata?
        let healthRequest: Metadata?
        let configurationRequest: Metadata?
        let descriptor: Metadata?
    }
    private let root: URL
    private let queue = DispatchQueue(label: "com.orbitagent.gateway-wake", qos: .utility)
    private let condition = NSCondition()
    private var revision: UInt64 = 0
    private var snapshot: Snapshot
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var sourceIdentities: [URL: Identity] = [:]
    private var closed = false

    init(root: URL) {
        self.root = root
        snapshot = Self.capture(root)
        queue.sync {
            installWatch(root)
            installWatch(root.appendingPathComponent("clients", isDirectory: true))
            for name in ["health-request.json", "configuration-request.json", "runtime.json"] {
                installWatch(root.appendingPathComponent(name))
            }
        }
    }
    private static func metadata(_ url: URL) -> Metadata? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return nil }
        return Metadata(value)
    }
    private static func capture(_ root: URL) -> Snapshot {
        Snapshot(clients: metadata(root.appendingPathComponent("clients", isDirectory: true)),
            healthRequest: metadata(root.appendingPathComponent("health-request.json")),
            configurationRequest: metadata(root.appendingPathComponent("configuration-request.json")),
            descriptor: metadata(root.appendingPathComponent("runtime.json")))
    }
    private func installWatch(_ url: URL) {
        guard !closed, sources[url] == nil else { return }
        guard let expected = Self.metadata(url)?.identity else { return }
        let descriptor = Darwin.open(url.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              Metadata(opened).identity == expected else {
            Darwin.close(descriptor)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: queue)
        sources[url] = source
        sourceIdentities[url] = expected
        source.setEventHandler { [weak self] in self?.refresh() }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }
    private func replaceWatch(_ url: URL) {
        sources.removeValue(forKey: url)?.cancel()
        sourceIdentities.removeValue(forKey: url)
        installWatch(url)
    }
    private func refresh() {
        guard !closed else { return }
        let current = Self.capture(root)
        let clientsReplaced = snapshot.clients?.identity != current.clients?.identity
        let changed = current != snapshot
        snapshot = current
        if clientsReplaced { replaceWatch(root.appendingPathComponent("clients", isDirectory: true)) }
        let requestURLs = ["health-request.json", "configuration-request.json", "runtime.json"].map {
            root.appendingPathComponent($0)
        }
        for url in requestURLs where sourceIdentities[url] != Self.metadata(url)?.identity {
            replaceWatch(url)
        }
        if changed { signal() }
    }
    func token() -> UInt64 { condition.withLock { revision } }
    func signal() { condition.withLock { revision &+= 1; condition.broadcast() } }
    @discardableResult
    func wait(after token: UInt64, timeout: TimeInterval = 5) -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while revision == token {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            _ = condition.wait(until: Date(timeIntervalSinceNow: remaining))
        }
        return revision != token
    }
    func close() {
        queue.sync {
            guard !closed else { return }
            closed = true
            condition.withLock { revision &+= 1; condition.broadcast() }
            for source in sources.values { source.cancel() }
            sources.removeAll()
            sourceIdentities.removeAll()
        }
    }
}

/// Private runtime compatibility boundary; never falls back to PATH or a shared profile.
extension ManagedOpenClawDescriptor {
    static let root = GeminiAPIKeyStore.defaultFileURL().deletingLastPathComponent().appendingPathComponent("ManagedOpenClaw")
    static let url = root.appendingPathComponent("runtime.json")
    static func load(from url: URL = Self.url) throws -> Self {
        let data: Data
        do { data = try PrivateRuntimeMetadata.document(url, maximum: RuntimeDescriptorContract.maxBytes).data }
        catch PrivateRuntimeMetadata.Failure.symlink { throw PrivateDirectoryPermissions.Failure.symlink }
        catch { throw ManagedOpenClawError.invalidDescriptor }
        do { _ = try RuntimeDescriptorContract.parse(data, root: url.deletingLastPathComponent()) }
        catch let error as RuntimeDescriptorContract.Failure where error.code == "symlink" {
            throw PrivateDirectoryPermissions.Failure.symlink
        } catch { throw ManagedOpenClawError.invalidDescriptor }
        var value = try JSONDecoder().decode(Self.self, from: data)
        value.sourceURL = url
        return value
    }
    func checkPrivateDirectories() throws {
        let root = (sourceURL ?? Self.url).deletingLastPathComponent()
        for path in try RuntimeDescriptorContract.directoryPaths(root: root, paths: pathValues) {
            try PrivateDirectoryPermissions.check(path)
        }
    }
    var environment: [String: String] {
        var env = OpenClawService.managedEnvironment(nodePath: node).values
        env["OPENCLAW_STATE_DIR"] = state; env["OPENCLAW_CONFIG_PATH"] = config
        env["OPENCLAW_PROFILE"] = "taskpilot"; env["OPENCLAW_NO_RESPAWN"] = "1"
        env["TASKPILOT_MANAGED_DESCRIPTOR"] = (sourceURL ?? Self.url).path
        env["TASKPILOT_MANAGED_FINGERPRINT"] = instanceID + ":" + installationFingerprint + ":" + configurationFingerprint
        return env
    }
}

enum ManagedOpenClawError: LocalizedError {
    case invalidDescriptor, command(String)
    var errorDescription: String? {
        switch self {
        case .invalidDescriptor: return "TaskPilot’s private OpenClaw descriptor is incompatible. Reconfigure in Settings."
        case .command(let detail): return detail
        }
    }
}

struct ManagedProcessIdentity: Codable, Equatable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64
    static func read(_ pid: Int32) -> Self? {
        var value = TPProcessIdentity()
        guard tp_process_identity(pid, &value) != 0, value.zombie == 0 else { return nil }
        return Self(pid: pid, seconds: value.seconds, microseconds: value.microseconds)
    }
    var alive: Bool { Self.read(pid) == self }
}

struct GatewayRecoveryClock: Codable, Equatable {
    let bootSession: String
    let wall: TimeInterval
    let monotonic: TimeInterval

    private static let systemBootSession: String = {
        var bytes = [CChar](repeating: 0, count: 128)
        var size = bytes.count
        let result = bytes.withUnsafeMutableBytes {
            sysctlbyname("kern.bootsessionuuid", $0.baseAddress, &size, nil, 0)
        }
        if result == 0, size > 1, size <= bytes.count, bytes[size - 1] == 0,
           let uuid = UUID(uuidString: String(cString: bytes)) { return uuid.uuidString }
        // If boot identity is unavailable, trust uptime only within this host.
        return "host-" + UUID().uuidString
    }()
    static var current: Self {
        Self(bootSession: systemBootSession, wall: Date().timeIntervalSince1970,
             monotonic: ProcessInfo.processInfo.systemUptime)
    }
    fileprivate var valid: Bool {
        !bootSession.isEmpty && bootSession.utf8.count <= 128 &&
            wall.isFinite && monotonic.isFinite && monotonic >= 0
    }
}

/// A single budget survives host/app restarts. Refresh and task starts cannot reset it.
struct GatewayRecoveryBudget: Codable, Equatable {
    static let restartWindow: TimeInterval = 600
    static let uncertainClockCooldown: TimeInterval = 60
    private static let clockTolerance: TimeInterval = 5
    private struct Timing: Codable, Equatable {
        var version = 1
        var anchor: GatewayRecoveryClock
        var restarts: [TimeInterval]
        var nextProbe: TimeInterval
    }
    // Retain the original wall-clock fields for older records and diagnostics.
    var restarts: [TimeInterval] = []
    var nextProbe: TimeInterval = 0
    var circuits = 0
    var restartReserved = false
    private var timing: Timing?
    enum CodingKeys: String, CodingKey { case restarts, nextProbe, circuits, restartReserved, timing }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        restarts = try values.decode([TimeInterval].self, forKey:.restarts)
        nextProbe = try values.decode(TimeInterval.self, forKey:.nextProbe)
        circuits = try values.decode(Int.self, forKey:.circuits)
        restartReserved = try values.decodeIfPresent(Bool.self, forKey:.restartReserved) ?? false
        if values.contains(.timing) {
            // Damage to new clock metadata must not discard the legacy budget.
            timing = (try? values.decode(Timing.self, forKey:.timing)) ?? Timing(version:0,
                anchor:GatewayRecoveryClock(bootSession:"", wall:0, monotonic:0), restarts:[], nextProbe:0)
        }
    }

    private mutating func store(_ value: Timing, at clock: GatewayRecoveryClock) {
        var value = value
        value.anchor = clock
        timing = value
        restarts = value.restarts.map { clock.wall - (clock.monotonic - $0) }
        nextProbe = value.nextProbe == 0 ? 0 : clock.wall + max(0, value.nextProbe - clock.monotonic)
    }

    /// Call before admission and persist a changed result before launching work.
    /// An unchanged refresh does not rewrite the clock anchor or the record.
    @discardableResult
    mutating func synchronize(at clock: GatewayRecoveryClock) -> Bool {
        precondition(clock.valid)
        let previous = self
        let hasRecovery = !restarts.isEmpty || nextProbe != 0 || circuits != 0 || restartReserved ||
            timing.map { !$0.restarts.isEmpty || $0.nextProbe != 0 } == true
        circuits = min(3, max(0, circuits))
        func uncertainTiming() -> Timing {
            // Unknown elapsed time must not erase spent attempts. Rebase them
            // into one bounded window, never preserve an hours-away deadline.
            let count = min(3, max(restarts.count, timing?.restarts.count ?? 0))
            return Timing(anchor: clock, restarts: Array(repeating: clock.monotonic, count: count),
                nextProbe: hasRecovery ? clock.monotonic + Self.uncertainClockCooldown : 0)
        }
        if var value = timing {
            let valid = value.version == 1 && value.anchor.valid && value.restarts.count == restarts.count &&
                value.restarts.count <= 3 && value.restarts.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= value.anchor.monotonic } &&
                value.nextProbe.isFinite && (value.nextProbe == 0 ||
                    value.nextProbe >= value.anchor.monotonic && value.nextProbe - value.anchor.monotonic <= 300)
            if !valid || value.anchor.bootSession != clock.bootSession || clock.monotonic < value.anchor.monotonic {
                store(uncertainTiming(), at: clock)
            } else {
                value.restarts.removeAll { clock.monotonic - $0 >= Self.restartWindow }
                let drift = (clock.wall - value.anchor.wall) - (clock.monotonic - value.anchor.monotonic)
                if abs(drift) > Self.clockTolerance {
                    if hasRecovery { value.nextProbe = max(value.nextProbe, clock.monotonic + Self.uncertainClockCooldown) }
                    value.anchor = clock
                }
                if value.nextProbe <= clock.monotonic { value.nextProbe = 0 }
                if value != timing { store(value, at: clock) }
            }
        } else {
            // Legacy records use their original wall-clock ages once, then gain
            // boot-aware timing. Future/inconsistent dates take the safe path.
            let valid = restarts.count <= 3 && restarts.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= clock.wall } &&
                nextProbe.isFinite && nextProbe >= 0 && nextProbe - clock.wall <= 300
            let recent = restarts.filter { clock.wall - $0 < Self.restartWindow }
            if valid && recent.allSatisfy({ clock.wall - $0 <= clock.monotonic }) {
                store(Timing(anchor: clock, restarts: recent.map { clock.monotonic - (clock.wall - $0) },
                    nextProbe: nextProbe > clock.wall ? clock.monotonic + (nextProbe - clock.wall) : 0), at: clock)
            } else { store(uncertainTiming(), at: clock) }
        }
        return self != previous
    }

    func probeIsDue(at clock: GatewayRecoveryClock) -> Bool {
        guard let timing, timing.anchor.bootSession == clock.bootSession,
              clock.monotonic >= timing.anchor.monotonic else { return false }
        return clock.monotonic >= timing.nextProbe
    }
    var monotonicProbeDeadline: TimeInterval { timing?.nextProbe ?? .infinity }

    mutating func failed(at clock: GatewayRecoveryClock = .current) -> TimeInterval {
        synchronize(at: clock)
        var value = timing!
        let delay: TimeInterval
        if restarts.count < 3 {
            delay = [1, 3, 10][restarts.count]
            value.restarts.append(clock.monotonic); restartReserved = true
        } else {
            delay = min(300, 60 * pow(2, Double(circuits)))
            restartReserved = false; circuits = min(3, circuits + 1)
        }
        value.nextProbe = max(value.nextProbe, clock.monotonic + delay)
        store(value, at: clock)
        return max(0, value.nextProbe - clock.monotonic)
    }
    mutating func healthy(at clock: GatewayRecoveryClock = .current) {
        synchronize(at: clock)
        restartReserved = false; circuits = 0
        var value = timing!; value.nextProbe = 0
        store(value, at: clock) // Restarts remain spent for ten minutes.
    }
}

struct FullIntegrityAuditSchedule {
    static let interval: TimeInterval = 60 * 60
    static let failedAuditRetryDelay: TimeInterval = 60
    private(set) var lastSuccessfulAudit: TimeInterval?
    private(set) var retryAfter: TimeInterval = 0
    private(set) var fullAuditRequired = false

    mutating func requireFullAudit() { fullAuditRequired = true }

    func shouldRun(at now: TimeInterval, forced: Bool = false) -> Bool {
        if forced { return true }
        let due = fullAuditRequired || (lastSuccessfulAudit.map { now < $0 || now - $0 >= Self.interval } ?? true)
        return due && now >= retryAfter
    }

    mutating func record(at now: TimeInterval, succeeded: Bool) {
        if succeeded {
            lastSuccessfulAudit = now
            retryAfter = 0
            fullAuditRequired = false
        } else {
            // Keep the last successful timestamp intact. This is only a retry
            // throttle after a failed pass, never a new audit baseline.
            retryAfter = now + Self.failedAuditRetryDelay
        }
    }

    mutating func reset() {
        lastSuccessfulAudit = nil
        retryAfter = 0
        fullAuditRequired = false
    }
}

/// App clients have separate birth-identity leases. A crashed/reused PID is not a client.
/// This helper owns the Gateway with the same native tree supervisor as commands.
/// It outlives its launcher, tears down after the final app exits, and installs no service.
enum ManagedGatewayHost {
    static func registerClient(root: URL = ManagedOpenClawDescriptor.root) throws -> URL {
        guard let identity = ManagedProcessIdentity.read(getpid()) else { throw ManagedOpenClawError.invalidDescriptor }
        let directory = root.appendingPathComponent("clients")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("\(identity.pid)-\(identity.seconds)-\(identity.microseconds).json")
        try write(identity, to: file)
        return file
    }
    static func clientsAlive(root: URL) -> Bool {
        var alive = false
        for file in (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("clients"), includingPropertiesForKeys: nil)) ?? [] {
            if let identity = try? PrivateRuntimeMetadata.decode(ManagedProcessIdentity.self, from: file), identity.alive {
                alive = true
            } else { try? FileManager.default.removeItem(at: file) }
        }
        return alive
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func writeHealth(_ descriptor: ManagedOpenClawDescriptor, state: String, detail: String, root: URL, gateway: SubprocessSupervisor? = nil) {
        var json: [String: Any] = ["version":1, "instance_id":descriptor.instanceID,
            "installation_fingerprint":descriptor.installationFingerprint,
            "configuration_fingerprint":descriptor.configurationFingerprint,
            "state":state, "detail":detail, "checked_at":Date().timeIntervalSince1970]
        for (key, pid) in [("host_identity", getpid()), ("gateway_identity", gateway?.processIdentifier ?? 0)] {
            if let identity = ManagedProcessIdentity.read(pid),
               let data = try? JSONEncoder().encode(identity),
               let value = try? JSONSerialization.jsonObject(with:data) { json[key] = value }
        }
        try? JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent("health.json"), options: .atomic)
    }
    /// Packaging smoke check: ACP image/JSON only, no native bridge or desktop input.
    static func headlessCheck(descriptorURL: URL, runtimeURL: URL) -> Int32 {
        let root = descriptorURL.deletingLastPathComponent()
        guard let client = try? registerClient(root: root) else { return 1 }
        let host = SubprocessSupervisor()
        host.executableURL = Bundle.main.executableURL
        host.arguments = ["--managed-openclaw-host", descriptorURL.path, runtimeURL.path]
        do { try host.run(); host.markOutputDrained() } catch { try? FileManager.default.removeItem(at:client); return 1 }
        defer {
            try? FileManager.default.removeItem(at:client)
            _ = host.waitForTree(until: .now() + 90)
        }
        let limit = ProcessInfo.processInfo.systemUptime + 600
        repeat {
            if let value = try? PrivateRuntimeMetadata.object(root.appendingPathComponent("health.json")),
               let descriptor = try? ManagedOpenClawDescriptor.load(from:descriptorURL),
               descriptor.acceptsHealth(value) {
                let input = FileHandle.standardInput.readData(ofLength:16384)
                let result = OpenClawService.run(executable:runtimeURL,
                    arguments:["--check-models", "--managed-descriptor", descriptorURL.path],
                    timeout:240, input:input, environment:descriptor.environment)
                FileHandle.standardOutput.write(Data((result.output + "\n").utf8))
                return result.status
            }
            Thread.sleep(forTimeInterval:0.2)
        } while ProcessInfo.processInfo.systemUptime < limit
        FileHandle.standardError.write(Data("Private Gateway did not establish authenticated ACP connectivity.\n".utf8))
        return 1
    }

    private static func ownedCommand(root: URL, executable: URL, arguments: [String], timeout: TimeInterval,
                                     environment: [String:String]? = nil,
                                     schedulingPriority: SubprocessSupervisor.SchedulingPriority = .inherited,
                                     cancellation suppliedCancellation: OpenClawCommandCancellation? = nil) -> OpenClawService.CommandResult {
        let cancellation = suppliedCancellation ?? OpenClawCommandCancellation()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos:.utility))
        timer.schedule(deadline:.now()+0.2, repeating:.milliseconds(200))
        timer.setEventHandler {
            // A config writer may own the configuration lock. Do not keep the
            // host waiting on an ACP child that is waiting on that same writer.
            let configurationPending = arguments.contains("--managed-acp-probe") &&
                FileManager.default.fileExists(atPath:root.appendingPathComponent("configuration-request.json").path)
            if !clientsAlive(root:root) || configurationPending { cancellation.cancel() }
        }
        timer.resume(); defer { timer.cancel() }
        return OpenClawService.run(executable:executable, arguments:arguments, timeout:timeout,
                                  environment:environment, cancellation:cancellation,
                                  schedulingPriority:schedulingPriority)
    }

    /// Readiness is established from a consistent descriptor snapshot while a
    /// shared runtime permit excludes offline configuration repair/restarts.
    /// These checks only read local metadata or query authenticated Gateway
    /// health; all repairs remain on the serialized host path.
    static func checkLocalReadiness(descriptorURL: URL, descriptor: ManagedOpenClawDescriptor,
                                    permit: ManagedRuntimePermit,
                                    timeout: TimeInterval = OpenClawService.localReadinessDeadline) -> LocalReadinessSnapshot {
        let root = descriptorURL.deletingLastPathComponent()
        let healthCancellation = OpenClawCommandCancellation()
        let probes: [LocalReadinessProbe: LocalReadinessProbeCoordinator.Probe] = [
            .descriptor: { [permit] _ in
                withExtendedLifetime(permit) {
                    do {
                        return try ManagedOpenClawDescriptor.load(from: descriptorURL) == descriptor
                            ? .passed : .failed("descriptor_changed")
                    } catch { return .failed("descriptor_invalid") }
                }
            },
            .privateDirectories: { [permit] _ in
                withExtendedLifetime(permit) {
                    do {
                        try descriptor.checkPrivateDirectories()
                        return .passed
                    } catch let failure as PrivateDirectoryPermissions.Failure {
                        return .failed(failure.rawValue)
                    } catch {
                        return .failed("private_directory_unavailable")
                    }
                }
            },
            .authenticatedGateway: { [permit] remaining in
                withExtendedLifetime(permit) {
                    guard remaining > 0 else { return .timedOut }
                    let milliseconds = max(1, min(4_000, Int(remaining * 1_000)))
                    let result = ownedCommand(root: root,
                        executable: URL(fileURLWithPath: descriptor.executable),
                        arguments: ["health", "--json", "--timeout", String(milliseconds)],
                        timeout: remaining, environment: descriptor.environment,
                        cancellation: healthCancellation)
                    if result.status == -2 { return .timedOut }
                    guard result.status == 0, object(result.output)?["ok"] as? Bool == true else {
                        return .failed("gateway_unavailable")
                    }
                    return .passed
                }
            }
        ]
        return LocalReadinessProbeCoordinator.run(timeout: timeout, probes: probes,
            onDeadline: { healthCancellation.cancel() })
    }

    static func localReadinessDetail(_ snapshot: LocalReadinessSnapshot) -> String {
        let details = snapshot.failures.map { failure -> String in
            switch failure.probe {
            case .descriptor:
                if failure.outcome == .timedOut {
                    return "Private OpenClaw descriptor validation did not finish before the shared readiness deadline."
                }
                return "TaskPilot’s private OpenClaw descriptor changed or failed validation."
            case .privateDirectories:
                if case .failed(let code) = failure.outcome {
                    return PrivateDirectoryPermissions.Failure(rawValue: code)?.localizedDescription ??
                        "TaskPilot could not verify its private runtime directories."
                }
                return "Private-directory verification did not finish before the shared readiness deadline."
            case .authenticatedGateway:
                if failure.outcome == .timedOut {
                    return "Authenticated Gateway health did not respond before the shared readiness deadline."
                }
                return "TaskPilot could not confirm authenticated Gateway health."
            }
        }
        return details.isEmpty ? "Private Gateway connected; ACP compatible" :
            details.joined(separator: " ") + " TaskPilot will continue through its normal recovery checks."
    }

    static func run(descriptorURL: URL, runtimeURL: URL) -> Int32 {
        let root = descriptorURL.deletingLastPathComponent()
        guard (try? PrivateDirectoryPermissions.check(root)) != nil else { return 1 }
        let lock = open(root.appendingPathComponent("gateway-owner.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { return 1 }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return 0 } // Another valid host owns drainage too.
        var budget: GatewayRecoveryBudget
        do {
            budget = try PrivateRuntimeMetadata.decodeIfPresent(GatewayRecoveryBudget.self,
                from: root.appendingPathComponent("recovery.json")) ?? GatewayRecoveryBudget()
        } catch { return 1 } // An invalid record cannot clear a persisted restart budget.
        var gateway: SubprocessSupervisor?
        var capture: BufferedProcessOutput?
        var descriptor: ManagedOpenClawDescriptor?
        var nextHealth: TimeInterval = 0
        var nextAudit: TimeInterval = 0
        var integritySchedule = FullIntegrityAuditSchedule()
        let fileHints = ManagedRuntimeFileHints(root: root)
        defer { fileHints.close() }
        let wake = ManagedGatewayWake(root: root)
        defer { wake.close() }
        let resources = runtimeURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("OpenClaw/managed")
        var acpVerified = false
        var repair = false
        func teardown() {
            gateway?.beginTeardown()
            _ = gateway?.waitForTree(ignoreInterrupt: true)
            _ = try? capture?.finish()
            gateway?.markOutputDrained(); capture?.close()
            gateway = nil; capture = nil; acpVerified = false
        }
        func collectUnusedProfiles() {
            // Best effort only, after tree/output drainage; never stop a live
            // Gateway just for housekeeping or change readiness on a failure.
            guard let permit = try? ManagedRuntimePermit(root:root, repairing:true) else { return }
            defer { withExtendedLifetime(permit) {} }
            _ = OpenClawService.run(executable:runtimeURL,
                arguments:["--managed-openclaw", "collect-profiles", "--managed-descriptor", descriptorURL.path], timeout:5)
        }
        // The root was durably recorded while suspended, before it could fork.
        // Capture live group members before retirement; after root exit, signal
        // only those recorded birth identities (never a potentially reused group).
        var abandoned: [ManagedProcessIdentity] = []
        let oldOwner: ManagedProcessIdentity?
        let oldProcesses: [ManagedProcessIdentity]?
        do {
            oldOwner = try PrivateRuntimeMetadata.decodeIfPresent(ManagedProcessIdentity.self,
                from: root.appendingPathComponent("gateway-root.json"))
            oldProcesses = try PrivateRuntimeMetadata.decodeIfPresent([ManagedProcessIdentity].self,
                from: root.appendingPathComponent("gateway-processes.json"), maximum: PrivateRuntimeMetadata.processListBytes)
        } catch { return 1 } // Unknown ownership cannot authorize a replacement Gateway.
        if let owner = oldOwner, owner.alive {
            var members = [TPProcessIdentity](repeating:TPProcessIdentity(),count:65536)
            let count = tp_process_group_snapshot(owner.pid,&members,Int32(members.count))
            if count < 0 { return 1 } // Ownership cannot be safely handed off.
            abandoned = members.prefix(Int(count)).map { ManagedProcessIdentity(pid:$0.pid,seconds:$0.seconds,microseconds:$0.microseconds) }
            if owner.alive { _ = Darwin.kill(-owner.pid,SIGTERM) }
        }
        // Recover only recorded birth identities. Never signal a reused PID or an unrelated listener.
        if let old = oldProcesses {
            abandoned += old
            for process in abandoned where process.alive { _ = Darwin.kill(process.pid, SIGTERM) }
            Thread.sleep(forTimeInterval: 0.2)
            for process in abandoned where process.alive { _ = Darwin.kill(process.pid, SIGKILL) }
        }
        for process in abandoned where process.alive { _ = Darwin.kill(process.pid,SIGKILL) }
        let drainage = ProcessInfo.processInfo.systemUptime + 5
        while abandoned.contains(where: { $0.alive }) && ProcessInfo.processInfo.systemUptime < drainage { Thread.sleep(forTimeInterval:0.02) }
        guard !abandoned.contains(where: { $0.alive }) else { return 1 }
        // Install cleanup only after ownership records have been accepted and
        // their processes drained. Invalid records must survive for inspection.
        defer {
            teardown()
            collectUnusedProfiles()
            for name in ["gateway-processes.json", "gateway-root.json"] { try? FileManager.default.removeItem(at:root.appendingPathComponent(name)) }
        }
        collectUnusedProfiles()
        while true {
            let wakeToken = wake.token()
            // Never publish health or launch repair through a replaced private root.
            guard (try? PrivateDirectoryPermissions.check(root)) != nil else { teardown(); return 1 }
            guard clientsAlive(root: root) else { break }
            do {
                let current = try ManagedOpenClawDescriptor.load(from: descriptorURL)
                if current != descriptor {
                    guard let permit = try? ManagedRuntimePermit(root:root, repairing:true) else {
                        writeHealth(current,state:"recovering",detail:"Waiting for owned work before refreshing the private runtime",root:root)
                        Thread.sleep(forTimeInterval:0.1); continue
                    }
                    defer { withExtendedLifetime(permit) {} }
                    teardown(); descriptor = current; nextHealth = 0; nextAudit = 0
                    integritySchedule.reset(); repair = false
                    writeHealth(current, state:"recovering", detail:"Preparing private Gateway connectivity", root:root)
                }
                fileHints.configure(ManagedRuntimeFileHints.targets(current, descriptorURL: descriptorURL))
                let now = Date().timeIntervalSince1970
                let monotonicNow = ProcessInfo.processInfo.systemUptime
                let dirtyMetadata = fileHints.takeChanges(at: monotonicNow)
                if dirtyMetadata.contains(.rescanRequired) { integritySchedule.requireFullAudit() }
                let configurationRequest = root.appendingPathComponent("configuration-request.json")
                if let requestDocument = try? PrivateRuntimeMetadata.document(configurationRequest, maximum: PrivateRuntimeMetadata.requestBytes),
                   let value = requestDocument.value as? [String:Any],
                   let id = value["request_id"] as? String, UUID(uuidString:id) != nil,
                   let ownerData = try? JSONSerialization.data(withJSONObject:value["owner"] ?? [:]),
                   let owner = try? JSONDecoder().decode(ManagedProcessIdentity.self,from:ownerData) {
                    if owner.alive {
                        guard let permit = try? ManagedRuntimePermit(root:root, repairing:true) else {
                            Thread.sleep(forTimeInterval:0.1); continue
                        }
                        defer { withExtendedLifetime(permit) {} }
                        writeHealth(current,state:"recovering",detail:"Finishing private configuration update",root:root)
                        teardown()
                        try write(["request_id":id],to:root.appendingPathComponent("configuration-ack.json"))
                        while clientsAlive(root:root) && owner.alive,
                              let pending = try? PrivateRuntimeMetadata.document(configurationRequest, maximum: PrivateRuntimeMetadata.requestBytes),
                              pending.data == requestDocument.data {
                            Thread.sleep(forTimeInterval:0.1)
                        }
                        try? FileManager.default.removeItem(at:root.appendingPathComponent("configuration-ack.json"))
                        descriptor = nil
                        continue
                    } else { try? FileManager.default.removeItem(at:configurationRequest) }
                }
                let request = root.appendingPathComponent("health-request.json")
                let requestValue = try? PrivateRuntimeMetadata.object(request, maximum: PrivateRuntimeMetadata.requestBytes)
                let requested = requestValue != nil
                let faultRequested = requestValue?["fault"] as? Bool == true
                if requested { try? FileManager.default.removeItem(at: request) }
                // Audits are local CLI/readback work, not provider generation.
                // Offline repair is excluded from every native delivery commit.
                let fullIntegrityAuditDue = integritySchedule.shouldRun(at:monotonicNow)
                let forceFullIntegrityAudit = integritySchedule.shouldRun(
                    at:monotonicNow, forced:faultRequested || repair || dirtyMetadata.contains(.installation) || dirtyMetadata.contains(.rescanRequired))
                if now >= nextAudit || faultRequested || requested && repair || fullIntegrityAuditDue || !dirtyMetadata.isEmpty {
                    // Only a routine audit is disposable. Startup/full audits,
                    // fault diagnosis and repairs retain their existing required
                    // path. Deferral is not an integrity failure or restart.
                    var maintenance: LocalWorkloadGovernor.Reservation?
                    if !forceFullIntegrityAudit && !repair && !faultRequested && !requested && dirtyMetadata.isEmpty {
                        do {
                            maintenance = try LocalWorkloadGovernor.shared.reserve(.maintenance)
                            try maintenance?.start()
                        } catch is LocalWorkloadGovernor.Refused {
                            maintenance?.finish(); nextAudit = now + 30
                            continue
                        }
                    }
                    defer { maintenance?.finish() }
                    if !dirtyMetadata.isEmpty {
                        writeHealth(current, state:"recovering", detail:"Checking private runtime changes", root:root)
                        nextHealth = 0
                    }
                    nextAudit = now + 300
                    var auditArguments = ["--managed-openclaw", "audit", "--managed-descriptor", descriptorURL.path]
                    if forceFullIntegrityAudit { auditArguments.append("--force-integrity-audit") }
                    let audit = ownedCommand(root:root, executable:runtimeURL,
                        arguments:auditArguments, timeout:90, schedulingPriority:.utility)
                    let auditResult = Self.object(audit.output)
                    fileHints.refresh()
                    if forceFullIntegrityAudit {
                        integritySchedule.record(at:ProcessInfo.processInfo.systemUptime,
                            succeeded:auditResult?["full_integrity_ok"] as? Bool == true)
                    }
                    if audit.status != 0 || auditResult?["ok"] as? Bool != true {
                        let causes = Set(auditResult?["causes"] as? [String] ?? [])
                        if causes.contains("database_inconclusive") {
                            nextAudit = now + 5; nextHealth = ProcessInfo.processInfo.systemUptime + 5
                            writeHealth(current, state:"recovering",
                                detail:"The private OpenClaw database check was busy or exceeded its short read-only limit. No database files were changed; TaskPilot will check again shortly.", root:root)
                            continue
                        }
                        if causes.contains("database_corrupt") {
                            teardown(); repair = true; nextAudit = now + 300; nextHealth = ProcessInfo.processInfo.systemUptime + 300
                            writeHealth(current, state:"needs_repair",
                                detail:"A private OpenClaw database failed its read-only integrity check. TaskPilot left it unchanged; inspect or reinstall the private runtime before continuing.", root:root)
                            continue
                        }
                        guard let permit = try? ManagedRuntimePermit(root:root, repairing:true) else {
                            nextAudit = now + 1
                            writeHealth(current,state:"recovering",detail:"Waiting for dispatched work to settle before private runtime repair",root:root)
                            Thread.sleep(forTimeInterval:0.1); continue
                        }
                        defer { withExtendedLifetime(permit) {} }
                        if let cause = Self.directoryAttentionCause(auditResult) {
                            teardown(); repair = true
                            writeHealth(current,state:"needs_repair",detail:PrivateVolumeCapabilities.Failure(rawValue: cause)?.localizedDescription ?? "\(cause): Private storage ACL, flags, ownership, or identity needs attention; automatic directory repair was withheld.",root:root)
                            continue
                        }
                        if causes.contains("private_configuration_path_changed") {
                            teardown(); repair = true; nextAudit = now + 300; nextHealth = ProcessInfo.processInfo.systemUptime + 300
                            writeHealth(current,state:"needs_repair",detail:"A private OpenClaw configuration path changed identity during a CLI operation. TaskPilot stopped activation and left the active runtime intact; inspect the private configuration directory before retrying.",root:root)
                            continue
                        }
                        if let detail = Self.cliContractAttentionDetail(auditResult) {
                            teardown(); repair = true; nextAudit = now + 300; nextHealth = ProcessInfo.processInfo.systemUptime + 300
                            writeHealth(current, state:"needs_repair", detail:detail, root:root)
                            continue
                        }
                        writeHealth(current,state:"recovering",detail:"Repairing TaskPilot-owned runtime settings",root:root)
                        teardown()
                        _ = budget.failed()
                        try write(budget,to:root.appendingPathComponent("recovery.json"))
                        let fixed = ownedCommand(root:root, executable:runtimeURL,
                            arguments:["--managed-openclaw", "repair", "--managed-resources", resources.path,
                                       "--managed-descriptor", descriptorURL.path], timeout:1200)
                        if fixed.status == 0 { descriptor = nil; continue }
                        repair = true
                        writeHealth(current,state:"needs_repair",detail:Self.provisioningResourceDetail(fixed.output) ?? "Private runtime repair did not pass its checks. Verify the saved Gemini key or reinstall TaskPilot; repeated repair is bounded.",root:root)
                        continue
                    }
                    repair = false
                }
                let recoveryClock = GatewayRecoveryClock.current
                if budget.synchronize(at: recoveryClock) {
                    try write(budget, to:root.appendingPathComponent("recovery.json"))
                }
                if !repair && budget.probeIsDue(at: recoveryClock) &&
                    (recoveryClock.monotonic >= nextHealth || requested || gateway?.isRunning == false) {
                    if gateway == nil && !budget.restartReserved && budget.restarts.count >= 3 {
                        _ = budget.failed()
                        try write(budget, to:root.appendingPathComponent("recovery.json"))
                        writeHealth(current, state:"recovering", detail:"Private Gateway restart circuit is open; waiting before another local probe", root:root)
                        continue
                    }
                    if gateway == nil {
                        budget.restartReserved = false
                        try write(budget, to:root.appendingPathComponent("recovery.json"))
                        // Binding collision does not authorize killing the listener.
                        if try portCollision(current.port) {
                            let moved = ownedCommand(root:root, executable: runtimeURL,
                                arguments: ["--managed-openclaw", "relocate", "--managed-descriptor", descriptorURL.path], timeout: 15)
                            guard moved.status == 0 else { throw ManagedOpenClawError.command("No private Gateway endpoint is available.") }
                            descriptor = nil; continue
                        }
                        let validation = ownedCommand(root:root, executable: URL(fileURLWithPath: current.executable), arguments:["config", "validate"], timeout:15, environment:current.environment)
                        if validation.status != 0 {
                            nextAudit = 0
                            writeHealth(current, state:"recovering", detail:"Checking private configuration before repair", root:root); continue
                        }
                        let process = SubprocessSupervisor()
                        let output = try BufferedProcessOutput(maximumBytes:0, merged:true)
                        process.executableURL = URL(fileURLWithPath: current.executable)
                        process.arguments = ["gateway", "run", "--bind", "loopback", "--port", String(current.port)]
                        process.terminationHandler = { _ in wake.signal() }
                        process.whenTreeExits { wake.signal() }
                        process.onLaunchAcknowledged = { identity in
                            try write(ManagedProcessIdentity(pid:identity.pid,seconds:identity.seconds,microseconds:identity.microseconds),
                                      to:root.appendingPathComponent("gateway-root.json"))
                        }
                        process.environment = current.environment
                        process.standardOutput = output.stdout; process.standardError = output.stderr
                        try process.run(); output.closeWriters(); gateway = process; capture = output
                        writeHealth(current, state:"recovering", detail:"Starting TaskPilot’s private Gateway", root:root)
                        // Startup polling does not consume restart attempts until the bounded window ends.
                        let deadline = ProcessInfo.processInfo.systemUptime + 20
                        repeat {
                            if !clientsAlive(root: root) { break }
                            let health = ownedCommand(root:root, executable:URL(fileURLWithPath:current.executable), arguments:["health", "--json", "--timeout", "2000"], timeout:5, environment:current.environment)
                            if health.status == 0 { break }
                            Thread.sleep(forTimeInterval:0.2)
                        } while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline
                    }
                    let result = ownedCommand(root:root, executable:URL(fileURLWithPath:current.executable), arguments:["health", "--json", "--timeout", "4000"], timeout:7, environment:current.environment)
                    let healthy = result.status == 0 && Self.object(result.output)?["ok"] as? Bool == true
                    if healthy && !acpVerified {
                        let acp = ownedCommand(root:root, executable:runtimeURL, arguments:["--managed-acp-probe", "--managed-descriptor", descriptorURL.path], timeout:150, environment:current.environment)
                        acpVerified = acp.status == 0
                        let cause = acp.status == -2 ? "timeout" : Self.object(acp.output)?["cause"] as? String ?? "startup"
                        if !acpVerified && cause == "authentication" {
                            repair = true
                            writeHealth(current,state:"needs_repair",detail:"Private Gateway authentication was rejected; checking TaskPilot-owned configuration",root:root)
                            nextAudit = now + 300
                            continue
                        }
                        if !acpVerified && cause == "incompatible" {
                            guard let permit = try? ManagedRuntimePermit(root:root, repairing:true) else { nextAudit = 0; continue }
                            defer { withExtendedLifetime(permit) {} }
                            teardown()
                            let rollback = ownedCommand(root:root, executable:runtimeURL,
                                arguments:["--managed-openclaw", "rollback", "--managed-descriptor", descriptorURL.path], timeout:30)
                            if rollback.status == 0 { descriptor = nil; continue }
                            repair = true
                            writeHealth(current,state:"needs_repair",detail:"Private OpenClaw does not support TaskPilot’s ACP handshake. Reinstall or reconfigure TaskPilot.",root:root)
                            continue
                        }
                    }
                    if healthy && acpVerified {
                        budget.healthy(); nextHealth = ProcessInfo.processInfo.systemUptime + 30
                        writeHealth(current, state:"healthy", detail:"Private Gateway connected; ACP compatible", root:root, gateway:gateway)
                    } else {
                        guard let permit = try? ManagedRuntimePermit(root:root, repairing:true) else {
                            nextAudit = 0; continue
                        }
                        defer { withExtendedLifetime(permit) {} }
                        teardown()
                        nextAudit = 0
                        _ = budget.failed()
                        nextHealth = budget.monotonicProbeDeadline
                        writeHealth(current, state:"recovering", detail:"Private Gateway unavailable; automatic recovery is waiting for its cooldown", root:root)
                    }
                    try write(budget, to:root.appendingPathComponent("recovery.json"))
                }
                if let process = gateway {
                    // Persist birth identities for abandoned-host recovery, without arguments or output.
                    var values = [TPProcessIdentity](repeating:TPProcessIdentity(), count:4096)
                    let count = tp_process_group_snapshot(process.processIdentifier, &values, Int32(values.count))
                    if count >= 0 {
                        let identities = values.prefix(Int(count)).map { ManagedProcessIdentity(pid:$0.pid, seconds:$0.seconds, microseconds:$0.microseconds) }
                        try write(identities, to:root.appendingPathComponent("gateway-processes.json"))
                    }
                }
            } catch {
                if let permit = try? ManagedRuntimePermit(root:root, repairing:true) {
                    teardown(); withExtendedLifetime(permit) {}
                }
                if let descriptor { writeHealth(descriptor, state:"recovering", detail:"Private Gateway local recovery failed; waiting for the next bounded check", root:root) }
                nextAudit = 0
                _ = budget.failed()
                try? write(budget, to:root.appendingPathComponent("recovery.json"))
            }
            // Client/request vnode changes and child exits wake this wait. A
            // bounded five-second timeout preserves recovery if a hint is lost.
            _ = wake.wait(after: wakeToken, timeout: 5)
        }
        if let descriptor { writeHealth(descriptor, state:"stopped", detail:"TaskPilot closed its private Gateway", root:root) }
        return 0
    }
    static func directoryAttentionCause(_ audit: [String:Any]?) -> String? {
        (audit?["causes"] as? [String])?.first {
            $0.hasPrefix("private_directory_") && $0 != "private_directory_permissions"
        }
    }
    static func provisioningResourceDetail(_ text: String) -> String? {
        guard let value = object(text), value["kind"] as? String == "error" else { return nil }
        switch value["error_code"] as? String {
        case "local_resource_disk_space":
            return "Not enough disk space to install or repair TaskPilot’s private OpenClaw. Free disk space, then retry. Any existing working installation was left intact."
        case "local_resource_disk_space_check":
            return "TaskPilot could not check free disk space for private OpenClaw. Check storage availability, then retry. Any existing working installation was left intact."
        case "private_directory_volume_unavailable", "private_directory_volume_atomic_rename", "private_directory_volume_directory_sync":
            return "TaskPilot could not verify replacement and directory syncing on its private storage volume. Check storage availability before retrying installation or repair."
        default: return nil
        }
    }
    static func object(_ text: String) -> [String:Any]? {
        guard text.utf8.count <= PrivateRuntimeMetadata.configurationBytes,
              let data = text.data(using:.utf8) else { return nil }
        return (try? PrivateRuntimeMetadata.parse(data)) as? [String:Any]
    }
    static func cliContractAttentionDetail(_ audit: [String:Any]?) -> String? {
        guard (audit?["causes"] as? [String])?.contains("managed_cli_contract") == true else { return nil }
        return "The pinned OpenClaw CLI does not match TaskPilot’s required configuration interface. Configuration repair was withheld; install a compatible TaskPilot runtime."
    }
    static func portAvailable(_ port: Int) -> Bool { (try? portCollision(port)) == false }
    static func portCollision(_ port: Int) throws -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ManagedOpenClawError.command("Private endpoint inspection failed") }; defer { close(fd) }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self, capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if result == 0 { return false }
        guard errno == EADDRINUSE else { throw ManagedOpenClawError.command("Private endpoint inspection failed") }
        return true
    }
}

final class OpenClawCommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: SubprocessSupervisor?
    private var exit: ProcessExitNotification?
    var isCancelled: Bool { lock.withLock { cancelled } }
    func bind(_ process: SubprocessSupervisor, exit: ProcessExitNotification) {
        lock.withLock { self.process = process; self.exit = exit; if cancelled { exit.interrupt() } }
    }
    func unbind() { lock.withLock { process = nil; exit = nil } }
    func cancel() {
        let owned = lock.withLock { () -> (SubprocessSupervisor?, ProcessExitNotification?) in
            cancelled = true; return (process, exit)
        }
        owned.0?.beginTeardown(); owned.1?.interrupt()
    }
}
