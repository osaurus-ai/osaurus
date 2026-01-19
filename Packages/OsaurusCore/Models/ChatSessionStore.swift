//
//  ChatSessionStore.swift
//  osaurus
//
//  Persistence for ChatSessionData
//

import Foundation

@MainActor
enum ChatSessionStore {
    // MARK: - Public API

    /// Load all sessions sorted by updatedAt (most recent first)
    static func loadAll() -> [ChatSessionData] {
        let directory = sessionsDirectory()
        OsaurusPaths.ensureExistsSilent(directory)

        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return
            files
            .filter { $0.pathExtension == "json" }
            .compactMap { file -> ChatSessionData? in
                do {
                    return try decoder.decode(ChatSessionData.self, from: Data(contentsOf: file))
                } catch {
                    print("[Osaurus] Failed to load session from \(file.lastPathComponent): \(error)")
                    return nil
                }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Load a specific session by ID
    static func load(id: UUID) -> ChatSessionData? {
        let url = sessionFileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ChatSessionData.self, from: Data(contentsOf: url))
        } catch {
            print("[Osaurus] Failed to load session \(id): \(error)")
            return nil
        }
    }

    /// Save a session (creates or updates)
    static func save(_ session: ChatSessionData) {
        let url = sessionFileURL(for: session.id)
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(session).write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save session \(session.id): \(error)")
        }
    }

    /// Delete a session by ID
    static func delete(id: UUID) {
        try? FileManager.default.removeItem(at: sessionFileURL(for: id))
    }

    // MARK: - Private

    private static func sessionsDirectory() -> URL {
        OsaurusPaths.resolveDirectory(new: OsaurusPaths.sessions(), legacy: "ChatSessions")
    }

    private static func sessionFileURL(for id: UUID) -> URL {
        sessionsDirectory().appendingPathComponent("\(id.uuidString).json")
    }
}
