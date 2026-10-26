import Foundation

/// Read-only traversal with an initial compatibility budget and one bounded
/// expansion of omitted branches. Nothing here publishes IDs or sends input.
final class ObservationCollection<Node> {
    static var version: Int { 1 }
    struct Scope {
        let pid: Int
        var processIdentity: AutomationApplicationIdentity? = nil
        var windowID: String?
        var parentID: String?
        var priority = 0
        var depth = 0
        var dictionary: [String: Any] {
            var result: [String: Any] = ["pid": pid]
            if let windowID { result["window_id"] = windowID }
            if let parentID { result["element_id"] = parentID }
            return result
        }
    }
    struct Entry { let node: Node; var scope: Scope }
    struct Inspection {
        var included = true
        var descend = true
        var relevance = 0
        var omission: String?
    }
    struct Page { let nodes: [Node]; let total: Int; var incomplete = false }
    struct Limits {
        var initialElements = 640
        var expandedElements = 1280
        var initialDepth = 14
        var expandedDepth = 28
        var children = 160
        var expansionPages = 16
    }
    private struct Pending {
        let entry: Entry
        let reason: String
        var offset: Int? // nil: unvisited node; otherwise children of a visited node
        var omitted = 1
        var attempted = false
    }
    let deadline: TimeInterval
    let now: () -> TimeInterval
    let limits: Limits
    private var pending: [Pending] = []
    private var readIssues: [[String: Any]] = []
    private var readIssueCounts: [String: Int] = [:]
    private var visited: [Node] = []
    private var identityIndex = NativeIdentityIndex<Node>()
    private var nextID = 1
    private var expanded = false
    private(set) var collected = 0
    private(set) var expansionAttempts = 0
    private(set) var expandedControls = 0
    private(set) var readRetries = 0
    var scope = Scope(pid: 0)
    var hasTime: Bool { now() < deadline }

    init(budget: TimeInterval, limits: Limits = Limits(), now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now; self.deadline = now() + max(0, budget); self.limits = limits
    }

    func issue(_ reason: String, attribute: String? = nil, code: Int? = nil) {
        readIssueCounts[reason, default: 0] += 1
        var row = scope.dictionary
        row["reason"] = reason; row["recovery"] = "unresolved"
        if let attribute { row["attribute"] = attribute }
        if let code { row["error_code"] = code }
        // Full counts stay accurate even when the diagnostic scope list is bounded.
        if readIssues.count < 32 { readIssues.append(row) }
    }
    func retriedRead() { readRetries += 1 }

    func collect(roots: [Entry], revision: String, expand: Bool = true, check: () throws -> Void,
                 equal: (Node, Node) -> Bool, identityHash: ((Node) -> UInt)? = nil,
                 inspect: (Entry, String) throws -> Inspection,
                 children: (Entry, Int, Int) throws -> Page,
                 shouldDefer: (Entry) -> Bool = { _ in false }) throws {
        let before = collected
        try BackendTelemetry.current.measure(.axCollection) { span in
            defer { span.record(items: collected - before) }
            try collectNodes(roots: roots, revision: revision, expand: expand, check: check,
                             equal: equal, identityHash: identityHash, inspect: inspect, children: children,
                             shouldDefer: shouldDefer)
        }
    }

    private func collectNodes(roots: [Entry], revision: String, expand: Bool, check: () throws -> Void,
                              equal: (Node, Node) -> Bool, identityHash: ((Node) -> UInt)?, inspect: (Entry, String) throws -> Inspection,
                              children: (Entry, Int, Int) throws -> Page, shouldDefer: (Entry) -> Bool) throws {
        func deferNode(_ entry: Entry, _ reason: String) { pending.append(Pending(entry: entry, reason: reason)) }
        func walk(_ entry: Entry) throws {
            try check()
            scope = entry.scope
            if shouldDefer(entry) {
                issue("accessibility_stalled_subtree_deferred", attribute: "AXChildren")
                return
            }
            guard hasTime else { deferNode(entry, "collection_timeout"); return }
            guard collected < (expanded ? limits.expandedElements : limits.initialElements) else {
                deferNode(entry, "element_limit"); return
            }
            guard entry.scope.depth <= (expanded ? limits.expandedDepth : limits.initialDepth) else {
                deferNode(entry, "depth_limit"); return
            }
            let duplicate: Bool
            if let identityHash {
                duplicate = identityIndex.contains(entry.node, hash: identityHash(entry.node), equal: equal)
            } else { duplicate = visited.contains { equal($0, entry.node) } }
            let id = "\(revision):e\(nextID)"; nextID += 1
            let info = try inspect(entry, id)
            try check()
            if let reason = info.omission { deferNode(entry, reason); return }
            guard info.included else { return }
            collected += 1
            if expanded { expandedControls += 1 }
            if duplicate || !info.descend { return }
            if let identityHash { _ = identityIndex.insert(entry.node, hash: identityHash(entry.node), equal: equal) }
            else { visited.append(entry.node) }
            var parent = entry
            parent.scope.parentID = id
            parent.scope.priority += info.relevance
            try page(parent, offset: 0)
        }
        func page(_ parent: Entry, offset: Int) throws {
            try check()
            scope = parent.scope
            guard hasTime else {
                pending.append(Pending(entry: parent, reason: "collection_timeout", offset: offset)); return
            }
            let result = try children(parent, offset, limits.children)
            try check()
            if result.incomplete {
                // One retry is performed by the read provider. Never spin on
                // a failed app or infer that an unreadable branch is empty.
                return
            }
            for (index, node) in result.nodes.enumerated() {
                var childScope = parent.scope; childScope.depth += 1
                childScope.parentID = parent.scope.parentID
                let entry = Entry(node: node, scope: childScope)
                if !hasTime || collected >= (expanded ? limits.expandedElements : limits.initialElements) {
                    pending.append(Pending(entry: parent, reason: hasTime ? "element_limit" : "collection_timeout",
                        offset: offset + index, omitted: max(1, result.total - offset - index)))
                    return
                }
                try walk(entry)
            }
            let end = offset + result.nodes.count
            if end < result.total {
                pending.append(Pending(entry: parent, reason: "child_limit", offset: end, omitted: result.total - end))
            }
        }

        for root in roots { try walk(root) }
        try check()
        guard expand else { return }
        expanded = true
        var remaining: [Pending] = []
        while !pending.isEmpty && expansionAttempts < limits.expansionPages && hasTime && collected < limits.expandedElements {
            try check()
            // Deterministic tie order. Task/window priority chooses a subtree,
            // never an action or a target on the model's behalf.
            let best = pending.indices.max { lhs, rhs in
                if pending[lhs].entry.scope.priority != pending[rhs].entry.scope.priority {
                    return pending[lhs].entry.scope.priority < pending[rhs].entry.scope.priority
                }
                return lhs > rhs
            }!
            var work = pending.remove(at: best)
            work.attempted = true
            if work.entry.scope.depth > limits.expandedDepth { remaining.append(work); continue }
            expansionAttempts += 1
            if let offset = work.offset { try page(work.entry, offset: offset) }
            else { try walk(work.entry) }
        }
        pending += remaining
        try check()
    }

    var reasonCounts: [String: Int] {
        var result = readIssueCounts
        for work in pending { result[work.reason, default: 0] += 1 }
        return result
    }
    var metadata: [String: Any] {
        let scopes = pending.prefix(32).map { work -> [String: Any] in
            var row = work.entry.scope.dictionary
            row["reason"] = work.reason
            row["omitted_child_roots_at_least"] = work.omitted
            row["recovery"] = work.attempted ? "bounded_expansion_exhausted" : "not_reached_within_budget"
            return row
        }
        let counts = reasonCounts
        return ["version": Self.version, "state": counts.isEmpty ? "complete" : "partial",
                "scope": "exposed_accessibility_tree_on_assigned_display", "collected_controls": collected,
                "reason_counts": counts, "limitations": Array((readIssues + scopes).prefix(32)),
                "limitation_scopes_omitted": max(0, readIssueCounts.values.reduce(0, +) + pending.count - 32),
                "local_expansion": ["subtrees_attempted": expansionAttempts, "controls_added": expandedControls,
                                    "read_retries": readRetries]]
    }
}
