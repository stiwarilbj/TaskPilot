import Darwin
import Foundation
import XCTest
@testable import OrbitAgent

final class FileInputAvailabilityTests: XCTestCase {
    private func file(_ name: String = "input.txt", contents: Data = Data("local bytes".utf8)) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("availability-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    private func assertUnavailable(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard let error = error as? TaskToolError else { return XCTFail("\(error)", file: file, line: line) }
            XCTAssertEqual(error.code, "file_contents_not_local", file: file, line: line)
            XCTAssertTrue(error.localizedDescription.contains("not available locally yet"), file: file, line: line)
        }
    }

    func testDatalessFlagsAndExplicitCloudStatusAreAuthoritative() throws {
        assertUnavailable { try FileInputAvailability.requireLocal(flags: UInt32(SF_DATALESS)) }
        assertUnavailable { try FileInputAvailability.requireLocal(flags: UInt32(SF_DATALESS), downloadStatus: .current) }
        assertUnavailable { try FileInputAvailability.requireLocal(flags: 0, downloadStatus: .notDownloaded) }
        for status in [nil, URLUbiquitousItemDownloadingStatus.current, .downloaded] {
            XCTAssertNoThrow(try FileInputAvailability.requireLocal(flags: UInt32(UF_HIDDEN), downloadStatus: status))
        }
    }

    func testPlaceholdersFailBeforeReadingParsingOrStaging() throws {
        let url = try file("report.pdf") // Intentionally invalid PDF must not be diagnosed as corrupt first.
        var boundaries: [BoundFileOperation.Boundary] = []
        let operation = try BoundFileOperation(url, downloadStatus: { _ in .notDownloaded }, hook: { boundaries.append($0) })
        assertUnavailable { _ = try operation.read(limit: 100) }
        assertUnavailable { _ = try operation.inspect(kind: "file_exists", expected: nil) }
        assertUnavailable { _ = try operation.replace(with: Data("new".utf8), append: true, mustBeAbsent: false) }
        assertUnavailable { _ = try operation.replace(with: Data("new".utf8), append: false, mustBeAbsent: false) }
        XCTAssertTrue(boundaries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), Data("local bytes".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["report.pdf"])
    }

    func testFreshInspectionSucceedsAfterProviderReportsLocalContents() throws {
        let url = try file()
        var status = URLUbiquitousItemDownloadingStatus.notDownloaded
        let operation = try BoundFileOperation(url, downloadStatus: { _ in status })
        assertUnavailable { _ = try operation.read(limit: 100) }
        status = .downloaded // A locally available older cloud version remains readable.
        XCTAssertEqual(try operation.read(limit: 100).data, Data("local bytes".utf8))
        status = .current
        XCTAssertEqual(try operation.read(limit: 100).data, Data("local bytes".utf8))
    }

    func testEmptySparseAndCloudNamedLocalFilesAreNotPlaceholders() throws {
        for name in ["empty.txt", ".report.icloud", "synced.txt"] {
            let url = try file(name, contents: Data())
            let operation = try BoundFileOperation(url, downloadStatus: { _ in nil })
            XCTAssertEqual(try operation.read(limit: 10).data, Data())
        }
        let sparse = try file("sparse.txt", contents: Data())
        let fd = open(sparse.path, O_WRONLY | O_CLOEXEC)
        guard fd >= 0 else { return XCTFail("Cannot create sparse fixture") }
        defer { close(fd) }
        XCTAssertEqual(ftruncate(fd, 4096), 0)
        XCTAssertEqual(try BoundFileOperation(sparse, downloadStatus: { _ in nil }).read(limit: 4).data, Data(count: 4))
    }

    func testUnsupportedMetadataPreservesLocalReadsAndReplacementRacesStayConflicts() throws {
        let url = try file()
        let operation = try BoundFileOperation(url, downloadStatus: { _ in throw CocoaError(.featureUnsupported) })
        XCTAssertEqual(try operation.read(limit: 100).data, Data("local bytes".utf8))
        let raced = try BoundFileOperation(url, downloadStatus: { path in
            try Data("replacement".utf8).write(to: path, options: .atomic)
            return .notDownloaded
        })
        XCTAssertThrowsError(try raced.read(limit: 100)) { error in
            XCTAssertTrue(error is BoundFileOperation.Conflict)
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("replacement".utf8))
    }

    func testNativeToolReturnsSpecificConditionAndOutcomeChecksRemainUnverified() async throws {
        let url = try file()
        let tools = TaskToolExecutor(fileDownloadStatus: { _ in .notDownloaded })
        do {
            _ = try await tools.perform(action: ["type": "read_file", "path": url.path])
            XCTFail("Placeholder returned readable evidence")
        } catch let error as TaskToolError {
            XCTAssertEqual(error.code, "file_contents_not_local")
            let failure = ActionContract.nativeFailure(error, code: error.code, outcome: "rejected")
            XCTAssertEqual(failure["verified"] as? Bool, false)
            XCTAssertEqual(failure["error_code"] as? String, "file_contents_not_local")
        }
        let checks = try await tools.checkOutcome(["type": "file_contents", "path": url.path, "content": "local bytes"])
        XCTAssertEqual(checks["verified"] as? Bool, false)
        let detail = try XCTUnwrap((checks["checks"] as? [[String: Any]])?.first)
        XCTAssertTrue((detail["reason"] as? String)?.contains("not available locally yet") == true)
        let missing = url.deletingLastPathComponent().appendingPathComponent("missing.txt")
        XCTAssertThrowsError(try BoundFileOperation(missing, downloadStatus: { _ in .notDownloaded }).read(limit: 1)) { error in
            XCTAssertTrue(error is BoundFileOperation.Conflict) // Absence isn't cloud metadata.
        }
    }
}
