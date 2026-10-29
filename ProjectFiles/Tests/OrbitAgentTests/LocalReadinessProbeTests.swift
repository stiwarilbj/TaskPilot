import Foundation
import XCTest
@testable import OrbitAgent

final class LocalReadinessProbeTests: XCTestCase {
    func testIndependentProbesStartTogetherAndShareOneDeadline() {
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let expected = LocalReadinessProbe.allCases.count
        let probes: [LocalReadinessProbe: LocalReadinessProbeCoordinator.Probe] = Dictionary(uniqueKeysWithValues: LocalReadinessProbe.allCases.map { kind in
            (kind, { (_: TimeInterval) -> LocalReadinessProbeOutcome in
                started.signal()
                // The first entered worker cannot finish until the others have
                // started, proving the coordinator did not serialize checks.
                gate.wait()
                return .passed
            })
        })

        // Release all workers when the shared allowance expires. A serial
        // coordinator would still return at the same one deadline, but it
        // could never have all workers waiting at once before that callback.
        let start = DispatchTime.now().uptimeNanoseconds
        let snapshot = LocalReadinessProbeCoordinator.run(timeout: 0.5, probes: probes, onDeadline: {
            for _ in 0..<expected { gate.signal() }
        })
        let elapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        XCTAssertTrue(snapshot.exceededDeadline)
        XCTAssertLessThan(elapsed, 1.0, "All probes must share one bounded wait")
        XCTAssertTrue(LocalReadinessProbe.allCases.allSatisfy { snapshot.outcomes[$0] == .timedOut })
        for _ in 0..<expected {
            XCTAssertEqual(started.wait(timeout: .now() + 0.5), .success,
                           "Every independent probe should start before the shared deadline")
        }
    }

    func testReadinessFailureExplanationUsesFixedProbeOrderNotCompletionOrder() {
        let probes: [LocalReadinessProbe: LocalReadinessProbeCoordinator.Probe] = [
            .descriptor: { _ in Thread.sleep(forTimeInterval: 0.04); return .failed("descriptor_invalid") },
            .privateDirectories: { _ in .failed("private_directory_permissions") },
            .authenticatedGateway: { _ in .failed("gateway_unavailable") }
        ]
        let result = LocalReadinessProbeCoordinator.run(timeout: 1, probes: probes)
        XCTAssertFalse(result.isReady)
        XCTAssertEqual(result.failures.map(\.probe), [.descriptor, .privateDirectories, .authenticatedGateway])
        XCTAssertEqual(result.failures.first?.outcome, .failed("descriptor_invalid"))
    }

    func testReadOnlyReadinessPermitPreventsRepairUntilAllChecksFinish() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let readPermit = try ManagedRuntimePermit(root: root, repairing: false, requireHealth: false)
            let probeStarted = DispatchSemaphore(value: 0)
            let releaseProbe = DispatchSemaphore(value: 0)
            let probeFinished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                _ = LocalReadinessProbeCoordinator.run(timeout: 2, probes: [
                    .descriptor: { _ in
                        probeStarted.signal()
                        releaseProbe.wait()
                        return .passed
                    },
                    .privateDirectories: { _ in .passed },
                    .authenticatedGateway: { _ in .passed }
                ])
                probeFinished.signal()
            }

            XCTAssertEqual(probeStarted.wait(timeout: .now() + 1), .success)
            XCTAssertThrowsError(try ManagedRuntimePermit(root: root, repairing: true, requireHealth: false),
                                 "Offline repair must not overlap a readiness snapshot")
            releaseProbe.signal()
            XCTAssertEqual(probeFinished.wait(timeout: .now() + 1), .success)
            withExtendedLifetime(readPermit) {}
        }
        XCTAssertNoThrow(try ManagedRuntimePermit(root: root, repairing: true, requireHealth: false),
                         "Repair can proceed after all read-only checks release their permit")
    }
}
