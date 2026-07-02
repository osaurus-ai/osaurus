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

@MainActor
public enum KnowledgeCollectionStore {
    // MARK: - Public API

    /// Load all collections sorted by name.
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
