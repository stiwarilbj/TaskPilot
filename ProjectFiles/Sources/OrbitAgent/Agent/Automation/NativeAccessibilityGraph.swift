import Foundation

/// Hashes select a bucket; equality establishes identity. CFHash alone is not
/// an AX identity, and distinct controls with colliding hashes must survive.
struct NativeIdentityIndex<Node> {
    private var buckets: [UInt: [Node]] = [:]
    func contains(_ node: Node, hash: UInt, equal: (Node, Node) -> Bool) -> Bool {
        buckets[hash]?.contains(where: { equal($0, node) }) == true
    }
    mutating func insert(_ node: Node, hash: UInt, equal: (Node, Node) -> Bool) -> Bool {
        if buckets[hash]?.contains(where: { equal($0, node) }) == true { return false }
        buckets[hash, default: []].append(node)
        return true
    }
}

/// Bounded topology only: no executable IDs, attributes, labels, or values.
/// Notifications invalidate descendants, including shared/cyclic branches.
/// Fresh post-capture enumeration remains mandatory even on a cache hit.
final class NativeAccessibilityGraph<Node> {
    struct Page { let children: [Node]; let total: Int }
    struct Ticket { fileprivate let revision: UInt64 }
    private struct Record {
        let node: Node
        var pages: [Int: Page] = [:]
        var edges: Set<Int> = []
    }
    private struct StallRecord {
        let node: Node
        var failures: Int
        var lastFailure: TimeInterval
        var deferredUntil: TimeInterval?
        var sequence: UInt64
    }
    private let lock = NSLock()
    private let hash: (Node) -> UInt
    private let equal: (Node, Node) -> Bool
    private let capacity: Int
    private let maxAge: TimeInterval
    private let stallCapacity: Int
    private let stallThreshold: Int
    private let stallWindow: TimeInterval
    private let stallCooldown: TimeInterval
    private let processIdentity: AutomationApplicationIdentity?
    private let now: () -> TimeInterval
    private var buckets: [UInt: [Int]] = [:]
    private var stalls: [UInt: [StallRecord]] = [:]
    private var stallCount = 0
    private var nextStallSequence: UInt64 = 0
    private var records: [Int: Record] = [:]
    private var nextID = 0
    private var edgeCount = 0
    private var revision: UInt64 = 0
    private var refreshed: TimeInterval
    private var monitored = false
    private var closed = false
    private var hitCount = 0
    private var rebuildCount = 0
    var hits: Int { lock.withLock { hitCount } }
    var rebuilds: Int { lock.withLock { rebuildCount } }

    init(capacity: Int = 4096, maxAge: TimeInterval = 2,
         stallCapacity: Int = 1024, stallThreshold: Int = 2,
         stallWindow: TimeInterval = 5, stallCooldown: TimeInterval = 2,
         processIdentity: AutomationApplicationIdentity? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         hash: @escaping (Node) -> UInt, equal: @escaping (Node, Node) -> Bool) {
        self.capacity = max(1, capacity); self.maxAge = max(0, maxAge)
        self.stallCapacity = max(1, stallCapacity); self.stallThreshold = max(2, stallThreshold)
        self.stallWindow = max(0, stallWindow); self.stallCooldown = max(0, stallCooldown)
        self.processIdentity = processIdentity
        self.now = now; self.hash = hash; self.equal = equal; refreshed = now()
    }
    private func find(_ node: Node) -> Int? {
        buckets[hash(node)]?.first { records[$0].map { equal($0.node, node) } == true }
    }
    private func clear() {
        records.removeAll(); buckets.removeAll(); nextID = 0; edgeCount = 0
        revision &+= 1; refreshed = now(); rebuildCount += 1
    }
    private func processMatches(_ identity: AutomationApplicationIdentity?) -> Bool {
        guard let processIdentity else { return identity == nil }
        return identity == processIdentity
    }
    private func stallIndex(_ node: Node) -> (hash: UInt, index: Int)? {
        let key = hash(node)
        guard let index = stalls[key]?.firstIndex(where: { equal($0.node, node) }) else { return nil }
        return (key, index)
    }
    private func removeStall(_ node: Node) {
        guard let location = stallIndex(node), var bucket = stalls[location.hash] else { return }
        bucket.remove(at: location.index); stallCount -= 1
        if bucket.isEmpty { stalls.removeValue(forKey: location.hash) }
        else { stalls[location.hash] = bucket }
    }
    private func removeOldestStallIfNeeded() {
        guard stallCount >= stallCapacity else { return }
        var oldest: (hash: UInt, index: Int, sequence: UInt64)?
        for (key, bucket) in stalls {
            for (index, record) in bucket.enumerated() where oldest == nil || record.sequence < oldest!.sequence {
                oldest = (key, index, record.sequence)
            }
        }
        guard let oldest, var bucket = stalls[oldest.hash] else { return }
        bucket.remove(at: oldest.index); stallCount -= 1
        if bucket.isEmpty { stalls.removeValue(forKey: oldest.hash) }
        else { stalls[oldest.hash] = bucket }
    }
    private func clearStalls() { stalls.removeAll(); stallCount = 0 }

    /// Record only slow native failures. A single error never blocks discovery;
    /// repeated failures on this exact node earn a brief cooldown.
    func recordTimeout(_ node: Node, processIdentity identity: AutomationApplicationIdentity? = nil) {
        lock.withLock {
            guard !closed, processMatches(identity) else { return }
            let current = now()
            let key = hash(node)
            if var bucket = stalls[key], let index = bucket.firstIndex(where: { equal($0.node, node) }) {
                var record = bucket[index]
                if current - record.lastFailure > stallWindow {
                    record.failures = 1
                    record.deferredUntil = nil
                } else {
                    record.failures += 1
                }
                record.lastFailure = current
                record.sequence = nextStallSequence
                nextStallSequence &+= 1
                if record.failures >= stallThreshold { record.deferredUntil = current + stallCooldown }
                bucket[index] = record
                stalls[key] = bucket
            } else {
                removeOldestStallIfNeeded()
                stalls[key, default: []].append(StallRecord(node: node, failures: 1,
                    lastFailure: current, deferredUntil: nil, sequence: nextStallSequence))
                nextStallSequence &+= 1
                stallCount += 1
            }
        }
    }

    /// Cooldown expiry is the retry path when no useful subtree notification
    /// arrives. Expired counters are discarded so a recovered app gets a fresh
    /// chance before it can be deferred again.
    func shouldDefer(_ node: Node, processIdentity identity: AutomationApplicationIdentity? = nil) -> Bool {
        lock.withLock {
            guard !closed, processMatches(identity), let location = stallIndex(node),
                  let record = stalls[location.hash]?[location.index], let until = record.deferredUntil else { return false }
            guard now() < until else { removeStall(node); return false }
            return true
        }
    }
    func setMonitoring(_ available: Bool) {
        lock.withLock {
            guard !closed else { return }
            if monitored != available { clear() }
            monitored = available
        }
    }
    func gap() { lock.withLock { guard !closed else { return }; clear() } }
    func close() { lock.withLock { clear(); clearStalls(); closed = true; monitored = false } }
    var nodeCount: Int { lock.withLock { records.count } }
    func beginRead() -> Ticket {
        lock.withLock {
            if now() - refreshed >= maxAge { clear() }
            return Ticket(revision: revision)
        }
    }
    func page(_ node: Node, offset: Int, count: Int, total: Int, fresh: Bool) -> Page? {
        lock.withLock {
            guard !closed, !fresh, monitored else { return nil }
            if now() - refreshed >= maxAge { clear(); return nil }
            guard let id = find(node), let page = records[id]?.pages[offset] else { return nil }
            guard page.total == total, page.children.count == min(count, max(0, total - offset)) else {
                invalidate(node); return nil
            }
            hitCount += 1
            return page
        }
    }
    /// Caller supplies only complete pages obtained from successful native reads.
    /// A concurrent notification prevents this read from clearing its invalidation.
    func store(_ node: Node, offset: Int, page: Page, ticket: Ticket) {
        lock.withLock {
            guard !closed, revision == ticket.revision, offset >= 0, page.total >= 0,
                  offset <= page.total, page.children.count <= page.total - offset, page.children.count <= capacity else { return }
            // Every page is also an edge list. Bound edges as well as nodes,
            // including highly connected or adversarial AX trees.
            if records.count + page.children.count + 1 > capacity || edgeCount + page.children.count > capacity * 2 {
                clear(); return
            }
            func intern(_ value: Node) -> Int {
                if let id = find(value) { return id }
                let id = nextID; nextID += 1
                records[id] = Record(node: value); buckets[hash(value), default: []].append(id)
                return id
            }
            let parent = intern(node)
            if records[parent]?.pages[offset]?.total != nil,
               records[parent]?.pages[offset]?.total != page.total { invalidate(node) }
            for child in page.children { _ = intern(child) }
            edgeCount -= records[parent]?.pages[offset]?.children.count ?? 0
            edgeCount += page.children.count
            records[parent]?.pages[offset] = page
            let edges = Set(records[parent]?.pages.values.flatMap { page in
                page.children.compactMap { find($0) }
            } ?? [])
            records[parent]?.edges = edges
        }
    }
    private func invalidate(_ node: Node) {
        revision &+= 1
        guard let root = find(node) else { clear(); clearStalls(); return }
        var pending = [root], seen: Set<Int> = []
        while let id = pending.popLast() {
            guard seen.insert(id).inserted else { continue }
            if let node = records[id]?.node { removeStall(node) }
            pending.append(contentsOf: records[id]?.edges ?? [])
            edgeCount -= records[id]?.pages.values.reduce(0) { $0 + $1.children.count } ?? 0
            records[id]?.pages.removeAll(); records[id]?.edges.removeAll()
        }
    }
    func changed(_ node: Node?, uncertain: Bool = false) {
        lock.withLock {
            guard !closed else { return }
            if uncertain || node == nil { clear(); clearStalls() }
            else { invalidate(node!) }
        }
    }
}
