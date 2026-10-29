import CryptoKit
import Darwin
import XCTest
@testable import OrbitAgent

final class BoundFileOperationTests: XCTestCase {
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bound-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func put(_ text: String, _ file: URL) throws { try Data(text.utf8).write(to: file) }
    func contents(_ file: URL) throws -> String { try String(contentsOf: file, encoding: .utf8) }
    func expectConflict(delivered: Bool, _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation()) {
            XCTAssertEqual(($0 as? BoundFileOperation.Conflict)?.delivered, delivered, "\($0)")
        }
    }
    func testCreateOverwriteAppendReadAndChecksReferToCommittedObject() throws {
        let file = try root().appendingPathComponent("result")
        let first = try BoundFileOperation(file).replace(with: Data("A".utf8), append: false, mustBeAbsent: true)
        XCTAssertEqual(first.0, 1)
        let read = try BoundFileOperation(file).read(limit: 10)
        XCTAssertEqual(read.fields["file_identity"] as? String, first.1["file_identity"] as? String)
        let second = try BoundFileOperation(file).replace(with: Data("B".utf8), append: true, mustBeAbsent: false)
        XCTAssertEqual(second.0, 2)
        XCTAssertEqual(try contents(file), "AB")
        let digest = SHA256.hash(data: Data("AB".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(second.1["file_sha256"] as? String, digest)
        XCTAssertNotEqual(first.1["file_identity"] as? String, second.1["file_identity"] as? String)
        let check = try BoundFileOperation(file).inspect(kind: "file_contents", expected: Data("AB".utf8))
        XCTAssertTrue(check.0)
        XCTAssertEqual(second.1["file_identity"] as? String, check.1["file_identity"] as? String)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["result"])
    }
    func testCommittedDigestProofIsReusedWithoutReadingAndHashingAgain() throws {
        let file = try root().appendingPathComponent("result")
        var boundaries: [BoundFileOperation.Boundary] = []
        let operation = try BoundFileOperation(file, hook: { boundaries.append($0) })
        let written = try operation.replace(with: Data("unchanged".utf8), append: false, mustBeAbsent: true)
        var proof = written.1
        proof["task_generation_id"] = "fixture-generation"
        proof["path"] = file.standardizedFileURL.path
        proof["file_size"] = written.0
        boundaries.removeAll()

        let lease = TaskLease(id: "fixture-generation")
        try TaskOwnership.$current.withValue(lease) {
            let reused = try XCTUnwrap(operation.reuseVerifiedDigest(kind: "file_contents",
                expected: Data("unchanged".utf8), generation: lease.id, proof: proof))
            XCTAssertEqual(reused["file_identity"] as? String, written.1["file_identity"] as? String)
            XCTAssertEqual(reused["file_sha256"] as? String, written.1["file_sha256"] as? String)
            XCTAssertEqual((reused["file_size"] as? NSNumber)?.intValue, written.0)
            XCTAssertTrue(boundaries.contains(.digestProofReused))
        }
    }

    func testDigestReusePropagatesTaskRevocationInsteadOfReportingAnUnknownCheck() throws {
        let file = try root().appendingPathComponent("result")
        let written = try BoundFileOperation(file).replace(with: Data("unchanged".utf8), append: false, mustBeAbsent: true)
        let lease = TaskLease(id: "revoked-digest-proof")
        var proof = written.1
        proof["task_generation_id"] = lease.id
        proof["path"] = file.standardizedFileURL.path
        proof["file_size"] = written.0
        let check = CommandExecutionPolicy.Check(type: "file_contents", path: file,
            expected: Data("unchanged".utf8), text: nil, fileDigestProof: proof,
            taskGenerationID: lease.id)

        try TaskOwnership.$current.withValue(lease) {
            lease.revoke()
            XCTAssertThrowsError(try check.evaluate(stdout: "", stdoutTruncated: false)) {
                XCTAssertTrue($0 is CancellationError)
            }
        }
    }

    func testReplacementAndSameSizeModificationRejectDigestProofAndInspectFreshState() throws {
        let file = try root().appendingPathComponent("result")
        let operation = try BoundFileOperation(file)
        let written = try operation.replace(with: Data("original".utf8), append: false, mustBeAbsent: true)
        let lease = TaskLease(id: "digest-proof-generation")
        var proof = written.1
        proof["task_generation_id"] = lease.id
        proof["path"] = file.standardizedFileURL.path
        proof["file_size"] = written.0

        try TaskOwnership.$current.withValue(lease) {
            try Data("original".utf8).write(to: file, options: .atomic)
            XCTAssertNil(try operation.reuseVerifiedDigest(kind: "file_contents",
                expected: Data("original".utf8), generation: lease.id, proof: proof))
            let replacement = try operation.inspect(kind: "file_contents", expected: Data("original".utf8))
            XCTAssertTrue(replacement.0)
            XCTAssertNotEqual(replacement.1["file_identity"] as? String, proof["file_identity"] as? String)

            let handle = try FileHandle(forWritingTo: file)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Data("modified".utf8))
            try handle.truncate(atOffset: UInt64("modified".utf8.count))
            try handle.synchronize()
            try handle.close()
            XCTAssertNil(try operation.reuseVerifiedDigest(kind: "file_contents",
                expected: Data("original".utf8), generation: lease.id, proof: proof))
            let changed = try operation.inspect(kind: "file_contents", expected: Data("original".utf8))
            XCTAssertFalse(changed.0)
            XCTAssertNotEqual(changed.1["file_version"] as? String, proof["file_version"] as? String)
        }
    }
    func testCapturesCompleteUTF8VersionsDuringTheDescriptorBoundWritePass() throws {
        let file = try root().appendingPathComponent("change.txt")
        let created = try BoundFileOperation(file).replaceCapturingText(with: Data("first\n".utf8),
            append: false, mustBeAbsent: true)
        XCTAssertEqual(created.0, 6)
        XCTAssertEqual(created.2?.beforeData, nil)
        XCTAssertEqual(created.2?.afterData, Data("first\n".utf8))
        XCTAssertEqual(created.2?.fileVersion, created.1["file_version"] as? String)
        XCTAssertTrue(created.2?.created == true)

        let appended = try BoundFileOperation(file).replaceCapturingText(with: Data("second\n".utf8),
            append: true, mustBeAbsent: false)
        XCTAssertEqual(appended.2?.beforeData, Data("first\n".utf8))
        XCTAssertEqual(appended.2?.afterData, Data("first\nsecond\n".utf8))
        XCTAssertNotNil(appended.2?.beforeVersion)
        XCTAssertFalse(appended.2?.created ?? true)
        XCTAssertEqual(try contents(file), "first\nsecond\n")
    }
    func testBinaryAndOversizedFilesDoNotProducePartialTextSnapshots() throws {
        let binary = try root().appendingPathComponent("binary.dat")
        let binaryResult = try BoundFileOperation(binary).replaceCapturingText(with: Data([0xff, 0x00, 0x01]),
            append: false, mustBeAbsent: true)
        XCTAssertNil(binaryResult.2)

        let oversized = try root().appendingPathComponent("large.txt")
        let large = Data(repeating: 0x61, count: 128 * 1024 + 1)
        let largeResult = try BoundFileOperation(oversized).replaceCapturingText(with: large,
            append: false, mustBeAbsent: true)
        XCTAssertNil(largeResult.2)
    }
    func testUnverifiedPostCommitMutationCannotProduceTextSnapshot() throws {
        let file = try root().appendingPathComponent("report.txt")
        try put("before", file)
        let operation = try BoundFileOperation(file, hook: {
            if $0 == .committed { try self.put("external", file) }
        })
        XCTAssertThrowsError(try operation.replaceCapturingText(with: Data("after".utf8),
            append: false, mustBeAbsent: false))
        XCTAssertEqual(try contents(file), "external")
    }
    func testAbsentPreconditionRejectsExistingAndLateContender() throws {
        let file = try root().appendingPathComponent("result")
        try put("existing", file)
        expectConflict(delivered: false) { _ = try BoundFileOperation(file).replace(with: Data(), append: false, mustBeAbsent: true) }
        try FileManager.default.removeItem(at: file)
        let operation = try BoundFileOperation(file, hook: { if $0 == .delivering { try self.put("contender", file) } })
        expectConflict(delivered: false) { _ = try operation.replace(with: Data("new".utf8), append: false, mustBeAbsent: true) }
        XCTAssertEqual(try contents(file), "contender")
    }
    func testLeafReplacementAndInPlaceEditBeforeCommitConflict() throws {
        for replace in [false, true] {
            let file = try root().appendingPathComponent("result")
            try put("old", file)
            let operation = try BoundFileOperation(file, hook: {
                if $0 == .beforeCommit {
                    if replace { try FileManager.default.removeItem(at: file) }
                    try self.put("concurrent", file)
                }
            })
            expectConflict(delivered: false) { _ = try operation.replace(with: Data("new".utf8), append: false, mustBeAbsent: false) }
            XCTAssertEqual(try contents(file), "concurrent")
        }
    }
    func testParentReplacementCannotRedirectWrite() throws {
        let root = try root(), directory = root.appendingPathComponent("parent"), moved = root.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("result")
        try put("old", file)
        let operation = try BoundFileOperation(file, hook: {
            if $0 == .beforeCommit {
                try FileManager.default.moveItem(at: directory, to: moved)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                try self.put("other", file)
            }
        })
        expectConflict(delivered: false) { _ = try operation.replace(with: Data("new".utf8), append: false, mustBeAbsent: false) }
        XCTAssertEqual(try contents(file), "other")
        XCTAssertEqual(try contents(moved.appendingPathComponent("result")), "old")
    }
    func testSymlinkSwapCannotWriteThroughLink() throws {
        let root = try root(), file = root.appendingPathComponent("result"), other = root.appendingPathComponent("other")
        try put("old", file); try put("protected", other)
        let operation = try BoundFileOperation(file, hook: {
            if $0 == .beforeCommit {
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
            }
        })
        expectConflict(delivered: false) { _ = try operation.replace(with: Data("new".utf8), append: false, mustBeAbsent: false) }
        XCTAssertEqual(try contents(other), "protected")
    }
    func testSwapRacePreservesDisplacedConcurrentDataAndNeverVerifies() throws {
        let root = try root(), file = root.appendingPathComponent("result")
        try put("old", file)
        let operation = try BoundFileOperation(file, hook: {
            if $0 == .delivering { try Data("concurrent".utf8).write(to: file, options: .atomic) }
        })
        expectConflict(delivered: true) { _ = try operation.replace(with: Data("new".utf8), append: false, mustBeAbsent: false) }
        let retained = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".taskpilot-stage-") }
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(try contents(retained[0]), "concurrent")
    }
    func testPostCommitReplacementDoesNotVerifyUnrelatedReadablePath() throws {
        let file = try root().appendingPathComponent("result")
        let operation = try BoundFileOperation(file, hook: {
            if $0 == .committed { try Data("new".utf8).write(to: file, options: .atomic) }
        })
        expectConflict(delivered: true) { _ = try operation.replace(with: Data("new".utf8), append: false, mustBeAbsent: true) }
    }
    func testReadAndOutcomeCheckRejectConcurrentChanges() throws {
        for kind in ["read", "file_exists", "file_contents"] {
            let file = try root().appendingPathComponent("result")
            try put("same", file)
            let operation = try BoundFileOperation(file, hook: {
                if $0 == .inspected { try Data("same".utf8).write(to: file, options: .atomic) }
            })
            expectConflict(delivered: false) {
                if kind == "read" { _ = try operation.read(limit: 10) }
                else { _ = try operation.inspect(kind: kind, expected: Data("same".utf8)) }
            }
        }
    }
    func testBatchInspectionSharesOneDescriptorSnapshotForRepeatedTargetChecks() throws {
        let file = try root().appendingPathComponent("result")
        try put("same", file)
        var boundaries: [BoundFileOperation.Boundary] = []
        let operation = try BoundFileOperation(file, hook: { boundaries.append($0) })
        let snapshots = try operation.inspectBatch([
            .init(kind: "file_exists", expected: nil),
            .init(kind: "file_contents", expected: Data("same".utf8)),
            .init(kind: "file_contents", expected: Data("other".utf8)),
            .init(kind: "path_absent", expected: nil)
        ])

        XCTAssertEqual(snapshots.map(\.matches), [true, true, false, false])
        XCTAssertEqual(boundaries.filter { $0 == .bound }.count, 1,
                       "All checks for one target should use one opened descriptor")
        XCTAssertEqual(boundaries.filter { $0 == .inspected }.count, 1,
                       "The shared snapshot should be validated once")
        let identity = try XCTUnwrap(snapshots[0].fields["file_identity"] as? String)
        let version = try XCTUnwrap(snapshots[0].fields["file_version"] as? String)
        XCTAssertEqual(snapshots[1].fields["file_identity"] as? String, identity)
        XCTAssertEqual(snapshots[2].fields["file_identity"] as? String, identity)
        XCTAssertEqual(snapshots[1].fields["file_version"] as? String, version)
        XCTAssertEqual(snapshots[2].fields["file_version"] as? String, version)
    }

    func testASeparateInspectionObservesReplacementIdentity() throws {
        let file = try root().appendingPathComponent("result")
        try put("before", file)
        let operation = try BoundFileOperation(file)
        let first = try operation.inspectBatch([.init(kind: "file_exists", expected: nil)]).first!
        try Data("after".utf8).write(to: file, options: .atomic)
        let second = try operation.inspectBatch([.init(kind: "file_exists", expected: nil)]).first!

        XCTAssertTrue(first.matches)
        XCTAssertTrue(second.matches)
        XCTAssertNotEqual(first.fields["file_identity"] as? String, second.fields["file_identity"] as? String)
        XCTAssertNotEqual(first.fields["file_version"] as? String, second.fields["file_version"] as? String)
    }

    func testDirectoryTypeAndExistenceChecksShareOneDescriptor() throws {
        let directory = try root().appendingPathComponent("Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var boundaries: [BoundFileOperation.Boundary] = []
        let operation = try BoundFileOperation(directory, hook: { boundaries.append($0) })
        let snapshots = try operation.inspectBatch([
            .init(kind: "directory_exists", expected: nil),
            .init(kind: "file_exists", expected: nil),
            .init(kind: "file_contents", expected: Data("unexpected".utf8)),
            .init(kind: "path_absent", expected: nil)
        ])
        XCTAssertEqual(snapshots.map(\.matches), [true, false, false, false])
        XCTAssertEqual(boundaries.filter { $0 == .bound }.count, 1)
        XCTAssertEqual(boundaries.filter { $0 == .inspected }.count, 1)
        XCTAssertNotNil(snapshots[0].fields["file_identity"])
    }

    func testCommandCheckBatchPreservesPerCheckResultsFromOneTargetSnapshot() throws {
        let file = try root().appendingPathComponent("result")
        try put("same", file)
        let checks = [
            CommandExecutionPolicy.Check(type: "file_exists", path: file, expected: nil, text: nil),
            CommandExecutionPolicy.Check(type: "file_contents", path: file, expected: Data("same".utf8), text: nil),
            CommandExecutionPolicy.Check(type: "file_contents", path: file, expected: Data("wrong".utf8), text: nil)
        ]
        let result = try CommandExecutionPolicy.Check.evaluateBatch(checks, stdout: "", stdoutTruncated: false)
        XCTAssertEqual(result.map { $0["verified"] as? Bool }, [true, true, false])
        XCTAssertEqual(result[0]["file_identity"] as? String, result[1]["file_identity"] as? String)
        XCTAssertEqual(result[1]["file_identity"] as? String, result[2]["file_identity"] as? String)
        XCTAssertEqual(result[1]["content_sha256"] as? String,
                       SHA256.hash(data: Data("same".utf8)).map { String(format: "%02x", $0) }.joined())
        XCTAssertNil(result[2]["content_sha256"])
    }
    func testCancellationBeforeCommitDeletesStageWithoutChangingDestination() throws {
        let file = try root().appendingPathComponent("result")
        try put("old", file)
        let operation = try BoundFileOperation(file, hook: { if $0 == .beforeCommit { throw CancellationError() } })
        XCTAssertThrowsError(try operation.replace(with: Data("new".utf8), append: false, mustBeAbsent: false)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try contents(file), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["result"])
    }
    func testPreservesPermissionsAndCreatesBoundParents() throws {
        let file = try root().appendingPathComponent("a/b/result")
        _ = try BoundFileOperation(file, createParents: true).replace(with: Data(), append: false, mustBeAbsent: true)
        XCTAssertEqual(chmod(file.path, 0o640), 0)
        _ = try BoundFileOperation(file).replace(with: Data("new".utf8), append: false, mustBeAbsent: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
    }
    func testReplacedStagingEntryIsRejectedAndNeverDeletedAsCleanup() throws {
        let root = try root(), file = root.appendingPathComponent("result")
        try put("old", file)
        var foreign: URL?
        let operation = try BoundFileOperation(file, hook: {
            if $0 == .staged {
                let stage = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasPrefix(".taskpilot-stage-") }!
                try Data("foreign".utf8).write(to: stage, options: .atomic)
                foreign = stage
            }
        })
        expectConflict(delivered: false) { _ = try operation.replace(with: Data("new".utf8), append: false, mustBeAbsent: false) }
        XCTAssertEqual(try contents(file), "old")
        XCTAssertEqual(try contents(XCTUnwrap(foreign)), "foreign")
    }
    func testRevocationDuringStagingCannotCommitAndRemovesTemporaryFile() throws {
        let file = try root().appendingPathComponent("result"), lease = TaskLease()
        try put("old", file)
        try TaskOwnership.$current.withValue(lease) {
            let operation = try BoundFileOperation(file, hook: { if $0 == .staged { lease.revoke() } })
            XCTAssertThrowsError(try operation.replace(with: Data("new".utf8), append: false, mustBeAbsent: false)) { XCTAssertTrue($0 is CancellationError) }
        }
        XCTAssertEqual(try contents(file), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["result"])
    }
    func testInPlaceChangeAfterCommitCannotAcquireVerification() throws {
        let file = try root().appendingPathComponent("result")
        let operation = try BoundFileOperation(file, hook: { if $0 == .committed { try self.put("different", file) } })
        expectConflict(delivered: true) { _ = try operation.replace(with: Data("new".utf8), append: false, mustBeAbsent: true) }
        XCTAssertEqual(try contents(file), "different")
    }
    func testPostDeliveryConflictReceiptRemainsUncertainAndCannotReplay() throws {
        let store = ActionReceiptStore(generation: UUID().uuidString), id = UUID().uuidString
        guard case .new(let token) = try store.begin(id: id, payload: ["type":"write_file", "path":"/fixture/a", "content":"A"]) else { return XCTFail() }
        token.fail(BoundFileOperation.Conflict(delivered: true, detail: "changed"), code: "file_conflict")
        XCTAssertEqual(token.receipt["state"] as? String, "unconfirmed")
        guard case .existing = try store.begin(id: id, payload: ["type":"write_file", "path":"/fixture/a", "content":"A"]) else { return XCTFail("Conflict authorized replay") }
    }
}
