import CryptoKit
import Foundation
import XCTest

@testable import OsaurusRepository

final class BoundedArchiveExtractorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-archive-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func test_extractsNormalArchiveAndPublishesCompleteTree() throws {
        let archive = try makeArchive(
            entries: [
                .directory("plugin/"),
                .file("plugin/Plugin.dylib", Data("binary".utf8)),
                .file("plugin/README.md", Data("docs".utf8)),
            ]
        )
        let destination = root.appendingPathComponent("output", isDirectory: true)

        try BoundedArchiveExtractor.extract(archive: archive, to: destination, policy: .plugin)

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("plugin/Plugin.dylib")),
            Data("binary".utf8)
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("plugin/README.md"), encoding: .utf8),
            "docs"
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertTrue(try extractionStagingEntries().isEmpty)
    }

    func test_successfulExtractionAtomicallyReplacesExistingDestination() throws {
        let archive = try makeArchive(entries: [.file("new.txt", Data("new".utf8))])
        let destination = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("old.txt"))

        try BoundedArchiveExtractor.extract(archive: archive, to: destination, policy: .plugin)

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("old.txt").path))
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("new.txt"), encoding: .utf8),
            "new"
        )
        XCTAssertTrue(try extractionStagingEntries().isEmpty)
    }

    func test_allowsExplicitDirectoryAfterImplicitParentCreation() throws {
        let archive = try makeArchive(
            entries: [
                .file("plugin/readme.txt", Data("content".utf8)),
                .directory("plugin/"),
            ]
        )
        let destination = root.appendingPathComponent("output")

        try BoundedArchiveExtractor.extract(archive: archive, to: destination, policy: .plugin)

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("plugin/readme.txt"), encoding: .utf8),
            "content"
        )
    }

    func test_rejectsTraversalAndDoesNotWriteOutsideDestination() throws {
        let archive = try makeArchive(entries: [.file("../escaped.txt", Data("owned".utf8))])
        let destination = root.appendingPathComponent("output", isDirectory: true)

        XCTAssertThrowsError(
            try BoundedArchiveExtractor.extract(archive: archive, to: destination, policy: .plugin)
        ) { error in
            XCTAssertTrue(error is ArchiveExtractionError)
            XCTAssertTrue(error.localizedDescription.contains("unsafe path"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try extractionStagingEntries().isEmpty)
    }

    func test_rejectsAbsoluteAndBackslashPaths() throws {
        for path in ["/tmp/escaped", "..\\escaped", "C:/escaped"] {
            let archive = try makeArchive(entries: [.file(path, Data())])
            XCTAssertThrowsError(
                try BoundedArchiveExtractor.extract(
                    archive: archive,
                    to: root.appendingPathComponent(UUID().uuidString),
                    policy: .plugin
                )
            )
        }
    }

    func test_rejectsCanonicalUnicodeAndCaseCollisions() throws {
        let archive = try makeArchive(
            entries: [
                .file("Plugin/é.txt", Data("one".utf8)),
                .file("plugin/e\u{301}.TXT", Data("two".utf8)),
            ]
        )

        XCTAssertThrowsError(
            try BoundedArchiveExtractor.extract(
                archive: archive,
                to: root.appendingPathComponent("output"),
                policy: .plugin
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("colliding path"))
        }
    }

    func test_rejectsUnicodeLineAndParagraphSeparatorsAndSanitizesError() throws {
        for separator in ["\u{2028}", "\u{2029}"] {
            let archive = try makeArchive(
                entries: [.file("plugin/before\(separator)after.txt", Data())]
            )

            XCTAssertThrowsError(
                try BoundedArchiveExtractor.extract(
                    archive: archive,
                    to: root.appendingPathComponent(UUID().uuidString),
                    policy: .plugin
                )
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("unsafe path syntax"))
                XCTAssertFalse(error.localizedDescription.contains(separator))
                XCTAssertTrue(error.localizedDescription.contains("before?after"))
            }
        }
    }

    func test_rejectsSymlinkBeforeExtraction() throws {
        let archive = try makeArchive(
            entries: [.symlink("plugin/Plugin.dylib", destination: "../../outside")]
        )

        XCTAssertThrowsError(
            try BoundedArchiveExtractor.extract(
                archive: archive,
                to: root.appendingPathComponent("output"),
                policy: .plugin
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("symbolic links"))
        }
        XCTAssertTrue(try extractionStagingEntries().isEmpty)
    }

    func test_rejectsNonUnixCreatorSymlinkMode() throws {
        let archive = try makeArchive(
            entries: [
                .symlink(
                    "plugin/Plugin.dylib",
                    destination: "../../outside",
                    creatorSystem: 0
                )
            ]
        )

        XCTAssertThrowsError(
            try BoundedArchiveExtractor.extract(
                archive: archive,
                to: root.appendingPathComponent("output"),
                policy: .plugin
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("symbolic links"))
        }
    }

    func test_rejectsUnicodePathOverrideExtraField() throws {
        var extra = Data()
        extra.appendLittleEndian(UInt16(0x7075))
        extra.appendLittleEndian(UInt16(1))
        extra.append(1)
        let archive = try makeArchive(
            entries: [.file("plugin/safe.txt", Data("safe".utf8), extra: extra)]
        )

        XCTAssertThrowsError(
            try BoundedArchiveExtractor.extract(
                archive: archive,
                to: root.appendingPathComponent("output"),
                policy: .plugin
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Unicode path override"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("output").path))
    }

    func test_rejectsSpecialFilesystemEntries() throws {
        let archive = try makeArchive(entries: [.special("plugin/socket", mode: 0o140755)])

        XCTAssertThrowsError(
            try BoundedArchiveExtractor.extract(
                archive: archive,
                to: root.appendingPathComponent("output"),
                policy: .plugin
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("special filesystem entries"))
        }
    }

    func test_allowsSmallRepetitiveDeflateBelowRatioFloor() throws {
        let source = root.appendingPathComponent("zeros.bin")
        try Data(repeating: 0, count: 1_048_576).write(to: source)
        let archive = root.appendingPathComponent("small-repetitive.zip")
        try run("/usr/bin/zip", arguments: ["-q", archive.path, source.lastPathComponent], directory: root)
        let destination = root.appendingPathComponent("output")

        try BoundedArchiveExtractor.extract(archive: archive, to: destination, policy: .plugin)

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("zeros.bin")).count,
            1_048_576
        )
    }

    func test_rejectsLargeDecompressionRatioAboveFloor() throws {
        let source = root.appendingPathComponent("zeros-large.bin")
        try Data(repeating: 0, count: 5 * 1_048_576).write(to: source)
        let archive = root.appendingPathComponent("ratio-bomb.zip")
        try run("/usr/bin/zip", arguments: ["-q", archive.path, source.lastPathComponent], directory: root)

        XCTAssertThrowsError(
            try BoundedArchiveExtractor.extract(
                archive: archive,
                to: root.appendingPathComponent("output"),
                policy: .plugin
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("decompression ratio"))
        }
    }

    func test_rejectsExpandedByteAndFileCountBudgets() throws {
        let archive = try makeArchive(
            entries: [
                .file("one", Data(repeating: 1, count: 8)),
                .file("two", Data(repeating: 2, count: 8)),
            ]
        )
        var policy = ArchiveExtractionPolicy.plugin
        policy.maximumExpandedBytes = 15
        XCTAssertThrowsError(
            try BoundedArchiveExtractor.extract(
                archive: archive,
                to: root.appendingPathComponent("bytes"),
                policy: policy
            )
        )

        policy = .plugin
        policy.maximumFileCount = 1
        XCTAssertThrowsError(
            try BoundedArchiveExtractor.extract(
                archive: archive,
                to: root.appendingPathComponent("count"),
                policy: policy
            )
        )
    }

    func test_rejectsPathDepthAndComponentLengthBudgets() throws {
        var policy = ArchiveExtractionPolicy.plugin
        policy.maximumPathDepth = 2
        let deep = try makeArchive(entries: [.file("a/b/c", Data())])
        XCTAssertThrowsError(
            try BoundedArchiveExtractor.extract(
                archive: deep,
                to: root.appendingPathComponent("deep"),
                policy: policy
            )
        )

        policy = .plugin
        policy.maximumComponentBytes = 3
        let long = try makeArchive(entries: [.file("four", Data())])
        XCTAssertThrowsError(
            try BoundedArchiveExtractor.extract(
                archive: long,
                to: root.appendingPathComponent("long"),
                policy: policy
            )
        )
    }

    func test_rejectsTruncatedListingAndPreservesExistingDestination() throws {
        let valid = try makeArchive(entries: [.file("file", Data("value".utf8))])
        var truncated = try Data(contentsOf: valid)
        truncated.removeLast(12)
        let archive = root.appendingPathComponent("truncated.zip")
        try truncated.write(to: archive)
        let destination = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)

        XCTAssertThrowsError(
            try BoundedArchiveExtractor.extract(archive: archive, to: destination, policy: .plugin)
        )
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
        XCTAssertTrue(try extractionStagingEntries().isEmpty)
    }

    func test_rejectsLocalHeaderThatDisagreesWithCentralListing() throws {
        let valid = try makeArchive(entries: [.file("file", Data("value".utf8))])
        var corrupted = try Data(contentsOf: valid)
        corrupted[14] ^= 0xff
        let archive = root.appendingPathComponent("mismatched-local-header.zip")
        try corrupted.write(to: archive)

        XCTAssertThrowsError(
            try BoundedArchiveExtractor.extract(
                archive: archive,
                to: root.appendingPathComponent("output"),
                policy: .plugin
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("local and central"))
        }
    }

    func test_rejectsReusedLocalHeaderRegion() throws {
        let archive = try makeArchive(
            entries: [
                .file("same", Data("first".utf8)),
                .file("same", Data("second".utf8)),
            ]
        )
        var data = try Data(contentsOf: archive)
        let central = Int(data.uint32(at: data.count - 6))
        let firstNameLength = Int(data.uint16(at: central + 28))
        let firstExtraLength = Int(data.uint16(at: central + 30))
        let firstCommentLength = Int(data.uint16(at: central + 32))
        let secondCentral = central + 46 + firstNameLength + firstExtraLength + firstCommentLength
        data.replaceLittleEndian(UInt32(0), at: secondCentral + 42)
        try data.write(to: archive)

        XCTAssertThrowsError(
            try BoundedArchiveExtractor.extract(
                archive: archive,
                to: root.appendingPathComponent("output"),
                policy: .plugin
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("overlap or reuse"))
        }
    }

    func test_streamingDeflateRejectsUnderdeclaredOutputBeforePublication() throws {
        let source = root.appendingPathComponent("underdeclared.bin")
        try Data(repeating: 0x41, count: 1_048_576).write(to: source)
        let archive = root.appendingPathComponent("underdeclared.zip")
        try run("/usr/bin/zip", arguments: ["-q", archive.path, source.lastPathComponent], directory: root)
        try patchDeclaredExpandedSize(in: archive, to: 1_024)
        let destination = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)

        XCTAssertThrowsError(
            try BoundedArchiveExtractor.extract(archive: archive, to: destination, policy: .plugin)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("more than its declared size"))
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
        XCTAssertTrue(try extractionStagingEntries().isEmpty)
    }

    func test_rejectsCRCFailureAndCleansStaging() throws {
        let archive = try makeArchive(entries: [.file("file", Data("value".utf8))])
        var data = try Data(contentsOf: archive)
        let nameLength = Int(data.uint16(at: 26))
        let extraLength = Int(data.uint16(at: 28))
        data[30 + nameLength + extraLength] ^= 0xff
        try data.write(to: archive)

        XCTAssertThrowsError(
            try BoundedArchiveExtractor.extract(
                archive: archive,
                to: root.appendingPathComponent("output"),
                policy: .plugin
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("CRC"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("output").path))
        XCTAssertTrue(try extractionStagingEntries().isEmpty)
    }

    func test_rejectsTrailingBytesAfterDeflateStream() throws {
        let source = root.appendingPathComponent("deflated.txt")
        try Data(repeating: 0x41, count: 128 * 1024).write(to: source)
        let archive = root.appendingPathComponent("trailing-deflate.zip")
        try run("/usr/bin/zip", arguments: ["-q", archive.path, source.lastPathComponent], directory: root)
        try appendTrailingCompressedByte(to: archive)

        XCTAssertThrowsError(
            try BoundedArchiveExtractor.extract(
                archive: archive,
                to: root.appendingPathComponent("output"),
                policy: .plugin
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("exact compressed range"))
        }
    }

    func test_rejectsStoredSizeMismatch() throws {
        let archive = try makeArchive(entries: [.file("file", Data("value".utf8))])
        var data = try Data(contentsOf: archive)
        let central = Int(data.uint32(at: data.count - 6))
        data.replaceLittleEndian(UInt32(4), at: 18)
        data.replaceLittleEndian(UInt32(4), at: central + 20)
        try data.write(to: archive)

        XCTAssertThrowsError(
            try BoundedArchiveExtractor.extract(
                archive: archive,
                to: root.appendingPathComponent("output"),
                policy: .plugin
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("stored entry"))
        }
    }

    func test_rejectsEncryptedUnsupportedAndZip64Metadata() throws {
        let encrypted = try makeArchive(entries: [.file("encrypted", Data())])
        try patchFlags(in: encrypted, flags: 0x0801)
        XCTAssertThrowsError(
            try BoundedArchiveExtractor.extract(
                archive: encrypted,
                to: root.appendingPathComponent("encrypted-output"),
                policy: .plugin
            )
        )

        let unsupported = try makeArchive(entries: [.file("unsupported", Data())])
        try patchMethod(in: unsupported, method: 99)
        XCTAssertThrowsError(
            try BoundedArchiveExtractor.extract(
                archive: unsupported,
                to: root.appendingPathComponent("unsupported-output"),
                policy: .plugin
            )
        )

        var zip64Extra = Data()
        zip64Extra.appendLittleEndian(UInt16(0x0001))
        zip64Extra.appendLittleEndian(UInt16(0))
        let zip64 = try makeArchive(entries: [.file("zip64", Data(), extra: zip64Extra)])
        XCTAssertThrowsError(
            try BoundedArchiveExtractor.extract(
                archive: zip64,
                to: root.appendingPathComponent("zip64-output"),
                policy: .plugin
            )
        )
    }

    func test_expectedArchiveHashBindsInspectedBytes() throws {
        let archive = try makeArchive(entries: [.file("file", Data("value".utf8))])
        let data = try Data(contentsOf: archive)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        XCTAssertNoThrow(
            try BoundedArchiveExtractor.extract(
                archive: archive,
                to: root.appendingPathComponent("valid"),
                policy: .plugin,
                expectedSHA256: digest
            )
        )
        XCTAssertThrowsError(
            try BoundedArchiveExtractor.extract(
                archive: archive,
                to: root.appendingPathComponent("mismatch"),
                policy: .plugin,
                expectedSHA256: String(repeating: "0", count: 64)
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("SHA-256"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("mismatch").path))
    }

    func test_acceptsStoredEntryWithDataDescriptor() throws {
        let archive = try makeArchive(
            entries: [
                .file("descriptor.txt", Data("descriptor".utf8), usesDataDescriptor: true)
            ]
        )
        let destination = root.appendingPathComponent("output")

        try BoundedArchiveExtractor.extract(archive: archive, to: destination, policy: .plugin)

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("descriptor.txt"), encoding: .utf8),
            "descriptor"
        )
    }

    func test_stripsSetIDBitsAndPreservesSafeExecutablePermissions() throws {
        let archive = try makeArchive(
            entries: [
                .file("script", Data("#!/bin/sh".utf8), mode: 0o106777)
            ]
        )
        let destination = root.appendingPathComponent("output")

        try BoundedArchiveExtractor.extract(archive: archive, to: destination, policy: .plugin)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: destination.appendingPathComponent("script").path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    private func extractionStagingEntries() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".extracting-") }
    }

    private func makeArchive(entries: [ZipEntry]) throws -> URL {
        var local = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            let offset = UInt32(local.count)
            let crc = crc32(entry.contents)
            let flags: UInt16 = entry.usesDataDescriptor ? 0x0808 : 0x0800
            local.appendLittleEndian(UInt32(0x0403_4b50))
            local.appendLittleEndian(UInt16(20))
            local.appendLittleEndian(flags)
            local.appendLittleEndian(UInt16(0))
            local.appendLittleEndian(UInt16(0))
            local.appendLittleEndian(UInt16(0))
            local.appendLittleEndian(entry.usesDataDescriptor ? UInt32(0) : crc)
            local.appendLittleEndian(entry.usesDataDescriptor ? UInt32(0) : UInt32(entry.contents.count))
            local.appendLittleEndian(entry.usesDataDescriptor ? UInt32(0) : UInt32(entry.contents.count))
            local.appendLittleEndian(UInt16(name.count))
            local.appendLittleEndian(UInt16(entry.extra.count))
            local.append(name)
            local.append(entry.extra)
            local.append(entry.contents)
            if entry.usesDataDescriptor {
                local.appendLittleEndian(UInt32(0x0807_4b50))
                local.appendLittleEndian(crc)
                local.appendLittleEndian(UInt32(entry.contents.count))
                local.appendLittleEndian(UInt32(entry.contents.count))
            }

            central.appendLittleEndian(UInt32(0x0201_4b50))
            central.appendLittleEndian(UInt16((Int(entry.creatorSystem) << 8) | 20))
            central.appendLittleEndian(UInt16(20))
            central.appendLittleEndian(flags)
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(crc)
            central.appendLittleEndian(UInt32(entry.contents.count))
            central.appendLittleEndian(UInt32(entry.contents.count))
            central.appendLittleEndian(UInt16(name.count))
            central.appendLittleEndian(UInt16(entry.extra.count))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt32(entry.mode) << 16)
            central.appendLittleEndian(offset)
            central.append(name)
            central.append(entry.extra)
        }

        var archive = local
        archive.append(central)
        archive.appendLittleEndian(UInt32(0x0605_4b50))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(UInt32(central.count))
        archive.appendLittleEndian(UInt32(local.count))
        archive.appendLittleEndian(UInt16(0))
        let url = root.appendingPathComponent("\(UUID().uuidString).zip")
        try archive.write(to: url)
        return url
    }

    private func patchDeclaredExpandedSize(in archive: URL, to size: UInt32) throws {
        var data = try Data(contentsOf: archive)
        let eocd = data.count - 22
        let central = Int(data.uint32(at: eocd + 16))
        data.replaceLittleEndian(size, at: central + 24)
        let flags = data.uint16(at: 6)
        if flags & 0x8 == 0 {
            data.replaceLittleEndian(size, at: 22)
        } else {
            let nameLength = Int(data.uint16(at: 26))
            let extraLength = Int(data.uint16(at: 28))
            let compressedSize = Int(data.uint32(at: central + 20))
            var descriptor = 30 + nameLength + extraLength + compressedSize
            if data.uint32(at: descriptor) == 0x0807_4b50 { descriptor += 4 }
            data.replaceLittleEndian(size, at: descriptor + 8)
        }
        try data.write(to: archive)
    }

    private func patchFlags(in archive: URL, flags: UInt16) throws {
        var data = try Data(contentsOf: archive)
        let central = Int(data.uint32(at: data.count - 6))
        data.replaceLittleEndian(flags, at: 6)
        data.replaceLittleEndian(flags, at: central + 8)
        try data.write(to: archive)
    }

    private func patchMethod(in archive: URL, method: UInt16) throws {
        var data = try Data(contentsOf: archive)
        let central = Int(data.uint32(at: data.count - 6))
        data.replaceLittleEndian(method, at: 8)
        data.replaceLittleEndian(method, at: central + 10)
        try data.write(to: archive)
    }

    private func appendTrailingCompressedByte(to archive: URL) throws {
        var data = try Data(contentsOf: archive)
        let oldEOCD = data.count - 22
        let oldCentral = Int(data.uint32(at: oldEOCD + 16))
        XCTAssertEqual(data.uint16(at: 6) & 0x8, 0, "Fixture must use local sizes")
        let nameLength = Int(data.uint16(at: 26))
        let extraLength = Int(data.uint16(at: 28))
        let oldCompressedSize = data.uint32(at: 18)
        let insertion = 30 + nameLength + extraLength + Int(oldCompressedSize)
        data.insert(0, at: insertion)
        let newCentral = oldCentral + 1
        let newEOCD = oldEOCD + 1
        data.replaceLittleEndian(oldCompressedSize + 1, at: 18)
        data.replaceLittleEndian(oldCompressedSize + 1, at: newCentral + 20)
        data.replaceLittleEndian(UInt32(newCentral), at: newEOCD + 16)
        try data.write(to: archive)
    }

    private func run(_ executable: String, arguments: [String], directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1)))
            }
        }
        return ~crc
    }
}

private struct ZipEntry {
    let path: String
    let contents: Data
    let mode: UInt16
    let extra: Data
    let creatorSystem: UInt8
    let usesDataDescriptor: Bool

    static func file(
        _ path: String,
        _ contents: Data,
        extra: Data = Data(),
        usesDataDescriptor: Bool = false,
        mode: UInt16 = 0o100644
    ) -> Self {
        Self(
            path: path,
            contents: contents,
            mode: mode,
            extra: extra,
            creatorSystem: 3,
            usesDataDescriptor: usesDataDescriptor
        )
    }

    static func directory(_ path: String) -> Self {
        Self(
            path: path,
            contents: Data(),
            mode: 0o040755,
            extra: Data(),
            creatorSystem: 3,
            usesDataDescriptor: false
        )
    }

    static func symlink(_ path: String, destination: String, creatorSystem: UInt8 = 3) -> Self {
        Self(
            path: path,
            contents: Data(destination.utf8),
            mode: 0o120777,
            extra: Data(),
            creatorSystem: creatorSystem,
            usesDataDescriptor: false
        )
    }

    static func special(_ path: String, mode: UInt16) -> Self {
        Self(
            path: path,
            contents: Data(),
            mode: mode,
            extra: Data(),
            creatorSystem: 3,
            usesDataDescriptor: false
        )
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    mutating func replaceLittleEndian<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        var replacement = Data()
        replacement.appendLittleEndian(value)
        replaceSubrange(offset..<(offset + replacement.count), with: replacement)
    }
}
