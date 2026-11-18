//
//  SyncLocalSessionState.swift
//  osaurus
//
//  Per-session state that stays on this device: the folder bookmark, tool
//  step logs, and turn fields that didn't fit a synced app data write.
//  One file per session under `sync-local/`, honoring the at-rest policy.
//

import Foundation

struct SyncLocalSessionState: Codable, Sendable {
    var folderBookmark: Data?
    /// Turn id → call id → step log.
    var toolCallLogs: [String: [String: SubagentRunLog]] = [:]
    /// Turn id → JSON object of fields dropped from the synced write.
    var overflow: [String: Data] = [:]

    var isEmpty: Bool { folderBookmark == nil && toolCallLogs.isEmpty && overflow.isEmpty }

    func overflowObject(forTurn id: UUID) -> JSONObject? {
        SyncConversationMapper.parseObject(overflow[id.uuidString.lowercased()])
    }
}

enum SyncLocalSessionStore {
    private static func url(for sessionId: UUID) -> URL {
        OsaurusPaths.syncLocalState().appendingPathComponent("\(sessionId.uuidString.lowercased()).json")
    }

    static func load(_ sessionId: UUID) -> SyncLocalSessionState? {
        guard let data = try? EncryptedFileStore.readPolicyAware(plaintextURL: url(for: sessionId)) else { return nil }
        return try? JSONDecoder().decode(SyncLocalSessionState.self, from: data)
    }

    static func save(_ state: SyncLocalSessionState, for sessionId: UUID) {
        guard !state.isEmpty else {
            delete(sessionId)
            return
        }
        do {
            let data = try JSONEncoder().encode(state)
            try EncryptedFileStore.writePolicyAware(data, toPlaintextURL: url(for: sessionId))
        } catch {
            print("[SyncLocalSessionStore] Failed to save local state for \(sessionId): \(error)")
        }
    }

    static func delete(_ sessionId: UUID) {
        EncryptedFileStore.removeTwins(forPlaintextURL: url(for: sessionId))
    }

    /// Local state for `session`: its bookmark, step logs and the overflow
    /// of each turn as it was just encoded.
    static func state(
        for session: ChatSessionData,
        overflow: [UUID: JSONObject]
    ) -> SyncLocalSessionState {
        var state = SyncLocalSessionState(folderBookmark: session.folderBookmark)
        for turn in session.turns where !turn.toolCallLogs.isEmpty {
            state.toolCallLogs[turn.id.uuidString.lowercased()] = turn.toolCallLogs
        }
        for (turnId, object) in overflow where !object.isEmpty {
            if let data = try? SyncConversationMapper.serialize(object) {
                state.overflow[turnId.uuidString.lowercased()] = data
            }
        }
        return state
    }
}
