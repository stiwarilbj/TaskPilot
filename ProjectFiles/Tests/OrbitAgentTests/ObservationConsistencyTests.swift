import XCTest
@testable import OrbitAgent

final class ObservationConsistencyTests: XCTestCase {
    private struct Candidate { let number: Int; let signature: String }
    private final class World {
        var time: Double = 1
        var epoch = 0
        var scene = "window-1"
        var controls = "controls-1"
        var stages = 0
        var captures = 0
        var published: [Int] = []
        var discarded: [URL] = []
        var images: [URL] = []
        var refreshes: [Bool] = []
        var sleeps: [Double] = []
        var summary = ObservationConsistencyDiagnostics()
        var cancelled = false
        var checkpoints = 0
        var onCheckpoint: (() -> Void)?
        var onSleep: (() -> Void)?
        var onCapture: (() throws -> Void)?
        var onStage: (() -> Void)?
        var onPublish: (() throws -> Void)?
        deinit { for url in images { try? FileManager.default.removeItem(at: url) } }
        func collect(budget: Double = 5) async throws -> (Candidate, URL) {
            try await ObservationConsistency.collect(budget: budget, now: { self.time },
                checkpoint: {
                    self.checkpoints += 1; self.onCheckpoint?()
                    if self.cancelled { throw CancellationError() }
                },
                suspensionRevision: { self.epoch }, scene: { self.scene },
                stage: {
                    self.stages += 1; self.onStage?()
                    return Candidate(number: self.stages, signature: self.controls)
                }, signature: { $0.signature }, capture: { refresh in
                    self.captures += 1; self.refreshes.append(refresh)
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("consistency-\(UUID()).png")
                    try Data([1, 2, 3]).write(to: url); self.images.append(url)
                    // Model capture returns only after its own cleanup on error.
                    do { try self.onCapture?() }
                    catch { try? FileManager.default.removeItem(at: url); throw error }
                    return url
                }, discard: {
                    self.discarded.append($0); try? FileManager.default.removeItem(at: $0)
                }, publish: {
                    try self.onPublish?(); self.published.append($0.number)
                }, sleep: { self.sleeps.append($0); self.time += $0; self.onSleep?() },
                report: { self.summary = $0 })
        }
    }

    func testHealthyPairCapturesOnceAndPublishesOnlySecondTree() async throws {
        let world = World()
        let (candidate, url) = try await world.collect()
        XCTAssertEqual(candidate.number, 2)
        XCTAssertEqual(world.captures, 1)
        XCTAssertEqual(world.published, [2])
        XCTAssertEqual(world.refreshes, [false])
        XCTAssertTrue(world.discarded.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testCaptureGeometryMismatchRefreshesWithoutPublishingWrongTargets() async throws {
        let world = World()
        world.onCapture = { if world.captures == 1 { throw ScreenCoordinateError.captureChanged } }
        _ = try await world.collect()
        XCTAssertEqual(world.captures, 2)
        XCTAssertEqual(world.refreshes, [false, true])
        XCTAssertEqual(world.summary.rejected["capture_geometry"], 1)
        XCTAssertEqual(world.published, [3])
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.images[0].path))
    }

    func testPersistentCaptureGeometryMismatchHasExistingBoundAndNoPublishedTargets() async {
        let world = World()
        world.onCapture = { throw ScreenCoordinateError.captureChanged }
        do { _ = try await world.collect(budget: 0.25); XCTFail("Geometry must become stable") }
        catch { XCTAssertTrue(error is ObservationConsistencyError) }
        XCTAssertTrue(world.published.isEmpty)
        XCTAssertLessThanOrEqual(world.summary.elapsedSeconds, 0.25)
        XCTAssertTrue(world.images.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testWindowChangeDuringCaptureDiscardsPixelsAndRefreshesMetadata() async throws {
        let world = World()
        world.onCapture = { if world.captures == 1 { world.scene = "window-2" } }
        _ = try await world.collect()
        XCTAssertEqual(world.captures, 2)
        XCTAssertEqual(world.refreshes, [false, true])
        XCTAssertEqual(world.discarded.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.discarded[0].path))
        XCTAssertEqual(world.published, [3])
        XCTAssertEqual(world.summary.rejected["window_during_capture"], 1)
    }

    func testChangeWhileCollectingFirstTreeRetriesBeforeCapture() async throws {
        let world = World()
        world.onStage = { if world.stages == 1 { world.scene = "new-window" } }
        _ = try await world.collect()
        XCTAssertEqual(world.captures, 1)
        XCTAssertEqual(world.refreshes, [true])
        XCTAssertEqual(world.published, [3])
        XCTAssertEqual(world.summary.rejected["window_before_capture"], 1)
    }

    func testChangeWhileCollectingSecondTreeRejectsIt() async throws {
        let world = World()
        world.onStage = { if world.stages == 2 { world.scene = "new-window" } }
        _ = try await world.collect()
        XCTAssertEqual(world.captures, 2)
        XCTAssertEqual(world.published, [4])
        XCTAssertEqual(world.summary.rejected["window_during_controls"], 1)
    }

    func testControlChangeRetriesWithoutPublishingRejectedIDs() async throws {
        let world = World()
        world.onCapture = { world.controls = "field-ready" }
        _ = try await world.collect()
        XCTAssertEqual(world.captures, 2)
        XCTAssertEqual(world.published, [4])
        XCTAssertEqual(world.summary.rejected["control_layout"], 1)
    }

    func testPersistentChangesRespectFiveSecondBudgetAndBackoff() async {
        let world = World()
        world.onCapture = { world.scene = "moving-window-\(world.captures)"; world.time += 0.02 }
        do { _ = try await world.collect(); XCTFail("Must not publish changing evidence") }
        catch { XCTAssertTrue(error is ObservationConsistencyError) }
        XCTAssertTrue(world.published.isEmpty)
        XCTAssertTrue(world.images.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(Array(world.sleeps.prefix(4)), [0.1, 0.2, 0.4, 0.5])
        XCTAssertLessThanOrEqual(world.summary.elapsedSeconds, 5.02)
    }

    func testSettlingDeadlineIsNotExtended() async {
        let world = World()
        world.onCapture = { world.scene = "moving-window-\(world.captures)"; world.time += 0.01 }
        do { _ = try await world.collect(budget: 0.25); XCTFail() }
        catch { XCTAssertTrue(error is ObservationConsistencyError) }
        XCTAssertLessThanOrEqual(world.summary.elapsedSeconds, 0.26)
        XCTAssertTrue(world.published.isEmpty)
    }

    func testSlowStableOwnedReadDoesNotBecomeAnUnstableError() async throws {
        let world = World()
        world.onCapture = { world.time += 6 }
        _ = try await world.collect()
        XCTAssertEqual(world.captures, 1)
        XCTAssertEqual(world.published, [2])
        XCTAssertTrue(world.sleeps.isEmpty)
    }

    func testSlowUnstableReadCannotStartAnotherAttemptAfterDeadline() async {
        let world = World()
        world.onCapture = { world.time += 6; world.scene = "changed" }
        do { _ = try await world.collect(); XCTFail() }
        catch { XCTAssertTrue(error is ObservationConsistencyError) }
        XCTAssertEqual(world.captures, 1)
        XCTAssertEqual(world.discarded.count, 1)
        XCTAssertTrue(world.published.isEmpty)
    }

    func testWindowIdentityGeometryStackingAndDisplayChangesAllRejectOldPair() async throws {
        for change in ["replacement-window-ID", "different-PID-or-launch", "different-display-geometry",
                       "different-display-resolution", "new-stacking-order", "different-focused-window"] {
            let world = World()
            world.onCapture = { if world.captures == 1 { world.scene = change } }
            _ = try await world.collect()
            XCTAssertEqual(world.captures, 2, change)
            XCTAssertEqual(world.discarded.count, 1, change)
            XCTAssertEqual(world.published, [3], change)
        }
    }

    func testCancellationDuringBackoffStopsWithoutNewCapture() async {
        let world = World()
        world.onCapture = { world.scene = "changed" }
        world.onSleep = { world.cancelled = true }
        // Cancellation while backing off must prevent another capture.
        do { _ = try await world.collect(); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(world.published.isEmpty)
        XCTAssertEqual(world.discarded.count, 1)
    }

    func testCancellationAfterCaptureDeletesImageAndPublishesNothing() async {
        let world = World()
        world.onCapture = { world.cancelled = true }
        do { _ = try await world.collect(); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(world.discarded.count, 1)
        XCTAssertTrue(world.published.isEmpty)
    }

    func testRevocationImmediatelyBeforePublicationCannotCommit() async {
        let world = World()
        let lease = TaskLease()
        world.onPublish = { lease.revoke(); try lease.commit { XCTFail("Stale publication") } }
        do { _ = try await world.collect(); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(world.published.isEmpty)
        XCTAssertEqual(world.discarded.count, 1)
    }

    func testPauseResumeDiscardsOldCaptureAndRestartsBudget() async throws {
        let world = World()
        world.onCapture = { if world.captures == 1 { world.epoch += 1; world.time += 30 } }
        _ = try await world.collect()
        XCTAssertEqual(world.captures, 2)
        XCTAssertEqual(world.discarded.count, 1)
        XCTAssertEqual(world.published, [3])
        XCTAssertEqual(world.summary.rejected["pause"], 1)
    }

    func testPauseAtRetryBoundaryCannotEscapeAsAnUnclassifiedError() async throws {
        let world = World()
        world.onCapture = { if world.captures == 1 { world.scene = "moved" } }
        world.onCheckpoint = { if world.checkpoints == 6 { world.epoch += 1; world.time += 30 } }
        _ = try await world.collect()
        XCTAssertEqual(world.captures, 2)
        XCTAssertEqual(world.discarded.count, 1)
        XCTAssertEqual(world.summary.rejected["pause"], 1)
    }

    func testPauseImmediatelyBeforePublicationRestartsWithoutPublishingOldPair() async throws {
        let world = World()
        world.onPublish = {
            if world.captures == 1 { world.epoch += 1; throw CancellationError() }
        }
        _ = try await world.collect()
        XCTAssertEqual(world.captures, 2)
        XCTAssertEqual(world.published, [4])
        XCTAssertEqual(world.discarded.count, 1)
    }

    func testPermissionFailureDoesNotEnterConsistencyRetries() async {
        let world = World()
        world.onCapture = { throw ScreenCaptureError.permissionDenied("fixture") }
        do { _ = try await world.collect(); XCTFail() }
        catch { XCTAssertTrue(error is ScreenCaptureError) }
        XCTAssertEqual(world.captures, 1)
        XCTAssertTrue(world.sleeps.isEmpty)
        XCTAssertTrue(world.published.isEmpty)
    }

    private func elements(prefix: String = "a", value: String = "hello") -> [[String: Any]] {
        [["id": "\(prefix):root", "pid": 42, "role": "AXWindow", "title": "Editor", "frame": ["x": 1, "y": 2]],
         ["id": "\(prefix):field", "parent_id": "\(prefix):root", "window_id": "\(prefix):w1", "pid": 42,
          "role": "AXTextField", "title": "Name", "value": value, "focused": true, "enabled": true,
          "frame": ["x": 10, "y": 20], "actions": ["AXPress"]]]
    }

    func testSignatureIgnoresScopedIDsAndTreeEnumerationOrder() throws {
        let first = try ObservationConsistency.controlSignature(elements: elements(), applications: [])
        let second = try ObservationConsistency.controlSignature(elements: elements(prefix: "b").reversed(), applications: [])
        XCTAssertEqual(first, second)
    }

    func testSignatureDetectsTargetAndFieldChanges() throws {
        let source = elements()
        let baseline = try ObservationConsistency.controlSignature(elements: source, applications: [])
        let changes: [(String, Any)] = [("value", "new text"), ("title", "Other name"), ("role", "AXButton"),
            ("frame", ["x": 99, "y": 20]), ("focused", false), ("enabled", false),
            ("pid", 43), ("parent_id", "missing"), ("actions", [])]
        for (field, value) in changes {
            var changed = source; changed[1][field] = value
            XCTAssertNotEqual(baseline, try ObservationConsistency.controlSignature(elements: changed, applications: []), field)
        }
    }

    func testProgressValuesIgnoredButMenusAndSheetsDetected() throws {
        let progress: [[String: Any]] = [["role": "AXProgressIndicator", "value": 0.1, "pid": 42]]
        var updated = progress; updated[0]["value"] = 0.9
        let baseline = try ObservationConsistency.controlSignature(elements: progress, applications: [])
        XCTAssertEqual(baseline, try ObservationConsistency.controlSignature(elements: updated, applications: []))
        for role in ["AXMenu", "AXSheet", "AXDialog"] {
            XCTAssertNotEqual(baseline, try ObservationConsistency.controlSignature(elements: progress + [["role": role, "pid": 42]], applications: []))
        }
    }

    func testGraphicsOnlyAppMetadataStillParticipates() throws {
        let app: [String: Any] = ["pid": 42, "accessibility_available": false,
            "windows": [["window_id": "a:w1", "frame": ["x": 10, "y": 20], "source": "core_graphics"]]]
        var same = app; same["windows"] = [["window_id": "b:w1", "frame": ["x": 10, "y": 20], "source": "core_graphics"]]
        let baseline = try ObservationConsistency.controlSignature(elements: [], applications: [app])
        XCTAssertEqual(baseline, try ObservationConsistency.controlSignature(elements: [], applications: [same]))
        same["windows"] = [["frame": ["x": 99, "y": 20], "source": "core_graphics"]]
        XCTAssertNotEqual(baseline, try ObservationConsistency.controlSignature(elements: [], applications: [same]))
    }
}
