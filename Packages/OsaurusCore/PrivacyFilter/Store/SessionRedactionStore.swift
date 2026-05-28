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

    /// LRU-ordered session ids — most recently used at the tail.
    /// Used to evict the oldest map when `maps.count` exceeds
    /// `lruCapacity`, so a long-running process that keeps minting
    /// fresh per-request UUIDs (the H3 fallback path) can't grow
    /// the table unboundedly. Auto-approve / require-review flags
    /// for evicted sessions are also dropped — the contract is
    /// "session is gone, start fresh".
    private var lruOrder: [String] = []

    /// Sessions where the user has flipped "Always approve in this
    /// conversation" in the review sheet. Lives next to the maps so a
    /// single `invalidate(_:)` call wipes both.
    private var autoApproveSessions: Set<String> = []

    /// Sessions that have OPTED OUT of the global "always approve"
    /// default. Wins over both `PrivacyFilterConfiguration.alwaysApproveByDefault`
    /// and `autoApproveSessions` — power users running with auto-approve
    /// globally can still force a single sensitive conversation to
    /// surface the review sheet.
    private var requireReviewSessions: Set<String> = []

    /// Soft cap on the number of `RedactionMap` instances retained
    /// in memory. Picked to comfortably exceed the realistic open
    /// chat count (open windows × open conversations) while still
    /// bounding the worst case where a buggy client keeps minting
    /// fresh session ids. When this cap is hit the LRU evicts the
    /// oldest map; the next request for that session id mints a
    /// new (empty) map, so placeholder stability across the gap
    /// is lost — acceptable because (a) the typical lifecycle is
    /// well below this, and (b) the alternative is unbounded heap
    /// growth.
    static let lruCapacity: Int = 64

    private init() {}

    // MARK: - Reads

    func get(_ sessionId: String) -> RedactionMap? {
        if let map = maps[sessionId] {
            touchLRU(sessionId)
            return map
        }
        return nil
    }

    /// Fetch the map for this session, minting one if absent. The
    /// `conversationID` is only used for tagging/logging — keying is
    /// purely by `sessionId` string.
    func getOrCreate(
        _ sessionId: String,
        conversationID: UUID
    ) -> RedactionMap {
        if let existing = maps[sessionId] {
            touchLRU(sessionId)
            return existing
        }
        let map = RedactionMap(conversationID: conversationID)
        maps[sessionId] = map
        touchLRU(sessionId)
        evictIfNeeded()
        return map
    }

    /// Move `sessionId` to the recently-used end of the LRU order.
    /// Cheap O(n) — `lruOrder` is at most `lruCapacity` entries, so
    /// the linear `firstIndex` scan is bounded.
    private func touchLRU(_ sessionId: String) {
        if let idx = lruOrder.firstIndex(of: sessionId) {
            lruOrder.remove(at: idx)
        }
        lruOrder.append(sessionId)
    }

    /// Drop the oldest entries until we're at or below
    /// `lruCapacity`. Eviction also drops any auto-approve /
    /// require-review flag for the dropped session because those
    /// rights belong to a live conversation, not a stale id.
    private func evictIfNeeded() {
        while lruOrder.count > Self.lruCapacity {
            let oldest = lruOrder.removeFirst()
            maps.removeValue(forKey: oldest)
            autoApproveSessions.remove(oldest)
            requireReviewSessions.remove(oldest)
        }
    }

    /// True when the user opted into auto-approve for this session.
    /// The pipeline skips the review sheet in that case (still scrubs;
    /// just doesn't ask).
    func isAutoApproveEnabled(_ sessionId: String) -> Bool {
        autoApproveSessions.contains(sessionId)
    }

    /// True when the user explicitly opted INTO review for this
    /// session. Wins over the global default and the per-session
    /// auto-approve flag — surfaces the sheet even if everything else
    /// would have silently approved.
    func isReviewRequired(_ sessionId: String) -> Bool {
        requireReviewSessions.contains(sessionId)
    }

    // MARK: - Writes

    func setAutoApprove(_ sessionId: String, enabled: Bool) {
        if enabled {
            autoApproveSessions.insert(sessionId)
            // Auto-approve and require-review are mutually exclusive
            // by definition; flipping one clears the other so the UI
            // can't get stuck in a contradictory state.
            requireReviewSessions.remove(sessionId)
        } else {
            autoApproveSessions.remove(sessionId)
        }
    }

    func setRequireReview(_ sessionId: String, enabled: Bool) {
        if enabled {
            requireReviewSessions.insert(sessionId)
            autoApproveSessions.remove(sessionId)
        } else {
            requireReviewSessions.remove(sessionId)
        }
    }

    // MARK: - Diagnostics

    /// Snapshot of every (sessionId, placeholder, original) triple
    /// currently interned. Intended for a developer-facing inspector
    /// UI (and for tests). The originals are PII — callers MUST NOT
    /// log, persist, or display the result outside an explicitly
    /// developer-mode surface.
    public struct InspectorEntry: Sendable {
        public let sessionId: String
        public let placeholder: Placeholder
        public let original: String
    }

    public func inspectorSnapshot() async -> [InspectorEntry] {
        var out: [InspectorEntry] = []
        for (sid, map) in maps {
            for (placeholder, original) in await map.snapshot() {
                out.append(
                    InspectorEntry(
                        sessionId: sid,
                        placeholder: placeholder,
                        original: original
                    )
                )
            }
        }
        return out
    }

    // MARK: - Invalidation

    /// Drop the map + auto-approve flag for this session. Called from
    /// `ChatSession.reset()`, `ChatSession.load(from:)`, and from the
    /// "Forget redactions in this conversation" UI action.
    func invalidate(_ sessionId: String) {
        maps.removeValue(forKey: sessionId)
        if let idx = lruOrder.firstIndex(of: sessionId) {
            lruOrder.remove(at: idx)
        }
        autoApproveSessions.remove(sessionId)
        requireReviewSessions.remove(sessionId)
    }

    /// Drop every session entry. Used by factory reset / test helpers.
    func invalidateAll() {
        maps.removeAll()
        lruOrder.removeAll()
        autoApproveSessions.removeAll()
        requireReviewSessions.removeAll()
    }
}
