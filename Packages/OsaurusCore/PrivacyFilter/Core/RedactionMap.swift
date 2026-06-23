//
//  RedactionMap.swift
//  osaurus / PrivacyFilter
//
//  Per-conversation intern table: original string -> `Placeholder` ->
//  back to original on response. Lives in-memory only (see
//  SessionRedactionStore for the process-wide keyed cache) and is
//  cleared when a chat session resets.
//
//  An actor wraps the tables so the outbound scrubber and the inbound
//  `StreamingUnscrubber` can read/write from different tasks without
//  external locks.
//
//  Counter contract:
//    * On any APPROVED send, per-category counters are monotonic.
//      Skipping or forgetting an already-shipped placeholder never
//      reuses its index — `[PHONE_1]` is gone forever once it left
//      the machine.
//    * On a CANCELED detection (review sheet dismissed before
//      send), the pipeline rolls counters back via
//      `rollbackToSnapshot` so a retry on the same originals
//      reuses the same indices the user saw. Safe because the
//      canceled placeholders never escaped this map.
//

import Foundation

public actor RedactionMap {
    public let conversationID: UUID

    /// Maps `original text` -> minted `Placeholder`. Hit before
    /// minting so repeated occurrences of the same original reuse one
    /// placeholder.
    private var forward: [String: Placeholder] = [:]

    /// Maps placeholder `token` string -> original text. The
    /// `StreamingUnscrubber` looks up by token; constant-time access
    /// matters because every streamed chunk does at least one lookup
    /// per matched token.
    private var reverse: [String: String] = [:]

    /// Monotonic counters keyed by the placeholder's EFFECTIVE PREFIX
    /// (category default like `PHONE`, or a custom rule label like
    /// `CUSTOMER`). `intern` reads-then-bumps so indices are 1-based
    /// and contiguous within a prefix. Keying by prefix (not category)
    /// guarantees token uniqueness even when two custom rules in
    /// different categories share a label — they'd otherwise both mint
    /// `[LABEL_1]` for distinct originals and collide in `reverse`.
    private var counters: [String: Int] = [:]

    public init(conversationID: UUID) {
        self.conversationID = conversationID
    }

    // MARK: - Mint

    /// Intern a detected original string for the given category. If the
    /// same original has already been interned in this map (regardless
    /// of category, since the original is the dictionary key), the
    /// existing placeholder is returned. Otherwise a fresh
    /// `[CATEGORY_N]` placeholder is minted.
    public func intern(
        _ original: String,
        as category: EntityCategory,
        label: String? = nil
    ) -> Placeholder {
        if let existing = forward[original] {
            return existing
        }
        let prefix = label ?? category.prefix
        let next = (counters[prefix] ?? 0) + 1
        counters[prefix] = next
        let placeholder = Placeholder(category: category, index: next, prefixOverride: label)
        forward[original] = placeholder
        reverse[placeholder.token] = original
        return placeholder
    }

    /// Intern an entire segment's detections in a single actor hop.
    /// Hot-path optimisation: `PrivacyFilterEngine.detect` used to
    /// `await map.intern(…)` once per match, which on a 30-hit
    /// segment costs 30 actor hops. Batching collapses that into
    /// one hop and preserves the per-pair semantics (idempotent on
    /// repeat originals, monotonic category counters).
    public func internBatch(
        _ items: [(original: String, category: EntityCategory, label: String?)]
    ) -> [Placeholder] {
        var placeholders: [Placeholder] = []
        placeholders.reserveCapacity(items.count)
        for item in items {
            if let existing = forward[item.original] {
                placeholders.append(existing)
                continue
            }
            let prefix = item.label ?? item.category.prefix
            let next = (counters[prefix] ?? 0) + 1
            counters[prefix] = next
            let placeholder = Placeholder(
                category: item.category,
                index: next,
                prefixOverride: item.label
            )
            forward[item.original] = placeholder
            reverse[placeholder.token] = item.original
            placeholders.append(placeholder)
        }
        return placeholders
    }

    // MARK: - Resolve

    /// Lookup the original behind a placeholder token. Returns `nil`
    /// when the streamed text contained a `[CATEGORY_N]`-shaped token
    /// that was never minted (e.g. a hallucinated placeholder from the
    /// model). Callers should leave unknown tokens as-is.
    public func resolve(token: String) -> String? {
        reverse[token]
    }

    // MARK: - Rollback (cancel path)

    /// Drop a set of originals from the intern table. Per-category
    /// counters stay put — this is the "shipped, then forgotten"
    /// primitive used by `Forget redactions`.
    ///
    /// Most pipeline callers want `rollbackToSnapshot` instead,
    /// which also rewinds counters so a retry of the same
    /// originals reuses the same indices the user just saw.
    public func removeOriginals(_ originals: Set<String>) {
        guard !originals.isEmpty else { return }
        for original in originals {
            if let placeholder = forward.removeValue(forKey: original) {
                reverse.removeValue(forKey: placeholder.token)
            }
        }
    }

    /// Snapshot of the per-prefix counters. Captured pre-detection
    /// and replayed via `rollbackToSnapshot` on a canceled review.
    public var counterSnapshot: [String: Int] {
        counters
    }

    /// Restore the map to a pre-detection state: drop the freshly
    /// interned originals AND rewind per-category counters.
    ///
    /// Safe iff the canceled placeholders never escaped this map
    /// (no wire send, no log, no peer process). The pipeline's
    /// cancel branch satisfies that — Insights wire-body capture
    /// is gated on a successful send.
    public func rollbackToSnapshot(
        removingOriginals originals: Set<String>,
        counters snapshot: [String: Int]
    ) {
        removeOriginals(originals)
        counters = snapshot
    }

    // MARK: - Inspection

    /// Snapshot of every minted (placeholder, original) pair. Used by
    /// the review sheet's "always approve" path and by tests. Returned
    /// as a plain array — copies are cheap (string pairs).
    public func snapshot() -> [(Placeholder, String)] {
        forward.map { (original, placeholder) in (placeholder, original) }
    }

    /// Largest currently-minted token length (in characters). Used by
    /// `StreamingUnscrubber` to bound how much trailing text it has
    /// to buffer before deciding a `[` can't be the start of a
    /// placeholder.
    public var maxTokenLength: Int {
        reverse.keys.map(\.count).max() ?? 0
    }

    /// `true` when no entities have been interned yet. Used by the
    /// settings UI to disable the "Forget redactions" action when
    /// there's nothing to clear.
    public var isEmpty: Bool {
        forward.isEmpty
    }
}
