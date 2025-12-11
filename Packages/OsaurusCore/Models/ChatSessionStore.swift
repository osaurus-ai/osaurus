//
//  ChatSessionStore.swift
//  osaurus
//
//  Persistence for ChatSessionData (Application Support bundle directory)
//

import Foundation

@MainActor
enum ChatSessionStore {
    /// Optional directory override for tests
    static var overrideDirectory: URL?

    // MARK: - Public API

    /// Load all sessions sorted by updatedAt (most recent first)
    static func loadAll() -> [ChatSessionData] {
        let directory = sessionsDirectory()
        ensureDirectoryExists(directory)

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else {
            return []
        }

        var sessions: [ChatSessionData] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let session = try decoder.decode(ChatSessionData.self, from: data)
                sessions.append(session)
            } catch {
                print("[Osaurus] Failed to load session from \(file.lastPathComponent): \(error)")
            }
        }

        // Sort by updatedAt descending (most recent first)
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Load a specific session by ID
    static func load(id: UUID) -> ChatSessionData? {
        let url = sessionFileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ChatSessionData.self, from: data)
        } catch {
            print("[Osaurus] Failed to load session \(id): \(error)")
            return nil
        }
    }

    /// Save a session (creates or updates)
    static func save(_ session: ChatSessionData) {
        let url = sessionFileURL(for: session.id)
        ensureDirectoryExists(url.deletingLastPathComponent())

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(session)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save session \(session.id): \(error)")
        }
    }

    /// Delete a session by ID
    static func delete(id: UUID) {
        let url = sessionFileURL(for: id)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            print("[Osaurus] Failed to delete session \(id): \(error)")
        }
    }

    // MARK: - Private

    private static func sessionsDirectory() -> URL {
        if let overrideDirectory {
            return overrideDirectory.appendingPathComponent("ChatSessions", isDirectory: true)
        }
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "osaurus"
        return
            supportDir
            .appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent("ChatSessions", isDirectory: true)
    }

    private static func sessionFileURL(for id: UUID) -> URL {
        sessionsDirectory().appendingPathComponent("\(id.uuidString).json")
    }

    private static func ensureDirectoryExists(_ url: URL) {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                print("[Osaurus] Failed to create directory \(url.path): \(error)")
            }
        }
    }
}
