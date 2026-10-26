import Darwin
import Foundation

/// Vnode notifications are invalidation hints only. No contents, health verdicts,
/// recursive scans or timers live here; the host runs its existing audits.
final class ManagedRuntimeFileHints {
    struct Changes: OptionSet, Equatable {
        let rawValue: Int
        static let installation = Self(rawValue: 1)
        static let configuration = Self(rawValue: 2)
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

    init(root: URL, openDescriptor: @escaping (String) -> Int32 = {
        Darwin.open($0, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
    }) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.openDescriptor = openDescriptor
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
            if markChanges && snapshots[url] != current { pending.formUnion(scope) }
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
            for watch in watches.values { watch.source.cancel() }
            watches.removeAll(); snapshots.removeAll(); targets.removeAll()
        }
        cancellations.wait()
    }
}
