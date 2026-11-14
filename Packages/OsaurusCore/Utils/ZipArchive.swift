//
//  ZipArchive.swift
//  osaurus
//
//  Minimal zip container support. Reading serves conversation imports
//  (ChatGPT and Google Takeout exports arrive zipped) and OOXML document
//  edits; writing serves the XLSX/PPTX emitters and in-place document
//  edits. Foundation has no zip API, and this is far too small a need to
//  take on a dependency: the reader walks the central directory and
//  inflates entries with the system Compression framework (zip method 8
//  is raw DEFLATE, which is what `NSData.decompressed(using: .zlib)`
//  expects, and what `compressed(using: .zlib)` produces).
//
//  Deliberately not a general zip library — no encryption, and the
//  writer is ZIP32 only (documents never approach 4 GB). Zip64 is
//  supported read-only because large ChatGPT exports (multi-GB of
//  history) really do arrive in that format and were previously rejected
//  as "unsupported".
//

import Foundation

enum ZipArchiveError: LocalizedError {
    case notAnArchive
    case corruptArchive
    case unsupportedEntry(String)
    case checksumMismatch(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAnArchive:
            return L("The file is not a zip archive.")
        case .corruptArchive:
            return L(
                "The zip archive is damaged and can't be read. Try unzipping it first, then import the JSON files inside."
            )
        case .unsupportedEntry(let name):
            return L("The zip entry \"\(name)\" uses an unsupported format.")
        case .checksumMismatch(let name):
            return L("The zip entry \"\(name)\" is damaged (checksum mismatch).")
        case .writeFailed(let reason):
            return L("Couldn't write the zip archive: \(reason)")
        }
    }
}

public enum ZipArchive {

    public struct Entry: Sendable {
        public let name: String
        let method: UInt16
        let flags: UInt16
        let crc32: UInt32
        let compressedSize: Int
        public let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    /// Cheap sniff so callers can branch between raw JSON and zipped
    /// exports without relying on the file extension.
    public static func isArchive(_ data: Data) -> Bool {
        data.count >= 4 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4B
    }

    /// Lists the archive's entries from the central directory.
    public static func entries(in data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        guard isArchive(data) else { throw ZipArchiveError.notAnArchive }

        // End-of-central-directory record: scan backwards over the
        // trailing comment (up to 64 KB) for its signature.
        let eocdSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let scanFloor = max(0, bytes.count - 65_557)
        var eocd: Int? = nil
        var i = bytes.count - 22
        while i >= scanFloor {
            if bytes[i] == 0x50, Array(bytes[i..<i + 4]) == eocdSignature {
                eocd = i
                break
            }
            i -= 1
        }
        guard let eocd else { throw ZipArchiveError.corruptArchive }

        var entryCount = Int(u16(bytes, eocd + 10))
        var offset = Int(u32(bytes, eocd + 16))

        // Zip64: when the classic record's fields saturate, the real
        // values live in a zip64 EOCD record, found via a locator that
        // sits immediately before the classic record.
        if entryCount == 0xFFFF || offset == 0xFFFF_FFFF {
            let locator = eocd - 20
            guard locator >= 0, u32(bytes, locator) == 0x0706_4B50 else {
                throw ZipArchiveError.corruptArchive
            }
            let eocd64 = Int(u64(bytes, locator + 8))
            guard eocd64 + 56 <= bytes.count, u32(bytes, eocd64) == 0x0606_4B50 else {
                throw ZipArchiveError.corruptArchive
            }
            entryCount = Int(u64(bytes, eocd64 + 32))
            offset = Int(u64(bytes, eocd64 + 48))
        }

        var entries: [Entry] = []
        for _ in 0..<entryCount {
            guard offset + 46 <= bytes.count, u32(bytes, offset) == 0x0201_4B50 else {
                throw ZipArchiveError.corruptArchive
            }
            let flags = u16(bytes, offset + 8)
            let method = u16(bytes, offset + 10)
            let crc = u32(bytes, offset + 16)
            var compressedSize = Int(u32(bytes, offset + 20))
            let rawUncompressedSize = u32(bytes, offset + 24)
            var uncompressedSize = Int(rawUncompressedSize)
            let nameLength = Int(u16(bytes, offset + 28))
            let extraLength = Int(u16(bytes, offset + 30))
            let commentLength = Int(u16(bytes, offset + 32))
            var localHeaderOffset = Int(u32(bytes, offset + 42))
            guard offset + 46 + nameLength + extraLength <= bytes.count else {
                throw ZipArchiveError.corruptArchive
            }
            let name =
                String(bytes: bytes[offset + 46..<offset + 46 + nameLength], encoding: .utf8)
                ?? ""

            if flags & 0x1 != 0 {  // bit 0 = encrypted
                throw ZipArchiveError.unsupportedEntry(name)
            }

            // Saturated 32-bit fields defer to the zip64 extra field
            // (id 0x0001): 64-bit values in a fixed order, present only
            // for the fields that saturated.
            if compressedSize == 0xFFFF_FFFF || rawUncompressedSize == 0xFFFF_FFFF
                || localHeaderOffset == 0xFFFF_FFFF
            {
                var extra = offset + 46 + nameLength
                let extraEnd = extra + extraLength
                var found = false
                while extra + 4 <= extraEnd {
                    let fieldId = u16(bytes, extra)
                    let fieldSize = Int(u16(bytes, extra + 2))
                    guard extra + 4 + fieldSize <= extraEnd else { break }
                    if fieldId == 0x0001 {
                        var cursor = extra + 4
                        let fieldEnd = extra + 4 + fieldSize
                        if rawUncompressedSize == 0xFFFF_FFFF {
                            guard cursor + 8 <= fieldEnd else { break }
                            uncompressedSize = Int(u64(bytes, cursor))
                            cursor += 8
                        }
                        if compressedSize == 0xFFFF_FFFF {
                            guard cursor + 8 <= fieldEnd else { break }
                            compressedSize = Int(u64(bytes, cursor))
                            cursor += 8
                        }
                        if localHeaderOffset == 0xFFFF_FFFF {
                            guard cursor + 8 <= fieldEnd else { break }
                            localHeaderOffset = Int(u64(bytes, cursor))
                            cursor += 8
                        }
                        found = true
                        break
                    }
                    extra += 4 + fieldSize
                }
                guard found, compressedSize != 0xFFFF_FFFF, localHeaderOffset != 0xFFFF_FFFF
                else {
                    throw ZipArchiveError.unsupportedEntry(name)
                }
            }

            entries.append(
                Entry(
                    name: name,
                    method: method,
                    flags: flags,
                    crc32: crc,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localHeaderOffset
                )
            )
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Extracts one entry's contents. Supports stored (0) and DEFLATE (8).
    /// `verifyChecksum` rejects entries whose bytes don't match their CRC —
    /// document edits use it so a damaged part is never rewritten as valid.
    public static func extract(_ entry: Entry, from data: Data, verifyChecksum: Bool = false) throws -> Data {
        let raw = try rawPayload(entry, from: data)
        let out: Data
        switch entry.method {
        case 0:
            out = raw
        case 8:
            if raw.isEmpty && entry.uncompressedSize == 0 {
                out = Data()
                break
            }
            do {
                out = try (raw as NSData).decompressed(using: .zlib) as Data
            } catch {
                throw ZipArchiveError.corruptArchive
            }
        default:
            throw ZipArchiveError.unsupportedEntry(entry.name)
        }
        if verifyChecksum, ZipCRC32.checksum(out) != entry.crc32 {
            throw ZipArchiveError.checksumMismatch(entry.name)
        }
        return out
    }

    /// The entry's stored bytes exactly as they sit in the archive (still
    /// compressed), for copying untouched entries into a rewritten archive.
    static func rawPayload(_ entry: Entry, from data: Data) throws -> Data {
        let offset = entry.localHeaderOffset
        guard offset >= 0, offset + 30 <= data.count else { throw ZipArchiveError.corruptArchive }
        let base = data.startIndex
        func le16(_ at: Int) -> Int { Int(data[base + at]) | Int(data[base + at + 1]) << 8 }
        guard le16(offset) == 0x4B50, le16(offset + 2) == 0x0403 else {
            throw ZipArchiveError.corruptArchive
        }
        // The local header's name/extra lengths can differ from the
        // central directory's, so re-read them here.
        let nameLength = le16(offset + 26)
        let extraLength = le16(offset + 28)
        let start = offset + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.count else {
            throw ZipArchiveError.corruptArchive
        }
        return data.subdata(in: base + start..<base + start + entry.compressedSize)
    }

    /// Rewrite an archive: entries named in `replacing` get new contents
    /// (nil deletes them), every other entry is copied byte-for-byte
    /// (compressed payload, CRC and all) in its original order, and names
    /// in `replacing` that weren't in the source are appended in `order`
    /// (or sorted). Untouched parts survive exactly, which is what keeps
    /// an in-place document edit from disturbing anything it didn't mean to.
    public static func rewrite(
        _ source: Data,
        replacing: [String: Data?],
        appendOrder: [String]? = nil
    ) throws -> Data {
        let entries = try entries(in: source)
        var writer = ZipArchiveWriter()
        var seen = Set<String>()
        for entry in entries {
            seen.insert(entry.name)
            if let replacement = replacing[entry.name] {
                if let data = replacement {
                    try writer.add(path: entry.name, data: data)
                }
            } else {
                try writer.addRaw(entry, from: source)
            }
        }
        let additions = (appendOrder ?? replacing.keys.sorted()).filter { !seen.contains($0) }
        for name in additions {
            if case .some(.some(let data)) = replacing[name] {
                try writer.add(path: name, data: data)
            }
        }
        return try writer.finalize()
    }

    // MARK: - Little-endian reads

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func u64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        UInt64(u32(bytes, offset)) | UInt64(u32(bytes, offset + 4)) << 32
    }
}

// MARK: - Writer

/// Builds a ZIP32 archive. New entries are DEFLATE-compressed when that
/// saves space (stored otherwise, or always when `compress` is false —
/// e.g. an ODF `mimetype` that must lead the archive uncompressed);
/// `addRaw` copies an entry from another archive without recompressing.
public struct ZipArchiveWriter {
    private struct CentralEntry {
        let name: Data
        let method: UInt16
        let flags: UInt16
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
    }

    private var archive = Data()
    private var central: [CentralEntry] = []
    private var names = Set<String>()

    public init() {}

    public mutating func add(path: String, data: Data, compress: Bool = true) throws {
        var method: UInt16 = 0
        var payload = data
        if compress, data.count > 64,
            let deflated = try? (data as NSData).compressed(using: .zlib) as Data,
            deflated.count < data.count
        {
            method = 8
            payload = deflated
        }
        try append(
            path: path, method: method, crc32: ZipCRC32.checksum(data),
            payload: payload, uncompressedSize: data.count)
    }

    /// Copy `entry` from `source` exactly as stored (no inflate/deflate).
    public mutating func addRaw(_ entry: ZipArchive.Entry, from source: Data) throws {
        guard entry.method == 0 || entry.method == 8 else {
            throw ZipArchiveError.unsupportedEntry(entry.name)
        }
        let payload = try ZipArchive.rawPayload(entry, from: source)
        try append(
            path: entry.name, method: entry.method, crc32: entry.crc32,
            payload: payload, uncompressedSize: entry.uncompressedSize)
    }

    public mutating func finalize() throws -> Data {
        var directory = Data()
        for entry in central {
            directory.appendLE32(0x0201_4B50)
            directory.appendLE16(20)  // version made by
            directory.appendLE16(20)  // version needed
            directory.appendLE16(entry.flags)
            directory.appendLE16(entry.method)
            directory.appendLE16(0)  // mod time
            directory.appendLE16(0x21)  // mod date: 1980-01-01
            directory.appendLE32(entry.crc32)
            directory.appendLE32(entry.compressedSize)
            directory.appendLE32(entry.uncompressedSize)
            directory.appendLE16(UInt16(entry.name.count))
            directory.appendLE16(0)  // extra
            directory.appendLE16(0)  // comment
            directory.appendLE16(0)  // disk
            directory.appendLE16(0)  // internal attrs
            directory.appendLE32(0)  // external attrs
            directory.appendLE32(entry.localHeaderOffset)
            directory.append(entry.name)
        }
        let directoryOffset = try Self.u32(archive.count, "central directory offset")
        let directorySize = try Self.u32(directory.count, "central directory size")
        guard central.count <= Int(UInt16.max) else {
            throw ZipArchiveError.writeFailed("too many entries")
        }
        var out = archive
        out.append(directory)
        out.appendLE32(0x0605_4B50)
        out.appendLE16(0)
        out.appendLE16(0)
        out.appendLE16(UInt16(central.count))
        out.appendLE16(UInt16(central.count))
        out.appendLE32(directorySize)
        out.appendLE32(directoryOffset)
        out.appendLE16(0)
        return out
    }

    private mutating func append(
        path: String, method: UInt16, crc32: UInt32, payload: Data, uncompressedSize: Int
    ) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
            !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        else {
            throw ZipArchiveError.writeFailed("invalid entry path '\(path)'")
        }
        guard names.insert(path).inserted else {
            throw ZipArchiveError.writeFailed("duplicate entry '\(path)'")
        }
        let name = Data(path.utf8)
        guard name.count <= Int(UInt16.max) else {
            throw ZipArchiveError.writeFailed("entry name too long")
        }
        let isASCII = path.utf8.allSatisfy { $0 < 0x80 }
        let flags: UInt16 = isASCII ? 0 : 0x0800  // bit 11: UTF-8 name
        let offset = try Self.u32(archive.count, "local header offset")
        let compressedSize = try Self.u32(payload.count, "\(path) size")
        let size = try Self.u32(uncompressedSize, "\(path) size")

        archive.appendLE32(0x0403_4B50)
        archive.appendLE16(20)
        archive.appendLE16(flags)
        archive.appendLE16(method)
        archive.appendLE16(0)
        archive.appendLE16(0x21)
        archive.appendLE32(crc32)
        archive.appendLE32(compressedSize)
        archive.appendLE32(size)
        archive.appendLE16(UInt16(name.count))
        archive.appendLE16(0)
        archive.append(name)
        archive.append(payload)

        central.append(
            CentralEntry(
                name: name, method: method, flags: flags, crc32: crc32,
                compressedSize: compressedSize, uncompressedSize: size,
                localHeaderOffset: offset))
    }

    private static func u32(_ value: Int, _ label: String) throws -> UInt32 {
        guard value >= 0, value <= Int(UInt32.max) else {
            throw ZipArchiveError.writeFailed("\(label) exceeds ZIP32 limits")
        }
        return UInt32(value)
    }
}

// MARK: - CRC-32

enum ZipCRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            table.withUnsafeBufferPointer { t in
                for byte in raw {
                    crc = (crc >> 8) ^ t[Int((crc ^ UInt32(byte)) & 0xFF)]
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE16(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    mutating func appendLE32(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ])
    }
}
