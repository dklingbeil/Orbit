import Compression
import Foundation

/// Minimal in-memory ZIP writer (store + deflate) for OOXML, ODF and EPUB containers.
public struct ZipWriter {
    private struct Entry {
        let name: Data
        let crc: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let method: UInt16
        let offset: UInt32
    }

    private var data = Data()
    private var entries: [Entry] = []

    public init() {}

    /// Adds a file. `compress: false` stores it verbatim (required for EPUB's `mimetype`).
    public mutating func add(_ path: String, _ contents: Data, compress: Bool = true) {
        let nameData = Data(path.utf8)
        let crc = CRC32.checksum(contents)
        var method: UInt16 = 0
        var payload = contents
        if compress, contents.count > 64, let deflated = Deflate.compress(contents), deflated.count < contents.count {
            method = 8
            payload = deflated
        }
        let offset = UInt32(data.count)
        var header = Data()
        header.appendLE(UInt32(0x04034b50))
        header.appendLE(UInt16(20))          // version needed
        header.appendLE(UInt16(0x0800))      // UTF-8 names
        header.appendLE(method)
        header.appendLE(UInt16(0))           // mod time
        header.appendLE(UInt16(0x21))        // mod date (1980-01-01)
        header.appendLE(crc)
        header.appendLE(UInt32(payload.count))
        header.appendLE(UInt32(contents.count))
        header.appendLE(UInt16(nameData.count))
        header.appendLE(UInt16(0))
        data.append(header)
        data.append(nameData)
        data.append(payload)
        entries.append(Entry(name: nameData, crc: crc, compressedSize: UInt32(payload.count),
                             uncompressedSize: UInt32(contents.count), method: method, offset: offset))
    }

    public mutating func add(_ path: String, _ text: String, compress: Bool = true) {
        add(path, Data(text.utf8), compress: compress)
    }

    public func finish() -> Data {
        var out = data
        let directoryOffset = UInt32(out.count)
        var directory = Data()
        for entry in entries {
            directory.appendLE(UInt32(0x02014b50))
            directory.appendLE(UInt16(0x031E))  // made by: Unix, v3.0
            directory.appendLE(UInt16(20))
            directory.appendLE(UInt16(0x0800))
            directory.appendLE(entry.method)
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0x21))
            directory.appendLE(entry.crc)
            directory.appendLE(entry.compressedSize)
            directory.appendLE(entry.uncompressedSize)
            directory.appendLE(UInt16(entry.name.count))
            directory.appendLE(UInt16(0))       // extra
            directory.appendLE(UInt16(0))       // comment
            directory.appendLE(UInt16(0))       // disk
            directory.appendLE(UInt16(0))       // internal attrs
            directory.appendLE(UInt32(0o100644) << 16)
            directory.appendLE(entry.offset)
            directory.append(entry.name)
        }
        out.append(directory)
        out.appendLE(UInt32(0x06054b50))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt32(directory.count))
        out.appendLE(directoryOffset)
        out.appendLE(UInt16(0))
        return out
    }
}

/// Minimal ZIP reader (store + deflate, no ZIP64).
public struct ZipReader {
    public struct Entry {
        public let path: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    public let entries: [Entry]

    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
        self.data = data
        guard data.count >= 22 else { throw OrbitError.invalidInput("Not a ZIP container.") }
        // Locate the end-of-central-directory record.
        var eocd = -1
        let lowerBound = max(0, data.count - 65_557)
        var index = data.count - 22
        while index >= lowerBound {
            if data.readLE(UInt32.self, at: index) == 0x06054b50 { eocd = index; break }
            index -= 1
        }
        guard eocd >= 0 else { throw OrbitError.invalidInput("Not a ZIP container.") }
        let count = Int(data.readLE(UInt16.self, at: eocd + 10))
        var offset = Int(data.readLE(UInt32.self, at: eocd + 16))
        var entries: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= data.count, data.readLE(UInt32.self, at: offset) == 0x02014b50 else { break }
            let method = data.readLE(UInt16.self, at: offset + 10)
            let compressed = Int(data.readLE(UInt32.self, at: offset + 20))
            let uncompressed = Int(data.readLE(UInt32.self, at: offset + 24))
            let nameLength = Int(data.readLE(UInt16.self, at: offset + 28))
            let extraLength = Int(data.readLE(UInt16.self, at: offset + 30))
            let commentLength = Int(data.readLE(UInt16.self, at: offset + 32))
            let local = Int(data.readLE(UInt32.self, at: offset + 42))
            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else { break }
            let name = String(decoding: data[data.startIndex + nameStart ..< data.startIndex + nameStart + nameLength], as: UTF8.self)
            entries.append(Entry(path: name, method: method, compressedSize: compressed,
                                 uncompressedSize: uncompressed, localHeaderOffset: local))
            offset = nameStart + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    public func contains(_ path: String) -> Bool { entries.contains { $0.path == path } }

    public func entry(_ path: String) -> Entry? {
        entries.first { $0.path == path } ?? entries.first { $0.path.lowercased() == path.lowercased() }
    }

    public func read(_ path: String) throws -> Data {
        guard let entry = entry(path) else { throw OrbitError.invalidInput("Missing \(path) in container.") }
        return try read(entry)
    }

    public func read(_ entry: Entry) throws -> Data {
        let local = entry.localHeaderOffset
        guard data.readLE(UInt32.self, at: local) == 0x04034b50 else { throw OrbitError.invalidInput("Corrupt ZIP entry \(entry.path).") }
        let nameLength = Int(data.readLE(UInt16.self, at: local + 26))
        let extraLength = Int(data.readLE(UInt16.self, at: local + 28))
        let start = data.startIndex + local + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.endIndex else { throw OrbitError.invalidInput("Truncated ZIP entry \(entry.path).") }
        let payload = data[start ..< start + entry.compressedSize]
        switch entry.method {
        case 0: return Data(payload)
        case 8:
            guard let inflated = Deflate.decompress(Data(payload), expectedSize: entry.uncompressedSize) else {
                throw OrbitError.invalidInput("Couldn't decompress \(entry.path).")
            }
            return inflated
        default:
            throw OrbitError.unsupported("ZIP compression method \(entry.method)")
        }
    }

    public func readString(_ path: String) throws -> String {
        String(decoding: try read(path), as: UTF8.self)
    }
}

enum Deflate {
    /// Raw DEFLATE (RFC 1951), which is what ZIP stores.
    static func compress(_ input: Data) -> Data? {
        let capacity = input.count + input.count / 10 + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        output.count = written
        return output
    }

    static func decompress(_ input: Data, expectedSize: Int) -> Data? {
        if expectedSize == 0 { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { return nil }
        return output
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFFFFFF
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= count else { return 0 }
        var value: T = 0
        let start = startIndex + offset
        for i in 0..<size { value |= T(self[start + i]) << (8 * i) }
        return value
    }
}

/// XML text helpers.
enum XML {
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                // Drop control characters XML 1.0 forbids.
                if scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r" { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Parses XML into Foundation's DOM. `tidyHTML` lets messy HTML through.
    static func document(_ data: Data, tidyHTML: Bool = false) throws -> XMLDocument {
        do {
            return try XMLDocument(data: data, options: tidyHTML ? [.documentTidyHTML] : [])
        } catch {
            if tidyHTML { throw OrbitError.invalidInput("Couldn't parse the document markup.") }
            return try XMLDocument(data: data, options: [.documentTidyXML])
        }
    }
}

extension XMLNode {
    /// Local element name without namespace prefix, lowercased.
    var tag: String { (localName ?? name ?? "").lowercased() }

    var elementChildren: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }

    /// All descendant elements with a given local name (depth-first, document order).
    func descendants(_ tag: String) -> [XMLElement] {
        var result: [XMLElement] = []
        for child in elementChildren {
            if child.tag == tag { result.append(child) }
            result += child.descendants(tag)
        }
        return result
    }

    func firstDescendant(_ tag: String) -> XMLElement? {
        for child in elementChildren {
            if child.tag == tag { return child }
            if let hit = child.firstDescendant(tag) { return hit }
        }
        return nil
    }

    func child(_ tag: String) -> XMLElement? { elementChildren.first { $0.tag == tag } }
}

extension XMLElement {
    /// Attribute lookup by local name, ignoring prefixes ("r:id" → "id").
    func attr(_ name: String) -> String? {
        if let direct = attribute(forName: name)?.stringValue { return direct }
        for attribute in attributes ?? [] {
            let local = attribute.localName ?? attribute.name ?? ""
            if local == name || attribute.name == name { return attribute.stringValue }
        }
        return nil
    }
}
