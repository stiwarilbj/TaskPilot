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

/// One scoped native subscription. AX registration/removal and callbacks use
/// the main run loop; vnode descriptors are closed before the wait drains.
final class NativeChangeSubscription: LocalChangeSource {
    private struct FileWatch {
        let path: String
        let device: dev_t
        let inode: ino_t
        let descriptor: Int32
        let source: DispatchSourceFileSystemObject
    }
    private let signal: LocalChangeSignal
    private var observer: AXObserver?
    private var registrations: [(AXUIElement, CFString)] = []
    private var fileURL: URL?
    private var files: [FileWatch] = []
    private var closed = false
    var supported: Bool { !registrations.isEmpty || !files.isEmpty }

    init(signal: LocalChangeSignal) { self.signal = signal }

    static func accessibility(pid: pid_t?, elements: [AXUIElement], signal: LocalChangeSignal,
                              deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 0.5) async -> NativeChangeSubscription {
        let source = NativeChangeSubscription(signal: signal)
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
            for (element, events) in [(app, applicationEvents)] + elements.map({ ($0, controlEvents) }) {
                // Unsupported registrations simply leave polling available.
                defer { AXUIElementSetMessagingTimeout(element, 0) }
                for event in events where signal.isCurrent && !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
                    AXUIElementSetMessagingTimeout(element, Float(min(0.05, max(0.001, deadline - ProcessInfo.processInfo.systemUptime))))
                    if AXObserverAddNotification(observer, element, event as CFString, context) == .success {
                        source.registrations.append((element, event as CFString))
                    }
                }
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
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
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
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
            candidate = try await check(); if candidate != nil { count += 1 }
            var reason = "condition_candidate"
            while candidate != true, signal.isCurrent, now() < deadline {
                let interval = max(0, min(0.5, deadline - now()))
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
