//
//  BoundedArchiveExtractor.swift
//  OsaurusRepository
//
//  Validates ZIP metadata, inflates bounded streams in-process, then verifies the
//  staged filesystem tree before publishing it atomically.
//

import Darwin
import CryptoKit
import Foundation
import zlib

enum ArchiveExtractionError: Error, Equatable, LocalizedError {
    case malformed(String)
    case unsupported(String)
    case unsafePath(String)
    case unsafeEntry(String)
    case resourceLimit(String)
    case extractionFailed(Int32, String)
    case verificationFailed(String)
    case publicationFailed(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let detail): "Archive metadata is malformed: \(detail)"
        case .unsupported(let detail): "Archive uses an unsupported ZIP feature: \(detail)"
        case .unsafePath(let detail): "Archive contains an unsafe path: \(detail)"
        case .unsafeEntry(let detail): "Archive contains an unsafe entry: \(detail)"
        case .resourceLimit(let detail): "Archive exceeds the extraction safety budget: \(detail)"
        case .extractionFailed(let status, let detail):
            "Archive extraction failed with status \(status): \(detail)"
        case .verificationFailed(let detail): "Extracted archive failed verification: \(detail)"
        case .publicationFailed(let detail): "Extracted archive could not be published: \(detail)"
        }
    }
}

struct ArchiveExtractionPolicy: Sendable {
    var maximumArchiveBytes: UInt64 = 256 * 1024 * 1024
    var maximumExpandedBytes: UInt64 = 1024 * 1024 * 1024
    var maximumFileCount = 20_000
    var maximumPathDepth = 32
    var maximumPathBytes = 1_024
    var maximumComponentBytes = 255
    var maximumCompressionRatio = 200.0
    var minimumExpandedBytesForRatio: UInt64 = 4 * 1024 * 1024

    static let plugin = Self()
    static let registry = Self(
        maximumArchiveBytes: 128 * 1024 * 1024,
        maximumExpandedBytes: 512 * 1024 * 1024,
        maximumFileCount: 30_000
    )
}

enum BoundedArchiveExtractor {
    @discardableResult
    static func extract(
        archive: URL,
        to destination: URL,
        policy: ArchiveExtractionPolicy,
        expectedSHA256: String? = nil
    ) throws -> URL {
        let manifest = try inspect(
            archive: archive,
            policy: policy,
            expectedSHA256: expectedSHA256
        )
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw ArchiveExtractionError.publicationFailed("could not prepare the extraction parent")
        }

        let staging = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).extracting-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: staging,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        } catch {
            throw ArchiveExtractionError.publicationFailed("could not create a private staging directory")
        }
        defer { try? fileManager.removeItem(at: staging) }
        let stagingRoot = staging.resolvingSymlinksInPath().standardizedFileURL

        try extractEntries(manifest: manifest, to: stagingRoot, policy: policy)
        try verify(staging: stagingRoot, manifest: manifest, policy: policy)

        do {
            var destinationInfo = stat()
            if lstat(destination.path, &destinationInfo) == 0 {
                guard destinationInfo.st_mode & S_IFMT == S_IFDIR else {
                    throw ArchiveExtractionError.publicationFailed(
                        "existing destination is not a directory"
                    )
                }
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch let error as ArchiveExtractionError {
            throw error
        } catch {
            throw ArchiveExtractionError.publicationFailed("atomic destination replacement failed")
        }
        return destination
    }

    // MARK: - ZIP manifest validation

    private struct ManifestEntry {
        enum Kind { case file, directory }
        let path: String
        let kind: Kind
        let method: UInt16
        let checksum: UInt32
        let compressedSize: UInt64
        let expandedSize: UInt64
        let compressedRange: Range<Int>
        let fullLocalRange: Range<Int>
        let permissions: mode_t
    }

    private struct Manifest {
        let archiveData: Data
        let entries: [ManifestEntry]
        let expectedPaths: [String: ManifestEntry.Kind]
        let expandedBytes: UInt64
    }

    private static func inspect(
        archive: URL,
        policy: ArchiveExtractionPolicy,
        expectedSHA256: String?
    ) throws -> Manifest {
        let values: URLResourceValues
        do {
            values = try archive.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        } catch {
            throw ArchiveExtractionError.malformed("archive attributes could not be read")
        }
        guard values.isRegularFile == true, let fileSize = values.fileSize else {
            throw ArchiveExtractionError.malformed("input is not a regular file")
        }
        let archiveBytes = UInt64(fileSize)
        guard archiveBytes <= policy.maximumArchiveBytes else {
            throw ArchiveExtractionError.resourceLimit(
                "compressed size \(archiveBytes) bytes exceeds \(policy.maximumArchiveBytes) bytes"
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: archive)
        } catch {
            throw ArchiveExtractionError.malformed("archive bytes could not be read")
        }
        guard UInt64(data.count) <= policy.maximumArchiveBytes else {
            throw ArchiveExtractionError.resourceLimit(
                "compressed bytes exceed \(policy.maximumArchiveBytes) bytes"
            )
        }
        if let expectedSHA256 {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard expectedSHA256.count == 64,
                expectedSHA256.allSatisfy(\.isHexDigit),
                actual == expectedSHA256.lowercased()
            else {
                throw ArchiveExtractionError.verificationFailed(
                    "archive SHA-256 does not match the verified artifact"
                )
            }
        }
        let eocd = try endOfCentralDirectory(in: data)
        let entryCount = Int(try data.uint16(at: eocd + 10))
        let centralSize = UInt64(try data.uint32(at: eocd + 12))
        let centralOffset = UInt64(try data.uint32(at: eocd + 16))
        let disk = try data.uint16(at: eocd + 4)
        let centralDisk = try data.uint16(at: eocd + 6)
        let diskEntries = try data.uint16(at: eocd + 8)

        guard disk == 0, centralDisk == 0, diskEntries == entryCount else {
            throw ArchiveExtractionError.unsupported("multi-disk archives are not accepted")
        }
        guard entryCount != Int(UInt16.max), centralSize != UInt64(UInt32.max),
            centralOffset != UInt64(UInt32.max)
        else {
            throw ArchiveExtractionError.unsupported("ZIP64 archives are outside the plugin archive budget")
        }
        guard entryCount > 0 else {
            throw ArchiveExtractionError.malformed("archive has no entries")
        }
        guard entryCount <= policy.maximumFileCount else {
            throw ArchiveExtractionError.resourceLimit(
                "entry count \(entryCount) exceeds \(policy.maximumFileCount)"
            )
        }
        guard centralOffset + centralSize == UInt64(eocd) else {
            throw ArchiveExtractionError.malformed("central directory bounds do not match the archive listing")
        }

        var offset = try Int(exactly: centralOffset).unwrapped("central directory offset overflows")
        let centralEnd = offset + (try Int(exactly: centralSize).unwrapped("central directory size overflows"))
        var entries: [ManifestEntry] = []
        var expected: [String: ManifestEntry.Kind] = [:]
        var explicitPaths: Set<String> = []
        var usedLocalOffsets: Set<UInt64> = []
        var expandedTotal: UInt64 = 0
        var compressedTotal: UInt64 = 0

        for _ in 0..<entryCount {
            guard offset + 46 <= centralEnd, try data.uint32(at: offset) == 0x0201_4b50 else {
                throw ArchiveExtractionError.malformed("central directory entry is truncated or missing")
            }
            let versionMadeBy = try data.uint16(at: offset + 4)
            let flags = try data.uint16(at: offset + 8)
            let method = try data.uint16(at: offset + 10)
            let checksum = try data.uint32(at: offset + 16)
            let compressedSize = UInt64(try data.uint32(at: offset + 20))
            let expandedSize = UInt64(try data.uint32(at: offset + 24))
            let nameLength = Int(try data.uint16(at: offset + 28))
            let extraLength = Int(try data.uint16(at: offset + 30))
            let commentLength = Int(try data.uint16(at: offset + 32))
            let diskStart = try data.uint16(at: offset + 34)
            let externalAttributes = try data.uint32(at: offset + 38)
            let localOffset = UInt64(try data.uint32(at: offset + 42))
            let next = offset + 46 + nameLength + extraLength + commentLength
            guard nameLength > 0, next <= centralEnd else {
                throw ArchiveExtractionError.malformed("central directory variable fields are truncated")
            }
            guard flags & 0x1 == 0 else {
                throw ArchiveExtractionError.unsupported("encrypted entries are not accepted")
            }
            let allowedFlags: UInt16 = 0x080e
            guard flags & ~allowedFlags == 0 else {
                throw ArchiveExtractionError.unsupported("general-purpose ZIP flags are not accepted")
            }
            if method == 0, flags & 0x6 != 0 {
                throw ArchiveExtractionError.unsupported("stored entries contain compression option flags")
            }
            guard method == 0 || method == 8 else {
                throw ArchiveExtractionError.unsupported("compression method \(method) is not accepted")
            }
            if method == 0, compressedSize != expandedSize {
                throw ArchiveExtractionError.malformed(
                    "stored entry compressed and expanded sizes differ"
                )
            }
            guard diskStart == 0 else {
                throw ArchiveExtractionError.unsupported("entry references another archive disk")
            }
            guard compressedSize != UInt64(UInt32.max), expandedSize != UInt64(UInt32.max),
                localOffset != UInt64(UInt32.max)
            else {
                throw ArchiveExtractionError.unsupported("ZIP64 entry metadata is not accepted")
            }

            let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
            try validateExtraFields(
                data.subdata(
                    in: (offset + 46 + nameLength)..<(offset + 46 + nameLength + extraLength)
                ),
                context: "central directory"
            )
            if flags & 0x0800 == 0, nameData.contains(where: { $0 >= 0x80 }) {
                throw ArchiveExtractionError.unsafePath("legacy-encoded non-ASCII filenames are not accepted")
            }
            guard let path = String(data: nameData, encoding: .utf8) else {
                throw ArchiveExtractionError.unsafePath("filename is not valid UTF-8")
            }
            let kind = try entryKind(
                path: path,
                externalAttributes: externalAttributes
            )
            if kind == .directory, compressedSize != 0 || expandedSize != 0 {
                throw ArchiveExtractionError.malformed("directory entry contains file data")
            }
            let normalized = try validatedPath(path, kind: kind, policy: policy)
            guard usedLocalOffsets.insert(localOffset).inserted else {
                throw ArchiveExtractionError.malformed(
                    "local ZIP entry regions overlap or reuse a header"
                )
            }
            let localLayout = try validateLocalHeader(
                data: data,
                offset: localOffset,
                expectedName: nameData,
                expectedFlags: flags,
                expectedMethod: method,
                expectedChecksum: checksum,
                compressedSize: compressedSize,
                expandedSize: expandedSize,
                centralDirectoryOffset: centralOffset
            )

            if let existing = expected[normalized] {
                let isFirstExplicitDirectory = existing == .directory
                    && kind == .directory
                    && !explicitPaths.contains(normalized)
                guard isFirstExplicitDirectory else {
                    throw ArchiveExtractionError.unsafePath(
                        "duplicate or colliding path '\(safeArchiveName(path))'"
                    )
                }
            }
            try addImplicitParents(of: normalized, to: &expected)
            if kind == .file, expected.keys.contains(where: { $0.hasPrefix(normalized + "/") }) {
                throw ArchiveExtractionError.unsafePath(
                    "file collides with an existing directory path '\(safeArchiveName(path))'"
                )
            }
            expected[normalized] = kind
            explicitPaths.insert(normalized)

            if kind == .file {
                expandedTotal = try adding(expandedSize, to: expandedTotal, label: "expanded byte count")
            }
            compressedTotal = try adding(compressedSize, to: compressedTotal, label: "compressed byte count")
            guard expandedTotal <= policy.maximumExpandedBytes else {
                throw ArchiveExtractionError.resourceLimit(
                    "expanded size exceeds \(policy.maximumExpandedBytes) bytes"
                )
            }
            try validateRatio(
                expanded: expandedSize,
                compressed: compressedSize,
                maximum: policy.maximumCompressionRatio,
                minimumExpandedBytes: policy.minimumExpandedBytesForRatio,
                label: safeArchiveName(path)
            )
            let creatorSystem = UInt8(versionMadeBy >> 8)
            let unixMode = UInt16(externalAttributes >> 16)
            entries.append(
                ManifestEntry(
                    path: path,
                    kind: kind,
                    method: method,
                    checksum: checksum,
                    compressedSize: compressedSize,
                    expandedSize: expandedSize,
                    compressedRange: localLayout.compressedRange,
                    fullLocalRange: localLayout.fullRange,
                    permissions: safePermissions(
                        unixMode: unixMode,
                        creatorSystem: creatorSystem,
                        kind: kind
                    )
                )
            )
            offset = next
        }

        guard offset == centralEnd else {
            throw ArchiveExtractionError.malformed("central directory entry count does not consume its listing")
        }
        try validateDisjointLocalRanges(entries.map(\.fullLocalRange))
        try validateRatio(
            expanded: expandedTotal,
            compressed: compressedTotal,
            maximum: policy.maximumCompressionRatio,
            minimumExpandedBytes: policy.minimumExpandedBytesForRatio,
            label: "archive total"
        )
        return Manifest(
            archiveData: data,
            entries: entries,
            expectedPaths: expected,
            expandedBytes: expandedTotal
        )
    }

    private static func endOfCentralDirectory(in data: Data) throws -> Int {
        guard data.count >= 22 else { throw ArchiveExtractionError.malformed("end record is missing") }
        let lowerBound = max(0, data.count - 65_557)
        for offset in stride(from: data.count - 22, through: lowerBound, by: -1) {
            guard (try? data.uint32(at: offset)) == 0x0605_4b50 else { continue }
            let commentLength = Int(try data.uint16(at: offset + 20))
            guard offset + 22 + commentLength == data.count else { continue }
            return offset
        }
        throw ArchiveExtractionError.malformed("valid end-of-central-directory record is missing")
    }

    private static func entryKind(
        path: String,
        externalAttributes: UInt32
    ) throws -> ManifestEntry.Kind {
        let directoryByName = path.hasSuffix("/")
        let mode = UInt16(externalAttributes >> 16)
        let type = mode & 0o170000
        switch type {
        case 0:
            return directoryByName ? .directory : .file
        case 0o040000:
            guard directoryByName else {
                throw ArchiveExtractionError.unsafeEntry("directory entry is missing its trailing slash")
            }
            return .directory
        case 0o100000:
            guard !directoryByName else {
                throw ArchiveExtractionError.unsafeEntry("regular file is marked as a directory")
            }
            return .file
        case 0o120000:
            throw ArchiveExtractionError.unsafeEntry("symbolic links are not accepted")
        default:
            throw ArchiveExtractionError.unsafeEntry("special filesystem entries are not accepted")
        }
    }

    private static func validatedPath(
        _ path: String,
        kind: ManifestEntry.Kind,
        policy: ArchiveExtractionPolicy
    ) throws -> String {
        guard !path.hasPrefix("/"), !path.hasPrefix("\\"), !path.contains("\\"),
            !path.contains("\0"),
            !path.unicodeScalars.contains(where: isUnsafeTextScalar)
        else {
            throw ArchiveExtractionError.unsafePath(
                "unsafe path syntax '\(safeArchiveName(path))'"
            )
        }
        guard path.utf8.count <= policy.maximumPathBytes else {
            throw ArchiveExtractionError.resourceLimit("path exceeds \(policy.maximumPathBytes) UTF-8 bytes")
        }
        var candidate = path
        if kind == .directory { candidate.removeLast() }
        let components = candidate.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.count <= policy.maximumPathDepth else {
            throw ArchiveExtractionError.resourceLimit("path depth exceeds \(policy.maximumPathDepth)")
        }
        for (index, component) in components.enumerated() {
            guard !component.isEmpty, component != ".", component != ".." else {
                throw ArchiveExtractionError.unsafePath(
                    "empty or traversal component in '\(safeArchiveName(path))'"
                )
            }
            guard component.utf8.count <= policy.maximumComponentBytes else {
                throw ArchiveExtractionError.resourceLimit(
                    "path component exceeds \(policy.maximumComponentBytes) UTF-8 bytes"
                )
            }
            if index == 0, component.count >= 2,
                component[component.index(after: component.startIndex)] == ":" {
                throw ArchiveExtractionError.unsafePath(
                    "drive-qualified path '\(safeArchiveName(path))'"
                )
            }
        }
        return components
            .map { $0.precomposedStringWithCanonicalMapping.lowercased() }
            .joined(separator: "/")
    }

    private static func addImplicitParents(
        of path: String,
        to expected: inout [String: ManifestEntry.Kind]
    ) throws {
        let components = path.split(separator: "/")
        guard components.count > 1 else { return }
        for index in 1..<components.count {
            let parent = components.prefix(index).joined(separator: "/")
            if let existing = expected[parent], existing == .file {
                throw ArchiveExtractionError.unsafePath(
                    "entry descends through file '\(safeArchiveName(parent))'"
                )
            }
            expected[parent] = .directory
        }
    }

    private struct LocalEntryLayout {
        let compressedRange: Range<Int>
        let fullRange: Range<Int>
    }

    private static func validateLocalHeader(
        data: Data,
        offset rawOffset: UInt64,
        expectedName: Data,
        expectedFlags: UInt16,
        expectedMethod: UInt16,
        expectedChecksum: UInt32,
        compressedSize: UInt64,
        expandedSize: UInt64,
        centralDirectoryOffset: UInt64
    ) throws -> LocalEntryLayout {
        let offset = try Int(exactly: rawOffset).unwrapped("local header offset overflows")
        guard offset + 30 <= data.count, try data.uint32(at: offset) == 0x0403_4b50 else {
            throw ArchiveExtractionError.malformed("local file header is missing or truncated")
        }
        let flags = try data.uint16(at: offset + 6)
        let method = try data.uint16(at: offset + 8)
        guard flags == expectedFlags, method == expectedMethod else {
            throw ArchiveExtractionError.malformed("local and central entry settings differ")
        }
        if flags & 0x8 == 0 {
            guard try data.uint32(at: offset + 14) == expectedChecksum,
                UInt64(try data.uint32(at: offset + 18)) == compressedSize,
                UInt64(try data.uint32(at: offset + 22)) == expandedSize
            else {
                throw ArchiveExtractionError.malformed("local and central entry sizes or checksum differ")
            }
        } else {
            let localChecksum = try data.uint32(at: offset + 14)
            let localCompressedSize = UInt64(try data.uint32(at: offset + 18))
            let localExpandedSize = UInt64(try data.uint32(at: offset + 22))
            guard localChecksum == 0 || localChecksum == expectedChecksum,
                localCompressedSize == 0 || localCompressedSize == compressedSize,
                localExpandedSize == 0 || localExpandedSize == expandedSize
            else {
                throw ArchiveExtractionError.malformed(
                    "data-descriptor local fields contradict central metadata"
                )
            }
        }
        let nameLength = Int(try data.uint16(at: offset + 26))
        let extraLength = Int(try data.uint16(at: offset + 28))
        let dataStart = offset + 30 + nameLength + extraLength
        let dataEnd64 = UInt64(dataStart) + compressedSize
        guard dataStart <= data.count, dataEnd64 <= centralDirectoryOffset,
            let dataEnd = Int(exactly: dataEnd64)
        else {
            throw ArchiveExtractionError.malformed("entry payload extends into the central directory")
        }
        guard data.subdata(in: (offset + 30)..<(offset + 30 + nameLength)) == expectedName else {
            throw ArchiveExtractionError.malformed("local and central filenames differ")
        }
        try validateExtraFields(
            data.subdata(
                in: (offset + 30 + nameLength)..<(offset + 30 + nameLength + extraLength)
            ),
            context: "local header"
        )
        let fullEnd: Int
        if flags & 0x8 != 0 {
            fullEnd = try validateDataDescriptor(
                data: data,
                offset: dataEnd,
                checksum: expectedChecksum,
                compressedSize: compressedSize,
                expandedSize: expandedSize,
                centralDirectoryOffset: centralDirectoryOffset
            )
        } else {
            fullEnd = dataEnd
        }
        return LocalEntryLayout(
            compressedRange: dataStart..<dataEnd,
            fullRange: offset..<fullEnd
        )
    }

    private static func validateDataDescriptor(
        data: Data,
        offset initialOffset: Int,
        checksum: UInt32,
        compressedSize: UInt64,
        expandedSize: UInt64,
        centralDirectoryOffset: UInt64
    ) throws -> Int {
        func matches(at offset: Int) throws -> Bool {
            guard UInt64(offset + 12) <= centralDirectoryOffset else { return false }
            return try data.uint32(at: offset) == checksum
                && UInt64(data.uint32(at: offset + 4)) == compressedSize
                && UInt64(data.uint32(at: offset + 8)) == expandedSize
        }
        if try matches(at: initialOffset) { return initialOffset + 12 }
        if try data.uint32(at: initialOffset) == 0x0807_4b50,
            try matches(at: initialOffset + 4) {
            return initialOffset + 16
        }
        throw ArchiveExtractionError.malformed("data descriptor differs from central metadata")
    }

    private static func validateDisjointLocalRanges(_ ranges: [Range<Int>]) throws {
        guard ranges.count > 1 else { return }
        let sorted = ranges.sorted {
            if $0.lowerBound == $1.lowerBound { return $0.upperBound < $1.upperBound }
            return $0.lowerBound < $1.lowerBound
        }
        for index in 1..<sorted.count where sorted[index - 1].upperBound > sorted[index].lowerBound {
            throw ArchiveExtractionError.malformed(
                "local ZIP entry regions overlap or reuse archive bytes"
            )
        }
    }

    private static func validateExtraFields(_ data: Data, context: String) throws {
        var offset = 0
        while offset < data.count {
            guard offset + 4 <= data.count else {
                throw ArchiveExtractionError.malformed("\(context) extra field is truncated")
            }
            let identifier = try data.uint16(at: offset)
            let payloadLength = Int(try data.uint16(at: offset + 2))
            let next = offset + 4 + payloadLength
            guard next <= data.count else {
                throw ArchiveExtractionError.malformed("\(context) extra field payload is truncated")
            }
            switch identifier {
            case 0x0001:
                throw ArchiveExtractionError.unsupported("ZIP64 extra fields are not accepted")
            case 0x7075:
                // Info-ZIP may replace the validated filename with this Unicode
                // path during extraction. Reject it instead of validating one
                // path and allowing the extractor to materialize another.
                throw ArchiveExtractionError.unsafePath(
                    "Unicode path override extra fields are not accepted"
                )
            default:
                break
            }
            offset = next
        }
    }

    private static func adding(_ value: UInt64, to total: UInt64, label: String) throws -> UInt64 {
        let (sum, overflow) = total.addingReportingOverflow(value)
        guard !overflow else { throw ArchiveExtractionError.resourceLimit("\(label) overflowed") }
        return sum
    }

    private static func validateRatio(
        expanded: UInt64,
        compressed: UInt64,
        maximum: Double,
        minimumExpandedBytes: UInt64,
        label: String
    ) throws {
        guard expanded >= minimumExpandedBytes else { return }
        guard compressed > 0 else {
            throw ArchiveExtractionError.resourceLimit("'\(label)' expands from zero compressed bytes")
        }
        guard Double(expanded) / Double(compressed) <= maximum else {
            throw ArchiveExtractionError.resourceLimit(
                "'\(label)' exceeds the \(Int(maximum)):1 decompression ratio limit"
            )
        }
    }

    private static func safePermissions(
        unixMode: UInt16,
        creatorSystem: UInt8,
        kind: ManifestEntry.Kind
    ) -> mode_t {
        guard creatorSystem == 3 else { return kind == .directory ? 0o700 : 0o600 }
        let permissions = mode_t(unixMode & 0o0777) & ~mode_t(0o022)
        guard permissions != 0 else { return kind == .directory ? 0o700 : 0o600 }
        return permissions | (kind == .directory ? 0o700 : 0o600)
    }

    private static func safeArchiveName(_ value: String) -> String {
        let filtered = value.unicodeScalars.map { scalar in
            isUnsafeTextScalar(scalar)
                ? "?"
                : String(scalar)
        }.joined()
        return String(filtered.prefix(160))
    }

    private static func isUnsafeTextScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar)
            || CharacterSet.newlines.contains(scalar)
            || isBidirectionalControl(scalar)
    }

    private static func isBidirectionalControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061c, 0x200e...0x200f, 0x202a...0x202e, 0x2066...0x2069:
            true
        default:
            false
        }
    }

    // MARK: - Bounded extraction and filesystem verification

    private static let extractionChunkBytes = 64 * 1024

    private static func extractEntries(
        manifest: Manifest,
        to staging: URL,
        policy: ArchiveExtractionPolicy
    ) throws {
        var globalExpandedBytes: UInt64 = 0
        var directoryPermissions: [(URL, mode_t)] = []

        for entry in manifest.entries {
            let destination = try outputURL(for: entry.path, kind: entry.kind, under: staging)
            switch entry.kind {
            case .directory:
                try createDirectories(for: entry.path, under: staging)
                directoryPermissions.append((destination, entry.permissions))
            case .file:
                try createParentDirectories(for: entry.path, under: staging)
                try extractFile(
                    entry,
                    archiveData: manifest.archiveData,
                    destination: destination,
                    globalExpandedBytes: &globalExpandedBytes,
                    policy: policy
                )
            }
        }

        guard globalExpandedBytes == manifest.expandedBytes else {
            throw ArchiveExtractionError.verificationFailed(
                "streamed byte count differs from the validated manifest"
            )
        }
        for (directory, permissions) in directoryPermissions.sorted(by: {
            $0.0.pathComponents.count > $1.0.pathComponents.count
        }) {
            guard chmod(directory.path, permissions) == 0 else {
                throw ArchiveExtractionError.extractionFailed(
                    Int32(errno),
                    "could not apply safe directory permissions"
                )
            }
        }
    }

    private static func extractFile(
        _ entry: ManifestEntry,
        archiveData: Data,
        destination: URL,
        globalExpandedBytes: inout UInt64,
        policy: ArchiveExtractionPolicy
    ) throws {
        let descriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw ArchiveExtractionError.extractionFailed(
                Int32(errno),
                "could not create staged file"
            )
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var entryExpandedBytes: UInt64 = 0
        var runningChecksum = zlib.crc32(0, nil, 0)

        do {
            let writeChunk: (Data) throws -> Void = { chunk in
                let chunkBytes = UInt64(chunk.count)
                let nextEntry = try adding(chunkBytes, to: entryExpandedBytes, label: "entry byte count")
                let nextGlobal = try adding(chunkBytes, to: globalExpandedBytes, label: "global byte count")
                guard nextEntry <= entry.expandedSize else {
                    throw ArchiveExtractionError.resourceLimit(
                        "entry '\(safeArchiveName(entry.path))' produced more than its declared size"
                    )
                }
                guard nextGlobal <= policy.maximumExpandedBytes else {
                    throw ArchiveExtractionError.resourceLimit(
                        "streamed output exceeds \(policy.maximumExpandedBytes) bytes"
                    )
                }
                try handle.write(contentsOf: chunk)
                runningChecksum = chunk.withUnsafeBytes { bytes in
                    zlib.crc32(
                        runningChecksum,
                        bytes.bindMemory(to: Bytef.self).baseAddress,
                        uInt(chunk.count)
                    )
                }
                entryExpandedBytes = nextEntry
                globalExpandedBytes = nextGlobal
            }

            switch entry.method {
            case 0:
                try copyStoredEntry(entry, from: archiveData, writeChunk: writeChunk)
            case 8:
                try inflateDeflatedEntry(entry, from: archiveData, writeChunk: writeChunk)
            default:
                throw ArchiveExtractionError.unsupported("compression method is not accepted")
            }

            guard entryExpandedBytes == entry.expandedSize else {
                throw ArchiveExtractionError.malformed(
                    "entry '\(safeArchiveName(entry.path))' produced fewer bytes than declared"
                )
            }
            guard UInt32(truncatingIfNeeded: runningChecksum) == entry.checksum else {
                throw ArchiveExtractionError.verificationFailed(
                    "entry '\(safeArchiveName(entry.path))' failed CRC validation"
                )
            }
            try handle.close()
            guard chmod(destination.path, entry.permissions) == 0 else {
                throw ArchiveExtractionError.extractionFailed(
                    Int32(errno),
                    "could not apply safe file permissions"
                )
            }
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func copyStoredEntry(
        _ entry: ManifestEntry,
        from archiveData: Data,
        writeChunk: (Data) throws -> Void
    ) throws {
        guard entry.compressedSize == entry.expandedSize,
            entry.compressedRange.count == Int(entry.compressedSize)
        else {
            throw ArchiveExtractionError.malformed("stored entry size metadata is inconsistent")
        }
        var offset = entry.compressedRange.lowerBound
        while offset < entry.compressedRange.upperBound {
            let end = min(offset + extractionChunkBytes, entry.compressedRange.upperBound)
            try writeChunk(archiveData.subdata(in: offset..<end))
            offset = end
        }
    }

    private static func inflateDeflatedEntry(
        _ entry: ManifestEntry,
        from archiveData: Data,
        writeChunk: (Data) throws -> Void
    ) throws {
        var stream = z_stream()
        let initialization = inflateInit2_(
            &stream,
            -MAX_WBITS,
            zlibVersion(),
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialization == Z_OK else {
            throw ArchiveExtractionError.extractionFailed(
                initialization,
                "raw deflate initialization failed"
            )
        }
        defer { inflateEnd(&stream) }

        try archiveData.withUnsafeBytes { archiveBytes in
            guard let baseAddress = archiveBytes.baseAddress else {
                throw ArchiveExtractionError.malformed("archive data is unavailable")
            }
            let input = baseAddress.advanced(by: entry.compressedRange.lowerBound)
                .assumingMemoryBound(to: Bytef.self)
            stream.next_in = UnsafeMutablePointer(mutating: input)
            stream.avail_in = uInt(entry.compressedRange.count)
            var output = [UInt8](repeating: 0, count: extractionChunkBytes)

            while true {
                var produced = 0
                let status = output.withUnsafeMutableBytes { outputBytes -> Int32 in
                    stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(outputBytes.count)
                    let result = inflate(&stream, Z_NO_FLUSH)
                    produced = outputBytes.count - Int(stream.avail_out)
                    return result
                }
                if produced > 0 {
                    try writeChunk(Data(output.prefix(produced)))
                }
                if status == Z_STREAM_END { break }
                guard status == Z_OK else {
                    throw ArchiveExtractionError.extractionFailed(
                        status,
                        "raw deflate stream is malformed or truncated"
                    )
                }
                guard produced > 0 || stream.avail_in > 0 else {
                    throw ArchiveExtractionError.extractionFailed(
                        Z_BUF_ERROR,
                        "raw deflate stream ended without a terminator"
                    )
                }
            }

            guard stream.avail_in == 0,
                UInt64(stream.total_in) == entry.compressedSize
            else {
                throw ArchiveExtractionError.malformed(
                    "deflate stream did not consume its exact compressed range"
                )
            }
        }
    }

    private static func createParentDirectories(for path: String, under root: URL) throws {
        let components = archivePathComponents(path, isDirectory: false)
        try createDirectories(components: Array(components.dropLast()), under: root)
    }

    private static func createDirectories(for path: String, under root: URL) throws {
        try createDirectories(components: archivePathComponents(path, isDirectory: true), under: root)
    }

    private static func createDirectories(components: [String], under root: URL) throws {
        let fileManager = FileManager.default
        var current = root
        for component in components {
            current.appendPathComponent(component, isDirectory: true)
            current = current.standardizedFileURL
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw ArchiveExtractionError.unsafePath("staged path collides with a file")
                }
                continue
            }
            do {
                try fileManager.createDirectory(
                    at: current,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
                )
            } catch {
                throw ArchiveExtractionError.extractionFailed(
                    Int32((error as NSError).code),
                    "could not create staged directory"
                )
            }
        }
    }

    private static func outputURL(
        for path: String,
        kind: ManifestEntry.Kind,
        under root: URL
    ) throws -> URL {
        var output = root
        for component in archivePathComponents(path, isDirectory: kind == .directory) {
            output.appendPathComponent(component, isDirectory: false)
        }
        output = output.standardizedFileURL
        let lexicalRoot = root.standardizedFileURL.path
        guard output.path.hasPrefix(lexicalRoot + "/") else {
            throw ArchiveExtractionError.unsafePath("entry resolves outside the staging root")
        }
        return output
    }

    private static func archivePathComponents(_ path: String, isDirectory: Bool) -> [String] {
        var candidate = path
        if isDirectory { candidate.removeLast() }
        return candidate.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }

    private static func verify(staging: URL, manifest: Manifest, policy: ArchiveExtractionPolicy) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: staging,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw ArchiveExtractionError.verificationFailed("could not enumerate staged output")
        }

        var actual: [String: ManifestEntry.Kind] = [:]
        var fileCount = 0
        var expandedBytes: UInt64 = 0
        let canonicalRoot = staging.resolvingSymlinksInPath().standardizedFileURL.path
        for case let url as URL in enumerator {
            // Do not resolve the child path before lstat; resolving it would follow a
            // malicious symlink before verification. The enumerator already returns
            // paths beneath the canonicalized temporary-directory spelling.
            let canonicalPath = url.standardizedFileURL.path
            guard canonicalPath.hasPrefix(canonicalRoot + "/") else {
                throw ArchiveExtractionError.verificationFailed("staged entry resolves outside extraction root")
            }
            let relative = String(canonicalPath.dropFirst(canonicalRoot.count + 1))
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw ArchiveExtractionError.verificationFailed(
                    "could not inspect '\(safeArchiveName(relative))'"
                )
            }
            let type = info.st_mode & S_IFMT
            let kind: ManifestEntry.Kind
            switch type {
            case S_IFDIR:
                kind = .directory
            case S_IFREG:
                guard info.st_nlink == 1 else {
                    throw ArchiveExtractionError.verificationFailed(
                        "hard-linked file '\(safeArchiveName(relative))' is not accepted"
                    )
                }
                kind = .file
                fileCount += 1
                expandedBytes = try adding(UInt64(info.st_size), to: expandedBytes, label: "staged byte count")
            case S_IFLNK:
                enumerator.skipDescendants()
                throw ArchiveExtractionError.verificationFailed(
                    "symbolic link '\(safeArchiveName(relative))' is not accepted"
                )
            default:
                enumerator.skipDescendants()
                throw ArchiveExtractionError.verificationFailed(
                    "special file '\(safeArchiveName(relative))' is not accepted"
                )
            }
            let normalized = try validatedPath(
                kind == .directory ? relative + "/" : relative,
                kind: kind,
                policy: policy
            )
            guard actual[normalized] == nil else {
                throw ArchiveExtractionError.verificationFailed(
                    "output contains colliding path '\(safeArchiveName(relative))'"
                )
            }
            actual[normalized] = kind
        }

        guard actual == manifest.expectedPaths else {
            let missing = Set(manifest.expectedPaths.keys).subtracting(actual.keys).sorted().prefix(3)
                .map(safeArchiveName)
            let unexpected = Set(actual.keys).subtracting(manifest.expectedPaths.keys).sorted().prefix(3)
                .map(safeArchiveName)
            throw ArchiveExtractionError.verificationFailed(
                "staged paths differ from the validated manifest (missing: \(missing); unexpected: \(unexpected))"
            )
        }
        guard fileCount <= policy.maximumFileCount, expandedBytes <= policy.maximumExpandedBytes else {
            throw ArchiveExtractionError.verificationFailed("staged output exceeds its validated resource budget")
        }
        guard expandedBytes == manifest.expandedBytes else {
            throw ArchiveExtractionError.verificationFailed(
                "staged byte count \(expandedBytes) differs from declared \(manifest.expandedBytes)"
            )
        }
    }
}

private extension Data {
    func uint16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw ArchiveExtractionError.malformed("16-bit field is truncated")
        }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw ArchiveExtractionError.malformed("32-bit field is truncated")
        }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}

private extension Optional {
    func unwrapped(_ message: String) throws -> Wrapped {
        guard let self else { throw ArchiveExtractionError.malformed(message) }
        return self
    }
}
