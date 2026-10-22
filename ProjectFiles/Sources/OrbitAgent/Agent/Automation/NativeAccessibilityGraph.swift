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
    private let lock = NSLock()
    private let hash: (Node) -> UInt
    private let equal: (Node, Node) -> Bool
    private let capacity: Int
    private let maxAge: TimeInterval
    private let now: () -> TimeInterval
    private var buckets: [UInt: [Int]] = [:]
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
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         hash: @escaping (Node) -> UInt, equal: @escaping (Node, Node) -> Bool) {
        self.capacity = max(1, capacity); self.maxAge = max(0, maxAge)
        self.now = now; self.hash = hash; self.equal = equal; refreshed = now()
    }
    private func find(_ node: Node) -> Int? {
        buckets[hash(node)]?.first { records[$0].map { equal($0.node, node) } == true }
    }
    private func clear() {
        records.removeAll(); buckets.removeAll(); nextID = 0; edgeCount = 0
        revision &+= 1; refreshed = now(); rebuildCount += 1
    }
    func setMonitoring(_ available: Bool) {
        lock.withLock {
            guard !closed else { return }
            if monitored != available { clear() }
            monitored = available
        }
    }
    func gap() { lock.withLock { guard !closed else { return }; clear() } }
    func close() { lock.withLock { clear(); closed = true; monitored = false } }
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
        guard let root = find(node) else { clear(); return }
        var pending = [root], seen: Set<Int> = []
        while let id = pending.popLast() {
            guard seen.insert(id).inserted else { continue }
            pending.append(contentsOf: records[id]?.edges ?? [])
            edgeCount -= records[id]?.pages.values.reduce(0) { $0 + $1.children.count } ?? 0
            records[id]?.pages.removeAll(); records[id]?.edges.removeAll()
        }
    }
    func changed(_ node: Node?, uncertain: Bool = false) {
        lock.withLock {
            guard !closed else { return }
            if uncertain || node == nil { clear() }
            else { invalidate(node!) }
        }
    }
}
