import Darwin
import Foundation
import XCTest
@testable import OrbitAgent

final class PrivateVolumeCapabilitiesTests: XCTestCase {
    private let supported = PrivateVolumeCapabilities.Profile(atomicRename: true, directorySync: true)
    private func key(_ device: Int32 = 1, flags: UInt32 = 0) -> PrivateVolumeCapabilities.Identity {
        .init(device: device, filesystemFirst: 2, filesystemSecond: 3, mountFlags: flags)
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testCacheReusesVolumeAcrossDirectoriesButNotIdentityChanges() throws {
        let cache = PrivateVolumeCapabilities.Cache()
        var probes = 0
        func probe() -> PrivateVolumeCapabilities.Profile { probes += 1; return supported }
        for _ in 0..<100 { _ = try cache.profile(for: key(), probe: probe) }
        XCTAssertEqual(probes, 1)
        _ = try cache.profile(for: key(2), probe: probe)
        _ = try cache.profile(for: key(flags: 1), probe: probe)
        XCTAssertEqual(probes, 3)
        let root = try fixture(), other = try fixture()
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        let otherFD = open(other.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { close(fd); close(otherFD) }
        XCTAssertEqual(try PrivateVolumeCapabilities.identity(fd), try PrivateVolumeCapabilities.identity(otherFD))
    }
    func testCacheIsBoundedCoalescesConcurrentProbesAndRetriesTransientErrors() throws {
        let cache = PrivateVolumeCapabilities.Cache(capacity: 2)
        XCTAssertThrowsError(try cache.profile(for: key()) { throw PrivateVolumeCapabilities.Failure.unavailable })
        var probes = 0
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            _ = try! cache.profile(for: key()) { probes += 1; return supported }
        }
        XCTAssertEqual(probes, 1)
        for device: Int32 in [2, 3, 1] {
            _ = try cache.profile(for: key(device)) { probes += 1; return supported }
        }
        XCTAssertEqual(probes, 4)
    }
    func testUnsupportedProfilesRemainUnsupportedAndProduceSpecificErrors() throws {
        for profile in [PrivateVolumeCapabilities.Profile(atomicRename: false, directorySync: false),
                        .init(atomicRename: true, directorySync: false)] {
            let cache = PrivateVolumeCapabilities.Cache()
            _ = try cache.profile(for: key()) { profile }
            let reused = try cache.profile(for: key()) { XCTFail("Must not reprobe"); return supported }
            XCTAssertThrowsError(try reused.require()) {
                XCTAssertEqual($0 as? PrivateVolumeCapabilities.Failure, profile.atomicRename ? .directorySync : .atomicRename)
            }
        }
    }
    func testRealProbeAndWarmChecksLeaveNoArtifactsOrUserOutputChanges() throws {
        let root = try fixture(), cache = PrivateVolumeCapabilities.Cache()
        let output = root.appendingPathComponent("keep.txt")
        try Data("user output".utf8).write(to: output)
        for _ in 0..<5 { try PrivateVolumeCapabilities.require(root, cache: cache) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["keep.txt"])
        XCTAssertEqual(try String(contentsOf: output), "user output")
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        XCTAssertThrowsError(try PrivateVolumeCapabilities.require(root, cache: cache)) {
            XCTAssertEqual($0 as? PrivateDirectoryPermissions.Failure, .permissions)
        }
    }
    func testFailedRenameAndSyncCleanProbeAndDistinguishUnsupportedFromIOErrors() throws {
        let root = try fixture(), fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { close(fd) }
        let noRename = try PrivateVolumeCapabilities.probe(fd, rename: { _, _, _, _ in errno = ENOTSUP; return -1 })
        XCTAssertEqual(noRename, .init(atomicRename: false, directorySync: false))
        let noSync = try PrivateVolumeCapabilities.probe(fd, sync: { _ in errno = EINVAL; return -1 })
        XCTAssertEqual(noSync, .init(atomicRename: true, directorySync: false))
        XCTAssertThrowsError(try PrivateVolumeCapabilities.probe(fd, rename: { _, _, _, _ in errno = EIO; return -1 }))
        XCTAssertThrowsError(try PrivateVolumeCapabilities.probe(fd, sync: { _ in errno = ENOSPC; return -1 }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    func testCachedStorageFailureIsClassifiedBeforePrivateWrites() throws {
        let root = try fixture(), fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { close(fd) }
        let cache = PrivateVolumeCapabilities.Cache()
        _ = try cache.profile(for: PrivateVolumeCapabilities.identity(fd)) { .init(atomicRename: true, directorySync: false) }
        XCTAssertThrowsError(try PrivateVolumeCapabilities.require(root, cache: cache)) {
            XCTAssertEqual($0 as? PrivateVolumeCapabilities.Failure, .directorySync)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        for cause in ["private_directory_volume_unavailable", "private_directory_volume_atomic_rename", "private_directory_volume_directory_sync"] {
            XCTAssertEqual(ManagedGatewayHost.directoryAttentionCause(["causes": [cause]]), cause)
            let detail = ManagedGatewayHost.provisioningResourceDetail("{\"kind\":\"error\",\"error_code\":\"\(cause)\",\"message\":\"private payload\"}")
            XCTAssertTrue(detail?.contains("storage volume") == true)
            XCTAssertFalse(detail?.contains("private payload") == true)
        }
    }
}
