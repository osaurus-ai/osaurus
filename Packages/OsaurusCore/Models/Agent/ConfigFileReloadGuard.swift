//
//  ConfigFileReloadGuard.swift
//  osaurus
//
//  Detects an edit to a cached JSON config file that did not come through
//  its store's `save` (a hand edit, another process, a restored backup), so
//  the Orchestrator can reload its configuration at the start of every turn
//  without re-decoding an unchanged file.
//

import CryptoKit
import Foundation

@MainActor
final class ConfigFileReloadGuard {
    private var lastModified: Date?
    /// Digests of payloads this process wrote. Saves land on disk
    /// asynchronously and in order, so an older write can still be the file's
    /// content after a newer save updated the cache; those are not edits.
    private var recentWrites: [SHA256Digest] = []
    private static let recentWriteLimit = 8

    /// Bumped on every save or detected reload; part of the Orchestrator's
    /// session tool fingerprint so a configuration change rebuilds its schema.
    private(set) var generation = 0

    func noteLoaded(from url: URL) {
        lastModified = Self.modificationDate(of: url)
    }

    func noteSaved(_ data: Data) {
        recentWrites.append(SHA256.hash(data: data))
        if recentWrites.count > Self.recentWriteLimit {
            recentWrites.removeFirst(recentWrites.count - Self.recentWriteLimit)
        }
        generation += 1
    }

    /// The file's new contents when it changed on disk since the last load
    /// and was not written by this process; nil otherwise.
    func externalChange(at url: URL) -> Data? {
        let modified = Self.modificationDate(of: url)
        guard modified != lastModified else { return nil }
        lastModified = modified
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard !recentWrites.contains(SHA256.hash(data: data)) else { return nil }
        generation += 1
        return data
    }

    func reset() {
        lastModified = nil
        recentWrites = []
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
