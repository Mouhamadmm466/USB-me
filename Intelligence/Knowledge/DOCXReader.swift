import Compression
import Foundation

/// Reads the text out of a .docx without any third-party code.
///
/// A .docx is a zip holding `word/document.xml`. Both halves are small enough to do properly here:
/// a minimal zip reader (stored and deflate entries, read through the central directory) and a
/// scanner that keeps the text runs and the paragraph breaks and ignores the rest of the markup.
enum DOCXReader {
    static func text(from data: Data) throws -> String {
        guard let entry = try ZipArchive(data: data).file(named: "word/document.xml") else {
            throw DocumentParseError.unreadable("Word document")
        }
        guard let xml = String(data: entry, encoding: .utf8) else {
            throw DocumentParseError.unreadable("Word document text")
        }
        return paragraphs(in: xml)
    }

    /// Keeps `<w:t>` runs and turns `</w:p>` into line breaks; everything else is formatting.
    static func paragraphs(in xml: String) -> String {
        var output = ""
        var index = xml.startIndex
        while index < xml.endIndex {
            guard let tagStart = xml[index...].firstIndex(of: "<") else { break }
            guard let tagEnd = xml[tagStart...].firstIndex(of: ">") else { break }
            let tag = xml[tagStart...tagEnd]
            if tag.hasPrefix("<w:t") && !tag.hasPrefix("<w:tbl") && !tag.hasSuffix("/>") {
                let textStart = xml.index(after: tagEnd)
                if let closing = xml.range(of: "</w:t>", range: textStart..<xml.endIndex) {
                    output += HTMLText.decode(String(xml[textStart..<closing.lowerBound]))
                    index = closing.upperBound
                    continue
                }
            } else if tag.hasPrefix("</w:p>") {
                output += "\n"
            } else if tag.hasPrefix("<w:br") || tag.hasPrefix("<w:cr") {
                output += "\n"
            } else if tag.hasPrefix("<w:tab") {
                output += "\t"
            }
            index = xml.index(after: tagEnd)
        }
        return output
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The smallest zip reader that can open an Office file: central directory, stored and deflate.
struct ZipArchive {
    private let data: Data
    private let entries: [String: Entry]

    struct Entry {
        var compression: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    init(data: Data) throws {
        self.data = data
        entries = try Self.readCentralDirectory(data)
    }

    var fileNames: [String] { Array(entries.keys) }

    func file(named name: String) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        // The local header repeats the name and extra fields; the payload starts after them.
        let base = entry.localHeaderOffset
        guard data.count >= base + 30, Self.read32(data, base) == 0x04034b50 else {
            throw DocumentParseError.unreadable("zip entry")
        }
        let nameLength = Int(Self.read16(data, base + 26))
        let extraLength = Int(Self.read16(data, base + 28))
        let start = base + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard end <= data.count else { throw DocumentParseError.unreadable("zip payload") }
        let payload = data.subdata(in: start..<end)

        switch entry.compression {
        case 0: return payload
        case 8: return Self.inflate(payload, expecting: entry.uncompressedSize)
        default: throw DocumentParseError.unsupported("compressed zip entry")
        }
    }

    // MARK: Reading

    private static func readCentralDirectory(_ data: Data) throws -> [String: Entry] {
        guard let eocd = endOfCentralDirectory(data) else { throw DocumentParseError.unreadable("zip directory") }
        var offset = Int(read32(data, eocd + 16))
        let count = Int(read16(data, eocd + 10))
        var entries: [String: Entry] = [:]
        for _ in 0..<count {
            guard offset + 46 <= data.count, read32(data, offset) == 0x02014b50 else { break }
            let nameLength = Int(read16(data, offset + 28))
            let extraLength = Int(read16(data, offset + 30))
            let commentLength = Int(read16(data, offset + 32))
            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else { break }
            let name = String(decoding: data.subdata(in: nameStart..<(nameStart + nameLength)), as: UTF8.self)
            entries[name] = Entry(
                compression: read16(data, offset + 10),
                compressedSize: Int(read32(data, offset + 20)),
                uncompressedSize: Int(read32(data, offset + 24)),
                localHeaderOffset: Int(read32(data, offset + 42))
            )
            offset = nameStart + nameLength + extraLength + commentLength
        }
        guard !entries.isEmpty else { throw DocumentParseError.unreadable("zip directory") }
        return entries
    }

    /// The end-of-central-directory record sits at the end, after a comment of up to 64 KB.
    private static func endOfCentralDirectory(_ data: Data) -> Int? {
        let minimum = 22
        guard data.count >= minimum else { return nil }
        let lowest = max(0, data.count - minimum - 65_535)
        var index = data.count - minimum
        while index >= lowest {
            if read32(data, index) == 0x06054b50 { return index }
            index -= 1
        }
        return nil
    }

    private static func inflate(_ payload: Data, expecting size: Int) -> Data? {
        guard size > 0 else { return Data() }
        // Deflate can expand pathological input; allow headroom but stay bounded.
        var destination = [UInt8](repeating: 0, count: max(size, payload.count * 4) + 4_096)
        let written = payload.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return destination.withUnsafeMutableBufferPointer { buffer in
                compression_decode_buffer(
                    buffer.baseAddress!, buffer.count, base, source.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        return Data(destination[0..<written])
    }

    private static func read16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        var value: UInt32 = 0
        for byte in (0..<4).reversed() {
            value = (value << 8) | UInt32(data[data.startIndex + offset + byte])
        }
        return value
    }
}
