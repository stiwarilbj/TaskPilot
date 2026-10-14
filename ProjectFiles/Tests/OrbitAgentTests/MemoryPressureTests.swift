import XCTest
@testable import OrbitAgent

final class MemoryPressureTests: XCTestCase {
    private final class Payload {}
    func testWarningAndCriticalReleaseCacheOwnershipButNormalDoesNot() {
        let monitor = MemoryPressureMonitor(listen: false)
        let cache = PressureSensitiveCache<Payload>(monitor: monitor)
        weak var released: Payload?
        do {
            let payload = Payload(); released = payload
            cache.store(payload, epoch: cache.snapshot().epoch)
        }
        monitor.receive(.normal)
        XCTAssertNotNil(released)
        monitor.receive(.warning)
        XCTAssertNil(released)
        cache.store(Payload(), epoch: cache.snapshot().epoch)
        monitor.receive(.critical)
        XCTAssertNil(cache.snapshot().value)
    }

    func testEvictionRejectsLateRefillAndAllowsFreshWork() {
        let monitor = MemoryPressureMonitor(listen: false)
        let cache = PressureSensitiveCache<String>(monitor: monitor)
        let before = cache.snapshot().epoch
        monitor.receive([.warning, .critical])
        cache.store("late capture", epoch: before)
        XCTAssertNil(cache.snapshot().value)
        cache.store("new capture", epoch: cache.snapshot().epoch)
        XCTAssertEqual(cache.snapshot().value, "new capture")
    }

    func testRegistrationsReleaseOwnersAndDisappearAtTeardown() {
        let monitor = MemoryPressureMonitor(listen: false)
        var calls = 0
        var registration: MemoryPressureMonitor.Registration? = monitor.register { calls += 1 }
        monitor.receive(.warning)
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(registration)
        registration = nil
        monitor.receive(.critical)
        XCTAssertEqual(calls, 1)
        weak var owner: PressureSensitiveCache<Payload>?
        do { let cache = PressureSensitiveCache<Payload>(monitor: monitor); owner = cache }
        XCTAssertNil(owner)
        monitor.receive(.critical)
    }

    func testConcurrentPressureAndRecreationPreserveReceiptsAndArtifacts() throws {
        let monitor = MemoryPressureMonitor(listen: false)
        let cache = PressureSensitiveCache<Int>(monitor: monitor)
        let lease = TaskLease(), id = UUID().uuidString
        let payload: [String: Any] = ["action": ["type": "write_file", "path": "/fixture/a", "content": "A"]]
        if case .new(let token) = try lease.actionReceipts.begin(id: id, payload: payload) {
            try token.dispatched()
            token.complete(["outcome": "verified", "content_sha256": "fixture"])
        } else { XCTFail("Missing new receipt") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("accepted evidence".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try lease.ownArtifact(file)
        DispatchQueue.concurrentPerform(iterations: 1000) { index in
            if index.isMultiple(of: 3) { monitor.receive(.warning) }
            else { cache.store(index, epoch: cache.snapshot().epoch) }
        }
        monitor.receive(.critical)
        XCTAssertNil(cache.snapshot().value)
        XCTAssertEqual(lease.state, .running)
        XCTAssertEqual(lease.actionReceipts.lookup(id)["state"] as? String, "confirmed")
        if case .existing = try lease.actionReceipts.begin(id: id, payload: payload) {} else { XCTFail("Receipt was lost") }
        XCTAssertEqual(try String(contentsOf: file), "accepted evidence")
        lease.revoke(); lease.retire()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
