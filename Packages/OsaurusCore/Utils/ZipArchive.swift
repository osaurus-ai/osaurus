//
//  ZipArchive.swift
//  osaurus
//
//  Minimal read-only zip container support for conversation imports
//  (ChatGPT and Google Takeout exports arrive zipped). Foundation has
//  no zip API, and this is far too small a need to take on a dependency:
//  the reader walks the central directory and inflates entries with the
//  system Compression framework (zip method 8 is raw DEFLATE, which is
//  what `NSData.decompressed(using: .zlib)` expects).
//
//  Deliberately not a general zip library — no CRC verification, no
//  encryption, no zip64 (a >4 GB chat export is not a real case), no
//  writing.
//

import Foundation

enum ZipArchiveError: LocalizedError {
    case notAnArchive
    case corruptArchive
    case unsupportedEntry(String)

    var errorDescription: String? {
        switch self {
        case .notAnArchive:
            return L("The file is not a zip archive.")
        case .corruptArchive:
            return L("The zip archive is damaged and can't be read.")
        case .unsupportedEntry(let name):
            return L("The zip entry \"\(name)\" uses an unsupported format.")
        }
    }
}

public enum ZipArchive {

    public struct Entry: Sendable {
        public let name: String
        let method: UInt16
        let compressedSize: Int
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

        let entryCount = Int(u16(bytes, eocd + 10))
        var offset = Int(u32(bytes, eocd + 16))

        var entries: [Entry] = []
        for _ in 0..<entryCount {
            guard offset + 46 <= bytes.count, u32(bytes, offset) == 0x0201_4B50 else {
                throw ZipArchiveError.corruptArchive
            }
            let flags = u16(bytes, offset + 8)
            let method = u16(bytes, offset + 10)
            let compressedSize = u32(bytes, offset + 20)
            let uncompressedSize = u32(bytes, offset + 24)
            let nameLength = Int(u16(bytes, offset + 28))
            let extraLength = Int(u16(bytes, offset + 30))
            let commentLength = Int(u16(bytes, offset + 32))
            let localHeaderOffset = u32(bytes, offset + 42)
            guard offset + 46 + nameLength <= bytes.count else {
                throw ZipArchiveError.corruptArchive
            }
            let name =
                String(bytes: bytes[offset + 46..<offset + 46 + nameLength], encoding: .utf8)
                ?? ""

            // Bit 0 = encrypted; 0xFFFFFFFF sizes/offset = zip64.
            if flags & 0x1 != 0 || compressedSize == 0xFFFF_FFFF
                || uncompressedSize == 0xFFFF_FFFF || localHeaderOffset == 0xFFFF_FFFF
            {
                throw ZipArchiveError.unsupportedEntry(name)
            }

            entries.append(
                Entry(
                    name: name,
                    method: method,
                    compressedSize: Int(compressedSize),
                    localHeaderOffset: Int(localHeaderOffset)
                )
            )
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Extracts one entry's contents. Supports stored (0) and DEFLATE (8).
    public static func extract(_ entry: Entry, from data: Data) throws -> Data {
        let bytes = [UInt8](data)
        let offset = entry.localHeaderOffset
        guard offset + 30 <= bytes.count, u32(bytes, offset) == 0x0403_4B50 else {
            throw ZipArchiveError.corruptArchive
        }
        // The local header's name/extra lengths can differ from the
        // central directory's, so re-read them here.
        let nameLength = Int(u16(bytes, offset + 26))
        let extraLength = Int(u16(bytes, offset + 28))
        let start = offset + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= bytes.count else {
            throw ZipArchiveError.corruptArchive
        }
        let raw = data.subdata(
            in: data.startIndex + start..<data.startIndex + start + entry.compressedSize
        )
        switch entry.method {
        case 0:
            return raw
        case 8:
            do {
                return try (raw as NSData).decompressed(using: .zlib) as Data
            } catch {
                throw ZipArchiveError.corruptArchive
            }
        default:
            throw ZipArchiveError.unsupportedEntry(entry.name)
        }
    }

    // MARK: - Little-endian reads

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
