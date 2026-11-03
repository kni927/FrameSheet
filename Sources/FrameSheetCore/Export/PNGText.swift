import Foundation

/// PNG `tEXt` chunks (§12): written before IEND, read back on import, in
/// the layout MoviePrint's `png-chunk-text` uses (keyword, NUL, Latin-1
/// text).
public enum PNGText {
    public enum Error: Swift.Error, Equatable {
        /// Not a PNG, or its chunks are cut short or fail their CRC.
        case invalidPNG
        /// No IEND chunk to insert before.
        case missingIEND
        /// A keyword or text that a tEXt chunk cannot hold: empty, a
        /// keyword of 80 or more characters, a NUL, or a character outside
        /// Latin-1.
        case invalidText(String)
    }

    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    struct Chunk {
        var type: String
        /// Range of the whole chunk (length, type, data, CRC) in the file.
        var range: Range<Int>
        var dataRange: Range<Int>
    }

    /// The PNG with one `tEXt` chunk per pair, in order, inserted
    /// immediately before IEND.
    public static func inserting(_ entries: [(keyword: String, text: String)], into png: Data) throws -> Data {
        let bytes = [UInt8](png)
        let chunks = try parse(bytes)
        guard let iend = chunks.last(where: { $0.type == "IEND" }) else { throw Error.missingIEND }
        var inserted: [UInt8] = []
        for entry in entries {
            inserted += try chunk(type: "tEXt", data: textData(keyword: entry.keyword, text: entry.text))
        }
        return Data(bytes[..<iend.range.lowerBound] + inserted + bytes[iend.range.lowerBound...])
    }

    /// All `tEXt` chunks in file order.
    public static func entries(in png: Data) throws -> [(keyword: String, text: String)] {
        let bytes = [UInt8](png)
        return try parse(bytes).filter { $0.type == "tEXt" }.compactMap { chunk in
            let data = bytes[chunk.dataRange]
            guard let nul = data.firstIndex(of: 0) else { return nil }
            let keyword = String(data: Data(data[..<nul]), encoding: .isoLatin1) ?? ""
            let text = String(data: Data(data[(nul + 1)...]), encoding: .isoLatin1) ?? ""
            return (keyword, text)
        }
    }

    /// The `tEXt` chunks by keyword; the first wins when a keyword repeats
    /// (MoviePrint reads with `find`).
    public static func dictionary(in png: Data) throws -> [String: String] {
        try entries(in: png).reduce(into: [:]) { result, entry in
            if result[entry.keyword] == nil { result[entry.keyword] = entry.text }
        }
    }

    static func parse(_ bytes: [UInt8]) throws -> [Chunk] {
        guard bytes.count >= signature.count, Array(bytes[0..<signature.count]) == signature else {
            throw Error.invalidPNG
        }
        var chunks: [Chunk] = []
        var offset = signature.count
        while offset < bytes.count {
            guard offset + 12 <= bytes.count else { throw Error.invalidPNG }
            let length = Int(readUInt32(bytes, at: offset))
            let typeStart = offset + 4
            let dataStart = typeStart + 4
            guard length <= bytes.count - dataStart - 4 else { throw Error.invalidPNG }
            let dataEnd = dataStart + length
            let crc = readUInt32(bytes, at: dataEnd)
            guard CRC32.checksum(bytes[typeStart..<dataEnd]) == crc else { throw Error.invalidPNG }
            let type = String(decoding: bytes[typeStart..<dataStart], as: Unicode.ASCII.self)
            chunks.append(Chunk(type: type, range: offset..<(dataEnd + 4), dataRange: dataStart..<dataEnd))
            offset = dataEnd + 4
            if type == "IEND" { break }
        }
        return chunks
    }

    static func textData(keyword: String, text: String) throws -> [UInt8] {
        guard !keyword.isEmpty, keyword.count < 80, let key = latin1(keyword), !key.contains(0) else {
            throw Error.invalidText(keyword)
        }
        // png-chunk-text also refuses empty text.
        guard !text.isEmpty, let value = latin1(text), !value.contains(0) else {
            throw Error.invalidText(text)
        }
        return key + [0] + value
    }

    static func latin1(_ string: String) -> [UInt8]? {
        string.data(using: .isoLatin1, allowLossyConversion: false).map { [UInt8]($0) }
    }

    static func chunk(type: String, data: [UInt8]) -> [UInt8] {
        let typeBytes = Array(type.utf8)
        let crc = CRC32.checksum(typeBytes + data)
        return bigEndian(UInt32(data.count)) + typeBytes + data + bigEndian(crc)
    }

    static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}

/// CRC-32 as PNG uses it (ISO 3309, polynomial 0xEDB88320), table based.
enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
