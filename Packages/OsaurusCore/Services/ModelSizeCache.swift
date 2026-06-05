//
//  ModelSizeCache.swift
//  osaurus
//
//  On-disk cache for model download sizes (the exact byte total of the
//  files Osaurus downloads for a repo). Replaces the hand-coded
//  `downloadSizeBytes` literals that used to live in the curated catalog.
//
//  Why a cache:
//  - The accurate size comes from the Hugging Face tree API (summing the
//    files matching `ModelDownloadService.downloadFilePatterns`). Fetching
//    it on every launch for ~100 repos is wasteful, so we persist the
//    answer keyed by repo id + the repo's HF `lastModified` revision and
//    only re-fetch when the revision actually changes.
//  - The startup path seeds sizes synchronously from this cache so the
//    first paint shows last-known-accurate sizes even offline.
//
//  Concurrency: a process-wide dictionary guarded by an `NSLock` (the
//  same shape as `ModelManager`'s local-models cache). Reads are
//  synchronous; writes flush the whole map to disk atomically.
//

import Foundation

/// Persistent, process-wide cache of model download sizes.
enum ModelSizeCache {
    /// One cached size measurement for a repo.
    struct Entry: Codable {
        /// Total bytes of the files Osaurus downloads for this repo.
        let bytes: Int64
        /// HF `lastModified` revision string the measurement was taken
        /// against, when known. `nil` for entries fetched on-demand
        /// (e.g. the detail modal) where we don't have a cheap revision
        /// signal — those rely on `ttl` instead.
        let revision: String?
        /// When the measurement was taken. Drives TTL expiry for
        /// revision-less entries.
        let fetchedAt: Date
    }

    /// On-disk envelope. Versioned so a future format change can reject
    /// older payloads cleanly instead of crashing the decoder.
    private struct Persisted: Codable {
        static let currentSchemaVersion: Int = 1
        var schemaVersion: Int
        var entries: [String: Entry]
    }

    /// How long a revision-less entry stays fresh. Model weight files
    /// effectively never change once published, so a long TTL keeps the
    /// detail-modal estimate from re-fetching on every open.
    static let revisionlessTTL: TimeInterval = 30 * 24 * 60 * 60

    private static let lock = NSLock()
    private static nonisolated(unsafe) var cache: [String: Entry]?

    // MARK: - Public read API

    /// Cached size for `id` if present and still fresh, otherwise `nil`.
    /// Freshness rules:
    /// - When `revision` is provided, the cached entry must carry the
    ///   same revision (exact invalidation).
    /// - When `revision` is `nil`, any non-expired entry (per `ttl`) is
    ///   accepted regardless of its stored revision.
    static func bytes(forId id: String, matchingRevision revision: String? = nil) -> Int64? {
        guard let entry = entry(forId: id) else { return nil }
        if let revision {
            return entry.revision == revision ? entry.bytes : nil
        }
        if let entryRevision = entry.revision, !entryRevision.isEmpty {
            // Has a concrete revision but the caller didn't supply one to
            // compare against — trust it (revisions only change when the
            // repo changes, which the org refresh detects separately).
            return entry.bytes
        }
        // Revision-less entry: honor the TTL.
        let age = Date().timeIntervalSince(entry.fetchedAt)
        return age <= revisionlessTTL ? entry.bytes : nil
    }

    /// Raw cached entry for `id` (no freshness filtering).
    static func entry(forId id: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return loadedLocked()[normalize(id)]
    }

    // MARK: - Public write API

    /// Record a freshly measured size for `id`, flushing to disk.
    static func record(id: String, bytes: Int64, revision: String?) {
        guard bytes > 0 else { return }
        let entry = Entry(bytes: bytes, revision: revision, fetchedAt: Date())
        lock.lock()
        var map = loadedLocked()
        map[normalize(id)] = entry
        cache = map
        lock.unlock()
        persist(map)
    }

    // MARK: - Test support

    /// Drops the in-memory copy so the next read re-hydrates from disk.
    /// Used by tests after pointing `OsaurusPaths` at a fixture root.
    static func invalidateInMemory() {
        lock.lock()
        cache = nil
        lock.unlock()
    }

    // MARK: - Private

    private static func normalize(_ id: String) -> String {
        id.lowercased()
    }

    /// Returns the in-memory map, loading from disk on first access.
    /// Caller must hold `lock`.
    private static func loadedLocked() -> [String: Entry] {
        if let cache { return cache }
        let loaded = loadFromDisk()
        cache = loaded
        return loaded
    }

    private static func loadFromDisk() -> [String: Entry] {
        let url = OsaurusPaths.modelSizeCacheFile()
        guard FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let payload = try? JSONDecoder().decode(Persisted.self, from: data),
            payload.schemaVersion == Persisted.currentSchemaVersion
        else {
            return [:]
        }
        return payload.entries
    }

    private static func persist(_ map: [String: Entry]) {
        let url = OsaurusPaths.modelSizeCacheFile()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        let payload = Persisted(
            schemaVersion: Persisted.currentSchemaVersion,
            entries: map
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        // Atomic write so a crash mid-save can't leave a half-written file
        // that breaks the next load.
        try? data.write(to: url, options: [.atomic])
    }
}
