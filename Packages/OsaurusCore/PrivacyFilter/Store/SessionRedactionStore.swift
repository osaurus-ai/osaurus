//
//  SessionRedactionStore.swift
//  osaurus / PrivacyFilter
//
//  Process-wide cache of one `RedactionMap` per privacy scope, plus the
//  conversation-level review choices that ride with it. The pipeline
//  grabs the map via `getOrCreate(_:)` at outbound time so detection on
//  turn N reuses placeholders interned on turn N-1, and the streaming
//  unscrubber on the inbound side asks the same map to resolve
//  placeholders the model echoes back.
//
//  Keys are privacy scope ids: the root chat session's
//  `UUID.uuidString`, shared by that chat's subagents and delegated
//  workers (`ChatExecutionContext.privacyScopeId`). HTTP/plugin callers
//  pass `ChatCompletionRequest.session_id` in the same shape.
//

import Foundation

/// What a conversation does with fresh detections. Set by the user from
/// the composer's privacy chip or the review sheet; a conversation with
/// no explicit choice follows `PrivacyFilterConfiguration.defaultReviewPolicy`.
public enum ConversationPrivacyPolicy: String, Sendable, CaseIterable {
    /// Ask about new items (tool results and model output follow their
    /// own settings).
    case ask
    /// Redact every new item without asking.
    case autoRedact
    /// Send this conversation's messages as written.
    case off

    init(_ policy: PrivacyReviewPolicy) {
        switch policy {
        case .ask: self = .ask
        case .autoRedact: self = .autoRedact
        }
    }
}

/// A conversation-wide answer for every item of one category.
public enum PrivacyCategoryDecision: String, Sendable {
    case alwaysRedact
    case neverRedact
}

actor SessionRedactionStore {
    static let shared = SessionRedactionStore()

    /// One RedactionMap per scope. Cleared on chat close / reset /
    /// switch via `invalidate(_:)`.
    private var maps: [String: RedactionMap] = [:]

    /// LRU-ordered scope ids — most recently used at the tail.
    /// Used to evict the oldest map when `maps.count` exceeds
    /// `lruCapacity`, so a long-running process that keeps minting
    /// fresh per-request UUIDs (the H3 fallback path) can't grow
    /// the table unboundedly. Policies and category decisions for
    /// evicted scopes are also dropped — the contract is "scope is
    /// gone, start fresh".
    private var lruOrder: [String] = []

    /// Conversation policies the user chose explicitly. A scope without
    /// an entry follows the global default.
    private var policies: [String: ConversationPrivacyPolicy] = [:]

    /// Per-category answers the user gave from a review row's menu.
    private var categoryDecisions: [String: [EntityCategory: PrivacyCategoryDecision]] = [:]

    /// Scopes with a detect → review pass in flight, and the passes
    /// waiting their turn. One pass per scope at a time, so two
    /// subagents finding the same value open one sheet, and the second
    /// pass sees the first one's decisions.
    private var reviewLockHolders: Set<String> = []
    private var reviewLockWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Soft cap on the number of `RedactionMap` instances retained
    /// in memory. Picked to comfortably exceed the realistic open
    /// chat count (open windows × open conversations) while still
    /// bounding the worst case where a buggy client keeps minting
    /// fresh session ids. When this cap is hit the LRU evicts the
    /// oldest map; the next request for that scope mints a new
    /// (empty) map, so placeholder stability across the gap is lost —
    /// acceptable because (a) the typical lifecycle is well below
    /// this, and (b) the alternative is unbounded heap growth.
    static let lruCapacity: Int = 64

    private init() {}

    // MARK: - Maps

    func get(_ scopeId: String) -> RedactionMap? {
        if let map = maps[scopeId] {
            touchLRU(scopeId)
            return map
        }
        return nil
    }

    /// Fetch the map for this scope, minting one if absent. The
    /// `conversationID` is only used for tagging/logging — keying is
    /// purely by scope id.
    func getOrCreate(
        _ scopeId: String,
        conversationID: UUID
    ) -> RedactionMap {
        if let existing = maps[scopeId] {
            touchLRU(scopeId)
            return existing
        }
        let map = RedactionMap(conversationID: conversationID)
        maps[scopeId] = map
        touchLRU(scopeId)
        evictIfNeeded()
        return map
    }

    /// Move `scopeId` to the recently-used end of the LRU order.
    /// Cheap O(n) — `lruOrder` is at most `lruCapacity` entries, so
    /// the linear `firstIndex` scan is bounded.
    private func touchLRU(_ scopeId: String) {
        if let idx = lruOrder.firstIndex(of: scopeId) {
            lruOrder.remove(at: idx)
        }
        lruOrder.append(scopeId)
    }

    private func evictIfNeeded() {
        while lruOrder.count > Self.lruCapacity {
            let oldest = lruOrder.removeFirst()
            maps.removeValue(forKey: oldest)
            policies.removeValue(forKey: oldest)
            categoryDecisions.removeValue(forKey: oldest)
        }
    }

    // MARK: - Conversation policy

    /// The policy the user picked for this conversation, or `nil` when
    /// it follows the global default.
    func explicitPolicy(_ scopeId: String) -> ConversationPrivacyPolicy? {
        policies[scopeId]
    }

    /// The policy in force: the conversation's own choice, else the
    /// global default.
    func effectivePolicy(
        _ scopeId: String,
        config: PrivacyFilterConfiguration
    ) -> ConversationPrivacyPolicy {
        policies[scopeId] ?? ConversationPrivacyPolicy(config.defaultReviewPolicy)
    }

    /// Set (or clear, with `nil`) this conversation's policy.
    func setPolicy(_ scopeId: String, _ policy: ConversationPrivacyPolicy?) {
        guard policies[scopeId] != policy else { return }
        policies[scopeId] = policy
        Self.postChange(scopeId)
    }

    func categoryDecision(_ scopeId: String, _ category: EntityCategory) -> PrivacyCategoryDecision? {
        categoryDecisions[scopeId]?[category]
    }

    func categoryDecisions(_ scopeId: String) -> [EntityCategory: PrivacyCategoryDecision] {
        categoryDecisions[scopeId] ?? [:]
    }

    func setCategoryDecision(
        _ scopeId: String,
        _ category: EntityCategory,
        _ decision: PrivacyCategoryDecision?
    ) {
        var decisions = categoryDecisions[scopeId] ?? [:]
        guard decisions[category] != decision else { return }
        decisions[category] = decision
        categoryDecisions[scopeId] = decisions.isEmpty ? nil : decisions
        Self.postChange(scopeId)
    }

    private nonisolated static func postChange(_ scopeId: String) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .privacyConversationPolicyChanged,
                object: nil,
                userInfo: ["scopeId": scopeId]
            )
        }
    }

    // MARK: - Review lock

    /// Wait until no other detect → review pass is running for this
    /// scope, then take the lock. Every call must be paired with
    /// `releaseReviewLock(_:)`.
    func acquireReviewLock(_ scopeId: String) async {
        if !reviewLockHolders.contains(scopeId) {
            reviewLockHolders.insert(scopeId)
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            reviewLockWaiters[scopeId, default: []].append(cont)
        }
    }

    /// Hand the lock to the next waiting pass, or free it.
    func releaseReviewLock(_ scopeId: String) {
        if var waiters = reviewLockWaiters[scopeId], !waiters.isEmpty {
            let next = waiters.removeFirst()
            reviewLockWaiters[scopeId] = waiters.isEmpty ? nil : waiters
            next.resume()
        } else {
            reviewLockHolders.remove(scopeId)
        }
    }

    // MARK: - Diagnostics

    /// Snapshot of every (scopeId, placeholder, original) triple
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

    /// "Forget Redactions in This Conversation": drop the placeholders
    /// and category answers so the next send detects and asks afresh.
    /// The conversation policy stays, since the composer chip shows it.
    func forget(_ scopeId: String) {
        maps.removeValue(forKey: scopeId)
        if let idx = lruOrder.firstIndex(of: scopeId) {
            lruOrder.remove(at: idx)
        }
        categoryDecisions.removeValue(forKey: scopeId)
        Self.postChange(scopeId)
    }

    /// Drop the map, policy and category decisions for this scope.
    /// Called from `ChatSession.reset()` and `ChatSession.load(from:)`.
    func invalidate(_ scopeId: String) {
        maps.removeValue(forKey: scopeId)
        if let idx = lruOrder.firstIndex(of: scopeId) {
            lruOrder.remove(at: idx)
        }
        let removedPolicy = policies.removeValue(forKey: scopeId)
        let removedDecisions = categoryDecisions.removeValue(forKey: scopeId)
        if removedPolicy != nil || removedDecisions != nil { Self.postChange(scopeId) }
    }

    /// Drop every scope entry. Used by "Forget Redactions in Every
    /// Conversation", factory reset and test helpers.
    func invalidateAll() {
        maps.removeAll()
        lruOrder.removeAll()
        policies.removeAll()
        categoryDecisions.removeAll()
        Self.postChange("")
    }
}

public extension Foundation.Notification.Name {
    /// Posted (on the main actor) when a conversation's privacy policy
    /// or category decisions change. userInfo: `scopeId` (`String`,
    /// empty when every conversation was cleared).
    static let privacyConversationPolicyChanged = Foundation.Notification.Name(
        "PrivacyConversationPolicyChanged"
    )
}
