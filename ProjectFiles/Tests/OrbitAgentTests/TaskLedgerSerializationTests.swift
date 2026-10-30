import Foundation
import XCTest
@testable import OrbitAgent

final class TaskLedgerSerializationTests: XCTestCase {
    private enum PersistenceFailure: Error { case injected, waitExpired }
    private enum Stage: CaseIterable { case replacement, permissions }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var errors: [Error] = []
        private var snapshots: [AgentTaskLedgerSnapshot] = []
        func record(_ error: Error) { lock.lock(); defer { lock.unlock() }; errors.append(error) }
        func record(_ snapshot: AgentTaskLedgerSnapshot) { lock.lock(); defer { lock.unlock() }; snapshots.append(snapshot) }
        func check(snapshot: AgentTaskLedgerSnapshot? = nil, file: StaticString = #filePath, line: UInt = #line) {
            lock.lock(); defer { lock.unlock() }
            XCTAssertTrue(errors.isEmpty, "Unexpected persistence errors: \(errors)", file: file, line: line)
            if let snapshot { XCTAssertEqual(snapshots, [snapshot], file: file, line: line) }
        }
    }

    func testOverlappingSavesCommitInAdmissionOrderThroughReplacementAndPermissions() throws {
        for stage in Stage.allCases {
            let file = try fixtureFile()
            let older = snapshot("older"), newer = snapshot("newer")
            let olderBlocked = DispatchSemaphore(value: 0), releaseOlder = DispatchSemaphore(value: 0)
            let newerInvoked = DispatchSemaphore(value: 0), newerReplacing = DispatchSemaphore(value: 0)
            let olderReturned = DispatchSemaphore(value: 0), finished = DispatchGroup(), results = Results()
            let store = AgentTaskLedgerStore(fileURL: file) { data, url in
                let isOlder = try Self.decode(data) == older
                func blockOlder(at current: Stage) throws {
                    if isOlder && stage == current {
                        olderBlocked.signal()
                        guard releaseOlder.wait(timeout: .now() + 5) == .success else { throw PersistenceFailure.waitExpired }
                    }
                }
                try blockOlder(at: .replacement)
                if !isOlder { newerReplacing.signal() }
                try PrivateDurableFile.replace(data, at: url)
                try blockOlder(at: .permissions)
                try Self.finalizePermissions(url)
            }
            let copy = store
            defer { releaseOlder.signal() }
            finished.enter()
            DispatchQueue(label: "fixture.ledger.older").async {
                defer { olderReturned.signal(); finished.leave() }
                do { try store.save(queue: older.queue, history: older.history, activeTask: older.activeTask) }
                catch { results.record(error) }
            }
            XCTAssertEqual(olderBlocked.wait(timeout: .now() + 2), .success)
            finished.enter()
            DispatchQueue(label: "fixture.ledger.newer").async {
                defer { finished.leave() }
                newerInvoked.signal()
                do { try copy.save(queue: newer.queue, history: newer.history, activeTask: newer.activeTask) }
                catch { results.record(error) }
            }
            XCTAssertEqual(newerInvoked.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(newerReplacing.wait(timeout: .now() + 0.1), .timedOut,
                           "A newer snapshot cannot start replacing while the older save is unfinished.")
            XCTAssertEqual(olderReturned.wait(timeout: .now()), .timedOut,
                           "Save cannot report success before finalization finishes.")
            releaseOlder.signal()
            XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
            results.check()
            XCTAssertEqual(try store.load(), newer)
            XCTAssertEqual(try Self.decode(Data(contentsOf: file)), newer)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        }
    }

    func testLoadWaitsForCompletedReplacementAndPermissionFinalization() throws {
        let file = try fixtureFile(), expected = snapshot("committed")
        let finalizing = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let readerInvoked = DispatchSemaphore(value: 0), readerReturned = DispatchSemaphore(value: 0)
        let finished = DispatchGroup(), results = Results()
        let store = AgentTaskLedgerStore(fileURL: file) { data, url in
            try PrivateDurableFile.replace(data, at: url)
            finalizing.signal()
            guard release.wait(timeout: .now() + 5) == .success else { throw PersistenceFailure.waitExpired }
            try Self.finalizePermissions(url)
        }
        defer { release.signal() }
        finished.enter()
        DispatchQueue(label: "fixture.ledger.writer").async {
            defer { finished.leave() }
            do { try store.save(queue: expected.queue, history: expected.history, activeTask: expected.activeTask) }
            catch { results.record(error) }
        }
        XCTAssertEqual(finalizing.wait(timeout: .now() + 2), .success)
        finished.enter()
        DispatchQueue(label: "fixture.ledger.reader").async {
            defer { readerReturned.signal(); finished.leave() }
            readerInvoked.signal()
            do { results.record(try store.load()) } catch { results.record(error) }
        }
        XCTAssertEqual(readerInvoked.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(readerReturned.wait(timeout: .now() + 0.1), .timedOut)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        results.check(snapshot: expected)
    }

    func testReplacementAndFinalizationFailuresPropagateAndReleaseTheQueue() throws {
        for stage in Stage.allCases {
            let file = try fixtureFile(), original = snapshot("original"), failed = snapshot("failed"), next = snapshot("next")
            let store = AgentTaskLedgerStore(fileURL: file) { data, url in
                let shouldFail = try Self.decode(data) == failed
                if shouldFail && stage == .replacement { throw PersistenceFailure.injected }
                try PrivateDurableFile.replace(data, at: url)
                if shouldFail && stage == .permissions { throw PersistenceFailure.injected }
                try Self.finalizePermissions(url)
            }
            try store.save(queue: original.queue, history: original.history, activeTask: original.activeTask)
            XCTAssertThrowsError(try store.save(queue: failed.queue, history: failed.history, activeTask: failed.activeTask)) {
                guard case PersistenceFailure.injected = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
            // A post-replacement failure is reported, without pretending the old
            // bytes were restored. Either failure must release the operation queue.
            XCTAssertEqual(try store.load(), stage == .replacement ? original : failed)
            try store.save(queue: next.queue, history: next.history, activeTask: next.activeTask)
            XCTAssertEqual(try store.load(), next)
        }
    }

    private func fixtureFile() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("taskpilot-ledger-order-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent(AgentTaskLedgerStore.fileName)
    }

    private func snapshot(_ name: String) -> AgentTaskLedgerSnapshot {
        .init(queue: [QueuedAgentTask(request: name, queuedAt: Date(timeIntervalSince1970: 1234))],
              history: [AgentTaskHistoryEntry(request: name, responseTitle: name, response: name,
                outcome: .completed, startedAt: Date(timeIntervalSince1970: 1000),
                finishedAt: Date(timeIntervalSince1970: 1001), wasQueued: true)],
              activeTask: AgentTaskAuthorization(request: name, startedAt: Date(timeIntervalSince1970: 1002), wasQueued: false))
    }

    private static func decode(_ data: Data) throws -> AgentTaskLedgerSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(AgentTaskLedgerSnapshot.self, from: data)
    }

    private static func finalizePermissions(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
