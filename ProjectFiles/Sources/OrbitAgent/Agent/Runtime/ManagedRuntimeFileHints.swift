import Darwin
import Foundation
import CoreServices

/// Vnode notifications are invalidation hints only. No contents, health verdicts,
/// recursive scans or timers live here; the host runs its existing audits.
final class ManagedRuntimeFileHints {
    struct Changes: OptionSet, Equatable {
        let rawValue: Int
        static let installation = Self(rawValue: 1)
        static let configuration = Self(rawValue: 2)
        static let rescanRequired = Self(rawValue: 4)
    }
    private final class GapState {
        private let lock = NSLock()
        private var pending = false
        func record(_ flags: FSEventStreamEventFlags) {
            let mask = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
                kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped |
                kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
            if flags & FSEventStreamEventFlags(mask) != 0 { lock.withLock { pending = true } }
        }
        func take() -> Bool { lock.withLock { let value = pending; pending = false; return value } }
    }
    private struct Metadata: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let size: off_t
        let modified: timespec
        let changed: timespec
        var directory: Bool { mode & S_IFMT == S_IFDIR }
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.mode == rhs.mode &&
            (lhs.directory || (lhs.size == rhs.size &&
                lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec &&
                lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec))
        }
        func sameIdentity(as other: Self) -> Bool {
            device == other.device && inode == other.inode && mode & S_IFMT == other.mode & S_IFMT
        }
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; mode = value.st_mode
            size = value.st_size; modified = value.st_mtimespec; changed = value.st_ctimespec
        }
    }
    private struct Watch {
        let id: UUID
        let metadata: Metadata
        let source: DispatchSourceFileSystemObject
    }
    private let root: URL
    private let queue = DispatchQueue(label: "com.orbitagent.managed-file-hints", qos: .utility)
    private let cancellations = DispatchGroup()
    private let openDescriptor: (String) -> Int32
    private var targets: [URL: Changes] = [:]
    private var snapshots: [URL: Metadata] = [:]
    private var watches: [URL: Watch] = [:]
    private var pending: Changes = []
    private var nextDelivery: TimeInterval = 0
    private var closed = false
    private let gaps = GapState()
    private var gapStream: FSEventStreamRef?

    init(root: URL, watchNotificationGaps: Bool = true, openDescriptor: @escaping (String) -> Int32 = {
        Darwin.open($0, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
    }) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.openDescriptor = openDescriptor
        if watchNotificationGaps { queue.sync { startGapWatch() } }
    }

    /// Vnode sources do not expose event loss. FSEvents is used only for its
    /// loss/rescan flags; normal path changes remain on the existing vnode lane.
    private func startGapWatch() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(gaps).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<GapState>.fromOpaque(pointer).retain()
                return UnsafeRawPointer(pointer)
            }, release: { pointer in
                if let pointer { Unmanaged<GapState>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, _, flags, _ in
            guard let info else { return }
            let state = Unmanaged<GapState>.fromOpaque(info).takeUnretainedValue()
            for index in 0..<count { state.record(flags[index]) }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents)) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); return
        }
        gapStream = stream
    }

    /// Also allows deterministic loss-signal fixtures without dropping OS events.
    func noteEventFlags(_ flags: [FSEventStreamEventFlags]) {
        queue.sync { if !closed { for value in flags { gaps.record(value) } } }
    }

    static func targets(_ descriptor: ManagedOpenClawDescriptor, descriptorURL: URL) -> [URL: Changes] {
        let state = URL(fileURLWithPath: descriptor.state)
        let installation = URL(fileURLWithPath: descriptor.node).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        var result: [URL: Changes] = [:]
        for path in [descriptor.node, descriptor.entry, installation.appendingPathComponent("integrity.json").path] {
            result[URL(fileURLWithPath: path)] = .installation
        }
        for url in [descriptorURL, URL(fileURLWithPath: descriptor.config), URL(fileURLWithPath: descriptor.executable),
                    URL(fileURLWithPath: descriptor.tokenFile), state.appendingPathComponent("credential-fingerprint.json")] {
            result[url, default: []].insert(.configuration)
        }
        return result
    }

    /// Also watch ancestors to detect atomic replacement and creation. Directory
    /// entry churn is filtered by the relevant paths' identities/metadata; health
    /// and process-ledger writes must not create an audit feedback loop.
    func configure(_ files: [URL: Changes]) {
        queue.sync {
            guard !closed else { return }
            var desired: [URL: Changes] = [:]
            for (url, scope) in files {
                var path = url.standardizedFileURL
                guard path.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { continue }
                while path.path.hasPrefix(root.path + "/") || path.path == root.path {
                    desired[path, default: []].formUnion(scope)
                    if path.path == root.path { break }
                    path.deleteLastPathComponent()
                }
            }
            if desired.count > 32 { desired = [:] } // Timed audit remains authoritative.
            if desired != targets {
                for watch in watches.values { watch.source.cancel() }
                watches.removeAll(); snapshots.removeAll(); pending = []
                targets = desired
                reconcile(markChanges: false)
            }
        }
    }

    private func metadata(_ url: URL) -> Metadata? {
        var value = stat()
        let resolved = url.resolvingSymlinksInPath().path
        guard (resolved == root.path || resolved.hasPrefix(root.path + "/")),
              lstat(url.path, &value) == 0,
              value.st_mode & S_IFMT == S_IFREG || value.st_mode & S_IFMT == S_IFDIR else { return nil }
        return Metadata(value)
    }

    private func reconcile(markChanges: Bool) {
        for (url, scope) in targets {
            let current = metadata(url)
            if markChanges && snapshots[url] != current {
                pending.formUnion(scope)
                if let previous = snapshots[url], previous.directory,
                   current.map({ previous.sameIdentity(as: $0) }) != true { pending.insert(.rescanRequired) }
            }
            snapshots[url] = current
            if let watch = watches[url], current.map({ watch.metadata.sameIdentity(as: $0) }) != true {
                watches.removeValue(forKey: url)?.source.cancel()
            }
            guard watches[url] == nil, let current else { continue }
            let descriptor = openDescriptor(url.path)
            guard descriptor >= 0 else { continue } // Unsupported: retain timed checks.
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, Metadata(opened).sameIdentity(as: current) else { Darwin.close(descriptor); continue }
            let id = UUID()
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: queue)
            source.setEventHandler { [weak self] in
                guard let self, !self.closed, self.watches[url]?.id == id else { return }
                let events = self.watches[url]!.source.data
                if events.contains(.revoke) || current.directory && !events.intersection([.rename, .delete]).isEmpty {
                    self.pending.insert(.rescanRequired)
                }
                // File write notifications invalidate even if metadata appears
                // unchanged. Directory notifications first inspect relevant children.
                if !current.directory { self.pending.formUnion(scope) }
                self.reconcile(markChanges: true)
            }
            cancellations.enter()
            source.setCancelHandler { [cancellations] in Darwin.close(descriptor); cancellations.leave() }
            watches[url] = Watch(id: id, metadata: current, source: source)
            source.resume()
        }
    }

    func takeChanges(at now: TimeInterval) -> Changes {
        queue.sync {
            if gaps.take() { pending.insert(.rescanRequired) }
            guard !closed, !pending.isEmpty, now >= nextDelivery else { return [] }
            let value = pending; pending = []; nextDelivery = now + 5
            return value
        }
    }
    /// Timed audits rearm watchers too, covering missed replacement notifications.
    func refresh() { queue.sync { if !closed { reconcile(markChanges: true) } } }
    func close() {
        queue.sync {
            closed = true; pending = []
            if let gapStream {
                FSEventStreamStop(gapStream); FSEventStreamInvalidate(gapStream); FSEventStreamRelease(gapStream)
                self.gapStream = nil
            }
            for watch in watches.values { watch.source.cancel() }
            watches.removeAll(); snapshots.removeAll(); targets.removeAll()
        }
        cancellations.wait()
    }
}
