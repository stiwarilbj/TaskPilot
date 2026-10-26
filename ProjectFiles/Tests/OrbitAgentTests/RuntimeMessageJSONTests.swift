import Foundation
import XCTest
@testable import OrbitAgent

final class RuntimeMessageJSONTests: XCTestCase {
    func testRejectsSecuritySensitiveDuplicatesEvenWhenValuesMatch() {
        for key in ["kind", "task_generation_id", "instruction_revision", "working_document_revision",
                    "binding_revision", "revision", "request_id", "action_id", "method"] {
            for value in [0, 1] {
                let json = "{\"\(key)\":0,\"\(key)\":\(value)}"
                assertDuplicate(json)
            }
        }
    }

    func testEscapedKeysAndNestedObjectsCannotHideDuplicates() {
        assertDuplicate(#"{"kind":"status","k\u0069nd":"complete"}"#)
        assertDuplicate(#"{"params":{"action_id":"a","action\u005fid":"b"}}"#)
        assertDuplicate(#"{"items":[{"revision":0,"revision":1}]}"#)
        assertDuplicate(#"{"params":{"text":"first","text":"second"}}"#)
        assertDuplicate(#"{"":"a","":"b"}"#)
        assertDuplicate(#"{"a\"b":1,"a\u0022b":2}"#)
        assertDuplicate(#"{"\uD83D\uDE00":1,"😀":2}"#)
    }

    func testSeparateObjectsAndQuotedContentsRemainUnchanged() throws {
        let json = #"{"kind":"status","params":{"kind":"click","revision":1},"items":[{"revision":2},{"revision":3}],"message":"{\"kind\":1,\"kind\":2} \\ : [ ]", "unicode":"é😀"}"#
        let data = Data(json.utf8)
        let decoded = try RuntimeMessageJSON.decode(data)
        let ordinary = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(decoded as NSDictionary, ordinary as NSDictionary)
    }

    func testMalformedOrExcessivelyNestedFramesStillFail() {
        for json in ["[]", "null", "{} {}", "{\"kind\":}", "{\"kind\":\"unfinished",
                     #"{"\uZZZZ":1}"#, #"{"a" 1}"#,
                     "{\"a\":" + String(repeating: "[", count: 513) + "0" + String(repeating: "]", count: 513) + "}"] {
            XCTAssertThrowsError(try RuntimeMessageJSON.decode(Data(json.utf8)), json)
        }
        XCTAssertThrowsError(try RuntimeMessageJSON.decode(Data([0x7b, 0x22, 0xff, 0x22, 0x3a, 0x30, 0x7d])))
        for encoding in [String.Encoding.utf16, .utf16BigEndian, .utf32] {
            XCTAssertThrowsError(try RuntimeMessageJSON.decode(#"{"kind":0,"kind":1}"#.data(using: encoding)!))
        }
    }

    private func assertDuplicate(_ json: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try RuntimeMessageJSON.decode(Data(json.utf8)), file: file, line: line) { error in
            guard case RuntimeMessageJSON.Failure.duplicateField = error else {
                return XCTFail("Expected duplicate-field rejection, got \(error)", file: file, line: line)
            }
        }
    }
}
