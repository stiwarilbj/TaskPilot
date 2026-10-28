import Darwin
import Foundation
import XCTest
@testable import OrbitAgent

final class ProviderConfigurationTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-coordinator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testProbeUsesSharedLeaseAndReleasesOnClose() throws {
        let root = try directory()
        let first = try XCTUnwrap(OpenClawService.configurationLease(root: root))
        let second = try XCTUnwrap(OpenClawService.configurationLease(root: root))
        defer { first.release(); second.release() }
        let writer = open(root.appendingPathComponent("openclaw-configuration.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(writer, 0)
        defer { close(writer) }
        XCTAssertEqual(flock(writer, LOCK_EX | LOCK_NB), -1)
        XCTAssertEqual(errno, EWOULDBLOCK)
        first.release()
        XCTAssertEqual(flock(writer, LOCK_EX | LOCK_NB), -1)
        second.release()
        XCTAssertEqual(flock(writer, LOCK_EX | LOCK_NB), 0)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("openclaw-configuration.lock").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testProbeTimesOutWhileConfigurationWriterOwnsLease() throws {
        let root = try directory()
        let writer = open(root.appendingPathComponent("openclaw-configuration.lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        XCTAssertGreaterThanOrEqual(writer, 0)
        defer { close(writer) }
        XCTAssertEqual(flock(writer, LOCK_EX), 0)
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(try OpenClawService.configurationLease(root: root, timeout: 0.05))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        XCTAssertEqual(flock(writer, LOCK_UN), 0)
        let reader = try XCTUnwrap(OpenClawService.configurationLease(root: root, timeout: 0.05))
        reader.release()
    }

    func testPythonWriterAndNativeReaderUseSameLeaseProtocol() throws {
        let root = try directory()
        let ready = root.appendingPathComponent("ready")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import fcntl,os,pathlib,sys,time; f=os.open(sys.argv[1],os.O_CREAT|os.O_RDWR,0o600); fcntl.flock(f,fcntl.LOCK_EX); pathlib.Path(sys.argv[2]).touch(); time.sleep(5)", root.appendingPathComponent("openclaw-configuration.lock").path, ready.path]
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !FileManager.default.fileExists(atPath: ready.path) && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        XCTAssertNil(try OpenClawService.configurationLease(root: root, timeout: 0.05))
        process.terminate(); process.waitUntilExit()
        let lease = try XCTUnwrap(OpenClawService.configurationLease(root: root, timeout: 0.05))
        lease.release()
    }

    func testInvertedLeaseFailsBeforeOpeningOrWaitingAndLeavesHeldRankIntact() throws {
        let root = try directory().appendingPathComponent("must-not-be-created")
        let order = BackendLockOrder()
        let installation = try order.reserve(.installation)
        XCTAssertThrowsError(try OpenClawService.configurationLease(root: root, order: order)) {
            XCTAssertEqual($0 as? BackendLockOrderError, .violation)
            XCTAssertEqual($0.localizedDescription, "internal_lock_order")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertThrowsError(try order.reserve(.singleFlight))
        installation.release()
        let lease = try XCTUnwrap(OpenClawService.configurationLease(root: root, order: order))
        lease.release(); lease.release()
        let first = try order.reserve(.singleFlight)
        first.release()
    }

    func testEveryRankPairRejectsOnlyDescendingOrder() throws {
        XCTAssertEqual(BackendLockCategory.allCases.map(\.rawValue), [10, 20, 30, 40])
        for outer in BackendLockCategory.allCases {
            for inner in BackendLockCategory.allCases {
                let order = BackendLockOrder()
                let held = try order.reserve(outer)
                if inner.rawValue < outer.rawValue {
                    XCTAssertThrowsError(try order.reserve(inner)) {
                        XCTAssertEqual($0 as? BackendLockOrderError, .violation)
                    }
                } else {
                    let allowed = try order.reserve(inner)
                    allowed.release()
                }
                held.release()
            }
        }
    }

    func testLeaseDeinitAndFailedWaitReleaseRankAndRecordOnlyWaitFacts() throws {
        let root = try directory()
        let order = BackendLockOrder()
        var lease = try OpenClawService.configurationLease(root: root, order: order)
        XCTAssertNotNil(lease)
        XCTAssertThrowsError(try order.reserve(.singleFlight))
        lease = nil
        let single = try order.reserve(.singleFlight)
        single.release()
        let writer = open(root.appendingPathComponent("openclaw-configuration.lock").path, O_RDWR)
        defer { close(writer) }
        XCTAssertEqual(flock(writer, LOCK_EX | LOCK_NB), 0)
        XCTAssertNil(try OpenClawService.configurationLease(root: root, timeout: 0.01, order: order))
        let afterFailure = try order.reserve(.singleFlight)
        afterFailure.release()
        let sample = try XCTUnwrap(BackendLockOrder.waitSamples.last)
        XCTAssertEqual(sample.category, .configuration)
        XCTAssertGreaterThanOrEqual(sample.waitMilliseconds, 0)
        XCTAssertLessThanOrEqual(BackendLockOrder.waitSamples.count, 128)
    }

    func testOperationRanksFollowTaskContextAndWaitClockIsIndependent() async throws {
        var clock: TimeInterval = 1
        let context = BackendLockOrder(clock: { clock })
        try await BackendLockOrder.$operation.withValue(context) {
            let high = try BackendLockOrder.current.reserve(.state)
            await Task.yield()
            XCTAssertThrowsError(try BackendLockOrder.current.reserve(.configuration))
            high.measureWait { clock = 1.025 }
            high.release()
            let config = try BackendLockOrder.current.reserve(.configuration)
            config.release()
        }
        XCTAssertEqual(try XCTUnwrap(BackendLockOrder.waitSamples.last).waitMilliseconds, 25, accuracy: 0.001)
        let independent = BackendLockOrder()
        let high = try context.reserve(.state)
        let low = try independent.reserve(.singleFlight)
        low.release(); high.release()
    }
}
