//
//  EventStore.swift
//  osaurus
//
//  One JSON file per event under `~/.osaurus/events/{uuid}.json`.
//

import Foundation

public enum EventStore {
    static var directory: URL {
        let dir = OsaurusPaths.events()
        OsaurusPaths.ensureExistsSilent(dir)
        return dir
    }

    static func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Every event on disk, newest first. A file that does not decode is
    /// skipped and logged, never deleted.
    public static func loadAll() -> [OsaurusEvent] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var events: [OsaurusEvent] = []
        for file in files where file.pathExtension == "json" {
            guard UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { continue }
            do {
                events.append(try decoder.decode(OsaurusEvent.self, from: Data(contentsOf: file)))
            } catch {
                print("[Osaurus] Failed to load event from \(file.lastPathComponent): \(error)")
            }
        }
        return events.sorted { $0.createdAt > $1.createdAt }
    }

    public static func load(id: UUID) -> OsaurusEvent? {
        let url = fileURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(OsaurusEvent.self, from: data)
    }

    public static func save(_ event: OsaurusEvent) {
        do {
            try encoder.encode(event).write(to: fileURL(for: event.id), options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save event \(event.id): \(error)")
        }
    }

    @discardableResult
    public static func delete(id: UUID) -> Bool {
        do {
            try FileManager.default.removeItem(at: fileURL(for: id))
            return true
        } catch {
            return false
        }
    }
}
