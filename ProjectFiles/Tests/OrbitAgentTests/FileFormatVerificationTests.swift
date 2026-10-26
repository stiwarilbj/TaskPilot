import XCTest
import Compression
@testable import OrbitAgent

final class FileFormatVerificationTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("taskpilot-format-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testPDFRequiresHeaderCrossReferenceAndTerminalMarkerBeforeCommit() async throws {
        let root = try fixture(), file = root.appendingPathComponent("report.pdf")
        try Data("previous".utf8).write(to: file)
        do {
            _ = try await TaskToolExecutor().perform(action: ["type": "write_file", "path": file.path, "content": "not a pdf"])
            XCTFail("A mislabeled PDF was accepted")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: file), Data("previous".utf8), "Rejected format must not replace the destination")

        let noCrossReference = Data("%PDF-1.7\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF\n".utf8)
        do {
            _ = try await TaskToolExecutor().perform(action: ["type": "write_file", "path": file.path,
                                                                "content": noCrossReference.base64EncodedString(), "encoding": "base64"])
            XCTFail("A PDF without a cross-reference marker was accepted")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: file), Data("previous".utf8))

        let body = "%PDF-1.7\n1 0 obj\n<< /Type /Catalog >>\nendobj\n"
        let pdf = Data((body + "xref\n0 2\n0000000000 65535 f \n0000000009 00000 n \ntrailer\n<< /Size 2 /Root 1 0 R >>\nstartxref\n\(body.utf8.count)\n%%EOF\n").utf8)
        let action: [String: Any] = ["type": "write_file", "path": file.path,
                                     "content": pdf.base64EncodedString(), "encoding": "base64"]
        let result = try await TaskToolExecutor().perform(action: action)
        try ActionContract.validateNativeResult(result, action: action)
        XCTAssertEqual((result["file_format"] as? [String: Any])?["format"] as? String, "pdf")
        XCTAssertEqual((result["file_format"] as? [String: Any])?["verified"] as? Bool, true)
        var missingAttestation = result
        missingAttestation.removeValue(forKey: "file_format")
        XCTAssertThrowsError(try ActionContract.validateNativeResult(missingAttestation, action: action))
    }

    func testOOXMLRequiresExpectedPackageEntriesAndAttestsReadback() async throws {
        let root = try fixture(), docx = root.appendingPathComponent("report.docx")
        let docxBytes = zip([
            ("[Content_Types].xml", "<Types><Override ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>", 8),
            ("word/document.xml", "<w:document xmlns:w=\"urn:word\"/>", 8)
        ])
        let tools = TaskToolExecutor()
        let written = try await tools.perform(action: ["type": "write_file", "path": docx.path,
                                                         "content": docxBytes.base64EncodedString(), "encoding": "base64"])
        XCTAssertEqual((written["file_format"] as? [String: Any])?["format"] as? String, "docx")
        let read = try await tools.perform(action: ["type": "read_file", "path": docx.path])
        XCTAssertEqual((read["file_format"] as? [String: Any])?["format"] as? String, "docx")

        let xlsx = root.appendingPathComponent("book.xlsx")
        let workbook = zip([
            ("[Content_Types].xml", "<Types><Override ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/></Types>", 8),
            ("xl/workbook.xml", "<workbook xmlns=\"urn:sheet\"/>", 8),
            ("xl/worksheets/sheet1.xml", "<worksheet xmlns=\"urn:sheet\"/>", 8)
        ])
        let workbookResult = try await tools.perform(action: ["type": "write_file", "path": xlsx.path,
                                                                "content": workbook.base64EncodedString(), "encoding": "base64"])
        XCTAssertEqual((workbookResult["file_format"] as? [String: Any])?["format"] as? String, "xlsx")
        let checked = try await tools.checkOutcome(["type": "file_exists", "path": xlsx.path])
        try ActionContract.validateCheckBatch(checked)
        let item = (checked["checks"] as? [[String: Any]])?.first
        XCTAssertEqual(item?["verified"] as? Bool, true)
        XCTAssertEqual((item?["file_format"] as? [String: Any])?["format"] as? String, "xlsx")
    }

    func testArbitraryZipRenamedXLSXDoesNotPassFileCheck() async throws {
        let root = try fixture(), file = root.appendingPathComponent("fake.xlsx")
        let bytes = zip([("readme.txt", "not a workbook", 0)])
        try bytes.write(to: file)
        let result = try await TaskToolExecutor().checkOutcome(["type": "file_exists", "path": file.path])
        XCTAssertEqual((result["checks"] as? [[String: Any]])?.first?["verified"] as? Bool, false)
        XCTAssertNil((result["checks"] as? [[String: Any]])?.first?["file_format"])
    }

    func testDOCXRequiresTheWordDocumentPartBeforeCommitting() async throws {
        let root = try fixture(), file = root.appendingPathComponent("incomplete.docx")
        let incomplete = zip([("[Content_Types].xml", "<Types/>", 0)])
        do {
            _ = try await TaskToolExecutor().perform(action: ["type": "write_file", "path": file.path,
                                                                "content": incomplete.base64EncodedString(), "encoding": "base64"])
            XCTFail("A ZIP package without the Word document part was accepted")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    private func zip(_ entries: [(String, String, UInt16)]) -> Data {
        var output = Data(), central = Data()
        for (name, contents, method) in entries {
            let nameBytes = Data(name.utf8), bytes = Data(contents.utf8)
            let compressed = method == 8 ? deflate(bytes) : bytes
            let checksum = crc32(bytes), localOffset = UInt32(output.count)
            append(UInt32(0x04034b50), to: &output); append(UInt16(20), to: &output)
            append(UInt16(0), to: &output); append(method, to: &output)
            append(UInt16(0), to: &output); append(UInt16(0), to: &output)
            append(checksum, to: &output); append(UInt32(compressed.count), to: &output); append(UInt32(bytes.count), to: &output)
            append(UInt16(nameBytes.count), to: &output); append(UInt16(0), to: &output)
            output.append(nameBytes); output.append(compressed)

            append(UInt32(0x02014b50), to: &central); append(UInt16(20), to: &central); append(UInt16(20), to: &central)
            append(UInt16(0), to: &central); append(method, to: &central)
            append(UInt16(0), to: &central); append(UInt16(0), to: &central)
            append(checksum, to: &central); append(UInt32(compressed.count), to: &central); append(UInt32(bytes.count), to: &central)
            append(UInt16(nameBytes.count), to: &central); append(UInt16(0), to: &central); append(UInt16(0), to: &central)
            append(UInt16(0), to: &central); append(UInt16(0), to: &central); append(UInt32(0), to: &central)
            append(localOffset, to: &central); central.append(nameBytes)
        }
        let centralOffset = UInt32(output.count), centralSize = UInt32(central.count)
        output.append(central)
        append(UInt32(0x06054b50), to: &output); append(UInt16(0), to: &output); append(UInt16(0), to: &output)
        append(UInt16(entries.count), to: &output); append(UInt16(entries.count), to: &output)
        append(centralSize, to: &output); append(centralOffset, to: &output); append(UInt16(0), to: &output)
        return output
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
        }
        return ~crc
    }

    private func deflate(_ data: Data) -> Data {
        let algorithm = COMPRESSION_ZLIB
        let capacity = max(64, data.count + data.count / 8 + 64)
        let scratchSize = max(1, compression_encode_scratch_buffer_size(algorithm))
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchSize, alignment: MemoryLayout<UInt64>.alignment)
        defer { scratch.deallocate() }
        var output = Data(count: capacity)
        let count = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                guard let destinationBase = destination.baseAddress, let sourceBase = source.baseAddress else { return 0 }
                return compression_encode_buffer(destinationBase.assumingMemoryBound(to: UInt8.self), capacity,
                    sourceBase.assumingMemoryBound(to: UInt8.self), data.count, scratch, algorithm)
            }
        }
        guard count > 0 else { return data }
        output.count = count
        return output
    }
}
