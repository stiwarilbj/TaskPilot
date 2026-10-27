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

    func testStartupRepairsOnlyKnownScratchModeAndReadsBack() throws {
        let root = try fixture()
        for mode: mode_t in [0o755, 0o777, 0o1700] {
            XCTAssertEqual(chmod(root.path, mode), 0)
            XCTAssertThrowsError(try PrivateDirectoryPermissions.check(root)) {
                XCTAssertEqual($0 as? PrivateDirectoryPermissions.Failure, .permissions)
            }
            try TaskTemporaryResourceLedger.prepareStartup(root: root)
            try PrivateDirectoryPermissions.check(root)
            var status = stat(); XCTAssertEqual(lstat(root.path, &status), 0)
            XCTAssertEqual(status.st_mode & 0o7777, 0o700)
        }
    }

    func testUnopenableScratchFailsClosedRatherThanPathBasedChmod() throws {
        let root = try fixture(); XCTAssertEqual(chmod(root.path, 0o000), 0)
        defer { _ = chmod(root.path, 0o700) }
        XCTAssertThrowsError(try TaskTemporaryResourceLedger.prepareStartup(root: root)) {
            XCTAssertEqual($0 as? PrivateDirectoryPermissions.Failure, .permissions)
        }
    }

    func testStartupRejectsSymlinkWithoutChangingTarget() throws {
        let root = try fixture(), target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o755])
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try TaskTemporaryResourceLedger.prepareStartup(root: link)) {
            XCTAssertEqual($0 as? PrivateDirectoryPermissions.Failure, .symlink)
        }
        var status = stat(); XCTAssertEqual(lstat(target.path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o7777, 0o755)
        let file = root.appendingPathComponent("file"); try Data().write(to: file)
        XCTAssertThrowsError(try TaskTemporaryResourceLedger.prepareStartup(root: file))
    }

    func testStartupCreatesMissingPrivateRoot() throws {
        let root = try fixture().appendingPathComponent("new-scratch")
        try TaskTemporaryResourceLedger.prepareStartup(root: root)
        try PrivateDirectoryPermissions.check(root)
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

    func testCaptureDiskEstimateIncludesReserveAndRejectsOverflow() throws {
        XCTAssertEqual(try CaptureDiskHeadroom.requiredBytes(pixelBytes: 0), 17 * 1024 * 1024)
        XCTAssertEqual(try CaptureDiskHeadroom.requiredBytes(pixelBytes: 4096), 17 * 1024 * 1024 + 8192)
        XCTAssertThrowsError(try CaptureDiskHeadroom.requiredBytes(pixelBytes: .max))
        XCTAssertThrowsError(try CaptureDiskHeadroom.requiredBytes(pixelBytes: .max / 2))
        try CaptureDiskHeadroom.check(descriptor: -1, requiredBytes: 10, readAvailable: { _ in 10 })
        XCTAssertThrowsError(try CaptureDiskHeadroom.check(descriptor: -1, requiredBytes: 10, readAvailable: { _ in 9 })) { error in
            guard case CaptureDiskHeadroom.Failure.insufficientSpace = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try CaptureDiskHeadroom.check(descriptor: -1, requiredBytes: 0)) { error in
            guard case CaptureDiskHeadroom.Failure.unavailable = error else { return XCTFail("\(error)") }
        }
    }

    func testDiskCheckUsesExistingVolumeWithoutCreatingMissingDirectories() throws {
        let root = try fixture(), missing = root.appendingPathComponent("missing/capture", isDirectory: true)
        try CaptureDiskHeadroom.check(directory: missing, requiredBytes: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
        let lease = try TaskTemporaryResourceLedger.makeLease(root: root)
        let capture = try lease.captureDirectory()
        try capture.requireDiskHeadroom(0)
        let parked = lease.directoryURL.appendingPathComponent("parked")
        try FileManager.default.moveItem(at: capture.directoryURL, to: parked)
        try FileManager.default.createDirectory(at: capture.directoryURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try capture.requireDiskHeadroom(0))
        lease.removeDirectory()
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

    func testCaptureRemovalStaysOnItsDescriptorWhenParentPathIsSwapped() throws {
        let root = try fixture(), lease = try TaskTemporaryResourceLedger.makeLease(root: root)
        let capture = try lease.captureDirectory()
        let file = capture.directoryURL.appendingPathComponent("screen.png")
        try Data("owned".utf8).write(to: file)
        let expected = TaskCaptureDirectory.FileIdentity(try XCTUnwrap(capture.status(named: file.lastPathComponent)))
        let parked = root.appendingPathComponent("parked")
        XCTAssertTrue(try capture.removeFile(named: file.lastPathComponent, expected: expected, beforeRemoval: {
            try FileManager.default.moveItem(at: capture.directoryURL, to: parked)
            try FileManager.default.createDirectory(at: capture.directoryURL, withIntermediateDirectories: false)
            try Data("keep".utf8).write(to: file)
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parked.appendingPathComponent(file.lastPathComponent).path))
        lease.removeDirectory()
        XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
    }

    func testFileSwapBetweenInspectionAndRemovalIsRestoredWithoutDeletion() throws {
        for useSymlink in [false, true] {
            let root = try fixture(), lease = try TaskTemporaryResourceLedger.makeLease(root: root)
            let capture = try lease.captureDirectory()
            let file = capture.directoryURL.appendingPathComponent("screen.png")
            let protected = root.appendingPathComponent("protected.png")
            try Data("owned".utf8).write(to: file)
            try Data("keep".utf8).write(to: protected)
            let expected = TaskCaptureDirectory.FileIdentity(try XCTUnwrap(capture.status(named: file.lastPathComponent)))
            let parked = capture.directoryURL.appendingPathComponent("previous.png")
            XCTAssertFalse(try capture.removeFile(named: file.lastPathComponent, expected: expected, beforeRemoval: {
                try FileManager.default.moveItem(at: file, to: parked)
                if useSymlink { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: protected) }
                else { try Data("new data".utf8).write(to: file) }
            }))
            XCTAssertEqual(try Data(contentsOf: parked), Data("owned".utf8))
            XCTAssertEqual(try Data(contentsOf: file), Data((useSymlink ? "keep" : "new data").utf8))
            XCTAssertEqual(try Data(contentsOf: protected), Data("keep".utf8))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: capture.directoryURL.path).contains { $0.hasPrefix(".discard-") })
            lease.removeDirectory()
        }
    }

    func testAbandonedRecoveryRetainsReplacedCaptureDirectory() throws {
        for replaceCapture in [false, true] {
            let root = try fixture()
            var lease: TaskTemporaryResourceLease? = try TaskTemporaryResourceLedger.makeLease(root: root)
            let scratch = try XCTUnwrap(lease).directoryURL
            let capture = try XCTUnwrap(lease).captureDirectory()
            let file = capture.directoryURL.appendingPathComponent("screen.png")
            try Data("keep".utf8).write(to: file)
            if replaceCapture {
                try FileManager.default.moveItem(at: capture.directoryURL, to: root.appendingPathComponent("original"))
                try FileManager.default.createDirectory(at: capture.directoryURL, withIntermediateDirectories: false)
                try Data("replacement".utf8).write(to: file)
            }
            let owner = scratch.appendingPathComponent(TaskTemporaryResourceLedger.ownerFileName)
            var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: owner)) as? [String: Any])
            XCTAssertNotNil(record["captureDirectory"])
            record["processStartSeconds"] = UInt64.max
            try JSONSerialization.data(withJSONObject: record).write(to: owner)
            lease = nil // Release the live lease, as process exit would.
            XCTAssertEqual(TaskTemporaryResourceLedger.reclaimAbandoned(root: root), replaceCapture ? 0 : 1)
            if replaceCapture { XCTAssertEqual(try Data(contentsOf: file), Data("replacement".utf8)) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path)) }
        }
    }

    func testRestoreCollisionPreservesBothReplacementsThroughRetirementAndRecovery() throws {
        let root = try fixture(), lease = try TaskTemporaryResourceLedger.makeLease(root: root)
        let capture = try lease.captureDirectory()
        let file = capture.directoryURL.appendingPathComponent("screen.png")
        try Data("owned".utf8).write(to: file)
        let expected = TaskCaptureDirectory.FileIdentity(try XCTUnwrap(capture.status(named: file.lastPathComponent)))
        let parked = capture.directoryURL.appendingPathComponent("original.png")
        XCTAssertFalse(try capture.removeFile(named: file.lastPathComponent, expected: expected, beforeRemoval: {
            try FileManager.default.moveItem(at: file, to: parked)
            try Data("raced replacement".utf8).write(to: file)
        }, afterQuarantine: {
            try Data("newer replacement".utf8).write(to: file)
        }))
        XCTAssertTrue(capture.hasRemovalConflict)
        let names = try FileManager.default.contentsOfDirectory(atPath: capture.directoryURL.path)
        let quarantine = try XCTUnwrap(names.first { $0.hasPrefix(".discard-") })
        XCTAssertEqual(try Data(contentsOf: capture.directoryURL.appendingPathComponent(quarantine)), Data("raced replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: file), Data("newer replacement".utf8))
        lease.removeDirectory()
        let owner = lease.directoryURL.appendingPathComponent(TaskTemporaryResourceLedger.ownerFileName)
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: owner)) as? [String: Any])
        record["processStartSeconds"] = UInt64.max
        try JSONSerialization.data(withJSONObject: record).write(to: owner)
        XCTAssertEqual(TaskTemporaryResourceLedger.reclaimAbandoned(root: root), 0)
        XCTAssertEqual(try Data(contentsOf: file), Data("newer replacement".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: capture.directoryURL.appendingPathComponent(quarantine).path))
    }

    func testReplacedScratchAndSymlinkCaptureCannotBeAcquired() throws {
        let root = try fixture(), lease = try TaskTemporaryResourceLedger.makeLease(root: root)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let capture = lease.directoryURL.appendingPathComponent("capture")
        try FileManager.default.createSymbolicLink(at: capture, withDestinationURL: outside)
        XCTAssertThrowsError(try lease.captureDirectory())
        try FileManager.default.removeItem(at: capture)
        try FileManager.default.moveItem(at: lease.directoryURL, to: root.appendingPathComponent("original"))
        try FileManager.default.createDirectory(at: lease.directoryURL, withIntermediateDirectories: false)
        let replacement = lease.directoryURL.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: replacement)
        XCTAssertThrowsError(try lease.captureDirectory())
        lease.removeDirectory(); lease.removeDirectory()
        XCTAssertEqual(try Data(contentsOf: replacement), Data("keep".utf8))
    }
}
