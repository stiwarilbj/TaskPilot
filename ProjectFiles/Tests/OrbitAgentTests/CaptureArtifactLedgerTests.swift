import Foundation
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
}
