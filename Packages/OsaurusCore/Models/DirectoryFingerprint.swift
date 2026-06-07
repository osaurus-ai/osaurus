//
//  DirectoryFingerprint.swift
//  osaurus
//
//  Shallow Merkle hash of directory state for cheap change detection.
//  Hashes file metadata (path + size + mtime) per entry, then hashes
//  all entry hashes into a single root. Diffing is a single string
//  comparison; detailed diff only computed when root hashes differ.
//

import CryptoKit
import Foundation

// MARK: - Directory Fingerprint

/// A snapshot of a directory's file metadata, hashed into a Merkle tree.
/// Comparing two fingerprints is a single string comparison (the root hash).
public struct DirectoryFingerprint: Sendable {
    /// Individual file entries with their metadata hashes
    public let entries: [FileEntry]

    /// Merkle root hash -- compare this to detect any change
    public let hash: String

    /// A single file's metadata hash
    public struct FileEntry: Comparable, Sendable {
        /// Path relative to the fingerprinted root
        public let relativePath: String
        /// Hash of the file's metadata (size + mtime)
        public let hash: String

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.relativePath < rhs.relativePath
        }
    }

    // MARK: - Capture

    /// Capture a fingerprint of a directory using stat() only -- no file content reads.
    ///
    /// - Parameters:
    ///   - root: The directory to fingerprint
    ///   - excludedSubpaths: Subpaths to skip entirely (e.g., nested watched folders)
    /// - Returns: A fingerprint representing the current directory state
    public static func capture(_ root: URL, excludedSubpaths: Set<URL> = []) throws -> DirectoryFingerprint {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let rootPath = root.path

        guard
            let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        else {
            throw DirectoryFingerprintError.enumerationFailed(root)
        }

        var entries: [FileEntry] = []

        for case let url as URL in enumerator {
            // Skip excluded subpaths (other watched folders)
            if excludedSubpaths.contains(where: { url.path.hasPrefix($0.path) }) {
                enumerator.skipDescendants()
                continue
            }

            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }

            // Compute relative path
            var relativePath = url.path
            if relativePath.hasPrefix(rootPath) {
                relativePath = String(relativePath.dropFirst(rootPath.count))
                if relativePath.hasPrefix("/") {
                    relativePath = String(relativePath.dropFirst())
                }
            }

            // Shallow hash: metadata only (size + mtime). No disk I/O beyond stat().
            let size = values.fileSize ?? 0
            let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0

            var hasher = SHA256()
            hasher.update(data: Data(relativePath.utf8))
            withUnsafeBytes(of: size) { hasher.update(bufferPointer: $0) }
            withUnsafeBytes(of: mtime) { hasher.update(bufferPointer: $0) }
            let fileHash = hasher.finalize().hexPrefix(8)

            entries.append(FileEntry(relativePath: relativePath, hash: fileHash))
        }

        entries.sort()

        // Merkle root: hash all the entry hashes
        var rootHasher = SHA256()
        for entry in entries {
            rootHasher.update(data: Data("\(entry.relativePath):\(entry.hash)".utf8))
        }
        let rootHash = rootHasher.finalize().hexPrefix(16)

        return DirectoryFingerprint(entries: entries, hash: rootHash)
    }

    // MARK: - Comparison

    /// Cheap check -- single string comparison of root hashes
    public func changed(from other: DirectoryFingerprint) -> Bool {
        hash != other.hash
    }

    /// Detailed diff -- only call when root hashes differ.
    /// Returns the sets of added, removed, and modified relative paths.
    public func diff(from other: DirectoryFingerprint) -> DirectoryDiff {
        let oldMap = Dictionary(uniqueKeysWithValues: other.entries.map { ($0.relativePath, $0.hash) })
        let newMap = Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, $0.hash) })

        let oldPaths = Set(oldMap.keys)
        let newPaths = Set(newMap.keys)

        return DirectoryDiff(
            added: newPaths.subtracting(oldPaths),
            removed: oldPaths.subtracting(newPaths),
            modified: oldPaths.intersection(newPaths).filter { oldMap[$0] != newMap[$0] }
        )
    }
}

// MARK: - Directory Diff

/// The difference between two directory fingerprints
public struct DirectoryDiff: Sendable {
    /// Paths that exist in the new fingerprint but not the old
    public let added: Set<String>
    /// Paths that existed in the old fingerprint but not the new
    public let removed: Set<String>
    /// Paths that exist in both but have different metadata hashes
    public let modified: Set<String>

    /// Whether there are no differences
    public var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && modified.isEmpty
    }

    /// Total number of changed paths
    public var totalCount: Int {
        added.count + removed.count + modified.count
    }
}

// MARK: - Errors

public enum DirectoryFingerprintError: Error, LocalizedError {
    case enumerationFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .enumerationFailed(let url):
            return "Failed to enumerate directory: \(url.path)"
        }
    }
}

// MARK: - SHA256 Hex Extension

extension SHA256Digest {
    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// Returns the first `byteCount` bytes of the digest as a hex string.
    /// Encodes via a digit table -- `String(format:)` parses the format and
    /// takes a locale lock per byte, far too slow for the per-file hot path.
    func hexPrefix(_ byteCount: Int) -> String {
        var chars: [UInt8] = []
        chars.reserveCapacity(byteCount * 2)
        for byte in prefix(byteCount) {
            chars.append(Self.hexDigits[Int(byte >> 4)])
            chars.append(Self.hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: chars, as: UTF8.self)
    }
}
