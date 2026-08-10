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
//  encryption, no writing. Zip64 is supported read-only because large
//  ChatGPT exports (multi-GB of history) really do arrive in that
//  format and were previously rejected as "unsupported".
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
            return L(
                "The zip archive is damaged and can't be read. Try unzipping it first, then import the JSON files inside."
            )
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
            var compressedSize = Int(u32(bytes, offset + 20))
            let uncompressedSize = u32(bytes, offset + 24)
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
            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF
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
                        if uncompressedSize == 0xFFFF_FFFF {
                            guard cursor + 8 <= fieldEnd else { break }
                            cursor += 8  // uncompressed size, unused here
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
                    compressedSize: compressedSize,
                    localHeaderOffset: localHeaderOffset
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

    private static func u64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        UInt64(u32(bytes, offset)) | UInt64(u32(bytes, offset + 4)) << 32
    }
}
