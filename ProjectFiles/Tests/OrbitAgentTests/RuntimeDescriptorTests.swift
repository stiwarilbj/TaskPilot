import XCTest
import Darwin
@testable import OrbitAgent

final class RuntimeDescriptorTests: XCTestCase {
    private var corpusURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/runtime-descriptor-cases.json")
    }

    func testSharedCorpus() throws {
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: corpusURL)) as! [String: Any]
        // Foundation deliberately preserves macOS's /var alias even when asked
        // to resolve it. Use the real directory, matching Python Path.resolve.
        let canonical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        let parent = URL(fileURLWithPath: String(cString: canonical))
        for entry in corpus["cases"] as! [[String: Any]] {
            let name = entry["name"] as! String
            let root = parent.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            func bind(_ value: Any) throws -> Any {
                let data = try JSONSerialization.data(withJSONObject: value)
                let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "$ROOT", with: root.path)
                return try JSONSerialization.jsonObject(with: Data(text.utf8))
            }
            var value = try bind(corpus["descriptor"]!) as! [String: Any]
            if let updates = entry["set"] { value.merge(try bind(updates) as! [String: Any]) { _, new in new } }
            for field in entry["remove"] as? [String] ?? [] { value.removeValue(forKey: field) }
            if let links = entry["links"] {
                for (name, target) in try bind(links) as! [String: String] {
                    let link = root.appendingPathComponent(name)
                    try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
                }
            }
            let rawFields = entry["raw_fields"] as? [String: String] ?? [:]
            let validationRoot = (entry["validation_root"] as? String).map { URL(fileURLWithPath: $0) } ?? root
            func json(_ value: Any) throws -> String {
                String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
            }
            let raw: String
            if let supplied = entry["raw"] as? String { raw = supplied }
            else { raw = "{" + (try value.keys.sorted().map { key in try json(key) + ":" + (rawFields[key] ?? json(value[key]!)) }).joined(separator: ",") + "}" }
            do {
                let parsed = try RuntimeDescriptorContract.parse(Data(raw.utf8), root: validationRoot)
                XCTAssertNil(entry["error"], name)
                XCTAssertEqual(parsed as NSDictionary, value as NSDictionary, name)
                let url = root.appendingPathComponent("runtime.json")
                try Data(raw.utf8).write(to: url)
                let typed = try ManagedOpenClawDescriptor.load(from: url)
                let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(typed)) as! [String: Any]
                let known = value.filter { RuntimeDescriptorContract.fieldOrder.contains($0.key) }
                XCTAssertEqual(encoded as NSDictionary, known as NSDictionary, name)
            } catch let failure as RuntimeDescriptorContract.Failure {
                let expected = entry["error"] as? [String: String]
                XCTAssertEqual(failure.field, expected?["field"], name)
                XCTAssertEqual(failure.code, expected?["code"], name)
            } catch { XCTFail("\(name): \(error)") }
        }
    }

    func testParserBoundsAndEncoding() {
        let cases: [(Data, String)] = [
            (Data(repeating: 0x20, count: RuntimeDescriptorContract.maxBytes + 1), "too_large"),
            ("{}".data(using: .utf16)!, "invalid_json"),
            (Data([0xef, 0xbb, 0xbf]) + Data("{}".utf8), "invalid_json"),
            (Data(("{\"x\":" + String(repeating: "[", count: 512) + "0" + String(repeating: "]", count: 512) + "}").utf8), "invalid_json")
        ]
        for (data, code) in cases {
            XCTAssertThrowsError(try RuntimeDescriptorContract.parse(data, root: FileManager.default.temporaryDirectory)) { error in
                XCTAssertEqual(error as? RuntimeDescriptorContract.Failure, .init(field: "descriptor", code: code))
            }
        }
    }
}
