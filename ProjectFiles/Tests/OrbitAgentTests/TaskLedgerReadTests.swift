import Darwin
import Foundation
import XCTest
@testable import OrbitAgent

final class TaskLedgerReadTests: XCTestCase {
    private func fixtureFile() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("taskpilot-ledger-read-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent(AgentTaskLedgerStore.fileName)
    }

    func testMissingLedgerIsEmptyButLegacyRecordsStillDecodeWithBoundedShortReads() throws {
        let file = try fixtureFile(), store = AgentTaskLedgerStore(fileURL: file)
        XCTAssertEqual(try store.load { _, _ in XCTFail("Missing files cannot be read"); return Data() }, .init())
        let queuedID = UUID(), historyID = UUID()
        let legacy = Data("""
        {"history":[{"id":"\(historyID)","request":"Résumé 😀","responseTitle":"Complete",
        "response":"Kept","outcome":"completed","startedAt":1000250,"finishedAt":1001500,"wasQueued":true}],
        "queue":[{"id":"\(queuedID)","request":"Résumé 😀","queuedAt":1234125}]}
        """.utf8)
        try legacy.write(to: file)
        var allowances: [Int] = [], opened: Int32 = -1
        let snapshot = try store.load { fd, maximum in
            opened = fd
            allowances.append(maximum)
            return try PrivateRuntimeMetadata.readChunk(fd, min(3, maximum))
        }
        XCTAssertEqual(snapshot.queue.map(\.id), [queuedID])
        XCTAssertEqual(snapshot.queue.first?.queuedAt, Date(timeIntervalSince1970: 1234.125))
        XCTAssertEqual(snapshot.history.map(\.id), [historyID])
        XCTAssertEqual(snapshot.history.first?.request, "Résumé 😀")
        XCTAssertEqual(snapshot.history.first?.startedAt, Date(timeIntervalSince1970: 1000.25))
        XCTAssertNil(snapshot.activeTask)
        XCTAssertNil(snapshot.queue.first?.exactInputReferences)
        XCTAssertLessThanOrEqual(try XCTUnwrap(allowances.max()), 65_536)
        XCTAssertEqual(try Data(contentsOf: file), legacy)
        XCTAssertEqual(fcntl(opened, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testOversizedLedgerFailsBeforeReadingAndRemainsUntouched() throws {
        let file = try fixtureFile(), store = AgentTaskLedgerStore(fileURL: file)
        try Data("{\"queue\":[],\"history\":[]}".utf8).write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(AgentTaskLedgerStore.maximumFileBytes) + 1)
        try handle.close()
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertThrowsError(try store.load { _, _ in
            XCTFail("Oversized ledger must fail before allocating content buffers"); return Data()
        }) { XCTAssertEqual($0 as? PrivateRuntimeMetadata.Failure, .size) }
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(before[.size] as? NSNumber, after[.size] as? NSNumber)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
    }

    func testMalformedAndDuplicateFieldsPreserveTheOriginalLedger() throws {
        let file = try fixtureFile(), store = AgentTaskLedgerStore(fileURL: file)
        let duplicateFields = [
            #"{"queue":[],"history":[],"queue":[]}"#,
            #"{"queue":[],"history":[],"histo\u0072y":[]}"#,
            #"{"queue":[{"id":"same","id":"other"}],"history":[]}"#,
            #"{"queue":[],"history":[{"requestMetrics":{"planning":1,"planning":2}}]}"#,
        ]
        for text in duplicateFields + [
            #"{"queue":[],"history":"wrong type"}"#,
            #"{"queue":[],"history":[]"#,
            "[]", "", "null",
        ] {
            let original = Data(text.utf8)
            try original.write(to: file)
            XCTAssertThrowsError(try store.load(), text) {
                if duplicateFields.contains(text) {
                    XCTAssertEqual($0 as? RuntimeMessageJSON.Failure, .duplicateField)
                }
            }
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
        try Data(#"{"queue":[],"history":[]}"#.utf8).write(to: file)
        XCTAssertEqual(try store.load(), .init(), "A rejected load must not poison the next valid load.")
    }

    func testSymlinksHardLinksAndNonregularFilesFailBeforeReading() throws {
        let file = try fixtureFile(), store = AgentTaskLedgerStore(fileURL: file)
        let target = file.appendingPathExtension("original")
        let original = Data(#"{"queue":[],"history":[]}"#.utf8)
        try original.write(to: target)
        for kind in ["symlink", "dangling symlink", "hard link", "directory", "fifo"] {
            switch kind {
            case "symlink": try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            case "dangling symlink":
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target.appendingPathExtension("missing"))
            case "hard link": XCTAssertEqual(link(target.path, file.path), 0)
            case "directory": try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            default: XCTAssertEqual(mkfifo(file.path, 0o600), 0)
            }
            XCTAssertThrowsError(try store.load { _, _ in
                XCTFail("Rejected \(kind) must not be read"); return Data()
            }, kind)
            XCTAssertEqual(try Data(contentsOf: target), original)
            try FileManager.default.removeItem(at: file)
        }
    }

    func testGrowthReplacementAndTruncationDuringReadRejectTheSnapshotAndCloseTheDescriptor() throws {
        let file = try fixtureFile(), store = AgentTaskLedgerStore(fileURL: file)
        let original = Data(#"{"queue":[],"history":[]}"#.utf8)
        let replacement = Data(#"{"queue":[],"history":[],"activeTask":null}"#.utf8)
        for change in ["growth", "replacement", "truncation", "removal"] {
            try original.write(to: file)
            var changed = false, opened: Int32 = -1, bytesRead = 0
            XCTAssertThrowsError(try store.load { fd, maximum in
                opened = fd
                let data = try PrivateRuntimeMetadata.readChunk(fd, min(3, maximum))
                bytesRead += data.count
                if !changed {
                    changed = true
                    if change == "removal" {
                        try FileManager.default.removeItem(at: file)
                    } else {
                        let next = change == "truncation" ? Data("{}".utf8) : replacement
                        try next.write(to: file, options: change == "replacement" ? .atomic : [])
                    }
                }
                return data
            }, change) { XCTAssertEqual($0 as? PrivateRuntimeMetadata.Failure, .changed) }
            XCTAssertLessThanOrEqual(bytesRead, AgentTaskLedgerStore.maximumFileBytes)
            XCTAssertNotEqual(opened, -1)
            XCTAssertEqual(fcntl(opened, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
            if change != "removal" {
                XCTAssertEqual(try Data(contentsOf: file), change == "truncation" ? Data("{}".utf8) : replacement)
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            }
        }
    }
}
