//
//  ZipArchiveWriterTests.swift
//  osaurusTests
//
//  The zip writer and in-place rewrite that document edits sit on:
//  round trips (stored + DEFLATE), byte-exact passthrough of untouched
//  entries, delete/append, CRC verification, path safety, and archives
//  the system `unzip` accepts.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ZipArchiveWriterTests {

    private func archive(_ files: [(String, Data)]) throws -> Data {
        var writer = ZipArchiveWriter()
        for (name, data) in files { try writer.add(path: name, data: data) }
        return try writer.finalize()
    }

    private func contents(_ data: Data) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for entry in try ZipArchive.entries(in: data) {
            out[entry.name] = try ZipArchive.extract(entry, from: data, verifyChecksum: true)
        }
        return out
    }

    private let big = Data(String(repeating: "<w:p>hello world</w:p>", count: 400).utf8)
    private let tiny = Data("ok".utf8)
    private let binary = Data((0..<2048).map { UInt8(truncatingIfNeeded: $0 &* 7919) })

    @Test func roundTripsStoredAndDeflatedEntries() throws {
        let zip = try archive([("word/document.xml", big), ("a.txt", tiny), ("media/img.bin", binary), ("empty", Data())])
        let entries = try ZipArchive.entries(in: zip)
        #expect(entries.map(\.name) == ["word/document.xml", "a.txt", "media/img.bin", "empty"])
        #expect(entries[0].method == 8 && entries[0].compressedSize < big.count)
        #expect(entries[1].method == 0)
        #expect(try contents(zip) == ["word/document.xml": big, "a.txt": tiny, "media/img.bin": binary, "empty": Data()])
    }

    /// Streaming zippers set general-purpose flag bit 3 and leave the
    /// local header's CRC/sizes zero (they follow in a data descriptor).
    /// The rewrite writes real values in the header and no descriptor, so
    /// the copied entry must not carry bit 3 — readers would otherwise look
    /// for a descriptor that isn't there.
    @Test func rawPassthroughClearsDataDescriptorFlag() throws {
        var source = try archive([("keep.xml", big), ("edit.xml", tiny)])
        let keep = try #require(try ZipArchive.entries(in: source).first { $0.name == "keep.xml" })
        // Patch the local header: flags |= 8, crc/sizes = 0, and the
        // central directory flags |= 8.
        let local = keep.localHeaderOffset
        source[local + 6] |= 0x08
        for i in 14..<26 { source[local + i] = 0 }
        let eocd = source.count - 22
        let cdOffset = Int(source[eocd + 16]) | Int(source[eocd + 17]) << 8 | Int(source[eocd + 18]) << 16 | Int(source[eocd + 19]) << 24
        source[cdOffset + 8] |= 0x08
        #expect(try ZipArchive.entries(in: source)[0].flags & 0x08 != 0)

        let rewritten = try ZipArchive.rewrite(source, replacing: ["edit.xml": Data("new".utf8)])
        let entries = try ZipArchive.entries(in: rewritten)
        #expect(entries.allSatisfy { $0.flags & 0x08 == 0 })
        let keepAfter = try #require(entries.first { $0.name == "keep.xml" })
        // Local header now carries the real CRC (offset 14) instead of zeros.
        let localCRC = (0..<4).reduce(UInt32(0)) { $0 | UInt32(rewritten[keepAfter.localHeaderOffset + 14 + $1]) << (8 * UInt32($1)) }
        #expect(localCRC == keep.crc32)
        #expect(try contents(rewritten) == ["keep.xml": big, "edit.xml": Data("new".utf8)])
    }

    @Test func rewriteCopiesUntouchedEntriesByteForByte() throws {
        let source = try archive([("keep.xml", big), ("edit.xml", Data("old".utf8)), ("drop.xml", tiny)])
        let rewritten = try ZipArchive.rewrite(
            source,
            replacing: ["edit.xml": Data("new".utf8), "drop.xml": nil, "added/new.xml": big])

        let before = try ZipArchive.entries(in: source)
        let after = try ZipArchive.entries(in: rewritten)
        #expect(after.map(\.name) == ["keep.xml", "edit.xml", "added/new.xml"])
        let keepBefore = try #require(before.first { $0.name == "keep.xml" })
        let keepAfter = try #require(after.first { $0.name == "keep.xml" })
        #expect(try ZipArchive.rawPayload(keepBefore, from: source) == ZipArchive.rawPayload(keepAfter, from: rewritten))
        #expect(keepBefore.crc32 == keepAfter.crc32 && keepBefore.method == keepAfter.method)
        #expect(try contents(rewritten) == ["keep.xml": big, "edit.xml": Data("new".utf8), "added/new.xml": big])
    }

    @Test func checksumVerificationCatchesCorruption() throws {
        var zip = try archive([("a.txt", Data("abcdefgh".utf8))])
        let entry = try #require(try ZipArchive.entries(in: zip).first)
        let payloadStart = entry.localHeaderOffset + 30 + "a.txt".utf8.count
        zip[payloadStart] ^= 0xFF
        #expect(throws: ZipArchiveError.self) {
            try ZipArchive.extract(entry, from: zip, verifyChecksum: true)
        }
        // Passthrough keeps the stored CRC, so the damage stays detectable.
        let rewritten = try ZipArchive.rewrite(zip, replacing: [:])
        let copied = try #require(try ZipArchive.entries(in: rewritten).first)
        #expect(throws: ZipArchiveError.self) {
            try ZipArchive.extract(copied, from: rewritten, verifyChecksum: true)
        }
    }

    @Test func rejectsUnsafeAndDuplicatePaths() throws {
        for bad in ["", "/abs.xml", "../escape.xml", "a/../../b", "a\\b"] {
            var writer = ZipArchiveWriter()
            #expect(throws: ZipArchiveError.self) { try writer.add(path: bad, data: tiny) }
        }
        var writer = ZipArchiveWriter()
        try writer.add(path: "dup.xml", data: tiny)
        #expect(throws: ZipArchiveError.self) { try writer.add(path: "dup.xml", data: tiny) }
        // `..` inside a name segment is fine.
        try writer.add(path: "notes..v2.xml", data: tiny)
    }

    @Test func systemUnzipAcceptsTheArchive() throws {
        let zip = try archive([("word/document.xml", big), ("ünïcode/名前.txt", tiny), ("media/img.bin", binary)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zipw-\(UUID().uuidString).zip")
        try zip.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-tq", url.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
