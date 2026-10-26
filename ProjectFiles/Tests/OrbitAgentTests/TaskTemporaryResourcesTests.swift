import Darwin
import Foundation
import XCTest
@testable import OrbitAgent

final class TaskTemporaryResourcesTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: mode_t(0o700))])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func abandonedDirectory(root: URL, processID: Int32, startSeconds: UInt64,
                                   startMicroseconds: UInt64 = 0) throws -> URL {
        let id = UUID().uuidString.lowercased()
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: mode_t(0o700))])
        let owner: [String: Any] = [
            "version": 1,
            "directoryID": id,
            "leaseID": UUID().uuidString.lowercased(),
            "processID": processID,
            "processStartSeconds": startSeconds,
            "processStartMicroseconds": startMicroseconds
        ]
        let ownerFile = directory.appendingPathComponent(TaskTemporaryResourceLedger.ownerFileName)
        try JSONSerialization.data(withJSONObject: owner).write(to: ownerFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode_t(0o600))],
            ofItemAtPath: ownerFile.path)
        return directory
    }

    func testLiveLeaseIsKeptAndGracefulRemovalNeverTouchesSiblingOutput() throws {
        let root = try fixture()
        let output = root.deletingLastPathComponent().appendingPathComponent("user-output-\(UUID().uuidString)")
        try Data("keep".utf8).write(to: output)
        defer { try? FileManager.default.removeItem(at: output) }

        let lease = try TaskTemporaryResourceLedger.makeLease(root: root)
        let scratch = lease.directoryURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.appendingPathComponent(".owner-lease").path))
        XCTAssertEqual(TaskTemporaryResourceLedger.reclaimAbandoned(root: root), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        lease.removeDirectory()
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testStartupReclaimsReusedProcessIdentityWithoutFollowingScratchSymlink() throws {
        let root = try fixture()
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outside) }
        let protected = outside.appendingPathComponent("keep.txt")
        try Data("user data".utf8).write(to: protected)

        // The PID is live but its recorded birth identity is different, so it
        // represents a reused PID and cannot retain ownership of this scratch.
        let directory = try abandonedDirectory(root: root, processID: getpid(), startSeconds: .max)
        let payload = directory.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: payload.appendingPathComponent("outside"),
            withDestinationURL: outside)

        XCTAssertEqual(TaskTemporaryResourceLedger.reclaimAbandoned(root: root), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try String(contentsOf: protected, encoding: .utf8), "user data")
    }

    func testMalformedOrUnverifiableOwnerMetadataIsRetained() throws {
        let root = try fixture()
        let directory = root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: mode_t(0o700))])
        let owner = directory.appendingPathComponent(TaskTemporaryResourceLedger.ownerFileName)
        try Data("not owner metadata".utf8).write(to: owner)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode_t(0o600))],
            ofItemAtPath: owner.path)

        XCTAssertEqual(TaskTemporaryResourceLedger.reclaimAbandoned(root: root), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }
}
