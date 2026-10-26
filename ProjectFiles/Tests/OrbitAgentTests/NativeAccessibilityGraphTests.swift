import ApplicationServices
import XCTest
@testable import OrbitAgent

final class NativeAccessibilityGraphTests: XCTestCase {
    private func graph(capacity: Int = 4096, now: @escaping () -> TimeInterval = { 1 }) -> NativeAccessibilityGraph<Int> {
        let graph = NativeAccessibilityGraph<Int>(capacity: capacity, now: now, hash: { UInt($0) }, equal: ==)
        graph.setMonitoring(true)
        return graph
    }
    private func store(_ graph: NativeAccessibilityGraph<Int>, _ node: Int, _ children: [Int], total: Int? = nil, offset: Int = 0) {
        graph.store(node, offset: offset, page: .init(children: children, total: total ?? children.count), ticket: graph.beginRead())
    }
    private func page(_ graph: NativeAccessibilityGraph<Int>, _ node: Int, total: Int, fresh: Bool = false) -> [Int]? {
        graph.page(node, offset: 0, count: 160, total: total, fresh: fresh)?.children
    }
    func testWarmBranchesAreReusedButFreshPassBypassesEveryCache() {
        let graph = graph(); store(graph, 0, [1, 2]); store(graph, 1, [3]); store(graph, 2, [4])
        XCTAssertEqual(page(graph, 0, total: 2), [1, 2])
        XCTAssertNil(page(graph, 0, total: 2, fresh: true))
        graph.changed(1)
        XCTAssertNil(page(graph, 1, total: 1))
        XCTAssertEqual(page(graph, 2, total: 1), [4])
        XCTAssertEqual(page(graph, 0, total: 2), [1, 2])
        store(graph, 1, [5]); XCTAssertEqual(page(graph, 1, total: 1), [5])
    }
    func testInvalidatesAllDescendantsThroughCyclesAndSharedEdges() {
        let graph = graph()
        store(graph, 0, [1, 2]); store(graph, 1, [0]); store(graph, 2, [3]); store(graph, 3, [1])
        graph.changed(0)
        for (node, count) in [(0, 2), (1, 1), (2, 1), (3, 1)] { XCTAssertNil(page(graph, node, total: count)) }
    }
    func testMissedNotificationsCountMismatchGapAndExpiryForceDiscovery() {
        var time: Double = 1
        let graph = graph(now: { time }); store(graph, 0, [1])
        XCTAssertNil(page(graph, 0, total: 2))
        store(graph, 0, [2]); graph.gap(); XCTAssertNil(page(graph, 0, total: 1))
        store(graph, 0, [3]); time += 3; XCTAssertNil(page(graph, 0, total: 1))
        store(graph, 0, [4]); graph.changed(99); XCTAssertNil(page(graph, 0, total: 1))
        store(graph, 0, [5]); graph.changed(0, uncertain: true); XCTAssertNil(page(graph, 0, total: 1))
    }
    func testNotificationDuringReadCannotRepopulateDirtyBranch() {
        let graph = graph(); store(graph, 0, [1])
        let ticket = graph.beginRead(); graph.changed(0)
        graph.store(0, offset: 0, page: .init(children: [2], total: 1), ticket: ticket)
        XCTAssertNil(page(graph, 0, total: 1))
    }
    func testUnsupportedSubscriptionsAndClosedTasksNeverReuseTopology() {
        let graph = graph(); store(graph, 0, [1]); graph.setMonitoring(false)
        store(graph, 0, [2]); XCTAssertNil(page(graph, 0, total: 1))
        graph.setMonitoring(true); XCTAssertNil(page(graph, 0, total: 1))
        store(graph, 0, [3]); graph.close(); store(graph, 0, [4]); graph.setMonitoring(true)
        XCTAssertEqual(graph.nodeCount, 0); XCTAssertNil(page(graph, 0, total: 1))
    }
    func testCapacityBoundsNodesAndEdges() {
        let graph = graph(capacity: 8)
        for index in 0..<100 { store(graph, index, [index + 1, index + 2]); XCTAssertLessThanOrEqual(graph.nodeCount, 8) }
        XCTAssertGreaterThan(graph.rebuilds, 1)
    }
    func testRepeatedSlowTimeoutsDeferExactSubtreeUntilChangeOrCooldown() {
        var time: Double = 1
        let process = identity()
        let graph = NativeAccessibilityGraph<Int>(stallCapacity: 8, stallThreshold: 2, stallWindow: 5,
            stallCooldown: 2, processIdentity: process, now: { time }, hash: { UInt($0) }, equal: ==)
        graph.setMonitoring(true)
        graph.recordTimeout(1, processIdentity: identity(2)) // Reused PID, different process instance.
        XCTAssertFalse(graph.shouldDefer(1, processIdentity: process))
        graph.recordTimeout(1, processIdentity: process)
        XCTAssertFalse(graph.shouldDefer(1, processIdentity: process))
        graph.recordTimeout(1, processIdentity: process)
        XCTAssertTrue(graph.shouldDefer(1, processIdentity: process))

        graph.store(0, offset: 0, page: .init(children: [1, 2], total: 2), ticket: graph.beginRead())
        graph.store(1, offset: 0, page: .init(children: [3], total: 1), ticket: graph.beginRead())
        for node in [3, 2] { graph.recordTimeout(node, processIdentity: process); graph.recordTimeout(node, processIdentity: process) }
        graph.changed(1) // A relevant subtree notification releases 1 and its descendants only.
        XCTAssertFalse(graph.shouldDefer(1, processIdentity: process))
        XCTAssertFalse(graph.shouldDefer(3, processIdentity: process))
        XCTAssertTrue(graph.shouldDefer(2, processIdentity: process))

        time += 2
        XCTAssertFalse(graph.shouldDefer(2, processIdentity: process))
        graph.recordTimeout(2, processIdentity: process)
        XCTAssertFalse(graph.shouldDefer(2, processIdentity: process)) // Cooldown expiry reset its streak.
    }

    func testUncertainChangesAndProcessClosureClearStallState() {
        let process = identity()
        let graph = NativeAccessibilityGraph<Int>(processIdentity: process, hash: { UInt($0) }, equal: ==)
        graph.recordTimeout(7, processIdentity: process); graph.recordTimeout(7, processIdentity: process)
        XCTAssertTrue(graph.shouldDefer(7, processIdentity: process))
        graph.changed(nil, uncertain: true)
        XCTAssertFalse(graph.shouldDefer(7, processIdentity: process))
        graph.recordTimeout(7, processIdentity: process); graph.recordTimeout(7, processIdentity: process)
        graph.close()
        XCTAssertFalse(graph.shouldDefer(7, processIdentity: process))
    }
    func testCollisionSafeGraphIdentity() {
        let graph = NativeAccessibilityGraph<Int>(hash: { _ in 0 }, equal: ==)
        graph.setMonitoring(true); store(graph, 1, [3]); store(graph, 2, [4])
        XCTAssertEqual(page(graph, 1, total: 1), [3]); XCTAssertEqual(page(graph, 2, total: 1), [4])
        graph.changed(1); XCTAssertEqual(page(graph, 2, total: 1), [4])
    }
    func testIndexedTraversalIsLinearFor1280ControlsAndPreservesAliasRows() throws {
        var comparisons = 0, reads = 0, rows: [String] = []
        let collection = ObservationCollection<Int>(budget: 5)
        try collection.collect(roots: [.init(node: 0, scope: .init(pid: 1))], revision: "fresh", check: {},
            equal: { comparisons += 1; return $0 == $1 }, identityHash: { UInt($0) },
            inspect: { _, id in rows.append(id); return .init() }, children: { entry, offset, count in
                reads += 1
                return .init(nodes: entry.node == 0 ? Array((1..<1280).dropFirst(offset).prefix(count)) : [], total: entry.node == 0 ? 1279 : 0)
            })
        XCTAssertEqual(rows.count, 1280); XCTAssertLessThan(comparisons, 1280)
        XCTAssertLessThan(reads, 1300); XCTAssertEqual(Set(rows).count, 1280)
        let aliases = ObservationCollection<Int>(budget: 5)
        var discovered: [Int] = [], inspected: [Int] = []
        try aliases.collect(roots: [.init(node: 0, scope: .init(pid: 1))], revision: "aliases", check: {}, equal: ==,
            identityHash: { _ in 0 }, inspect: { entry, _ in inspected.append(entry.node); return .init() },
            children: { entry, _, _ in discovered.append(entry.node); return .init(nodes: [1 - entry.node], total: 1) })
        XCTAssertEqual(inspected, [0, 1, 0]); XCTAssertEqual(discovered, [0, 1])
    }
    func testCachedTopologyStillInspectsCurrentBoundsAndCreatesFreshRevisionIDs() throws {
        let graph = graph(); store(graph, 0, [1])
        var bounds = 10
        func observe(_ revision: String) throws -> [(String, Int)] {
            var rows: [(String, Int)] = []
            let collection = ObservationCollection<Int>(budget: 5)
            try collection.collect(roots: [.init(node: 0, scope: .init(pid: 1))], revision: revision, check: {}, equal: ==,
                identityHash: { UInt($0) }, inspect: { _, id in rows.append((id, bounds)); return .init() },
                children: { entry, _, _ in .init(nodes: self.page(graph, entry.node, total: entry.node == 0 ? 1 : 0) ?? [], total: entry.node == 0 ? 1 : 0) })
            return rows
        }
        let first = try observe("one"); bounds = 20; let second = try observe("two")
        XCTAssertEqual(first.map(\.1), [10, 10]); XCTAssertEqual(second.map(\.1), [20, 20])
        XCTAssertTrue(first.allSatisfy { $0.0.hasPrefix("one:") }); XCTAssertTrue(second.allSatisfy { $0.0.hasPrefix("two:") })
    }
    func testFreshPostCaptureDetectsSameCountReplacementWithoutNotification() async throws {
        let graph = graph(); store(graph, 0, [1]); var actual = [1]
        var discarded = 0, published: [[Int]] = [], captures = 0, time: Double = 1
        let result = try await ObservationConsistency.collect(now: { time }, checkpoint: {}, scene: { 1 },
            stage: { _ in self.page(graph, 0, total: actual.count) ?? actual },
            stageAfter: { _ in self.store(graph, 0, actual); return actual },
            signature: { String(describing: $0) }, capture: { _ in
                captures += 1; actual = [2]; return URL(fileURLWithPath: "/unused-fixture")
            }, discard: { _ in discarded += 1 }, publish: { published.append($0) }, sleep: { time += $0 })
        XCTAssertEqual(result.0, [2]); XCTAssertEqual(captures, 2); XCTAssertEqual(discarded, 1); XCTAssertEqual(published, [[2]])
    }
    private func identity(_ launch: Double = 1) -> AutomationApplicationIdentity {
        .init(pid: 424242, bundleID: "fixture", bundlePath: "/fixture", name: "Fixture", launchDate: Date(timeIntervalSince1970: launch))
    }
    @MainActor func testProcessReplacementAndOldCallbacksCannotAffectNewGraph() async throws {
        let firstReady = expectation(description: "First subscription installed")
        let secondReady = expectation(description: "Replacement subscription installed")
        let released = expectation(description: "Subscriptions released"); released.expectedFulfillmentCount = 2
        let lease = TaskLease()
        var callbacks: [() -> Void] = [], closed = 0
        let session = NativeGraphSession(lease: lease, installer: { _, _, graph in
            graph.setMonitoring(true); callbacks.append { graph.changed(nil) }
            if callbacks.count == 1 { firstReady.fulfill() } else { secondReady.fulfill() }
            return { closed += 1; released.fulfill() }
        })
        session.prepare(identity(), windows: [])
        await fulfillment(of: [firstReady], timeout: 2)
        let old = try XCTUnwrap(session.graph(for: identity()))
        let parent = AXUIElementCreateApplication(424242) // handle only; no live AX queries
        old.store(parent, offset: 0, page: .init(children: [], total: 0), ticket: old.beginRead())
        old.recordTimeout(parent, processIdentity: identity())
        old.recordTimeout(parent, processIdentity: identity())
        XCTAssertTrue(old.shouldDefer(parent, processIdentity: identity()))
        session.prepare(identity(2), windows: [])
        await fulfillment(of: [secondReady], timeout: 2)
        XCTAssertNil(session.graph(for: identity()))
        let new = try XCTUnwrap(session.graph(for: identity(2)))
        XCTAssertFalse(old === new)
        XCTAssertFalse(new.shouldDefer(parent, processIdentity: identity(2)))
        new.store(parent, offset: 0, page: .init(children: [], total: 0), ticket: new.beginRead())
        callbacks[0]()
        XCTAssertNotNil(new.page(parent, offset: 0, count: 160, total: 0, fresh: false))
        XCTAssertEqual(old.nodeCount, 0)
        session.retainProcesses([])
        XCTAssertNil(session.graph(for: identity(2)))
        session.close(); session.close()
        await fulfillment(of: [released], timeout: 2)
        XCTAssertEqual(new.nodeCount, 0)
        XCTAssertEqual(closed, 2)
    }
    func testPauseAndRevocationInvalidateSessionWithoutNativeQueries() async throws {
        let lease = TaskLease()
        let session = NativeGraphSession(lease: lease, installer: { _, _, graph in graph.setMonitoring(true); return {} })
        session.prepare(identity(), windows: [])
        XCTAssertTrue(session.matches(lease)); XCTAssertFalse(session.matches(TaskLease()))
        lease.pause(); XCTAssertFalse(session.isCurrent); XCTAssertNil(session.graph(for: identity()))
        lease.resume(); XCTAssertFalse(session.matches(lease)) // epoch gap requires a new session
        session.close()
        let next = NativeGraphSession(lease: lease, installer: { _, _, _ in return {} })
        XCTAssertTrue(next.isCurrent); lease.revoke(); XCTAssertFalse(next.isCurrent)
        next.prepare(identity(), windows: []); XCTAssertNil(next.graph(for: identity()))
    }

}
