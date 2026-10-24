import CoreGraphics
import Foundation
import XCTest
@testable import OrbitAgent

final class LocalOperationBudgetTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double = 0
        var now: Double { lock.withLock { value } }
        func advance(_ seconds: Double) { lock.withLock { value += seconds } }
    }
    func testNestedChecksConsumeOneAllowanceAndReportTheConsumingPhase() throws {
        let clock = Clock(), budget = LocalOperationBudget(seconds: 1, phase: "activation", now: { clock.now })
        try LocalOperationBudget.$current.withValue(budget) {
            clock.advance(0.4)
            XCTAssertEqual(LocalOperationBudget.allowance(2), 0.6, accuracy: 0.001)
            try LocalOperationBudget.check("inspection")
            clock.advance(0.61)
            XCTAssertThrowsError(try LocalOperationBudget.check("capture")) { error in
                XCTAssertEqual((error as? LocalOperationBudget.Exhausted)?.phase, "inspection")
            }
            XCTAssertEqual(LocalOperationBudget.allowance(2), 0)
        }
    }
    func testExpiredPreflightCannotDispatchAndExpiredReadbackCannotRejectDeliveredWork() throws {
        for delivered in [false, true] {
            let clock = Clock(), budget = LocalOperationBudget(seconds: 1, phase: "activation", now: { clock.now })
            let lease = TaskLease(), id = UUID().uuidString.lowercased()
            guard case .new(let token) = try lease.actionReceipts.begin(id: id, payload: ["fixture": true]) else { return XCTFail() }
            var effects = 0
            try TaskOwnership.$current.withValue(lease) {
                try TaskOwnership.$actionReceipt.withValue(token) {
                    try LocalOperationBudget.$current.withValue(budget) {
                        if delivered { try TaskOwnership.commit { effects += 1 } }
                        clock.advance(1.1)
                        do { try TaskOwnership.commit { effects += 1 }; XCTFail("Expired delivery") }
                        catch { token.fail(error, code: "local_budget_exhausted") }
                    }
                }
            }
            XCTAssertEqual(effects, delivered ? 1 : 0)
            XCTAssertEqual(token.receipt["state"] as? String, delivered ? "unconfirmed" : "rejected")
            XCTAssertEqual(token.receipt["outcome"] as? String, delivered ? "delivered_unconfirmed" : "rejected")
        }
    }
    func testCaptureConsumesBudgetBeforeAnyPostCaptureCollectionOrPublication() async throws {
        let clock = Clock(), budget = LocalOperationBudget(seconds: 1, phase: "collection", now: { clock.now })
        var collections = 0, published = 0, discarded = 0, encodes = 0
        do {
            _ = try await LocalOperationBudget.$current.withValue(budget) {
                try await ObservationConsistency.collect(checkpoint: { try await TaskOwnership.checkpoint() }, scene: { 1 },
                    stage: { _ in collections += 1; clock.advance(0.4); return 1 }, signature: { String($0) },
                    capture: { _ in try LocalOperationBudget.check("capture"); clock.advance(0.7); return 7 },
                    discard: { _ in discarded += 1 }, prepare: { _, _, _ in encodes += 1 }, publish: { _ in published += 1 })
            }
            XCTFail("Late capture published")
        } catch { XCTAssertEqual((error as? LocalOperationBudget.Exhausted)?.phase, "capture") }
        XCTAssertEqual(collections, 1); XCTAssertEqual(discarded, 1)
        XCTAssertEqual(encodes, 0); XCTAssertEqual(published, 0)
    }
    func testQueuedAcquisitionExpiresWithoutReleasingTheActiveReservation() async throws {
        let queue = CaptureAcquisitionQueue(), active = try await queue.acquire(.evidence)
        let budget = LocalOperationBudget(seconds: 0.02, phase: "capture_queue")
        do {
            _ = try await LocalOperationBudget.$current.withValue(budget) {
                try await LocalOperationBudget.bounded(phase: "capture_queue") { try await queue.acquire(.evidence) }
            }
            XCTFail("Queue wait exceeded budget")
        } catch { XCTAssertTrue(error is LocalOperationBudget.Exhausted) }
        let stats = await queue.statistics
        XCTAssertEqual(stats.waitingEvidence, 0); XCTAssertEqual(stats.evidenceFrames, 1); XCTAssertTrue(stats.acquiring)
        try active.check(); await queue.acquired(active)
    }
    func testCancellationPrecedesReadinessAndCannotRenewTheBudget() async throws {
        let started = expectation(description: "Ready loop entered")
        let budget = LocalOperationBudget(seconds: 2, phase: "focus")
        let work = Task {
            try await LocalOperationBudget.$current.withValue(budget) {
                try await AutomationInputPolicy.waitUntilReady(ready: { started.fulfill(); return false })
            }
        }
        await fulfillment(of: [started], timeout: 1)
        work.cancel()
        do { try await work.value; XCTFail("Cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertGreaterThan(budget.remaining, 0)
    }
    func testSharedBudgetPreventsSecondReadinessProbe() async throws {
        let clock = Clock(), budget = LocalOperationBudget(seconds: 1, phase: "activation", now: { clock.now })
        var probes = 0
        do {
            try await LocalOperationBudget.$current.withValue(budget) {
                try await AutomationInputPolicy.waitUntilReady(ready: { clock.advance(1.1); return true })
                try await AutomationInputPolicy.waitUntilReady(ready: { probes += 1; return true })
            }
            XCTFail("Expired focus check")
        } catch { XCTAssertTrue(error is LocalOperationBudget.Exhausted) }
        XCTAssertEqual(probes, 0)
    }
    func testFileCommitAfterBudgetExpiryLeavesDestinationAndReceiptUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("budget-file-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("output")
        try Data("before".utf8).write(to: file)
        let clock = Clock(), budget = LocalOperationBudget(seconds: 1, phase: "file_staging", now: { clock.now })
        let operation = try BoundFileOperation(file, hook: { boundary in if boundary == .beforeCommit { clock.advance(1.1) } })
        XCTAssertThrowsError(try LocalOperationBudget.$current.withValue(budget) {
            try operation.replace(with: Data("after".utf8), append: false, mustBeAbsent: false)
        }) { XCTAssertTrue($0 is LocalOperationBudget.Exhausted) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "before")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["output"])
    }
    func testSlowCompressionDrainsAndRemovesItsFileAfterBudgetExpiry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("budget-png-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let encoder = CapturePNGEncoder(directory: root, writer: { image, url in
            Thread.sleep(forTimeInterval: 0.04) // Simulated nonpreemptible native work.
            try ScreenCaptureService.writePNG(image, to: url)
        })
        let service = ScreenCaptureService(encoder: encoder, acquirer: { _, _, _ in image })
        let display = DisplayDescriptor(id: 777, name: "fixture", x: 0, y: 0, width: 10, height: 10, isMain: false)
        let frame = try await service.acquire(display: display)
        do {
            _ = try await LocalOperationBudget.$current.withValue(LocalOperationBudget(seconds: 0.01, phase: "capture_encoding")) {
                try await service.encode(frame)
            }
            XCTFail("Late PNG published")
        } catch { XCTAssertTrue(error is LocalOperationBudget.Exhausted) }
        let active = await encoder.activeCount, pending = await encoder.pendingCount
        XCTAssertEqual(active, 0); XCTAssertEqual(pending, 0)
        if FileManager.default.fileExists(atPath: root.path) {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }
    @MainActor
    func testPrivateBridgeRejectsInvalidBudgetsWithoutDispatch() async throws {
        let lease = TaskLease()
        let bridge = AgentAutomationBridge(displayService: DisplayService(), accessibility: AccessibilityController(), capture: ScreenCaptureService())
        try bridge.bind(lease)
        for value: Any in [true, "100", 0, -1, 1.5, Double.infinity, 3_600_001] {
            let response = await bridge.handleOwned(["task_generation_id": lease.id, "instruction_revision": 0, "working_document_revision": 0, "method": "action_receipt",
                "params": ["action_id": UUID().uuidString, "local_budget_ms": value]], lease: lease)
            XCTAssertEqual(response["ok"] as? Bool, false)
            XCTAssertEqual(response["outcome"] as? String, "rejected")
        }
    }
}
