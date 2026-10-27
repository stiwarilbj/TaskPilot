import XCTest
import Darwin
@testable import OrbitAgent

final class BackendDescriptorsTests: XCTestCase {
    func testRawTicketsAreExactlyOnceAndOwnersRemainSeparate() {
        let registry = BackendDescriptors(), first = BackendDescriptors.Owner(), second = BackendDescriptors.Owner()
        let a = registry.opened(.subprocess, owner: first)
        let b = registry.opened(.capture, owner: second, retention: .retainedResource)
        XCTAssertEqual(registry.snapshot(owner: first).reduce(0) { $0 + $1.open }, 1)
        registry.transition(first, to: .draining)
        XCTAssertEqual(registry.snapshot(owner: first).first { $0.subsystem == .subprocess && $0.lifecycle == .draining }?.open, 1)
        XCTAssertEqual(registry.checkDrain(first).workRemaining, 1)
        XCTAssertEqual(registry.checkDrain(second).retainedResources, 1)
        registry.checkDrain(first)
        XCTAssertEqual(registry.drainStatistics.checks, 2)
        XCTAssertEqual(registry.drainStatistics.outstandingWork, 1)
        a.finish(); a.finish(); b.finish()
        XCTAssertTrue(registry.checkDrain(first).returnedToBaseline)
        XCTAssertTrue(registry.checkDrain(second).returnedToBaseline)
    }

    func testClosedAndDeallocatedHandlesAreReapedWithoutDoubleCountingBorrowers() throws {
        let registry = BackendDescriptors(), owner = BackendDescriptors.Owner()
        var pipe: Pipe? = Pipe()
        registry.track(pipe!.fileHandleForReading, subsystem: .subprocess, owner: owner)
        registry.track(pipe!.fileHandleForReading, subsystem: .runtimeReadPipe, owner: owner)
        registry.track(pipe!.fileHandleForWriting, subsystem: .runtimeWritePipe, owner: owner)
        XCTAssertEqual(registry.snapshot(owner: owner).reduce(0) { $0 + $1.open }, 2)
        try pipe!.fileHandleForReading.close()
        XCTAssertEqual(registry.snapshot(owner: owner).reduce(0) { $0 + $1.open }, 1)
        pipe = nil
        XCTAssertTrue(registry.checkDrain(owner).returnedToBaseline)
        XCTAssertEqual(registry.snapshot().count, BackendDescriptors.Subsystem.allCases.count * BackendDescriptors.Lifecycle.allCases.count)
    }

    func testClosedHandleCannotCountAReusedDescriptorAsItsOwn() throws {
        let registry = BackendDescriptors(), oldOwner = BackendDescriptors.Owner()
        let pipe = Pipe()
        registry.track(pipe.fileHandleForReading, subsystem: .runtimeReadPipe, owner: oldOwner)
        try pipe.fileHandleForReading.close()
        let replacement = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        defer { try? replacement.close(); try? pipe.fileHandleForWriting.close() }
        registry.track(replacement, subsystem: .subprocess, owner: nil)
        XCTAssertTrue(registry.checkDrain(oldOwner).returnedToBaseline)
        XCTAssertEqual(registry.snapshot().reduce(0) { $0 + $1.unowned }, 1)
    }

    func testRetiredOwnerDoesNotTransferResourcesToNewTask() throws {
        let registry = BackendDescriptors(), old = BackendDescriptors.Owner(), new = BackendDescriptors.Owner()
        let pipe = Pipe()
        registry.track(pipe.fileHandleForWriting, subsystem: .runtimeWritePipe, owner: old)
        registry.transition(old, to: .retired)
        registry.track(pipe.fileHandleForWriting, subsystem: .subprocess, owner: new)
        XCTAssertEqual(registry.snapshot(owner: old).first { $0.lifecycle == .retired && $0.subsystem == .runtimeWritePipe }?.open, 1)
        XCTAssertTrue(registry.checkDrain(new).returnedToBaseline)
        try pipe.fileHandleForReading.close(); try pipe.fileHandleForWriting.close()
        XCTAssertTrue(registry.checkDrain(old).returnedToBaseline)
    }

    func testConcurrentAccountingReturnsToBaseline() {
        let registry = BackendDescriptors(), owner = BackendDescriptors.Owner()
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            let ticket = registry.opened(.capture, owner: owner)
            _ = registry.snapshot(owner: owner)
            ticket.finish(); ticket.finish()
        }
        XCTAssertTrue(registry.checkDrain(owner).returnedToBaseline)
    }

    func testActualPipesAndWriterAreAccountedWithoutTakingClosureOwnership() throws {
        let lease = TaskLease()
        let pipe = try SubprocessSupervisor.makePrivatePipe(owner: lease.descriptorOwner)
        let queue = DispatchQueue(label: "descriptor-test")
        let writer = RuntimePipeWriter(handle: pipe.fileHandleForWriting, queue: queue,
                                       descriptorOwner: lease.descriptorOwner, failure: { _ in })
        XCTAssertEqual(BackendDescriptors.shared.snapshot(owner: lease.descriptorOwner).reduce(0) { $0 + $1.open }, 2)
        queue.sync { writer.cancel() }
        // Cancel stops writes, but the pipe's owner still owns its descriptor.
        XCTAssertEqual(BackendDescriptors.shared.snapshot(owner: lease.descriptorOwner).reduce(0) { $0 + $1.open }, 2)
        try pipe.fileHandleForReading.close(); try pipe.fileHandleForWriting.close()
        lease.revoke(); lease.retire()
        XCTAssertTrue(BackendDescriptors.shared.checkDrain(lease.descriptorOwner).returnedToBaseline)
    }

    func testFailedSpawnReleasesTheOwnedLaunchDescriptor() throws {
        let lease = TaskLease()
        let process = SubprocessSupervisor(descriptorOwner: lease.descriptorOwner)
        process.executableURL = URL(fileURLWithPath: "/taskpilot-fixture-nonexistent-executable")
        XCTAssertThrowsError(try process.run())
        lease.revoke(); lease.retire()
        XCTAssertTrue(BackendDescriptors.shared.checkDrain(lease.descriptorOwner).returnedToBaseline)
        // Repeated Stop after retirement must not regress diagnostic lifecycle.
        lease.revoke()
        XCTAssertEqual(lease.state, .retired)
    }

    func testCaptureDirectoryHoldsRemainVisibleAfterRetirementUntilReleased() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = BackendDescriptors.Owner()
        var lease: TaskTemporaryResourceLease? = try TaskTemporaryResourceLedger.makeLease(root: root, descriptorOwner: owner)
        var capture: TaskCaptureDirectory? = try lease!.captureDirectory()
        XCTAssertNotNil(capture)
        XCTAssertEqual(BackendDescriptors.shared.snapshot(owner: owner).reduce(0) { $0 + $1.open }, 3)
        lease!.removeDirectory(); lease = nil
        BackendDescriptors.shared.transition(owner, to: .retired)
        let held = BackendDescriptors.shared.checkDrain(owner)
        XCTAssertEqual(held.workRemaining, 0)
        XCTAssertEqual(held.retainedResources, 1)
        capture = nil
        XCTAssertTrue(BackendDescriptors.shared.checkDrain(owner).returnedToBaseline)
    }
}
