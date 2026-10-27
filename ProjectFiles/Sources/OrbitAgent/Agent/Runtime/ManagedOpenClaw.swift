import Darwin
import Foundation
import ProcessSupport

/// Private runtime compatibility boundary; never falls back to PATH or a shared profile.
struct ManagedOpenClawDescriptor: Codable, Equatable, Sendable {
    let version: Int
    let instanceID: String
    let installationFingerprint: String
    let configurationFingerprint: String
    let executable: String
    let node: String
    let entry: String
    let state: String
    let config: String
    let workspace: String
    let tokenFile: String
    let endpoint: String
    let port: Int
    let openclawVersion: String
    let nodeVersion: String
    private var sourceURL: URL? = nil
    enum CodingKeys: String, CodingKey {
        case version, executable, node, entry, state, config, workspace, endpoint, port
        case instanceID = "instance_id", installationFingerprint = "installation_fingerprint"
        case configurationFingerprint = "configuration_fingerprint", tokenFile = "token_file"
        case openclawVersion = "openclaw_version", nodeVersion = "node_version"
    }
    static let root = GeminiAPIKeyStore.defaultFileURL().deletingLastPathComponent().appendingPathComponent("ManagedOpenClaw")
    static let url = root.appendingPathComponent("runtime.json")
    static func load(from url: URL = Self.url) throws -> Self {
        var value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        let root = url.deletingLastPathComponent().resolvingSymlinksInPath().path + "/"
        guard value.version == 1, UUID(uuidString: value.instanceID) != nil,
              value.port > 1024, value.port < 65400,
              value.endpoint == "ws://127.0.0.1:\(value.port)",
              [value.executable, value.node, value.entry, value.state, value.config, value.workspace, value.tokenFile]
                .allSatisfy({ $0.hasPrefix("/") && URL(fileURLWithPath: $0).resolvingSymlinksInPath().path.hasPrefix(root) }) else {
            throw ManagedOpenClawError.invalidDescriptor
        }
        value.sourceURL = url
        return value
    }
    func checkPrivateDirectories() throws {
        let root = (sourceURL ?? Self.url).deletingLastPathComponent().standardizedFileURL
        var paths: Set<URL> = [root]
        let installation = URL(fileURLWithPath: node).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for leaf in [installation, URL(fileURLWithPath: state), URL(fileURLWithPath: workspace), URL(fileURLWithPath: config).deletingLastPathComponent()] {
            var current = leaf.standardizedFileURL
            while current.path != root.path {
                guard current.path.hasPrefix(root.path + "/") else { throw ManagedOpenClawError.invalidDescriptor }
                paths.insert(current); current.deleteLastPathComponent()
            }
        }
        for name in ["state", "agents", "agents/main", "agents/main/agent"] {
            let candidate = URL(fileURLWithPath: state).appendingPathComponent(name)
            var status = stat()
            if lstat(candidate.path, &status) == 0 { paths.insert(candidate) }
        }
        for path in paths.sorted(by: { $0.pathComponents.count < $1.pathComponents.count }) {
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

/// A single budget survives host/app restarts. Refresh and task starts cannot reset it.
struct GatewayRecoveryBudget: Codable, Equatable {
    var restarts: [TimeInterval] = []
    var nextProbe: TimeInterval = 0
    var circuits = 0
    var restartReserved = false
    enum CodingKeys: String, CodingKey { case restarts, nextProbe, circuits, restartReserved }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        restarts = try values.decode([TimeInterval].self, forKey:.restarts)
        nextProbe = try values.decode(TimeInterval.self, forKey:.nextProbe)
        circuits = try values.decode(Int.self, forKey:.circuits)
        restartReserved = try values.decodeIfPresent(Bool.self, forKey:.restartReserved) ?? false
    }
    mutating func failed(now: TimeInterval) -> TimeInterval {
        restarts.removeAll { now - $0 >= 600 }
        if restarts.count < 3 {
            let delay: TimeInterval = [1, 3, 10][restarts.count]
            restarts.append(now); restartReserved = true; nextProbe = now + delay; return delay
        }
        let delay = min(300.0, 60.0 * pow(2, Double(min(circuits, 3))))
        restartReserved = false
        circuits += 1; nextProbe = now + delay; return delay
    }
    mutating func healthy() { restartReserved = false; circuits = 0; nextProbe = 0 } // Restarts remain spent for ten minutes.
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
            if let data = try? Data(contentsOf: file), let identity = try? JSONDecoder().decode(ManagedProcessIdentity.self, from: data), identity.alive {
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
            if let data = try? Data(contentsOf:root.appendingPathComponent("health.json")),
               let value = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
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
                                     environment: [String:String]? = nil) -> OpenClawService.CommandResult {
        let cancellation = OpenClawCommandCancellation()
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
                                  environment:environment, cancellation:cancellation)
    }

    static func run(descriptorURL: URL, runtimeURL: URL) -> Int32 {
        let root = descriptorURL.deletingLastPathComponent()
        guard (try? PrivateDirectoryPermissions.check(root)) != nil else { return 1 }
        let lock = open(root.appendingPathComponent("gateway-owner.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { return 1 }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return 0 } // Another valid host owns drainage too.
        var budget = (try? JSONDecoder().decode(GatewayRecoveryBudget.self, from: Data(contentsOf: root.appendingPathComponent("recovery.json")))) ?? GatewayRecoveryBudget()
        var gateway: SubprocessSupervisor?
        var capture: BufferedProcessOutput?
        var descriptor: ManagedOpenClawDescriptor?
        var nextHealth: TimeInterval = 0
        var nextAudit: TimeInterval = 0
        var integritySchedule = FullIntegrityAuditSchedule()
        let fileHints = ManagedRuntimeFileHints(root: root)
        defer { fileHints.close() }
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
        defer {
            teardown()
            for name in ["gateway-processes.json", "gateway-root.json"] { try? FileManager.default.removeItem(at:root.appendingPathComponent(name)) }
        }
        // The root was durably recorded while suspended, before it could fork.
        // Capture live group members before retirement; after root exit, signal
        // only those recorded birth identities (never a potentially reused group).
        var abandoned: [ManagedProcessIdentity] = []
        if let data = try? Data(contentsOf:root.appendingPathComponent("gateway-root.json")),
           let owner = try? JSONDecoder().decode(ManagedProcessIdentity.self,from:data), owner.alive {
            var members = [TPProcessIdentity](repeating:TPProcessIdentity(),count:65536)
            let count = tp_process_group_snapshot(owner.pid,&members,Int32(members.count))
            if count < 0 { return 1 } // Ownership cannot be safely handed off.
            abandoned = members.prefix(Int(count)).map { ManagedProcessIdentity(pid:$0.pid,seconds:$0.seconds,microseconds:$0.microseconds) }
            if owner.alive { _ = Darwin.kill(-owner.pid,SIGTERM) }
        }
        // Recover only recorded birth identities. Never signal a reused PID or an unrelated listener.
        if let data = try? Data(contentsOf: root.appendingPathComponent("gateway-processes.json")),
           let old = try? JSONDecoder().decode([ManagedProcessIdentity].self, from: data) {
            abandoned += old
            for process in abandoned where process.alive { _ = Darwin.kill(process.pid, SIGTERM) }
            Thread.sleep(forTimeInterval: 0.2)
            for process in abandoned where process.alive { _ = Darwin.kill(process.pid, SIGKILL) }
        }
        for process in abandoned where process.alive { _ = Darwin.kill(process.pid,SIGKILL) }
        let drainage = ProcessInfo.processInfo.systemUptime + 5
        while abandoned.contains(where: { $0.alive }) && ProcessInfo.processInfo.systemUptime < drainage { Thread.sleep(forTimeInterval:0.02) }
        guard !abandoned.contains(where: { $0.alive }) else { return 1 }
        while true {
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
                if let data = try? Data(contentsOf:configurationRequest),
                   let value = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
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
                              let pending = try? Data(contentsOf:configurationRequest), pending == data {
                            Thread.sleep(forTimeInterval:0.1)
                        }
                        try? FileManager.default.removeItem(at:root.appendingPathComponent("configuration-ack.json"))
                        descriptor = nil
                        continue
                    } else { try? FileManager.default.removeItem(at:configurationRequest) }
                }
                let request = root.appendingPathComponent("health-request.json")
                let requested = FileManager.default.fileExists(atPath: request.path)
                let faultRequested = (try? Data(contentsOf:request)).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }?["fault"] as? Bool == true
                if requested { try? FileManager.default.removeItem(at: request) }
                // Audits are local CLI/readback work, not provider generation.
                // Offline repair is excluded from every native delivery commit.
                let fullIntegrityAuditDue = integritySchedule.shouldRun(at:monotonicNow)
                let forceFullIntegrityAudit = integritySchedule.shouldRun(
                    at:monotonicNow, forced:faultRequested || repair || dirtyMetadata.contains(.installation) || dirtyMetadata.contains(.rescanRequired))
                if now >= nextAudit || faultRequested || requested && repair || fullIntegrityAuditDue || !dirtyMetadata.isEmpty {
                    if !dirtyMetadata.isEmpty {
                        writeHealth(current, state:"recovering", detail:"Checking private runtime changes", root:root)
                        nextHealth = 0
                    }
                    nextAudit = now + 300
                    var auditArguments = ["--managed-openclaw", "audit", "--managed-descriptor", descriptorURL.path]
                    if forceFullIntegrityAudit { auditArguments.append("--force-integrity-audit") }
                    let audit = ownedCommand(root:root, executable:runtimeURL,
                        arguments:auditArguments, timeout:90)
                    let auditResult = Self.object(audit.output)
                    fileHints.refresh()
                    if forceFullIntegrityAudit {
                        integritySchedule.record(at:ProcessInfo.processInfo.systemUptime,
                            succeeded:auditResult?["full_integrity_ok"] as? Bool == true)
                    }
                    if audit.status != 0 || auditResult?["ok"] as? Bool != true {
                        guard let permit = try? ManagedRuntimePermit(root:root, repairing:true) else {
                            nextAudit = now + 1
                            writeHealth(current,state:"recovering",detail:"Waiting for dispatched work to settle before private runtime repair",root:root)
                            Thread.sleep(forTimeInterval:0.1); continue
                        }
                        defer { withExtendedLifetime(permit) {} }
                        if let cause = Self.directoryAttentionCause(auditResult) {
                            teardown(); repair = true
                            writeHealth(current,state:"needs_repair",detail:"\(cause): Private storage ownership or identity needs attention; automatic directory repair was withheld.",root:root)
                            continue
                        }
                        writeHealth(current,state:"recovering",detail:"Repairing TaskPilot-owned runtime settings",root:root)
                        teardown()
                        _ = budget.failed(now:now)
                        try write(budget,to:root.appendingPathComponent("recovery.json"))
                        let fixed = ownedCommand(root:root, executable:runtimeURL,
                            arguments:["--managed-openclaw", "repair", "--managed-resources", resources.path,
                                       "--managed-descriptor", descriptorURL.path], timeout:1200)
                        if fixed.status == 0 { descriptor = nil; continue }
                        repair = true
                        writeHealth(current,state:"needs_repair",detail:"Private runtime repair did not pass its checks. Verify the saved Gemini key or reinstall TaskPilot; repeated repair is bounded.",root:root)
                        continue
                    }
                    repair = false
                }
                if !repair && now >= budget.nextProbe && (now >= nextHealth || requested || gateway?.isRunning == false) {
                    budget.restarts.removeAll { now - $0 >= 600 }
                    if gateway == nil && !budget.restartReserved && budget.restarts.count >= 3 {
                        _ = budget.failed(now: now)
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
                    let healthy = result.status == 0 && (result.output.data(using:.utf8).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] })?["ok"] as? Bool == true
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
                        budget.healthy(); nextHealth = now + 30
                        writeHealth(current, state:"healthy", detail:"Private Gateway connected; ACP compatible", root:root, gateway:gateway)
                    } else {
                        guard let permit = try? ManagedRuntimePermit(root:root, repairing:true) else {
                            nextAudit = 0; continue
                        }
                        defer { withExtendedLifetime(permit) {} }
                        teardown()
                        nextAudit = 0
                        _ = budget.failed(now: Date().timeIntervalSince1970)
                        nextHealth = budget.nextProbe
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
                _ = budget.failed(now:Date().timeIntervalSince1970)
                try? write(budget, to:root.appendingPathComponent("recovery.json"))
            }
            Thread.sleep(forTimeInterval:1)
        }
        if let descriptor { writeHealth(descriptor, state:"stopped", detail:"TaskPilot closed its private Gateway", root:root) }
        return 0
    }
    static func directoryAttentionCause(_ audit: [String:Any]?) -> String? {
        (audit?["causes"] as? [String])?.first {
            $0.hasPrefix("private_directory_") && $0 != "private_directory_permissions"
        }
    }
    static func object(_ text: String) -> [String:Any]? {
        text.data(using:.utf8).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
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
