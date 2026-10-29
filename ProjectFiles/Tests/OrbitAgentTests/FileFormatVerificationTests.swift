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

        let pdf = readablePDF()
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
        let docxBytes = zip(documentEntries())
        let tools = TaskToolExecutor()
        let written = try await tools.perform(action: ["type": "write_file", "path": docx.path,
                                                         "content": docxBytes.base64EncodedString(), "encoding": "base64"])
        XCTAssertEqual((written["file_format"] as? [String: Any])?["format"] as? String, "docx")
        let read = try await tools.perform(action: ["type": "read_file", "path": docx.path])
        XCTAssertEqual((read["file_format"] as? [String: Any])?["format"] as? String, "docx")

        let xlsx = root.appendingPathComponent("book.xlsx")
        let workbook = zip(workbookEntries())
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

    private func readablePDF() -> Data {
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>",
                       "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                       "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>"]
        var text = "%PDF-1.7\n", offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(text.utf8.count)
            text += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let start = text.utf8.count
        text += "xref\n0 4\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { text += String(format: "%010d 00000 n \n", offset) }
        text += "trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n"
        return Data(text.utf8)
    }

    private func documentEntries() -> [(String, String, UInt16)] {
        [
            ("[Content_Types].xml", "<Types xmlns=\"\(ArtifactPackage.typesNS)\"><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>", 8),
            ("_rels/.rels", "<Relationships xmlns=\"\(ArtifactPackage.packageNS)\"><Relationship Id=\"r0\" Type=\"\(ArtifactPackage.officeNS)/officeDocument\" Target=\"word/document.xml\"/></Relationships>", 8),
            ("word/document.xml", "<w:document xmlns:w=\"\(ArtifactPackage.wordNS[0])\"><w:body><w:p/></w:body></w:document>", 8)
        ]
    }

    private func workbookEntries() -> [(String, String, UInt16)] {
        [
            ("[Content_Types].xml", "<Types xmlns=\"\(ArtifactPackage.typesNS)\"><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/custom.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>", 8),
            ("_rels/.rels", "<Relationships xmlns=\"\(ArtifactPackage.packageNS)\"><Relationship Id=\"r0\" Type=\"\(ArtifactPackage.officeNS)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>", 8),
            ("xl/workbook.xml", "<workbook xmlns=\"\(ArtifactPackage.sheetNS[0])\" xmlns:r=\"\(ArtifactPackage.officeNS)\"><sheets><sheet name=\"Budget\" sheetId=\"1\" r:id=\"s1\"/></sheets></workbook>", 8),
            ("xl/_rels/workbook.xml.rels", "<Relationships xmlns=\"\(ArtifactPackage.packageNS)\"><Relationship Id=\"s1\" Type=\"\(ArtifactPackage.officeNS)/worksheet\" Target=\"worksheets/custom.xml\"/></Relationships>", 8),
            ("xl/worksheets/custom.xml", "<worksheet xmlns=\"\(ArtifactPackage.sheetNS[0])\"><sheetData/></worksheet>", 8)
        ]
    }

    private func inspect(_ data: Data, named: String, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws -> [String: Any]? {
        let path = try fixture().appendingPathComponent(named)
        try data.write(to: path)
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        return try FileFormatVerifier.attestation(fileDescriptor: handle.fileDescriptor, size: Int64(data.count), filename: named, clock: clock)
    }

    func testMarkerOnlyPDFAndUnreadablePageTreeCannotProveStructure() throws {
        let body = "%PDF-1.7\n1 0 obj\n<< /Type /Catalog >>\nendobj\n"
        let data = Data((body + "xref\n0 2\n0000000000 65535 f \n0000000009 00000 n \ntrailer\n<< /Size 2 /Root 1 0 R >>\nstartxref\n\(body.utf8.count)\n%%EOF\n").utf8)
        XCTAssertNil(try inspect(data, named: "empty.pdf"))
        let accepted = try XCTUnwrap(inspect(readablePDF(), named: "valid.pdf"))
        XCTAssertEqual(accepted["facts"] as? [String], ["pdf_catalog", "pdf_pages"])
        XCTAssertEqual(accepted["structure_count"] as? Int, 1)
        try ActionContract.validateNativePayload("artifact_format", accepted)
    }

    func testWorkbookRelationshipsMustResolveEveryDeclaredSheet() throws {
        let mutations: [(String, String, String)] = [
            ("xl/workbook.xml", "r:id=\"s1\"", "r:id=\"missing\""),
            ("xl/_rels/workbook.xml.rels", "worksheets/custom.xml", "worksheets/missing.xml"),
            ("xl/_rels/workbook.xml.rels", "worksheets/custom.xml", "../../outside.xml"),
            ("xl/_rels/workbook.xml.rels", "worksheets/custom.xml", "https://example.invalid/sheet.xml"),
            ("xl/_rels/workbook.xml.rels", "worksheets/custom.xml", "%2fworksheets/custom.xml"),
            ("xl/_rels/workbook.xml.rels", "worksheets/custom.xml", "//worksheets/custom.xml"),
            ("xl/worksheets/custom.xml", "<sheetData/>", ""),
            ("xl/worksheets/custom.xml", "</worksheet>", ""),
            ("[Content_Types].xml", "spreadsheetml.worksheet+xml", "spreadsheetml.styles+xml")
        ]
        for (part, before, after) in mutations {
            let entries = workbookEntries().map { ($0.0, $0.0 == part ? $0.1.replacingOccurrences(of: before, with: after) : $0.1, $0.2) }
            XCTAssertNil(try inspect(zip(entries), named: "bad.xlsx"), "Accepted \(part): \(after)")
        }
        var entries = workbookEntries()
        entries[2].1 = entries[2].1.replacingOccurrences(of: "</sheets>", with: "<sheet name=\"Other\" sheetId=\"2\" r:id=\"missing\"/></sheets>")
        XCTAssertNil(try inspect(zip(entries), named: "partial.xlsx"), "One valid sheet cannot hide a missing second sheet")
    }

    func testWordRequiresBodyAndPackageRootAndRejectsEntityDeclarations() throws {
        let mutations: [(String, String, String)] = [
            ("word/document.xml", "<w:body><w:p/></w:body>", ""),
            ("word/document.xml", "</w:document>", ""),
            ("word/document.xml", "http://schemas.openxmlformats.org/wordprocessingml/2006/main", "urn:lookalike"),
            ("_rels/.rels", "word/document.xml", "missing.xml"),
            ("[Content_Types].xml", "PartName=\"/word/document.xml\"", "PartName=\"/different.xml\"")
        ]
        for (part, before, after) in mutations {
            let entries = documentEntries().map { ($0.0, $0.0 == part ? $0.1.replacingOccurrences(of: before, with: after) : $0.1, $0.2) }
            XCTAssertNil(try inspect(zip(entries), named: "bad.docx"))
        }
        var entries = documentEntries()
        entries[2].1 = "<!DOCTYPE w:document [<!ENTITY secret SYSTEM 'file:///not-read'>]>" + entries[2].1
        XCTAssertNil(try inspect(zip(entries), named: "entity.docx"))
    }

    func testDuplicatePackagePartsAndRelationshipsAreRejected() throws {
        var entries = workbookEntries()
        entries.append(entries.last!)
        XCTAssertNil(try inspect(zip(entries), named: "duplicate.xlsx"))
        entries = workbookEntries()
        entries[3].1 = entries[3].1.replacingOccurrences(of: "</Relationships>", with: "<Relationship Id=\"s1\" Type=\"other\" Target=\"worksheets/custom.xml\"/></Relationships>")
        XCTAssertNil(try inspect(zip(entries), named: "duplicate-link.xlsx"))
    }

    func testUnsupportedAndOverBudgetInputsCannotAcquireStructureProof() throws {
        XCTAssertNil(try inspect(readablePDF(), named: "unknown.bin"))
        var tick: TimeInterval = 0
        XCTAssertNil(try inspect(readablePDF(), named: "slow.pdf", clock: { tick += 1; return tick }))
        XCTAssertNil(try inspect(zip(workbookEntries()), named: "slow.xlsx", clock: { tick += 1; return tick }))
    }

    func testFormatAndDigestProofReuseIsBoundToExactObjectAndCompleteStages() throws {
        let path = try fixture().appendingPathComponent("report.pdf"), data = readablePDF()
        let operation = try BoundFileOperation(path)
        let (size, fields) = try operation.replace(with: data, append: false, mustBeAbsent: true)
        let lease = TaskLease(id: "artifact-proof-task")
        var proof = fields
        proof["task_generation_id"] = lease.id
        proof["path"] = path.standardizedFileURL.path
        proof["file_size"] = size
        try TaskOwnership.$current.withValue(lease) {
            let result = try XCTUnwrap(operation.reuseVerifiedDigest(kind: "file_contents", expected: data,
                generation: lease.id, proof: proof))
            XCTAssertEqual((result["file_format"] as? [String: Any])?["facts"] as? [String], ["pdf_catalog", "pdf_pages"])
            var weakProof = proof
            weakProof["file_format"] = ["format": "pdf", "verified": true]
            XCTAssertNil(try operation.reuseVerifiedDigest(kind: "file_contents", expected: data, generation: lease.id, proof: weakProof))
            try data.write(to: path, options: .atomic)
            XCTAssertNil(try operation.reuseVerifiedDigest(kind: "file_contents", expected: data, generation: lease.id, proof: proof))
            XCTAssertNotNil(try BoundFileOperation(path).read(limit: data.count).fileFormat)
        }
    }

    func testXMLWorkAndDeclaredPartSizesStayBounded() throws {
        var entries = documentEntries()
        entries[2].1 = "<w:document xmlns:w=\"\(ArtifactPackage.wordNS[0])\"><w:body>" + String(repeating: "<w:p/>", count: 50_001) + "</w:body></w:document>"
        XCTAssertNil(try inspect(zip(entries), named: "many-nodes.docx"))
        entries = documentEntries()
        entries[2].1 = String(repeating: "<x>", count: 65) + "text" + String(repeating: "</x>", count: 65)
        XCTAssertNil(try inspect(zip(entries), named: "deep.docx"))
        let oversized = try fixture().appendingPathComponent("large.pdf")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forUpdating: oversized)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 64 * 1024 * 1024 + 1)
        XCTAssertNil(try FileFormatVerifier.attestation(fileDescriptor: handle.fileDescriptor,
            size: 64 * 1024 * 1024 + 1, filename: "large.pdf"))
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
