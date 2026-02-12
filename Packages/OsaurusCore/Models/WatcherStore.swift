//
//  WatcherStore.swift
//  osaurus
//
//  Persistence layer for file system watchers.
//

import Foundation

/// Handles persistence of watchers to disk
public enum WatcherStore {
    // MARK: - Directory Management

    private static var watchersDirectory: URL {
        let dir = OsaurusPaths.watchers()
        OsaurusPaths.ensureExistsSilent(dir)
        return dir
    }

    private static func fileURL(for id: UUID) -> URL {
        watchersDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - CRUD Operations

    /// Load all watchers from disk
    public static func loadAll() -> [Watcher] {
        let fm = FileManager.default
        let dir = watchersDirectory

        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var watchers: [Watcher] = []

        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let watcher = try decoder.decode(Watcher.self, from: data)
                watchers.append(watcher)
            } catch {
                print("[Osaurus] Failed to load watcher from \(file.lastPathComponent): \(error)")
            }
        }

        // Sort by creation date (newest first)
        return watchers.sorted { $0.createdAt > $1.createdAt }
    }

    /// Load a single watcher by ID
    public static func load(id: UUID) -> Watcher? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Watcher.self, from: data)
        } catch {
            print("[Osaurus] Failed to load watcher \(id): \(error)")
            return nil
        }
    }

    /// Save a watcher to disk
    public static func save(_ watcher: Watcher) {
        let url = fileURL(for: watcher.id)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(watcher)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save watcher \(watcher.id): \(error)")
        }
    }

    /// Delete a watcher from disk
    /// - Returns: true if deletion was successful
    @discardableResult
    public static func delete(id: UUID) -> Bool {
        let url = fileURL(for: id)

        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            print("[Osaurus] Failed to delete watcher \(id): \(error)")
            return false
        }
    }

    /// Delete all watchers
    public static func deleteAll() {
        let fm = FileManager.default
        let dir = watchersDirectory

        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return
        }

        for file in files where file.pathExtension == "json" {
            try? fm.removeItem(at: file)
        }
    }
}
