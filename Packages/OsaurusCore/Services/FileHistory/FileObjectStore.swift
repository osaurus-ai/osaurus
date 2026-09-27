//
//  FileObjectStore.swift
//  osaurus
//
//  Content-addressed blob store for file history. A blob's key is the
//  sha256 of its bytes; blobs are immutable once written and shared by
//  every change entry (in any session) that references the same content.
//
//  Durability: bytes are cloned/copied to a temp file inside the store,
//  hashed from that private copy (so a file changing mid-capture can never
//  produce a key that doesn't match the stored bytes), fsynced, and only
//  then renamed into place. A signature is handed to the journal only after
//  the rename, so the database never references a missing blob.
//

import CryptoKit
import Darwin
import Foundation
import os

public final class FileObjectStore: @unchecked Sendable {
    public let root: URL
    private let objectsDir: URL
    private let tmpDir: URL
    private static let log = Logger(subsystem: "ai.osaurus", category: "file-history.objects")

    /// Files above this are not copied into history when the store can't
    /// APFS-clone them (a physical copy of a multi-GB file per edit would
    /// stall the tool call and balloon disk usage).
    static let maxCopiedObjectBytes: Int64 = 512 * 1024 * 1024

    public init(root: URL) {
        self.root = root
        self.objectsDir = root.appendingPathComponent("objects", isDirectory: true)
        self.tmpDir = root.appendingPathComponent("tmp", isDirectory: true)
    }

    // MARK: - Paths

    public func url(forHash hash: String) -> URL {
        let prefix = String(hash.prefix(2))
        return objectsDir.appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent(String(hash.dropFirst(2)))
    }

    public func contains(hash: String) -> Bool {
        FileManager.default.fileExists(atPath: url(forHash: hash).path)
    }

    private func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [root, objectsDir, tmpDir] where !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
    }

    // MARK: - Capture

    /// Capture the current state of `url` (never following a symlink).
    /// Returns nil when nothing exists there. Files are stored in the
    /// object store; oversized files degrade to a `big:` signature.
    public func captureState(at url: URL) -> FilePathState? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
            let type = attrs[.type] as? FileAttributeType
        else { return nil }
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue
        switch type {
        case .typeSymbolicLink:
            let target = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            return FilePathState(type: .symlink, signature: "link:\(target)", mode: mode)
        case .typeDirectory:
            return FilePathState(type: .directory, signature: "dir", mode: mode)
        default:
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            if size > Self.maxCopiedObjectBytes, !Self.canClone(from: url, to: root) {
                return FilePathState(
                    type: .file, signature: Self.bigSignature(size: size, attrs: attrs), mode: mode,
                    size: size)
            }
            do {
                let hash = try store(fileAt: url)
                return FilePathState(type: .file, signature: "sha256:\(hash)", mode: mode, size: size)
            } catch {
                Self.log.error(
                    "capture failed for \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)"
                )
                return FilePathState(
                    type: .file, signature: Self.bigSignature(size: size, attrs: attrs), mode: mode,
                    size: size)
            }
        }
    }

    /// Signature of `url` WITHOUT storing it (conflict checks), comparable
    /// with what this store's `captureState` produced: the same oversize
    /// rule applies, so a file that was recorded as `big:` (too large to
    /// copy across volumes) is not hashed here and misread as changed.
    public func liveSignature(at url: URL) -> FilePathState? {
        Self.liveSignature(at: url, storeRoot: root)
    }

    /// Store-independent variant. Pass the store root that captured the
    /// file whenever you compare against a stored signature.
    public static func liveSignature(at url: URL, storeRoot: URL? = nil) -> FilePathState? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
            let type = attrs[.type] as? FileAttributeType
        else { return nil }
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue
        switch type {
        case .typeSymbolicLink:
            let target = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            return FilePathState(type: .symlink, signature: "link:\(target)", mode: mode)
        case .typeDirectory:
            return FilePathState(type: .directory, signature: "dir", mode: mode)
        default:
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            if size > maxCopiedObjectBytes, let storeRoot, !canClone(from: url, to: storeRoot) {
                return FilePathState(
                    type: .file, signature: bigSignature(size: size, attrs: attrs), mode: mode, size: size)
            }
            guard let hash = sha256Hex(of: url) else {
                return FilePathState(
                    type: .file, signature: bigSignature(size: size, attrs: attrs), mode: mode, size: size)
            }
            return FilePathState(type: .file, signature: "sha256:\(hash)", mode: mode, size: size)
        }
    }

    /// Store a file's bytes; returns the sha256 key.
    @discardableResult
    public func store(fileAt url: URL) throws -> String {
        try ensureDirectories()
        let temp = tmpDir.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try Self.cloneOrCopy(from: url, to: temp)
        guard let hash = Self.sha256Hex(of: temp) else {
            throw CocoaError(.fileReadUnknown)
        }
        try commit(temp: temp, hash: hash)
        return hash
    }

    /// Store raw bytes; returns the sha256 key.
    @discardableResult
    public func store(data: Data) throws -> String {
        try ensureDirectories()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if contains(hash: hash) { return hash }
        let temp = tmpDir.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try data.write(to: temp)
        try commit(temp: temp, hash: hash)
        return hash
    }

    private func commit(temp: URL, hash: String) throws {
        let fm = FileManager.default
        let dest = url(forHash: hash)
        if fm.fileExists(atPath: dest.path) { return }
        try fm.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        Self.fsync(temp)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        do {
            try fm.moveItem(at: temp, to: dest)
        } catch {
            // Lost a race with a concurrent writer of the same content.
            if fm.fileExists(atPath: dest.path) { return }
            throw error
        }
    }

    public func data(forHash hash: String) -> Data? {
        try? Data(contentsOf: url(forHash: hash))
    }

    // MARK: - Restore

    /// Materialize a blob as a sibling temp file of `destination` (same
    /// volume, so the final swap is an atomic rename). Caller moves it in.
    public func materializeTemp(hash: String, besides destination: URL, mode: Int?) throws -> URL {
        let src = url(forHash: hash)
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".osaurus-restore-\(UUID().uuidString)")
        try Self.cloneOrCopy(from: src, to: temp)
        // The blob is content-addressed; a mismatch means the stored copy
        // (or this clone) is damaged. Never swap damaged bytes into place.
        guard Self.sha256Hex(of: temp) == hash else {
            try? FileManager.default.removeItem(at: temp)
            throw FileObjectStoreError.corruptObject(hash)
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode ?? 0o644)], ofItemAtPath: temp.path)
        return temp
    }

    static var tempExportRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("osaurus-file-history", isDirectory: true)
    }

    /// Remove every temp export (blobs opened in other apps or fed to
    /// document adapters). Run at launch: nothing can be holding one yet.
    public static func removeTempExports() {
        try? FileManager.default.removeItem(at: tempExportRoot)
    }

    /// Write a blob to a temp file carrying `filename`'s extension (for
    /// document adapters and "Open in default app").
    public func exportTemp(hash: String, filename: String, label: String) throws -> URL {
        let dir = Self.tempExportRoot
            .appendingPathComponent(String(hash.prefix(16)) + "-" + label, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        try Self.cloneOrCopy(from: url(forHash: hash), to: dest)
        return dest
    }

    // MARK: - GC

    /// Delete every blob whose key is not in `referenced`. Returns bytes freed.
    @discardableResult
    public func collectGarbage(keeping referenced: Set<String>) -> Int64 {
        let fm = FileManager.default
        var freed: Int64 = 0
        guard let prefixes = try? fm.contentsOfDirectory(atPath: objectsDir.path) else { return 0 }
        for prefix in prefixes {
            let dir = objectsDir.appendingPathComponent(prefix, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where !referenced.contains(prefix + name) {
                let file = dir.appendingPathComponent(name)
                let size = ((try? fm.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?
                    .int64Value ?? 0
                if (try? fm.removeItem(at: file)) != nil { freed += size }
            }
        }
        try? fm.removeItem(at: tmpDir)
        return freed
    }

    /// Total bytes held by blobs.
    public func totalBytes() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: objectsDir.path) else { return 0 }
        var total: Int64 = 0
        while enumerator.nextObject() != nil {
            if let size = enumerator.fileAttributes?[.size] as? NSNumber,
                enumerator.fileAttributes?[.type] as? FileAttributeType == .typeRegular
            {
                total += size.int64Value
            }
        }
        return total
    }

    // MARK: - Helpers

    public enum FileObjectStoreError: LocalizedError {
        /// Stored bytes no longer hash to their key.
        case corruptObject(String)

        public var errorDescription: String? {
            switch self {
            case .corruptObject:
                return L("The saved copy of this file is damaged and can't be restored.")
            }
        }
    }

    static func bigSignature(size: Int64, attrs: [FileAttributeKey: Any]) -> String {
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "big:\(size):\(Int64(mtime * 1_000_000_000))"
    }

    /// APFS clone when possible (`clonefile` is copy-on-write and near
    /// free), otherwise a byte copy. Never follows a symlink source.
    static func cloneOrCopy(from src: URL, to dest: URL) throws {
        if clonefile(src.path, dest.path, UInt32(CLONE_NOFOLLOW)) == 0 { return }
        try FileManager.default.copyItem(at: src, to: dest)
    }

    /// Whether `src` and `dir` live on the same clone-capable volume.
    static func canClone(from src: URL, to dir: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey, .volumeSupportsFileCloningKey]
        let probeDir = FileManager.default.fileExists(atPath: dir.path)
            ? dir : dir.deletingLastPathComponent()
        guard let a = try? src.resourceValues(forKeys: keys),
            let b = try? probeDir.resourceValues(forKeys: keys),
            let va = a.volumeIdentifier as? NSObject, let vb = b.volumeIdentifier as? NSObject
        else { return false }
        return va.isEqual(vb) && (a.volumeSupportsFileCloning ?? false)
    }

    static func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fsync(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        _ = Darwin.fsync(fd)
        close(fd)
    }
}
