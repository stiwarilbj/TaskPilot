import Darwin
import Foundation
import Compression

/// Small, descriptor-based checks for common document formats. This verifies
/// signatures and essential container structure; it does not parse document
/// content or claim that every optional format feature is valid.
enum FileFormatVerifier {
    static let maximumCentralDirectoryBytes = 4 * 1024 * 1024
    static let maximumEntries = 16_384
    private static let maximumNameBytes = 1_024
    private static let maximumRequiredPartBytes = 4 * 1024 * 1024
    private static let maximumInflatedBytes = 12 * 1024 * 1024

    static func expectedFormat(for filename: String) -> String? {
        switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
        case "pdf": return "pdf"
        case "docx": return "docx"
        case "xlsx": return "xlsx"
        default: return nil
        }
    }

    /// Returns a private attestation for valid supported formats. A nil result
    /// means the extension is unsupported or the bytes do not match it.
    static func attestation(fileDescriptor fd: Int32, size: Int64, filename: String) throws -> [String: Any]? {
        guard let format = expectedFormat(for: filename) else { return nil }
        let valid: Bool
        switch format {
        case "pdf": valid = try verifyPDF(fd, size: size)
        case "docx": valid = try verifyOOXML(fd, size: size, kind: .docx)
        case "xlsx": valid = try verifyOOXML(fd, size: size, kind: .xlsx)
        default: valid = false
        }
        return valid ? ["format": format, "verified": true] : nil
    }

    private static func read(_ fd: Int32, offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= Int64(Int.max) else { return Data() }
        var data = Data(count: count)
        var received = 0
        while received < count {
            let result = data.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return pread(fd, base.advanced(by: received), count - received, off_t(offset + Int64(received)))
            }
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if result == 0 { break }
            received += result
        }
        data.count = received
        return data
    }

    private static func verifyPDF(_ fd: Int32, size: Int64) throws -> Bool {
        guard size >= 12 else { return false }
        let header = try read(fd, offset: 0, count: 8)
        guard header.count == 8, header.prefix(5) == Data("%PDF-".utf8),
              header[5] >= 48, header[5] <= 57,
              header[6] == 46, header[7] >= 48, header[7] <= 57 else { return false }
        let tailCount = Int(min(size, 4_096))
        let tail = try read(fd, offset: size - Int64(tailCount), count: tailCount)
        guard let marker = tail.range(of: Data("%%EOF".utf8), options: .backwards) else { return false }
        guard tail[marker.upperBound...].allSatisfy({ isPDFWhitespace($0) }),
              let startxref = tail[..<marker.lowerBound].range(of: Data("startxref".utf8), options: .backwards) else {
            return false
        }
        var digitStart = startxref.upperBound
        while digitStart < marker.lowerBound, isPDFWhitespace(tail[digitStart]) { digitStart += 1 }
        var digitEnd = digitStart
        while digitEnd < marker.lowerBound, (48...57).contains(tail[digitEnd]) { digitEnd += 1 }
        guard digitEnd > digitStart,
              let offset = Int64(String(decoding: tail[digitStart..<digitEnd], as: UTF8.self)),
              offset > 0, offset < size else { return false }
        return try verifyPDFCrossReference(fd, offset: offset, size: size)
    }

    private static func verifyPDFCrossReference(_ fd: Int32, offset: Int64, size: Int64) throws -> Bool {
        let bytes = try read(fd, offset: offset, count: Int(min(size - offset, 4_096)))
        let classic = Data("xref".utf8)
        if bytes.starts(with: classic), bytes.count == classic.count || isPDFWhitespace(bytes[classic.count]) {
            return true
        }
        // Cross-reference streams point at an indirect object whose dictionary
        // identifies itself as /Type /XRef. Inspect only a small prefix.
        let prefix = String(decoding: bytes, as: UTF8.self)
        let pattern = #"^\s*[0-9]+\s+[0-9]+\s+obj\b(?s:.{0,4000}?<<.{0,4000}?/Type\s*/XRef\b)"#
        return prefix.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isPDFWhitespace(_ byte: UInt8) -> Bool {
        [0, 9, 10, 12, 13, 32].contains(byte)
    }

    private enum OOXMLKind { case docx, xlsx }
    private struct ZIPEntry {
        let name: String
        let method: UInt16
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let dataOffset: Int64
    }

    private static func verifyOOXML(_ fd: Int32, size: Int64, kind: OOXMLKind) throws -> Bool {
        // ZIP EOCD has a 22-byte fixed header and a maximum 65,535-byte comment.
        guard size >= 22 else { return false }
        let signature = try read(fd, offset: 0, count: 4)
        guard signature == Data([0x50, 0x4b, 0x03, 0x04]) else { return false }
        let tailCount = Int(min(size, 65_557))
        let tailOffset = size - Int64(tailCount)
        let tail = try read(fd, offset: tailOffset, count: tailCount)
        guard let eocd = findEOCD(in: tail), tail.count - eocd >= 22 else { return false }

        let disk = u16(tail, eocd + 4), centralDisk = u16(tail, eocd + 6)
        let diskEntries = u16(tail, eocd + 8), totalEntries = u16(tail, eocd + 10)
        let directorySize = u32(tail, eocd + 12), directoryOffset = u32(tail, eocd + 16)
        let commentLength = Int(u16(tail, eocd + 20))
        guard disk == 0, centralDisk == 0, diskEntries == totalEntries,
              totalEntries > 0, Int(totalEntries) <= maximumEntries,
              directorySize != UInt32.max, directoryOffset != UInt32.max,
              Int64(directorySize) <= Int64(maximumCentralDirectoryBytes),
              eocd + 22 + commentLength == tail.count else { return false }

        let eocdAbsolute = tailOffset + Int64(eocd)
        let directoryStart = Int64(directoryOffset), directoryEnd = directoryStart + Int64(directorySize)
        guard directoryEnd == eocdAbsolute, directoryStart >= 0, directoryEnd >= directoryStart,
              directoryEnd <= size else { return false }
        let directory = try read(fd, offset: directoryStart, count: Int(directorySize))
        guard directory.count == Int(directorySize) else { return false }

        var cursor = 0
        var requiredEntries: [String: ZIPEntry] = [:]
        var worksheetEntries: [ZIPEntry] = []
        var worksheetNames = Set<String>()
        for _ in 0..<Int(totalEntries) {
            try TaskOwnership.check()
            guard cursor <= directory.count - 46, u32(directory, cursor) == 0x02014b50 else { return false }
            let flags = u16(directory, cursor + 8), method = u16(directory, cursor + 10)
            let crc = u32(directory, cursor + 16), compressed = u32(directory, cursor + 20)
            let uncompressed = u32(directory, cursor + 24)
            let nameLength = Int(u16(directory, cursor + 28)), extraLength = Int(u16(directory, cursor + 30))
            let entryCommentLength = Int(u16(directory, cursor + 32))
            let startDisk = u16(directory, cursor + 34), localOffset = u32(directory, cursor + 42)
            let totalLength = 46 + nameLength + extraLength + entryCommentLength
            guard nameLength > 0, nameLength <= maximumNameBytes,
                  totalLength <= directory.count - cursor else { return false }
            let rawNameStart = cursor + 46
            let rawName = directory[rawNameStart..<(rawNameStart + nameLength)]
            let decodedName: String?
            if flags & 0x0800 != 0 {
                decodedName = String(data: Data(rawName), encoding: .utf8)
            } else {
                decodedName = String(data: Data(rawName), encoding: .utf8) ?? String(data: Data(rawName), encoding: .isoLatin1)
            }
            guard startDisk == 0,
                  flags & ~UInt16(0x080e) == 0, method == 0 || method == 8,
                  compressed != UInt32.max, uncompressed != UInt32.max,
                  localOffset != UInt32.max,
                  let name = decodedName,
                  !name.contains("\\"), !name.hasPrefix("/") else { return false }
            // Reject ZIP64 extra fields, whose sentinels would otherwise evade
            // the bounded offsets and sizes enforced by this reader.
            let extraStart = cursor + 46 + nameLength
            if containsZIP64Extra(directory, start: extraStart, length: extraLength) { return false }

            let local = Int64(localOffset)
            guard local >= 0, local + 30 <= directoryStart else { return false }
            let localHeader = try read(fd, offset: local, count: 30)
            guard localHeader.count == 30, u32(localHeader, 0) == 0x04034b50,
                  u16(localHeader, 6) == flags, u16(localHeader, 8) == method else { return false }
            if flags & 0x0008 == 0 {
                guard u32(localHeader, 14) == crc, u32(localHeader, 18) == compressed,
                      u32(localHeader, 22) == uncompressed else { return false }
            }
            let localNameLength = Int(u16(localHeader, 26)), localExtraLength = Int(u16(localHeader, 28))
            guard localNameLength == nameLength else { return false }
            let localName = try read(fd, offset: local + 30, count: localNameLength)
            guard localName == Data(rawName) else { return false }
            let dataStart = local + 30 + Int64(localNameLength + localExtraLength)
            let dataEnd = dataStart + Int64(compressed)
            guard dataStart >= local, dataEnd >= dataStart, dataEnd <= directoryStart else { return false }
            if isRequiredEntry(name, kind: kind) {
                guard compressed > 0, uncompressed > 0,
                      compressed <= UInt32(maximumRequiredPartBytes),
                      uncompressed <= UInt32(maximumRequiredPartBytes) else { return false }
                let entry = ZIPEntry(name: name, method: method, crc32: crc, compressedSize: compressed,
                                     uncompressedSize: uncompressed, dataOffset: dataStart)
                if isWorksheet(name) {
                    guard worksheetNames.insert(name).inserted else { return false }
                    worksheetEntries.append(entry)
                } else {
                    guard requiredEntries[name] == nil else { return false }
                    requiredEntries[name] = entry
                }
            }
            cursor += totalLength
        }
        guard cursor == directory.count else { return false }
        switch kind {
        case .docx:
            guard let contentTypes = requiredEntries["[Content_Types].xml"],
                  let document = requiredEntries["word/document.xml"],
                  let typesXML = try inflate(contentTypes, fd: fd),
                  hasXMLRoot(typesXML, "Types"),
                  contains(typesXML, "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"),
                  let documentXML = try inflate(document, fd: fd),
                  hasXMLRoot(documentXML, "document") else { return false }
            return true
        case .xlsx:
            guard let contentTypes = requiredEntries["[Content_Types].xml"],
                  let workbook = requiredEntries["xl/workbook.xml"],
                  let typesXML = try inflate(contentTypes, fd: fd),
                  hasXMLRoot(typesXML, "Types"),
                  contains(typesXML, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"),
                  let workbookXML = try inflate(workbook, fd: fd),
                  hasXMLRoot(workbookXML, "workbook") else { return false }
            var inflatedBytes = typesXML.count + workbookXML.count
            for worksheet in worksheetEntries {
                try TaskOwnership.check()
                let remaining = maximumInflatedBytes - inflatedBytes
                guard remaining > 0 else { break }
                guard Int(worksheet.uncompressedSize) <= remaining else { continue }
                let sheetXML = try inflate(worksheet, fd: fd, maximumOutput: remaining)
                inflatedBytes += Int(worksheet.uncompressedSize)
                if let sheetXML, hasXMLRoot(sheetXML, "worksheet") { return true }
            }
            return false
        }
    }

    private static func inflate(_ entry: ZIPEntry, fd: Int32,
                                maximumOutput: Int = maximumRequiredPartBytes) throws -> Data? {
        try TaskOwnership.check()
        let compressedSize = Int(entry.compressedSize), outputSize = Int(entry.uncompressedSize)
        guard compressedSize > 0, outputSize > 0,
              compressedSize <= maximumRequiredPartBytes, outputSize <= maximumRequiredPartBytes,
              outputSize <= maximumOutput else { return nil }
        let compressed = try read(fd, offset: entry.dataOffset, count: compressedSize)
        guard compressed.count == compressedSize else { return nil }
        let output: Data
        if entry.method == 0 {
            guard compressedSize == outputSize else { return nil }
            output = compressed
        } else if entry.method == 8 {
            var decoded = Data(count: outputSize)
            let count = decoded.withUnsafeMutableBytes { destination in
                compressed.withUnsafeBytes { source in
                    guard let destinationBase = destination.baseAddress, let sourceBase = source.baseAddress else { return 0 }
                    return compression_decode_buffer(destinationBase.assumingMemoryBound(to: UInt8.self), outputSize,
                        sourceBase.assumingMemoryBound(to: UInt8.self), compressedSize, nil, COMPRESSION_ZLIB)
                }
            }
            guard count == outputSize else { return nil }
            output = decoded
        } else { return nil }
        guard Self.crc32(output) == entry.crc32 else { return nil }
        return output
    }

    private static func hasXMLRoot(_ data: Data, _ expected: String) -> Bool {
        guard let xml = String(data: data, encoding: .utf8) else { return false }
        var index = xml.startIndex
        while index < xml.endIndex {
            guard let opening = xml[index...].firstIndex(of: "<") else { return false }
            let next = xml.index(after: opening)
            guard next < xml.endIndex else { return false }
            let marker = xml[next]
            if marker == "!", xml[opening...].hasPrefix("<!--") {
                guard let close = xml[opening...].range(of: "-->")?.upperBound else { return false }
                index = close
                continue
            }
            if marker == "?" || marker == "!" || marker == "/" {
                guard let close = xml[next...].firstIndex(of: ">") else { return false }
                index = xml.index(after: close)
                continue
            }
            var end = next
            while end < xml.endIndex, !xml[end].isWhitespace, xml[end] != ">", xml[end] != "/" { end = xml.index(after: end) }
            let qualifiedName = String(xml[next..<end])
            return qualifiedName.split(separator: ":").last.map(String.init) == expected
        }
        return false
    }

    private static func contains(_ data: Data, _ marker: String) -> Bool {
        data.range(of: Data(marker.utf8)) != nil
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
        }
        return ~crc
    }

    private static func findEOCD(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        var offset = data.count - 22
        while offset >= 0 {
            if u32(data, offset) == 0x06054b50, offset + 22 <= data.count,
               offset + 22 + Int(u16(data, offset + 20)) == data.count { return offset }
            if offset == 0 { break }
            offset -= 1
        }
        return nil
    }

    private static func containsZIP64Extra(_ data: Data, start: Int, length: Int) -> Bool {
        var cursor = start, end = start + length
        guard end <= data.count else { return true }
        while cursor < end {
            guard cursor + 4 <= end else { return true }
            let kind = u16(data, cursor), size = Int(u16(data, cursor + 2))
            if kind == 0x0001 { return true }
            guard cursor + 4 + size <= end else { return true }
            cursor += 4 + size
        }
        return false
    }

    private static func isRequiredEntry(_ name: String, kind: OOXMLKind) -> Bool {
        switch kind {
        case .docx: return name == "[Content_Types].xml" || name == "word/document.xml"
        case .xlsx: return name == "[Content_Types].xml" || name == "xl/workbook.xml" || isWorksheet(name)
        }
    }

    private static func isWorksheet(_ name: String) -> Bool {
        guard name.hasPrefix("xl/worksheets/sheet"), name.hasSuffix(".xml") else { return false }
        let number = name.dropFirst("xl/worksheets/sheet".count).dropLast(".xml".count)
        return !number.isEmpty && number.allSatisfy(\.isNumber)
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }
    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
}
