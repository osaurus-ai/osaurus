//
//  KnowledgeCollectionStore.swift
//  osaurus
//
//  Persistence for knowledge collections. One JSON file per collection
//  under `~/.osaurus/knowledge/collections/`, mirroring AgentStore /
//  ScheduleStore. Only registry metadata lives here — the corpus stays
//  in the user's folder and the derived index lives in knowledge.sqlite.
//

import Foundation

/// Nonisolated on purpose: every function here is pure filesystem I/O.
/// Directory enumeration plus per-file JSON decoding can stall for seconds
/// on a cold or contended disk, so registry loads must be able to run off
/// the main thread (Sentry APPLE-MACOS-1B6 measured `loadAll()` blocking
/// launch inside `KnowledgeManager.shared` init).
public enum KnowledgeCollectionStore {
    // MARK: - Public API

    /// `loadAll()` moved to a background thread. Prefer this from any
    /// MainActor caller.
    public static func loadAllAsync() async -> [KnowledgeCollection] {
        await Task.detached(priority: .userInitiated) {
            loadAll()
        }.value
    }

    /// Load all collections sorted by name. Blocking filesystem I/O — do
    /// not call on the main thread; use `loadAllAsync()` there.
    public static func loadAll() -> [KnowledgeCollection] {
        let directory = OsaurusPaths.knowledgeCollections()
        OsaurusPaths.ensureExistsSilent(directory)

        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var collections: [KnowledgeCollection] = []
        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                collections.append(try decoder.decode(KnowledgeCollection.self, from: data))
            } catch {
                print("[Osaurus] Failed to load knowledge collection from \(file.lastPathComponent): \(error)")
            }
        }

        return collections.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Load a specific collection by ID.
    public static func load(id: UUID) -> KnowledgeCollection? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(KnowledgeCollection.self, from: data)
        } catch {
            print("[Osaurus] Failed to load knowledge collection \(id): \(error)")
            return nil
        }
    }

    /// Save a collection (creates or updates).
    public static func save(_ collection: KnowledgeCollection) {
        let url = fileURL(for: collection.id)
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(collection)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save knowledge collection \(collection.id): \(error)")
        }
    }

    /// Delete a collection's registry record. Derived index cleanup
    /// (database rows, vector directory) is owned by `KnowledgeManager.delete`.
    @discardableResult
    public static func delete(id: UUID) -> Bool {
        do {
            try FileManager.default.removeItem(at: fileURL(for: id))
            return true
        } catch {
            print("[Osaurus] Failed to delete knowledge collection \(id): \(error)")
            return false
        }
    }

    // MARK: - Private

    private static func fileURL(for id: UUID) -> URL {
        OsaurusPaths.knowledgeCollections().appendingPathComponent("\(id.uuidString).json")
    }
}
