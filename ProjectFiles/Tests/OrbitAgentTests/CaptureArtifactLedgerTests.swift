import Foundation
import Darwin
import XCTest
@testable import OrbitAgent

final class CaptureArtifactLedgerTests: XCTestCase {
    private func owner(files: Int = 128, bytes: Int64 = 256 * 1024 * 1024) throws -> TaskLease {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-ledger-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return TaskLease(scratchRoot: root, captureFileLimit: files, captureByteLimit: bytes)
    }
    private func file(_ owner: TaskLease, bytes: Int, name: String = UUID().uuidString) throws -> URL {
        let directory = try owner.scratchDirectory().appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name + ".png")
        try Data(repeating: 42, count: bytes).write(to: url)
        return url
    }
    func testCountsArePerOwnerAndRegistrationIsIdempotent() throws {
        let first = try owner(), second = try owner()
        let a = try file(first, bytes: 11), b = try file(second, bytes: 7)
        try first.ownArtifact(a); try first.ownArtifact(a); try second.ownArtifact(b)
        XCTAssertEqual(first.captureArtifactUsage, .init(fileCount: 1, totalBytes: 11))
        XCTAssertEqual(second.captureArtifactUsage, .init(fileCount: 1, totalBytes: 7))
        first.revoke(); first.retire()
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        XCTAssertEqual(first.captureArtifactUsage, .init(fileCount: 0, totalBytes: 0))
        second.revoke(); second.retire()
    }
    func testLimitsRejectNewFileWithoutEvictingEvidenceAndDiscardFreesBudget() throws {
        let owner = try owner(files: 1, bytes: 5)
        let a = try file(owner, bytes: 5), b = try file(owner, bytes: 1)
        try owner.ownArtifact(a)
        XCTAssertThrowsError(try owner.ownArtifact(b))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        owner.discardArtifact(b)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
        owner.discardArtifact(a)
        let oversized = try file(owner, bytes: 6)
        XCTAssertThrowsError(try owner.ownArtifact(oversized))
        owner.discardArtifact(oversized)
        let exact = try file(owner, bytes: 5)
        try owner.ownArtifact(exact)
        XCTAssertEqual(owner.captureArtifactUsage.totalBytes, 5)
        owner.revoke(); owner.retire()
    }
    func testRuntimeUnlinkIsReconciledWithoutReadingImages() throws {
        let owner = try owner(files: 1, bytes: 8)
        let old = try file(owner, bytes: 8)
        try owner.ownArtifact(old)
        try FileManager.default.removeItem(at: old)
        let new = try file(owner, bytes: 7)
        try owner.ownArtifact(new)
        XCTAssertEqual(owner.captureArtifactUsage, .init(fileCount: 1, totalBytes: 7))
        owner.revoke(); owner.retire()
    }
    func testReaderHoldDefersDiscardAndRetiredDirectoryCleanup() throws {
        let owner = try owner()
        let a = try file(owner, bytes: 9)
        let directory = try owner.scratchDirectory()
        try owner.ownArtifact(a)
        var hold: CaptureArtifactHold? = try owner.retainCaptureArtifact(a)
        owner.discardArtifact(a)
        owner.revoke(); owner.retire(); owner.retire()
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertEqual(owner.captureArtifactUsage.totalBytes, 9)
        withExtendedLifetime(hold) {}
        hold = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(owner.captureArtifactUsage, .init(fileCount: 0, totalBytes: 0))
    }
    func testEncoderHoldProtectsPartialFileUntilDrain() throws {
        let owner = try owner()
        var hold: CaptureArtifactHold? = try owner.beginCaptureEncoding()
        let a = try file(owner, bytes: 3)
        let directory = try owner.scratchDirectory()
        owner.revoke(); owner.retire()
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertThrowsError(try owner.ownArtifact(a))
        owner.discardArtifact(a)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        withExtendedLifetime(hold) {}
        hold = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testUserOutputsForeignOwnersAndSymlinksNeverEnterCleanup() throws {
        let owner = try owner(), other = try self.owner()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("user-output-\(UUID()).png")
        try Data([1,2,3]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertThrowsError(try owner.ownArtifact(outside))
        owner.discardArtifact(outside)
        let foreign = try file(other, bytes: 3)
        try other.ownArtifact(foreign)
        XCTAssertThrowsError(try owner.ownArtifact(foreign))
        owner.discardArtifact(foreign)
        let link = try file(owner, bytes: 0)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try owner.ownArtifact(link))
        owner.discardArtifact(link)
        owner.revoke(); owner.retire()
        XCTAssertEqual(try Data(contentsOf: outside), Data([1,2,3]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        other.revoke(); other.retire()
    }
    func testMultipleHoldsAndConcurrentReadsStayBounded() throws {
        let owner = try owner()
        let a = try file(owner, bytes: 9)
        try owner.ownArtifact(a)
        var first: CaptureArtifactHold? = try owner.retainCaptureArtifact(a)
        var second: CaptureArtifactHold? = try owner.retainCaptureArtifact(a)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            XCTAssertEqual(owner.captureArtifactUsage.totalBytes, 9)
        }
        owner.revoke(); owner.retire()
        withExtendedLifetime(first) {}; first = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        withExtendedLifetime(second) {}; second = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertThrowsError(try owner.beginCaptureEncoding())
        XCTAssertThrowsError(try owner.retainCaptureArtifact(a))
    }

    func testRenamedCaptureDirectoryCannotRedirectCleanupOrRetains() throws {
        for useSymlink in [false, true] {
            let owner = try owner()
            let original = try file(owner, bytes: 9, name: "screen")
            let scratch = try owner.scratchDirectory()
            try owner.ownArtifact(original)
            var hold: CaptureArtifactHold? = try owner.retainCaptureArtifact(original)
            let parked = scratch.deletingLastPathComponent().appendingPathComponent("parked-\(UUID())")
            try FileManager.default.moveItem(at: original.deletingLastPathComponent(), to: parked)
            let replacement = scratch.deletingLastPathComponent().appendingPathComponent("replacement-\(UUID())")
            if useSymlink {
                try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
                try FileManager.default.createSymbolicLink(at: original.deletingLastPathComponent(), withDestinationURL: replacement)
            } else {
                try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: false)
            }
            let replacementFile = useSymlink ? replacement.appendingPathComponent(original.lastPathComponent) : original
            try Data("replacement".utf8).write(to: replacementFile)
            XCTAssertThrowsError(try owner.retainCaptureArtifact(original))
            XCTAssertThrowsError(try owner.ownArtifact(original))
            owner.discardArtifact(original)
            XCTAssertEqual(owner.captureArtifactUsage.totalBytes, 9)
            withExtendedLifetime(hold) {}; hold = nil
            XCTAssertFalse(FileManager.default.fileExists(atPath: parked.appendingPathComponent(original.lastPathComponent).path))
            XCTAssertEqual(owner.captureArtifactUsage, .init(fileCount: 0, totalBytes: 0))
            owner.revoke(); owner.retire()
            XCTAssertEqual(try Data(contentsOf: replacementFile), Data("replacement".utf8),
                           "Final scratch cleanup must also refuse a replacement capture directory")
        }
    }

    func testReplacedOrModifiedPNGRemainsChargedWithoutAuthorizingCleanup() throws {
        let owner = try owner()
        let original = try file(owner, bytes: 9)
        try owner.ownArtifact(original)
        let parked = original.appendingPathExtension("old")
        try FileManager.default.moveItem(at: original, to: parked)
        try Data("different".utf8).write(to: original)
        owner.discardArtifact(original)
        XCTAssertEqual(try Data(contentsOf: original), Data("different".utf8))
        XCTAssertEqual(owner.captureArtifactUsage, .init(fileCount: 1, totalBytes: 18))
        XCTAssertThrowsError(try owner.retainCaptureArtifact(original))

        let modified = try file(owner, bytes: 9)
        try owner.ownArtifact(modified)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: modified.path)
        owner.discardArtifact(modified)
        XCTAssertTrue(FileManager.default.fileExists(atPath: modified.path))
        XCTAssertEqual(owner.captureArtifactUsage, .init(fileCount: 2, totalBytes: 27))
        XCTAssertThrowsError(try owner.retainCaptureArtifact(modified))
        owner.revoke(); owner.retire()
    }

    func testHeldOriginalGrowthAndShrinkRefreshBytesAndEnforceAdmissionLimit() throws {
        let owner = try owner(bytes: 20)
        let a = try file(owner, bytes: 9)
        try owner.ownArtifact(a)
        var hold: CaptureArtifactHold? = try owner.retainCaptureArtifact(a)
        let writer = try FileHandle(forWritingTo: a)
        defer { try? writer.close() }
        try writer.truncate(atOffset: 21)
        XCTAssertEqual(owner.captureArtifactUsage, .init(fileCount: 1, totalBytes: 21))
        let b = try file(owner, bytes: 1)
        XCTAssertThrowsError(try owner.ownArtifact(b))
        XCTAssertThrowsError(try owner.retainCaptureArtifact(a), "Accounting must not validate changed pixels")
        try writer.truncate(atOffset: 4)
        XCTAssertEqual(owner.captureArtifactUsage.totalBytes, 4)
        try owner.ownArtifact(b)
        XCTAssertEqual(owner.captureArtifactUsage.totalBytes, 5)
        owner.discardArtifact(a)
        withExtendedLifetime(hold) {}; hold = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path), "Changed versions are never silently deleted")
        XCTAssertEqual(owner.captureArtifactUsage.totalBytes, 5)
        try FileManager.default.removeItem(at: a)
        XCTAssertEqual(owner.captureArtifactUsage, .init(fileCount: 1, totalBytes: 1))
        owner.revoke(); owner.retire()
    }

    func testHeldReplacementKeepsOriginalAndReplacementChargeUntilResolved() throws {
        let owner = try owner(bytes: 24)
        let a = try file(owner, bytes: 9)
        try owner.ownArtifact(a)
        var hold: CaptureArtifactHold? = try owner.retainCaptureArtifact(a)
        let parked = a.appendingPathExtension("old")
        try FileManager.default.moveItem(at: a, to: parked)
        try Data(repeating: 1, count: 14).write(to: a)
        for _ in 0..<3 { XCTAssertEqual(owner.captureArtifactUsage.totalBytes, 23) }
        let b = try file(owner, bytes: 2)
        XCTAssertThrowsError(try owner.ownArtifact(b))
        owner.discardArtifact(a)
        XCTAssertEqual(try Data(contentsOf: a).count, 14)
        try FileManager.default.removeItem(at: a)
        XCTAssertEqual(owner.captureArtifactUsage.totalBytes, 23, "A held original still exists after unlink")
        withExtendedLifetime(hold) {}; hold = nil
        XCTAssertEqual(owner.captureArtifactUsage, .init(fileCount: 0, totalBytes: 0))
        try owner.ownArtifact(b)
        owner.revoke(); owner.retire()
    }

    func testRestoredOriginalVersionResolvesAReplacementWithoutDeletingIt() throws {
        let owner = try owner()
        let a = try file(owner, bytes: 9)
        try owner.ownArtifact(a)
        let parked = a.appendingPathExtension("old")
        try FileManager.default.moveItem(at: a, to: parked)
        try Data(repeating: 1, count: 14).write(to: a)
        owner.discardArtifact(a)
        XCTAssertEqual(owner.captureArtifactUsage.totalBytes, 23)
        XCTAssertEqual(try Data(contentsOf: a).count, 14)
        try FileManager.default.removeItem(at: a)
        try FileManager.default.moveItem(at: parked, to: a)
        XCTAssertEqual(owner.captureArtifactUsage, .init(fileCount: 0, totalBytes: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        owner.revoke(); owner.retire()
    }

    func testUnreadableMetadataRetainsChargeUntilInspectionCanResolveIt() throws {
        if geteuid() == 0 { throw XCTSkip("Root bypasses directory search permissions") }
        let owner = try owner()
        let a = try file(owner, bytes: 9)
        try owner.ownArtifact(a)
        let directory = a.deletingLastPathComponent()
        let writer = try FileHandle(forWritingTo: a)
        try writer.truncate(atOffset: 13); try writer.close()
        XCTAssertEqual(owner.captureArtifactUsage.totalBytes, 13)
        XCTAssertEqual(chmod(directory.path, 0), 0)
        defer { _ = chmod(directory.path, 0o700) }
        owner.discardArtifact(a)
        XCTAssertEqual(owner.captureArtifactUsage, .init(fileCount: 1, totalBytes: 13))
        XCTAssertEqual(chmod(directory.path, 0o700), 0)
        XCTAssertEqual(owner.captureArtifactUsage.totalBytes, 13)
        try FileManager.default.removeItem(at: a)
        XCTAssertEqual(owner.captureArtifactUsage.totalBytes, 0)
        owner.revoke(); owner.retire()
    }

    func testUnlinkedHeldObjectRetainsItsChargeUntilLastHoldEnds() throws {
        let owner = try owner()
        let a = try file(owner, bytes: 9)
        try owner.ownArtifact(a)
        var hold: CaptureArtifactHold? = try owner.retainCaptureArtifact(a)
        try FileManager.default.removeItem(at: a)
        XCTAssertEqual(owner.captureArtifactUsage.totalBytes, 9)
        withExtendedLifetime(hold) {}; hold = nil
        XCTAssertEqual(owner.captureArtifactUsage.totalBytes, 0)
        owner.revoke(); owner.retire()
    }

    func testAccountingAdditionSaturatesInsteadOfOverflowing() {
        XCTAssertEqual(TaskLease.CaptureArtifactUsage.addingBytes(.max - 2, 3), .max)
        XCTAssertEqual(TaskLease.CaptureArtifactUsage.addingBytes(.max, 0), .max)
        XCTAssertEqual(TaskLease.CaptureArtifactUsage.addingBytes(9, 14), 23)
    }

    func testPartialCaptureDiscardUsesTheDirectoryPinnedBeforeEncoding() throws {
        let owner = try owner()
        var encoding: CaptureArtifactHold? = try owner.beginCaptureEncoding()
        let partial = try file(owner, bytes: 3, name: "partial")
        let scratch = try owner.scratchDirectory()
        let parked = scratch.deletingLastPathComponent().appendingPathComponent("partial-\(UUID())")
        try FileManager.default.moveItem(at: partial.deletingLastPathComponent(), to: parked)
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: false)
        try Data("replacement".utf8).write(to: partial)
        owner.discardArtifact(partial)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parked.appendingPathComponent(partial.lastPathComponent).path))
        XCTAssertEqual(try Data(contentsOf: partial), Data("replacement".utf8))
        owner.revoke(); owner.retire()
        withExtendedLifetime(encoding) {}; encoding = nil
        XCTAssertEqual(try Data(contentsOf: partial), Data("replacement".utf8))
    }
}
