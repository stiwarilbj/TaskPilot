import Darwin
import Foundation
import ProcessSupport

/// Retained by its monitor until the owned tree is empty, independently of the
/// immediate parent's lifetime. No task text, arguments or output enter metrics.
final class SubprocessSupervisor: @unchecked Sendable {
    enum Failure: LocalizedError {
        case launch(Int32), inspection, localResourceExhausted
        var errorDescription: String? {
            switch self {
            case .launch(let code): return "Could not launch an owned process group (\(code)): \(String(cString: strerror(code)))"
            case .inspection: return "Process-tree inspection failed; ownership has not been released"
            case .localResourceExhausted: return "local_resource_exhausted: Insufficient file descriptor headroom to launch a helper. No child was started."
            }
        }
    }
    struct DescriptorHeadroom {
        let available: UInt64
        let softLimit: UInt64
        // One /dev/null handle plus two advisory slots for transient spawn and
        // dispatch monitoring. Caller-created pipes are already in the sample.
        static let launchReserve: UInt64 = 3
        var permitsLaunch: Bool { softLimit >= 3 && available >= Self.launchReserve }
        static func read() -> Self? {
            var available: UInt64 = 0, limit: UInt64 = 0
            guard tp_descriptor_headroom(&available, &limit) == 1 else { return nil }
            return Self(available: available, softLimit: limit)
        }
    }
    struct Snapshot {
        var launched = false, groupAcknowledged = false, parentExited = false
        var treeFinished = false, outputDrained = false, teardownStarted = false
        var descendants = 0, inspectionFailed = false
    }
    enum TreeWait { case finished, interrupted, timedOut }
    var executableURL: URL?
    var arguments: [String] = []
    var environment: [String: String]?
    var currentDirectoryURL: URL?
    var onLaunchAcknowledged: ((TPProcessIdentity) throws -> Void)?
    var standardInput: Any = FileHandle.nullDevice
    var standardOutput: Any = FileHandle.nullDevice
    var standardError: Any = FileHandle.nullDevice
    private var exitHandler: ((SubprocessSupervisor) -> Void)?
    var terminationHandler: ((SubprocessSupervisor) -> Void)? {
        get { condition.withLock { exitHandler } }
        set { condition.withLock { exitHandler = newValue } }
    }
    private(set) var processIdentifier: pid_t = 0
    private let condition = NSCondition()
    // Output readers use their own bounded drain turns. Keep kernel exit and
    // teardown scheduling independent of stdout/stderr volume on that queue.
    private let queue = DispatchQueue(label: "com.orbitagent.process-tree", qos: .utility)
    private var rootExit: DispatchSourceProcess?
    private var monitor: DispatchSourceTimer?
    private var watchers: [pid_t: (TPProcessIdentity, DispatchSourceProcess)] = [:]
    private var identities: [pid_t: TPProcessIdentity] = [:]
    private var rootIdentity: TPProcessIdentity?
    private var groupRetired = false
    private var state = Snapshot()
    private var parentStatus: Int32 = 0
    private var interrupted = false
    private var onTreeExit: [() -> Void] = []
    // Injection rejects before spawn, also exercising group-setup failures.
    private let launchCheck: () throws -> Void
    private let inspectionCheck: () -> Bool
    let descriptorOwner: BackendDescriptors.Owner?
    private let resourceSnapshot: () -> DescriptorHeadroom?

    init(descriptorOwner: BackendDescriptors.Owner? = TaskOwnership.current?.descriptorOwner, launchCheck: @escaping () throws -> Void = {}, inspectionCheck: @escaping () -> Bool = { true },
         resourceSnapshot: @escaping () -> DescriptorHeadroom? = { DescriptorHeadroom.read() }) {
        self.descriptorOwner = descriptorOwner
        self.launchCheck = launchCheck; self.inspectionCheck = inspectionCheck; self.resourceSnapshot = resourceSnapshot
    }
    var snapshot: Snapshot { condition.withLock { state } }
    var isRunning: Bool { condition.withLock { state.launched && !state.parentExited } }
    var terminationStatus: Int32 { condition.withLock { parentStatus } }

    /// Foundation's Pipe does not set FD_CLOEXEC. Protect both controller
    /// copies before registering readers or publishing the pipe to a writer.
    static func makePrivatePipe(owner: BackendDescriptors.Owner? = TaskOwnership.current?.descriptorOwner,
                                subsystem: BackendDescriptors.Subsystem = .subprocess) throws -> Pipe {
        let pipe = Pipe()
        do {
            try protectPipeDescriptors(pipe)
            BackendDescriptors.shared.track(pipe.fileHandleForReading, subsystem: subsystem, owner: owner)
            BackendDescriptors.shared.track(pipe.fileHandleForWriting, subsystem: subsystem, owner: owner)
            return pipe
        }
        catch {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            throw error
        }
    }

    private static func protectPipeDescriptors(_ pipe: Pipe) throws {
        for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
            let descriptor = handle.fileDescriptor
            let flags = Darwin.fcntl(descriptor, F_GETFD)
            guard flags >= 0 else { throw Failure.launch(errno) }
            if flags & FD_CLOEXEC == 0,
               Darwin.fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == -1 {
                throw Failure.launch(errno)
            }
        }
    }

    func run() throws {
        do { try queue.sync {
            try launchCheck()
            guard !snapshot.launched, let executableURL else { throw Failure.launch(EINVAL) }
            // Advisory only: no limit changes or descriptor reservations. A
            // concurrent launch can consume headroom after this read; retain
            // all existing OS launch errors and partial-launch drainage.
            if let resources = resourceSnapshot(), !resources.permitsLaunch { throw Failure.localResourceExhausted }
            let argv = ([executableURL.path] + arguments).map { strdup($0) } + [nil]
            let env = (environment ?? ProcessInfo.processInfo.environment).sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { argv.forEach { free($0) }; env.forEach { free($0) } }
            let null = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
            guard null >= 0 else { throw Failure.launch(errno) }
            let nullTicket = BackendDescriptors.shared.opened(.subprocess, owner: descriptorOwner)
            defer { Darwin.close(null); nullTicket.finish() }
            func descriptor(_ object: Any, reading: Bool) -> Int32 {
                if let pipe = object as? Pipe { return (reading ? pipe.fileHandleForReading : pipe.fileHandleForWriting).fileDescriptor }
                let descriptor = (object as? FileHandle ?? .nullDevice).fileDescriptor
                return descriptor < 0 ? null : descriptor // Foundation's null-device sentinel.
            }
            var pid: pid_t = 0
            let code = tp_spawn(&pid, executableURL.path, argv, env,
                (currentDirectoryURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).path,
                descriptor(standardInput, reading: true), descriptor(standardOutput, reading: false), descriptor(standardError, reading: false))
            guard code == 0 else { throw Failure.launch(code) }
            processIdentifier = pid
            condition.withLock { state.launched = true; state.groupAcknowledged = true }
            var identity = TPProcessIdentity()
            if tp_process_identity(pid, &identity) == 1 { identities[pid] = identity; rootIdentity = identity }
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            rootExit = source
            source.setEventHandler { [self] in
                var status: Int32 = 0
                var result: pid_t
                repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
                // waitpid status macros are not imported by Swift.
                let code: Int32 = result == pid ? ((status & 0x7f) == 0 ? (status >> 8) & 0xff : status & 0x7f) : -1
                condition.withLock { parentStatus = code; state.parentExited = true; condition.broadcast() }
                source.setEventHandler {}; source.cancel(); rootExit = nil
                refresh()
                terminationHandler?(self)
                if snapshot.teardownStarted && !snapshot.treeFinished {
                    DispatchQueue.global(qos: .utility).async { self.signal(SIGKILL) }
                }
            }
            source.resume()
            watchProcesses()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            monitor = timer
            timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(25))
            // Strong retention is intentional: parent exit must not orphan ownership.
            timer.setEventHandler { [self] in refresh() }
            timer.resume()
            // App-owned long-lived services may journal birth/group identity
            // while the child is still suspended. A failed journal never releases it.
            if let onLaunchAcknowledged {
                guard let rootIdentity else { throw Failure.inspection }
                try onLaunchAcknowledged(rootIdentity)
            }
            // The program cannot fork or mutate before ownership and observers
            // are installed. Launch returns only after explicit release.
            if Darwin.kill(pid, SIGCONT) != 0 {
                let code = errno
                _ = Darwin.kill(pid, SIGKILL)
                throw Failure.launch(code)
            }
            // Close only child-side Pipe descriptors; supplied FileHandles
            // remain caller-owned (BufferedProcessOutput closes its writers).
            if let pipe = standardInput as? Pipe { try? pipe.fileHandleForReading.close() }
            for value in [standardOutput, standardError] {
                if let pipe = value as? Pipe { try? pipe.fileHandleForWriting.close() }
            }
            arguments = []; environment = nil; currentDirectoryURL = nil
            standardInput = FileHandle.nullDevice; standardOutput = FileHandle.nullDevice; standardError = FileHandle.nullDevice
        } } catch {
            if snapshot.launched {
                // Release failed after spawn: its stopped root must be reaped
                // before returning failure, without publishing an exit twice.
                terminationHandler = nil
                beginTeardown()
                _ = waitForTree(ignoreInterrupt: true)
            }
            throw error
        }
    }

    private static func same(_ a: TPProcessIdentity, _ b: TPProcessIdentity) -> Bool {
        a.pid == b.pid && a.seconds == b.seconds && a.microseconds == b.microseconds
    }

    private func refresh() {
        guard !snapshot.treeFinished else { return }
        guard inspectionCheck() else {
            condition.withLock { state.inspectionFailed = true; condition.broadcast() }; return
        }
        var values = [TPProcessIdentity](repeating: TPProcessIdentity(), count: 2048)
        var count = tp_process_snapshot(&values, Int32(values.count))
        while count == -EOVERFLOW, values.count < 65536 {
            values = [TPProcessIdentity](repeating: TPProcessIdentity(), count: values.count * 2)
            count = tp_process_snapshot(&values, Int32(values.count))
        }
        guard count >= 0 else {
            condition.withLock { state.inspectionFailed = true; condition.broadcast() }
            return // Fail closed: an unreadable tree is never an empty tree.
        }
        var all = Array(values.prefix(Int(count)))
        if !groupRetired {
            // Query group membership again, after the general inventory, so
            // denied inspection or a concurrent fork cannot look like emptiness.
            var group = [TPProcessIdentity](repeating: TPProcessIdentity(), count: 256)
            var members = tp_process_group_snapshot(processIdentifier, &group, Int32(group.count))
            while members == -EOVERFLOW, group.count < 65536 {
                group = [TPProcessIdentity](repeating: TPProcessIdentity(), count: group.count * 2)
                members = tp_process_group_snapshot(processIdentifier, &group, Int32(group.count))
            }
            guard members >= 0 else {
                condition.withLock { state.inspectionFailed = true; condition.broadcast() }; return
            }
            all.append(contentsOf: group.prefix(Int(members)))
        }
        let current = Dictionary(all.map { ($0.pid, $0) }, uniquingKeysWith: { _, latest in latest })
        for pid in identities.keys where current[pid] == nil {
            if kill(pid, 0) == 0 || errno != ESRCH {
                condition.withLock { state.inspectionFailed = true; condition.broadcast() }; return
            }
        }
        if let rootIdentity, let replacement = current[processIdentifier], !Self.same(rootIdentity, replacement) {
            groupRetired = true // A reused root PID cannot create another owned group.
        }
        if snapshot.parentExited && !current.values.contains(where: { $0.group == processIdentifier && $0.zombie == 0 }) {
            groupRetired = true // Escaped tracked children cannot keep an empty group ID reserved.
        }
        identities = identities.reduce(into: [:]) { result, entry in
            if let now = current[entry.key], Self.same(entry.value, now) { result[entry.key] = now }
        }
        // Spawn's SETPGROUP acknowledgement binds this group even if a very
        // short-lived root exits before the first inspection. Once empty it is
        // retired permanently, so a later reused PID cannot reacquire ownership.
        if !groupRetired {
            for item in current.values where item.group == processIdentifier { identities[item.pid] = item }
        }
        var added = true
        while added {
            added = false
            for item in current.values where identities[item.pid] == nil && identities[item.parent] != nil {
                identities[item.pid] = item; added = true
            }
        }
        let alive = identities.values.filter { $0.zombie == 0 }
        watchProcesses()
        let finished = condition.withLock { () -> Bool in
            state.descendants = alive.filter { $0.pid != processIdentifier }.count
            state.inspectionFailed = false
            state.treeFinished = state.parentExited && alive.isEmpty
            condition.broadcast()
            return state.treeFinished
        }
        if finished {
            monitor?.cancel(); monitor = nil
            for (_, source) in watchers.values { source.cancel() }
            watchers.removeAll()
            let callbacks = onTreeExit; onTreeExit.removeAll()
            for callback in callbacks { callback() }
        }
    }

    private func watchProcesses() {
        for (pid, (identity, source)) in watchers {
            if identities[pid].map({ Self.same(identity, $0) && $0.zombie == 0 }) != true {
                source.cancel(); watchers.removeValue(forKey: pid)
            }
        }
        for identity in identities.values where identity.zombie == 0 && watchers[identity.pid] == nil {
            guard watchers.count < 1024 else { break } // Inventory fallback still owns the remainder.
            let mask: DispatchSource.ProcessEvent = identity.pid == processIdentifier ? [.fork, .exec] : [.fork, .exec, .exit]
            let source = DispatchSource.makeProcessSource(identifier: identity.pid, eventMask: mask, queue: queue)
            watchers[identity.pid] = (identity, source)
            source.setEventHandler { [weak self] in self?.refresh() }
            source.resume()
        }
    }

    func interrupt() { condition.withLock { interrupted = true; condition.broadcast() } }

    func waitForTree(until deadline: DispatchTime = .distantFuture, ignoreInterrupt: Bool = false) -> TreeWait {
        condition.lock(); defer { condition.unlock() }
        while !state.treeFinished {
            if interrupted && !ignoreInterrupt { return .interrupted }
            if deadline == .distantFuture { condition.wait(); continue }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else { return .timedOut }
            _ = condition.wait(until: Date(timeIntervalSinceNow: Double(deadline.uptimeNanoseconds - now) / 1e9))
        }
        return .finished
    }

    func signal(_ signal: Int32) {
        queue.sync {
            refresh()
            guard !snapshot.treeFinished else { return }
            var live: [TPProcessIdentity] = []
            for old in identities.values {
                var current = TPProcessIdentity()
                if tp_process_identity(old.pid, &current) == 1, Self.same(old, current), current.zombie == 0 { live.append(current) }
            }
            // A live, identity-checked member anchors group ownership. This
            // also reaches children forked between inspection and signal.
            let groupOwned = !groupRetired && live.contains { $0.group == processIdentifier }
            if groupOwned { _ = kill(-processIdentifier, signal) }
            for item in live where !groupOwned || item.group != processIdentifier { _ = kill(item.pid, signal) }
        }
    }

    func terminate() { signal(SIGTERM) }
    func beginTeardown(grace: TimeInterval = 1) {
        let start = condition.withLock { () -> Bool in
            guard !state.teardownStarted else { return false }
            state.teardownStarted = true; return true
        }
        guard start else { return }
        signal(SIGCONT); signal(SIGTERM)
        if snapshot.parentExited { signal(SIGKILL); return }
        queue.asyncAfter(deadline: .now() + grace) { [self] in
            // Run outside our serial queue; signal performs serialized inspection.
            DispatchQueue.global(qos: .utility).async { self.signal(SIGKILL) }
        }
    }
    func markOutputDrained() { condition.withLock { state.outputDrained = true } }
    func whenTreeExits(_ callback: @escaping () -> Void) {
        queue.async { [self] in
            if snapshot.treeFinished { callback() } else { onTreeExit.append(callback) }
        }
    }
}

/// Explicitly requested background services remain owned resources, even when
/// cleanup is off and their originating task has retired. Only compatibility
/// metadata lives here; command text, output and task IDs are never retained.
final class PersistentProcessResources: @unchecked Sendable {
    static let shared = PersistentProcessResources()
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: SubprocessSupervisor] = [:]
    func retain(_ process: SubprocessSupervisor) {
        let id = ObjectIdentifier(process)
        lock.withLock { processes[id] = process }
        process.whenTreeExits { [weak self] in _ = self?.lock.withLock { self?.processes.removeValue(forKey: id) } }
    }
}
