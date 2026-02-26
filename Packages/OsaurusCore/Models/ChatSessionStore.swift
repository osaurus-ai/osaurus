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

    /// Load all sessions sorted by updatedAt (most recent first).
    /// Only metadata is loaded (turns are empty). Use `load(id:)` for full session data.
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
                    let metadata = try decoder.decode(ChatSessionMetadata.self, from: Data(contentsOf: file))
                    return ChatSessionData(
                        id: metadata.id,
                        title: metadata.title,
                        createdAt: metadata.createdAt,
                        updatedAt: metadata.updatedAt,
                        selectedModel: metadata.selectedModel,
                        turns: [],
                        agentId: metadata.agentId
                    )
                } catch {
                    print("[Osaurus] Failed to load session from \(file.lastPathComponent): \(error)")
                    return nil
                }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Lightweight struct that skips decoding turns (the heaviest field).
    private struct ChatSessionMetadata: Decodable {
        let id: UUID
        let title: String
        let createdAt: Date
        let updatedAt: Date
        let selectedModel: String?
        let agentId: UUID?
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
        OsaurusPaths.resolvePath(new: OsaurusPaths.sessions(), legacy: "ChatSessions")
    }

    private static func sessionFileURL(for id: UUID) -> URL {
        sessionsDirectory().appendingPathComponent("\(id.uuidString).json")
    }
}
