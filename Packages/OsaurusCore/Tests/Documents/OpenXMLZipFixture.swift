//
//  OpenXMLZipFixture.swift
//
//  Shared in-memory ZIP container writer for OpenXML test fixtures
//  (PPTX / XLSX / DOCX packages). Fixture builders own the XML parts;
//  this owns the ZIP plumbing — local file headers, central directory,
//  end-of-central-directory record, CRC-32, and optional DEFLATE — so the
//  byte-level machinery lives in exactly one place instead of being copied
//  into every adapter / tool test that needs an OpenXML package.
//

import Compression
import Foundation

enum OpenXMLZipFixture {
    /// How each entry's payload is stored in the archive. `.stored` keeps
    /// the bytes verbatim (smallest, dependency-free); `.deflated` exercises
    /// the parser's inflate path and silently falls back to `.stored` when
    /// zlib can't shrink the input.
    enum Compression {
        case stored
        case deflated

        /// Returns the ZIP method code and the bytes to embed for `data`.
        func encoded(_ data: Data) -> (method: UInt16, data: Data) {
            switch self {
            case .stored:
                return (0, data)
            case .deflated:
                var output = [UInt8](repeating: 0, count: max(64, data.count + 64))
                let written = data.withUnsafeBytes { sourceBuffer in
                    guard let source = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                        return 0
                    }
                    return compression_encode_buffer(
                        &output,
                        output.count,
                        source,
                        data.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
                guard written > 0, written < data.count else {
                    return (0, data)
                }
                return (8, Data(output.prefix(written)))
            }
        }
    }

    /// Build the archive bytes for `entries` (path → payload), in order.
    static func archive(
        entries: [(String, Data)],
        compression: Compression = .stored
    ) -> Data {
        var output = Data()
        var centralDirectory = Data()
        var records: [CentralRecord] = []

        for (path, data) in entries {
            let encoded = compression.encoded(data)
            let pathData = Data(path.utf8)
            let checksum = crc32(data)
            let localOffset = UInt32(output.count)

            output.appendUInt32LE(0x0403_4B50)
            output.appendUInt16LE(20)
            output.appendUInt16LE(0)
            output.appendUInt16LE(encoded.method)
            output.appendUInt16LE(0)
            output.appendUInt16LE(0)
            output.appendUInt32LE(checksum)
            output.appendUInt32LE(UInt32(encoded.data.count))
            output.appendUInt32LE(UInt32(data.count))
            output.appendUInt16LE(UInt16(pathData.count))
            output.appendUInt16LE(0)
            output.append(pathData)
            output.append(encoded.data)

            records.append(
                CentralRecord(
                    pathData: pathData,
                    method: encoded.method,
                    crc32: checksum,
                    compressedSize: UInt32(encoded.data.count),
                    uncompressedSize: UInt32(data.count),
                    localOffset: localOffset
                )
            )
        }

        let centralDirectoryOffset = UInt32(output.count)
        for record in records {
            centralDirectory.appendUInt32LE(0x0201_4B50)
            centralDirectory.appendUInt16LE(20)
            centralDirectory.appendUInt16LE(20)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(record.method)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt32LE(record.crc32)
            centralDirectory.appendUInt32LE(record.compressedSize)
            centralDirectory.appendUInt32LE(record.uncompressedSize)
            centralDirectory.appendUInt16LE(UInt16(record.pathData.count))
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt32LE(0)
            centralDirectory.appendUInt32LE(record.localOffset)
            centralDirectory.append(record.pathData)
        }
        output.append(centralDirectory)

        output.appendUInt32LE(0x0605_4B50)
        output.appendUInt16LE(0)
        output.appendUInt16LE(0)
        output.appendUInt16LE(UInt16(records.count))
        output.appendUInt16LE(UInt16(records.count))
        output.appendUInt32LE(UInt32(centralDirectory.count))
        output.appendUInt32LE(centralDirectoryOffset)
        output.appendUInt16LE(0)
        return output
    }

    /// Build the archive and write it to `destination`.
    static func write(
        entries: [(String, Data)],
        to destination: URL,
        compression: Compression = .stored
    ) throws {
        try archive(entries: entries, compression: compression).write(to: destination)
    }

    /// Standard ZIP CRC-32 (polynomial 0xEDB88320).
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private struct CentralRecord {
        let pathData: Data
        let method: UInt16
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localOffset: UInt32
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0x00FF))
        append(UInt8((value >> 8) & 0x00FF))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0x0000_00FF))
        append(UInt8((value >> 8) & 0x0000_00FF))
        append(UInt8((value >> 16) & 0x0000_00FF))
        append(UInt8((value >> 24) & 0x0000_00FF))
    }
}
