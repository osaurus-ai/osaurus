//
//  SessionRedactionStore.swift
//  osaurus / PrivacyFilter
//
//  Process-wide cache of one `RedactionMap` per chat session,
//  modeled on `SessionToolStateStore`. The pipeline grabs the map
//  via `getOrCreate(_:)` at outbound time so detection on turn N
//  reuses placeholders interned on turn N-1, and the streaming
//  unscrubber on the inbound side asks the same map to resolve
//  placeholders the model echoes back.
//
//  Keys are `sessionId` strings — chat callers pass
//  `UUID.uuidString` from `ChatSession.sessionId`; HTTP/plugin callers
//  already pass `ChatCompletionRequest.session_id` in the same shape.
//

import Foundation

actor SessionRedactionStore {
    static let shared = SessionRedactionStore()

    /// One RedactionMap per session. Cleared on chat close / reset /
    /// switch via `invalidate(_:)`.
    private var maps: [String: RedactionMap] = [:]

    /// Sessions where the user has flipped "Always approve in this
    /// conversation" in the review sheet. Lives next to the maps so a
    /// single `invalidate(_:)` call wipes both.
    private var autoApproveSessions: Set<String> = []

    private init() {}

    // MARK: - Reads

    func get(_ sessionId: String) -> RedactionMap? {
        maps[sessionId]
    }

    /// Fetch the map for this session, minting one if absent. The
    /// `conversationID` is only used for tagging/logging — keying is
    /// purely by `sessionId` string.
    func getOrCreate(
        _ sessionId: String,
        conversationID: UUID
    ) -> RedactionMap {
        if let existing = maps[sessionId] {
            return existing
        }
        let map = RedactionMap(conversationID: conversationID)
        maps[sessionId] = map
        return map
    }

    /// True when the user opted into auto-approve for this session.
    /// The pipeline skips the review sheet in that case (still scrubs;
    /// just doesn't ask).
    func isAutoApproveEnabled(_ sessionId: String) -> Bool {
        autoApproveSessions.contains(sessionId)
    }

    // MARK: - Writes

    func setAutoApprove(_ sessionId: String, enabled: Bool) {
        if enabled {
            autoApproveSessions.insert(sessionId)
        } else {
            autoApproveSessions.remove(sessionId)
        }
    }

    // MARK: - Invalidation

    /// Drop the map + auto-approve flag for this session. Called from
    /// `ChatSession.reset()`, `ChatSession.load(from:)`, and from the
    /// "Forget redactions in this conversation" UI action.
    func invalidate(_ sessionId: String) {
        maps.removeValue(forKey: sessionId)
        autoApproveSessions.remove(sessionId)
    }

    /// Drop every session entry. Used by factory reset / test helpers.
    func invalidateAll() {
        maps.removeAll()
        autoApproveSessions.removeAll()
    }
}
