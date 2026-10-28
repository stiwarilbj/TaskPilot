import Darwin
import Foundation
import XCTest
@testable import OrbitAgent

final class PrivateRuntimeMetadataTests: XCTestCase {
    private func file() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("metadata.json")
    }
    func testSharedLimitsAndJSONAcceptance() throws {
        struct Fixture: Decodable {
            struct Case: Decodable { let name: String; let json: String; let valid: Bool }
            let limits: [String: Int]; let cases: [Case]
        }
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/private-runtime-metadata.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        XCTAssertEqual(fixture.limits, ["request": PrivateRuntimeMetadata.requestBytes, "record": PrivateRuntimeMetadata.recordBytes,
            "descriptor": PrivateRuntimeMetadata.descriptorBytes, "configuration": PrivateRuntimeMetadata.configurationBytes,
            "process_list": PrivateRuntimeMetadata.processListBytes, "integrity": PrivateRuntimeMetadata.integrityBytes])
        XCTAssertEqual(PrivateRuntimeMetadata.descriptorBytes, RuntimeDescriptorContract.maxBytes)
        let url = try file()
        for test in fixture.cases {
            try Data(test.json.utf8).write(to: url)
            if test.valid { XCTAssertNoThrow(try PrivateRuntimeMetadata.document(url), test.name) }
            else { XCTAssertThrowsError(try PrivateRuntimeMetadata.document(url), test.name) }
        }
        for data in [Data([0x7b, 0x22, 0xff, 0x22, 0x3a, 0x30, 0x7d]), "{}".data(using: .utf16)!,
                     Data((String(repeating: "[", count: 513) + "0" + String(repeating: "]", count: 513)).utf8)] {
            XCTAssertThrowsError(try PrivateRuntimeMetadata.parse(data))
        }
    }
    func testExactLimitsAndShortReads() throws {
        let url = try file(), data = Data(("{\"x\":1}" + String(repeating: " ", count: 25)).utf8)
        try data.write(to: url)
        var allowances: [Int] = []
        let result = try PrivateRuntimeMetadata.document(url, maximum: data.count) { fd, maximum in
            allowances.append(maximum)
            return try PrivateRuntimeMetadata.readChunk(fd, min(3, maximum))
        }
        XCTAssertEqual(result.data, data)
        XCTAssertLessThanOrEqual(allowances.max()!, data.count)
        XCTAssertThrowsError(try PrivateRuntimeMetadata.document(url, maximum: data.count - 1) { _, _ in
            XCTFail("Oversized metadata must fail before any content read"); return Data()
        })
    }
    func testNoFollowHardLinksDirectoriesAndFIFOs() throws {
        let url = try file(), original = url.appendingPathExtension("original")
        try Data("{}".utf8).write(to: original)
        XCTAssertThrowsError(try PrivateRuntimeMetadata.document(url))
        XCTAssertNil(try PrivateRuntimeMetadata.decodeIfPresent(ManagedProcessIdentity.self, from: url))
        for kind in ["symlink", "hardlink", "directory", "fifo"] {
            switch kind {
            case "symlink": try FileManager.default.createSymbolicLink(at: url, withDestinationURL: original)
            case "hardlink": XCTAssertEqual(link(original.path, url.path), 0)
            case "directory": try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            default: XCTAssertEqual(mkfifo(url.path, 0o600), 0)
            }
            XCTAssertThrowsError(try PrivateRuntimeMetadata.document(url) { _, _ in
                XCTFail("Rejected \(kind) must not be read"); return Data()
            }, kind)
            try FileManager.default.removeItem(at: url)
        }
    }
    func testChangedObjectsAreRejectedAndDescriptorsClosed() throws {
        let url = try file()
        for change in ["replace", "same-size", "grow", "overflow"] {
            try Data("{\"x\":1}".utf8).write(to: url)
            var changed = false, observedFD: Int32 = -1, returned = 0
            XCTAssertThrowsError(try PrivateRuntimeMetadata.document(url, maximum: 32) { fd, maximum in
                observedFD = fd
                let data = try PrivateRuntimeMetadata.readChunk(fd, maximum)
                returned += data.count
                if !changed {
                    changed = true
                    let replacement = change == "overflow" ? String(repeating: " ", count: 100) :
                        change == "grow" ? "{\"x\":1} " : "{\"x\":2}"
                    try Data(replacement.utf8).write(to: url, options: change == "replace" ? .atomic : [])
                }
                return data
            }, change)
            XCTAssertLessThanOrEqual(returned, 32)
            XCTAssertNotEqual(observedFD, -1)
            XCTAssertEqual(fcntl(observedFD, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
        }
    }
    func testInvalidBudgetAndDescriptorCannotAcquireDefaultMeaning() throws {
        let url = try file()
        for data in [Data("{\"circuits\":0,\"circuits\":3}".utf8), Data(repeating: 0x20, count: PrivateRuntimeMetadata.recordBytes + 1)] {
            try data.write(to: url)
            XCTAssertThrowsError(try PrivateRuntimeMetadata.decodeIfPresent(GatewayRecoveryBudget.self, from: url))
        }
        try Data(repeating: 0x20, count: PrivateRuntimeMetadata.descriptorBytes + 1).write(to: url)
        XCTAssertThrowsError(try ManagedOpenClawDescriptor.load(from: url))
        XCTAssertNil(ManagedGatewayHost.object("{\"ok\":true,\"ok\":false}"))
        XCTAssertNil(ManagedGatewayHost.object("{\"full_integrity_ok\":true,\"full_integrity_ok\":false}"))
    }
    func testInvalidOwnershipRecordsSurviveRejectedHostStartup() throws {
        let url = try file(), root = url.deletingLastPathComponent()
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        for name in ["gateway-root.json", "gateway-processes.json"] {
            let record = root.appendingPathComponent(name), data = Data("{\"pid\":1,\"pid\":2}".utf8)
            try data.write(to: record)
            XCTAssertEqual(ManagedGatewayHost.run(descriptorURL: url, runtimeURL: root.appendingPathComponent("absent-runtime")), 1)
            XCTAssertEqual(try Data(contentsOf: record), data)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("health.json").path))
            try FileManager.default.removeItem(at: record)
        }
    }
}
