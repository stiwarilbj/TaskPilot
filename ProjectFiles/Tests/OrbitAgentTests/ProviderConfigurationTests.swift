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
        defer { close(first); close(second) }
        let writer = open(root.appendingPathComponent("openclaw-configuration.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(writer, 0)
        defer { close(writer) }
        XCTAssertEqual(flock(writer, LOCK_EX | LOCK_NB), -1)
        XCTAssertEqual(errno, EWOULDBLOCK)
        XCTAssertEqual(flock(first, LOCK_UN), 0)
        XCTAssertEqual(flock(writer, LOCK_EX | LOCK_NB), -1)
        XCTAssertEqual(flock(second, LOCK_UN), 0)
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
        XCTAssertNil(OpenClawService.configurationLease(root: root, timeout: 0.05))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        XCTAssertEqual(flock(writer, LOCK_UN), 0)
        let reader = try XCTUnwrap(OpenClawService.configurationLease(root: root, timeout: 0.05))
        close(reader)
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
        XCTAssertNil(OpenClawService.configurationLease(root: root, timeout: 0.05))
        process.terminate(); process.waitUntilExit()
        let lease = try XCTUnwrap(OpenClawService.configurationLease(root: root, timeout: 0.05))
        close(lease)
    }
}
