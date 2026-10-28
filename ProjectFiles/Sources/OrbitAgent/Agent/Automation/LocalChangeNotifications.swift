import ApplicationServices
import Darwin
import Foundation

/// Notifications are wakeups, never evidence. A signal belongs to one local
/// wait and one suspension epoch; it cannot resume a newer task or observation.
final class LocalChangeSignal: @unchecked Sendable {
    enum Wake: String { case notification, poll, interrupted }
    private let lock = NSLock()
    private let lease: TaskLease?
    private let epoch: Int
    private var pending = false
    private var closed = false
    private var waiter: CheckedContinuation<Wake, Never>?
    private var waiterID: UUID?
    private var timer: DispatchWorkItem?
    private var notificationCount = 0
    var notifications: Int { lock.withLock { notificationCount } }

    init(lease: TaskLease? = TaskOwnership.current) {
        self.lease = lease; epoch = lease?.suspensionRevision ?? 0
    }
    var isCurrent: Bool {
        lease == nil || (lease?.state == .running && lease?.suspensionRevision == epoch)
    }
    func notify() {
        guard isCurrent else { return }
        lock.lock()
        guard !closed else { lock.unlock(); return }
        notificationCount += 1; pending = true
        let continuation = waiter
        if continuation != nil { pending = false }
        waiter = nil; waiterID = nil; timer?.cancel(); timer = nil
        lock.unlock()
        continuation?.resume(returning: .notification)
    }
    func close() {
        lock.lock(); closed = true; pending = false
        let continuation = waiter; waiter = nil; waiterID = nil; timer?.cancel(); timer = nil
        lock.unlock()
        continuation?.resume(returning: .interrupted)
    }
    private func timeout(_ id: UUID) {
        lock.lock()
        guard waiterID == id else { lock.unlock(); return }
        let continuation = waiter; waiter = nil; waiterID = nil; timer = nil; lock.unlock()
        continuation?.resume(returning: .poll)
    }
    func wait(seconds: TimeInterval) async -> Wake {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                lock.lock()
                if closed || !isCurrent || Task.isCancelled {
                    lock.unlock(); continuation.resume(returning: .interrupted); return
                }
                if pending {
                    pending = false; lock.unlock(); continuation.resume(returning: .notification); return
                }
                // A wait has exactly one consumer. Its timeout and callbacks
                // compete under the same lock, so it is resumed exactly once.
                precondition(waiter == nil)
                waiter = continuation
                let id = UUID(); waiterID = id
                let work = DispatchWorkItem { [weak self] in self?.timeout(id) }
                timer = work
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, seconds), execute: work)
                lock.unlock()
            }
        }, onCancel: { self.close() })
    }
}

protocol LocalChangeSource: AnyObject {
    var supported: Bool { get }
    func refresh() async
    func close() async
}

/// Builds a bounded, ordered set of native element/notification pairs. AXUIElement
/// wrappers may be repeated in candidate lists, so identity is supplied by the
/// native caller (CFHash/CFEqual for Accessibility) rather than presentation data.
struct AccessibilityNotificationRegistrationPlanner {
    struct Pair<Element, Event> {
        let element: Element
        let event: Event
    }

    static func plan<Element, Event>(
        elements: [Element], application: Element,
        elementEvents: [Event], applicationEvents: [Event], maximum: Int,
        identityHash: (Element) -> UInt,
        elementsEqual: (Element, Element) -> Bool,
        eventsEqual: (Event, Event) -> Bool
    ) -> [Pair<Element, Event>] {
        guard maximum > 0 else { return [] }

        // Keep only the first two distinct elements for priority, ensuring a
        // repeated target cannot displace its container and a large candidate
        // list never becomes another unbounded allocation.
        var priorityElements: [Element] = []
        var priorityBuckets: [UInt: [Element]] = [:]
        for element in elements {
            if priorityElements.count == 2 { break }
            let hash = identityHash(element)
            guard !(priorityBuckets[hash] ?? []).contains(where: { elementsEqual($0, element) }) else { continue }
            priorityBuckets[hash, default: []].append(element)
            priorityElements.append(element)
        }

        var pairs: [Pair<Element, Event>] = []
        var pairBuckets: [UInt: [Pair<Element, Event>]] = [:]
        func append(_ element: Element, _ event: Event) {
            guard pairs.count < maximum else { return }
            let hash = identityHash(element)
            if (pairBuckets[hash] ?? []).contains(where: {
                elementsEqual($0.element, element) && eventsEqual($0.event, event)
            }) { return }
            let pair = Pair(element: element, event: event)
            pairBuckets[hash, default: []].append(pair)
            pairs.append(pair)
        }

        // Callers place the intended target first and its container second.
        // Register those before application events, then use remaining capacity
        // for additional candidates. This keeps the useful wakeups when a large
        // candidate list reaches the ceiling.
        for element in priorityElements {
            for event in elementEvents {
                append(element, event)
                if pairs.count == maximum { return pairs }
            }
        }
        for event in applicationEvents {
            append(application, event)
            if pairs.count == maximum { return pairs }
        }
        for element in elements where !priorityElements.contains(where: { elementsEqual($0, element) }) {
            for event in elementEvents {
                append(element, event)
                if pairs.count == maximum { return pairs }
            }
        }
        return pairs
    }
}

/// One scoped native subscription. AX registration/removal and callbacks use
/// the main run loop; vnode descriptors are closed before the wait drains.
final class NativeChangeSubscription: LocalChangeSource {
    static let accessibilityRegistrationLimit = 32

    private struct FileWatch {
        let path: String
        let device: dev_t
        let inode: ino_t
        let descriptor: Int32
        let source: DispatchSourceFileSystemObject
    }
    private let signal: LocalChangeSignal
    private var observer: AXObserver?
    private var observerSourceInstalled = false
    private var registrations: [(AXUIElement, CFString)] = []
    private var fileURL: URL?
    private var files: [FileWatch] = []
    private var closed = false
    var supported: Bool { !registrations.isEmpty || !files.isEmpty }

    init(signal: LocalChangeSignal) { self.signal = signal }

    static func accessibility(pid: pid_t?, elements: [AXUIElement], signal: LocalChangeSignal,
                              deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 0.5) async -> NativeChangeSubscription {
        let source = NativeChangeSubscription(signal: signal)
        let deadline = min(deadline, LocalOperationBudget.current?.deadline ?? deadline)
        await MainActor.run {
            guard signal.isCurrent, !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline,
                  let pid, pid > 0 else { return }
            var observer: AXObserver?
            guard AXObserverCreate(pid, { _, _, _, context in
                guard let context else { return }
                Unmanaged<LocalChangeSignal>.fromOpaque(context).takeUnretainedValue().notify()
            }, &observer) == .success, let observer else { return }
            source.observer = observer
            let app = AXUIElementCreateApplication(pid)
            let applicationEvents = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                kAXFocusedUIElementChangedNotification, kAXLayoutChangedNotification,
                kAXMenuOpenedNotification, kAXMenuClosedNotification]
            let controlEvents = [kAXValueChangedNotification, kAXSelectedChildrenChangedNotification,
                kAXElementBusyChangedNotification, kAXUIElementDestroyedNotification]
            let context = Unmanaged.passUnretained(signal).toOpaque()
            let plan = AccessibilityNotificationRegistrationPlanner.plan(
                elements: elements, application: app,
                elementEvents: controlEvents, applicationEvents: applicationEvents,
                maximum: Self.accessibilityRegistrationLimit,
                identityHash: { UInt(CFHash($0)) }, elementsEqual: { CFEqual($0, $1) },
                eventsEqual: ==
            )
            for pair in plan {
                // Unsupported or over-ceiling pairs retain the existing bounded
                // polling fallback. Every planned pair consumes at most one AX
                // call, and accepted registrations alone are removed at close.
                guard signal.isCurrent, !Task.isCancelled,
                      ProcessInfo.processInfo.systemUptime < deadline else { break }
                AXUIElementSetMessagingTimeout(pair.element,
                    Float(min(0.05, max(0.001, deadline - ProcessInfo.processInfo.systemUptime))))
                let notification = pair.event as CFString
                let status = AXObserverAddNotification(observer, pair.element, notification, context)
                AXUIElementSetMessagingTimeout(pair.element, 0)
                if status == .success { source.registrations.append((pair.element, notification)) }
            }
            if !source.registrations.isEmpty {
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                source.observerSourceInstalled = true
            }
        }
        return source
    }

    static func file(_ url: URL, signal: LocalChangeSignal) async -> NativeChangeSubscription {
        let source = NativeChangeSubscription(signal: signal); source.fileURL = url
        await source.refresh()
        return source
    }

    /// Watch the file and nearest existing ancestor: this covers content writes,
    /// atomic replacement, deletion, and initially absent parent directories.
    /// Also watch the resolved location for symlinked destinations, without
    /// keeping user paths or content in any persistent compatibility profile.
    static func fileWatchPaths(_ url: URL) -> [String] {
        var paths: Set<String> = []
        for target in [url.standardizedFileURL, url.resolvingSymlinksInPath()] {
            if FileManager.default.fileExists(atPath: target.path) { paths.insert(target.path) }
            var ancestor = target.deletingLastPathComponent()
            for _ in 0..<64 {
                if FileManager.default.fileExists(atPath: ancestor.path) { paths.insert(ancestor.path); break }
                let parent = ancestor.deletingLastPathComponent()
                if parent == ancestor { break }; ancestor = parent
            }
        }
        return Array(paths.sorted().prefix(4))
    }

    func refresh() async {
        guard !closed, signal.isCurrent, let fileURL else { return }
        let desired = Self.fileWatchPaths(fileURL)
        var retained: [FileWatch] = []
        for watch in files {
            var current = stat()
            if desired.contains(watch.path), Darwin.lstat(watch.path, &current) == 0,
               current.st_dev == watch.device, current.st_ino == watch.inode { retained.append(watch) }
            else { await Self.cancel(watch) }
        }
        files = retained
        for path in desired where !files.contains(where: { $0.path == path }) && signal.isCurrent {
            let descriptor = Darwin.open(path, O_EVTONLY | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { continue }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG || metadata.st_mode & S_IFMT == S_IFDIR else {
                Darwin.close(descriptor); continue
            }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke, .link],
                queue: DispatchQueue.global(qos: .utility))
            source.setEventHandler { [weak signal] in signal?.notify() }
            // Installed before resume; replacement never changes this handler
            // until cancellation is requested on the same scoped source.
            source.setCancelHandler { Darwin.close(descriptor) }
            files.append(.init(path: path, device: metadata.st_dev, inode: metadata.st_ino, descriptor: descriptor, source: source))
            source.resume()
        }
    }

    private static func cancel(_ watch: FileWatch) async {
        await withCheckedContinuation { continuation in
            watch.source.setCancelHandler { Darwin.close(watch.descriptor); continuation.resume() }
            watch.source.cancel()
        }
    }

    func close() async {
        guard !closed else { return }; closed = true; signal.close()
        await MainActor.run {
            if let observer {
                if observerSourceInstalled {
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                    observerSourceInstalled = false
                }
                for (element, event) in registrations {
                    // Cleanup must not wait on a hung application's default AX
                    // timeout. Releasing the observer also removes its source.
                    AXUIElementSetMessagingTimeout(element, 0.01)
                    AXObserverRemoveNotification(observer, element, event)
                    AXUIElementSetMessagingTimeout(element, 0)
                }
            }
            registrations.removeAll(); observer = nil
        }
        for watch in files { await Self.cancel(watch) }
        files.removeAll()
    }
}

enum LocalChangeWait {
    struct Result {
        let reason: String
        let candidate: Bool?
        let checks: Int
        let notifications: Int
        let pollWakeups: Int
        let supported: Bool
        var dictionary: [String: Any] {
            ["reason": reason, "effect_ready": candidate.map { $0 as Any } ?? NSNull(),
             "targeted_checks": checks, "notifications": notifications, "poll_wakeups": pollWakeups, "notification_supported": supported]
        }
    }
    /// Register first, then recheck. Lost/irrelevant events cannot satisfy a
    /// condition; absent/unsupported events get the same bounded readback.
    static func run(signal: LocalChangeSignal, source: LocalChangeSource, deadline: TimeInterval,
                    minimumDelay: TimeInterval = 0, check: () async throws -> Bool?,
                    now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                    sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                    wake: ((TimeInterval) async -> LocalChangeSignal.Wake)? = nil) async throws -> Result {
        let supported = source.supported
        var count = 0
        var candidate: Bool?
        var polls = 0
        var drained = false
        func drain() async {
            guard !drained else { return }; drained = true
            signal.close(); await source.close()
        }
        do {
            try await TaskOwnership.checkpoint()
            if minimumDelay > 0 { try await sleep(max(0, min(minimumDelay, deadline - now()))) }
            guard signal.isCurrent else {
                await drain()
                try await TaskOwnership.checkpoint()
                return .init(reason: "resumed", candidate: nil, checks: 0, notifications: signal.notifications, pollWakeups: polls, supported: supported)
            }
            try TaskOwnership.check(); try LocalOperationBudget.check("effect_check")
            candidate = try await check(); if candidate != nil { count += 1 }
            var reason = "condition_candidate"
            while candidate != true, signal.isCurrent, now() < deadline {
                let interval = LocalOperationBudget.allowance(max(0, min(0.5, deadline - now())))
                let result: LocalChangeSignal.Wake
                if let wake { result = await wake(interval) }
                else { result = await signal.wait(seconds: interval) }
                if result == .poll { polls += 1 }
                try Task.checkCancellation()
                guard signal.isCurrent else { reason = "resumed"; candidate = nil; break }
                if result == .notification {
                    // Coalesce bursts without repeatedly reading a large tree.
                    try await sleep(max(0, min(0.05, deadline - now())))
                }
                guard signal.isCurrent else { reason = "resumed"; candidate = nil; break }
                try TaskOwnership.check(); try LocalOperationBudget.check("effect_check")
                await source.refresh()
                guard signal.isCurrent else { reason = "resumed"; candidate = nil; break }
                candidate = try await check(); if candidate != nil { count += 1 }
                reason = result == .notification ? "change_notification" : "poll_timeout"
                if candidate == nil { break }
            }
            await drain()
            try await TaskOwnership.checkpoint()
            if !signal.isCurrent { reason = "resumed"; candidate = nil }
            return .init(reason: reason, candidate: candidate, checks: count,
                         notifications: signal.notifications, pollWakeups: polls, supported: supported)
        } catch {
            await drain()
            throw error
        }
    }
}

/// Task-scoped, bounded discovery subscriptions. Missing AX notifications never
/// imply an unchanged tree: unsupported registration disables topology reuse.
/// The post-capture pass enumerates afresh even when registration succeeds.
final class NativeGraphSession: @unchecked Sendable {
    typealias MonitorInstaller = @MainActor (AutomationApplicationIdentity, [AXUIElement], NativeAccessibilityGraph<AXUIElement>) -> (() -> Void)
    private final class Application {
        let identity: AutomationApplicationIdentity
        let windows: [AXUIElement]
        let graph: NativeAccessibilityGraph<AXUIElement>
        var observer: AXObserver? // main run loop only
        var injectedClose: (() -> Void)? // offline notification provider
        init(_ identity: AutomationApplicationIdentity, windows: [AXUIElement]) {
            self.identity = identity; self.windows = windows
            graph = NativeAccessibilityGraph<AXUIElement>(processIdentity: identity,
                hash: { UInt(CFHash($0)) }, equal: { CFEqual($0, $1) })
        }
    }
    private let lock = NSLock()
    private let lease: TaskLease
    private let epoch: Int
    private var applications: [pid_t: Application] = [:]
    private var closed = false
    private var revocation: UUID?
    private let installer: MonitorInstaller?
    init(lease: TaskLease, installer: MonitorInstaller? = nil) {
        self.installer = installer
        self.lease = lease; epoch = lease.suspensionRevision
        revocation = lease.observeRevocation { [weak self] in self?.close() }
    }
    var isCurrent: Bool { lease.state == .running && lease.suspensionRevision == epoch && !lock.withLock { closed } }
    func matches(_ lease: TaskLease) -> Bool { self.lease === lease && isCurrent }

    func prepare(_ identity: AutomationApplicationIdentity, windows: [AXUIElement]) {
        guard isCurrent else { return }
        var old: Application?
        let app: Application? = lock.withLock {
            guard !closed else { return nil }
            if let current = applications[identity.pid], current.identity == identity,
               current.windows.count == windows.count,
               zip(current.windows, windows).allSatisfy({ CFEqual($0, $1) }) { return nil }
            old = applications.removeValue(forKey: identity.pid)
            // Bound native handles/subscriptions, independently of collection limits.
            guard applications.count < 16, windows.count <= 16 else { return nil }
            let next = Application(identity, windows: windows)
            applications[identity.pid] = next
            return next
        }
        old?.graph.close()
        guard app != nil || old != nil else { return }
        Task { @MainActor [weak self] in
            if let old { Self.remove(old) }
            guard let self, let app, self.isCurrent,
                  self.lock.withLock({ self.applications[identity.pid] === app }) else { return }
            self.install(app)
        }
    }
    func retainProcesses(_ pids: Set<pid_t>) {
        let removed: [Application] = lock.withLock {
            let keys = applications.keys.filter { !pids.contains($0) }
            return keys.compactMap { applications.removeValue(forKey: $0) }
        }
        for app in removed { app.graph.close() }
        guard !removed.isEmpty else { return }
        Task { @MainActor in for app in removed { Self.remove(app) } }
    }
    func gap() {
        let graphs = lock.withLock { applications.values.map(\.graph) }
        for graph in graphs { graph.gap() }
    }
    func graph(for identity: AutomationApplicationIdentity) -> NativeAccessibilityGraph<AXUIElement>? {
        guard isCurrent else { return nil }
        return lock.withLock {
            guard let app = applications[identity.pid], app.identity == identity else { return nil }
            return app.graph
        }
    }
    func shouldDefer(_ node: AXUIElement, processIdentity identity: AutomationApplicationIdentity) -> Bool {
        graph(for: identity)?.shouldDefer(node, processIdentity: identity) ?? false
    }
    func recordTimeout(_ node: AXUIElement, processIdentity identity: AutomationApplicationIdentity) {
        graph(for: identity)?.recordTimeout(node, processIdentity: identity)
    }
    @MainActor private func install(_ app: Application) {
        guard isCurrent else { return }
        if let installer { app.injectedClose = installer(app.identity, app.windows, app.graph); return }
        var observer: AXObserver?
        guard AXObserverCreate(app.identity.pid, { _, element, notification, context in
            guard let context else { return }
            let app = Unmanaged<Application>.fromOpaque(context).takeUnretainedValue()
            // Unknown roots, destruction, menus and focus changes can alter
            // ownership outside a known subtree, so rebuild conservatively.
            let event = notification as String
            app.graph.changed(element, uncertain: event != kAXLayoutChangedNotification && event != kAXSelectedChildrenChangedNotification)
        }, &observer) == .success, let observer else { return }
        app.observer = observer
        let root = AXUIElementCreateApplication(app.identity.pid)
        let appEvents = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
            kAXMenuOpenedNotification, kAXMenuClosedNotification]
        let windowEvents = [kAXLayoutChangedNotification, kAXSelectedChildrenChangedNotification,
            kAXUIElementDestroyedNotification]
        let deadline = ProcessInfo.processInfo.systemUptime + 0.1
        var complete = true
        // Register each event on its owning scope. For example, requiring a
        // window to emit application menu events would disable useful caching.
        for (element, events) in [(root, appEvents)] + app.windows.map({ ($0, windowEvents) }) {
            defer { AXUIElementSetMessagingTimeout(element, 0) }
            for event in events {
                guard isCurrent, ProcessInfo.processInfo.systemUptime < deadline else { complete = false; continue }
                AXUIElementSetMessagingTimeout(element, Float(min(0.01, max(0.001, deadline - ProcessInfo.processInfo.systemUptime))))
                let result = AXObserverAddNotification(observer, element, event as CFString, Unmanaged.passUnretained(app).toOpaque())
                if result != .success && result != .notificationAlreadyRegistered { complete = false }
            }
        }
        guard isCurrent, lock.withLock({ applications[app.identity.pid] === app }) else { Self.remove(app); return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        app.graph.setMonitoring(complete)
    }
    @MainActor private static func remove(_ app: Application) {
        app.injectedClose?(); app.injectedClose = nil
        if let observer = app.observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        // Releasing the observer releases its registrations; no potentially
        // blocking cross-process removals during Stop or generation handoff.
        app.observer = nil
    }
    func close() {
        let ending: [Application] = lock.withLock {
            guard !closed else { return [] }; closed = true
            let values = Array(applications.values); applications.removeAll(); return values
        }
        for app in ending { app.graph.close() }
        guard !ending.isEmpty else { return }
        Task { @MainActor in for app in ending { Self.remove(app) } }
    }
    deinit {
        if let revocation { lease.removeRevocationObserver(revocation) }
        close()
    }
}
