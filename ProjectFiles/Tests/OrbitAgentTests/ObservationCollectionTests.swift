import XCTest
import ApplicationServices
@testable import OrbitAgent

final class ObservationCollectionTests: XCTestCase {
    private final class World {
        var time: Double = 0
        var tree: [Int: [Int]] = [:]
        var labels: [Int: String] = [:]
        var keywords = [String]()
        var rows = [[String: Any]]()
        var reads = [(Int, Int)]()
        var cancelled = false
        var afterInspection: (() -> Void)?
        func collect(_ roots: [ObservationCollection<Int>.Entry], limits: ObservationCollection<Int>.Limits = .init(),
                     budget: Double = 1) throws -> ObservationCollection<Int> {
            let result = ObservationCollection<Int>(budget: budget, limits: limits, now: { self.time })
            try result.collect(roots: roots, revision: "accepted", check: {
                if self.cancelled { throw CancellationError() }
            }, equal: ==, inspect: { entry, id in
                self.afterInspection?()
                if !result.hasTime { return .init(included: false, omission: "collection_timeout") }
                self.rows.append(["id": id, "node": entry.node, "parent": entry.scope.parentID ?? ""])
                return .init(relevance: AutomationObservationPolicy.keywordScore(self.labels[entry.node] ?? "", keywords: self.keywords))
            }, children: { entry, offset, count in
                self.reads.append((entry.node, offset))
                let children = self.tree[entry.node] ?? []
                return .init(nodes: Array(children.dropFirst(offset).prefix(count)), total: children.count)
            })
            return result
        }
    }
    private func entry(_ node: Int, priority: Int = 0) -> ObservationCollection<Int>.Entry {
        .init(node: node, scope: .init(pid: 42, priority: priority))
    }
    private func nodes(_ world: World) -> [Int] { world.rows.map { $0["node"] as! Int } }

    func testHealthyTreeNeedsNoExpansionAndOnlyExposedTreeIsClaimedComplete() throws {
        let world = World(); world.tree = [0: [1, 2], 1: [3]]
        let result = try world.collect([entry(0)])
        XCTAssertEqual(nodes(world), [0, 1, 3, 2])
        XCTAssertEqual(result.collected, 4)
        XCTAssertEqual(result.expansionAttempts, 0)
        XCTAssertEqual(result.metadata["state"] as? String, "complete")
        XCTAssertEqual(result.metadata["scope"] as? String, "exposed_accessibility_tree_on_assigned_display")
        XCTAssertTrue(result.reasonCounts.isEmpty)
    }

    func testOmittedChildrenArePagedLocallyAndKeepAcceptedParentIDs() throws {
        let world = World(); world.tree = [0: [1, 2, 3, 4]]
        let result = try world.collect([entry(0)], limits: .init(children: 2))
        XCTAssertEqual(nodes(world), [0, 1, 2, 3, 4])
        XCTAssertEqual(result.expansionAttempts, 1)
        XCTAssertEqual(result.expandedControls, 2)
        XCTAssertEqual(world.reads.filter { $0.0 == 0 }.map(\.1), [0, 2])
        XCTAssertEqual(world.rows.dropFirst().map { $0["parent"] as! String }, Array(repeating: "accepted:e1", count: 4))
        XCTAssertTrue(result.reasonCounts.isEmpty)
    }

    func testElementBudgetExpandsRelevantWindowBeforeUnrelatedBranches() throws {
        let world = World()
        let result = try world.collect([entry(0), entry(1), entry(2, priority: 300)],
            limits: .init(initialElements: 1, expandedElements: 2))
        XCTAssertEqual(nodes(world), [0, 2])
        XCTAssertEqual(result.expansionAttempts, 1)
        XCTAssertEqual(result.metadata["state"] as? String, "partial")
        XCTAssertEqual(result.reasonCounts["element_limit"], 1)
        let limitation = (result.metadata["limitations"] as! [[String: Any]])[0]
        XCTAssertEqual(limitation["pid"] as? Int, 42)
        XCTAssertEqual(limitation["omitted_child_roots_at_least"] as? Int, 1)
    }

    func testVisibleControlsAreCollectedBeforeSlowBackgroundDiscovery() throws {
        var time: Double = 0
        let result = ObservationCollection<Int>(budget: 1, now: { time })
        var nodes = [Int]()
        let inspect: (ObservationCollection<Int>.Entry, String) -> ObservationCollection<Int>.Inspection = { item, _ in
            nodes.append(item.node); return .init()
        }
        let children: (ObservationCollection<Int>.Entry, Int, Int) -> ObservationCollection<Int>.Page = { item, _, _ in
            .init(nodes: item.node == 0 ? [1] : [], total: item.node == 0 ? 1 : 0)
        }
        try result.collect(roots: [entry(0)], revision: "accepted", expand: false, check: {}, equal: ==,
                           inspect: inspect, children: children)
        XCTAssertEqual(nodes, [0, 1])
        time = 2 // Discovery of another app consumes the remaining local budget.
        try result.collect(roots: [entry(3)], revision: "accepted", check: {}, equal: ==,
                           inspect: inspect, children: children)
        XCTAssertEqual(nodes, [0, 1]); XCTAssertEqual(result.collected, 2)
        XCTAssertEqual(result.reasonCounts["collection_timeout"], 1)
        XCTAssertEqual(result.metadata["state"] as? String, "partial")
    }

    func testTaskLabelsChooseTheRelevantMissingSubtreeLocally() throws {
        let world = World(); world.keywords = ["quarterly", "export"]
        world.tree = [0: [1, 5], 2: [3, 4]]; world.labels[2] = "Quarterly export panel"
        let result = try world.collect([entry(0), entry(2)], limits: .init(initialElements: 4, expandedElements: 5, children: 1))
        XCTAssertEqual(nodes(world), [0, 1, 2, 3, 4]) // Later relevant branch beats earlier noise.
        XCTAssertEqual(result.reasonCounts["child_limit"], 1)
        XCTAssertEqual(result.metadata["state"] as? String, "partial")
        XCTAssertEqual(AutomationObservationPolicy.keywordScore("Quarterly export panel", keywords: world.keywords), 120)
        XCTAssertEqual(AutomationObservationPolicy.keywordScore("Résumé export", keywords: ["resume", "export"]), 120)
    }

    func testDepthLimitIsRecoveredThenExplicitlyReportedAtTheHardBound() throws {
        let world = World(); world.tree = [0: [1], 1: [2], 2: [3]]
        let result = try world.collect([entry(0)], limits: .init(initialDepth: 0, expandedDepth: 2))
        XCTAssertEqual(nodes(world), [0, 1, 2])
        XCTAssertEqual(result.reasonCounts["depth_limit"], 1)
        XCTAssertEqual(result.metadata["state"] as? String, "partial")
        XCTAssertEqual((result.metadata["limitations"] as! [[String: Any]])[0]["element_id"] as? String, "accepted:e3")
    }

    func testExpansionHasOneBoundAndDoesNotReadAnEntireHugeTree() throws {
        let world = World(); world.tree = [0: Array(1...10_000)]
        let result = try world.collect([entry(0)], limits: .init(initialElements: 2, expandedElements: 4, children: 2, expansionPages: 1))
        XCTAssertEqual(nodes(world), [0, 1, 2, 3])
        XCTAssertLessThanOrEqual(result.expansionAttempts, 1)
        XCTAssertEqual(result.metadata["state"] as? String, "partial")
        XCTAssertGreaterThan((result.metadata["limitations"] as! [[String: Any]])[0]["omitted_child_roots_at_least"] as! Int, 9_000)
    }

    func testTimeoutDropsTheUnfinishedControlAndReportsRemainingScope() throws {
        let world = World(); world.tree = [0: [1]]
        world.afterInspection = { world.time += 0.1 }
        let result = try world.collect([entry(0)], budget: 0.15)
        XCTAssertEqual(nodes(world), [0])
        XCTAssertEqual(result.collected, 1)
        XCTAssertEqual(result.reasonCounts["collection_timeout"], 1)
        XCTAssertEqual(result.expansionAttempts, 0)
    }

    func testCancellationNeverReturnsAnAcceptedCollection() throws {
        let world = World(); world.tree = [0: [1]]
        world.afterInspection = { world.cancelled = true }
        XCTAssertThrowsError(try world.collect([entry(0)])) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(world.reads.isEmpty)
    }

    func testAccessibilityCyclesNeverRewalkAVisitedSubtree() throws {
        let world = World(); world.tree = [0: [1], 1: [0]]
        let result = try world.collect([entry(0)])
        XCTAssertEqual(result.collected, 3) // Preserve the existing focused-field alias contract.
        XCTAssertEqual(world.reads.map(\.0), [0, 1])
        XCTAssertTrue(result.reasonCounts.isEmpty)
    }

    func testUnreadableBranchesAndBoundedDiagnosticsAreNeverReportedComplete() {
        let result = ObservationCollection<Int>(budget: 1)
        result.scope = .init(pid: 42, parentID: "accepted:e1")
        for _ in 0..<100 { result.issue("accessibility_timeout", attribute: "AXChildren", code: -25204) }
        XCTAssertEqual(result.reasonCounts["accessibility_timeout"], 100)
        XCTAssertEqual((result.metadata["limitations"] as! [[String: Any]]).count, 32)
        XCTAssertEqual(result.metadata["limitation_scopes_omitted"] as? Int, 68)
        XCTAssertEqual(result.metadata["state"] as? String, "partial")
    }

    func testReadRecoveryIsLocalAndDoesNotRetryUnsupportedLeafAttributes() {
        var time: Double = 0
        var attempts = 0, retries = 0
        var issues = [String]()
        let context = ObservationAccessibilityReads.Context(deadline: 1, now: { time },
            report: { reason, _, _ in issues.append(reason) }, retried: { retries += 1 }, shouldRetry: { true })
        // The closure supplies fake results; no read, app launch or desktop event is sent.
        let element = AXUIElementCreateApplication(2_147_483_647)
        XCTAssertEqual(context.read(element, attribute: "AXChildren") {
            attempts += 1; time += 0.08; return attempts == 1 ? .cannotComplete : .success
        }, .success)
        XCTAssertEqual(attempts, 2); XCTAssertEqual(retries, 1); XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(context.read(element, attribute: "AXHelp") { attempts += 1; return .attributeUnsupported }, .attributeUnsupported)
        XCTAssertEqual(attempts, 3); XCTAssertEqual(retries, 1); XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(context.failures, 0)
        XCTAssertEqual(context.read(element, attribute: "AXRole", required: true) { return .noValue }, .noValue)
        XCTAssertEqual(issues, ["accessibility_incomplete"])
        XCTAssertEqual(context.failures, 1)
        time = 2
        _ = context.read(element, attribute: "AXChildren") { XCTFail("No query after deadline"); return .success }
        XCTAssertEqual(issues.last, "collection_timeout")
    }

    func testReadRetriesAreSharedAndRepeatedAttributesCannotExhaustObservationTime() {
        var retries = 0, reads = 0
        let context = ObservationAccessibilityReads.Context(deadline: 1, now: { 0 },
            report: { _, _, _ in }, retried: { retries += 1 }, shouldRetry: { true })
        let element = AXUIElementCreateApplication(2_147_483_647)
        for _ in 0..<10 { _ = context.read(element, attribute: "AXChildren") { reads += 1; return .cannotComplete } }
        XCTAssertEqual(retries, 1); XCTAssertEqual(reads, 11)
        for index in 0..<10 { _ = context.read(element, attribute: "AXFixture\(index)") { reads += 1; return .cannotComplete } }
        XCTAssertEqual(retries, 8); XCTAssertEqual(reads, 28)
    }

    func testUnreadableSubtreeDoesNotSpinOrHideSiblingControls() throws {
        let result = ObservationCollection<Int>(budget: 1, now: { 0 })
        var nodes = [Int](), reads = [Int]()
        try result.collect(roots: [entry(0), entry(2)], revision: "accepted", check: {}, equal: ==,
            inspect: { item, _ in nodes.append(item.node); return .init() }, children: { item, _, _ in
                reads.append(item.node)
                if item.node == 0 {
                    result.issue("accessibility_read_error", attribute: "AXChildren", code: -25204)
                    return .init(nodes: [], total: 0, incomplete: true)
                }
                return .init(nodes: item.node == 2 ? [3] : [], total: item.node == 2 ? 1 : 0)
            })
        XCTAssertEqual(nodes, [0, 2, 3]); XCTAssertEqual(reads, [0, 2, 3])
        XCTAssertEqual(result.reasonCounts["accessibility_read_error"], 1)
        XCTAssertEqual((result.metadata["limitations"] as! [[String: Any]])[0]["element_id"] as? String, "accepted:e1")
    }

    func testGraphicsOnlyAppReportsMissingAccessibilityInsteadOfNoControls() {
        XCTAssertTrue(AccessibilityController.hasObservableWindow(accessibilityCount: 0, graphicsCount: 1))
        let result = ObservationCollection<Int>(budget: 1)
        result.scope = .init(pid: 42)
        result.issue("accessibility_unavailable", attribute: "AXWindows")
        XCTAssertEqual(result.collected, 0)
        XCTAssertEqual(result.metadata["state"] as? String, "partial")
        XCTAssertEqual(result.reasonCounts["accessibility_unavailable"], 1)
    }
}
