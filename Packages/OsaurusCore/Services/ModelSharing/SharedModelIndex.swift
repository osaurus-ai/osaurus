//
//  SharedModelIndex.swift
//  osaurus
//
//  Turns a `ShareableModel` into what the share node publishes: every file
//  with its SHA-256. Hashing a multi-gigabyte bundle takes a while, so
//  digests are cached on disk by path, size and modification time and a
//  model is hashed once, not on every launch.
//

import CryptoKit
import Foundation
import OsaurusSync

actor SharedModelIndex {
    struct Entry: Codable, Equatable {
        let size: Int64
        let modified: Double
        let sha256: String
    }

    private let cacheURL: URL
    private var entries: [String: Entry]
    private var dirty = false

    init(cacheURL: URL = OsaurusPaths.modelSharingHashCacheFile()) {
        self.cacheURL = cacheURL
        entries = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) }
            ?? [:]
    }

    /// True when every file of `model` already has a cached digest.
    func isPrepared(_ model: ShareableModel) -> Bool {
        model.files.allSatisfy { cached($0) != nil }
    }

    /// The published form of `model`, hashing files without a cached digest.
    /// Throws `CancellationError` when the calling task is cancelled.
    func prepare(_ model: ShareableModel) throws -> SharedModel {
        var files: [SharedModelFile] = []
        for file in model.files {
            try Task.checkCancellation()
            let digest: String
            if let cached = cached(file) {
                digest = cached
            } else {
                digest = try Self.sha256(of: file.url)
                entries[file.url.path] = Entry(
                    size: file.size,
                    modified: file.modified.timeIntervalSince1970,
                    sha256: digest
                )
                dirty = true
            }
            files.append(
                SharedModelFile(path: file.path, size: UInt64(file.size), sha256: digest, sourcePath: file.url.path)
            )
        }
        return SharedModel(
            id: model.id,
            kind: model.kind.rawValue,
            format: model.kind.format,
            name: model.name,
            repoId: model.repoId,
            revision: model.revision,
            files: files
        )
    }

    /// Drops digests for files no longer part of any shareable model and
    /// writes the cache if it changed.
    func save(keeping models: [ShareableModel]) {
        let live = Set(models.flatMap { $0.files.map(\.url.path) })
        let before = entries.count
        entries = entries.filter { live.contains($0.key) }
        guard dirty || entries.count != before else { return }
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(entries).write(to: cacheURL, options: .atomic)
            dirty = false
        } catch {
            print("[SharedModelIndex] Failed to save digests: \(error)")
        }
    }

    private func cached(_ file: ShareableFile) -> String? {
        guard let entry = entries[file.url.path],
            entry.size == file.size,
            entry.modified == file.modified.timeIntervalSince1970
        else { return nil }
        return entry.sha256
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let data = try handle.read(upToCount: 8 * 1024 * 1024), !data.isEmpty else { return false }
            try Task.checkCancellation()
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
