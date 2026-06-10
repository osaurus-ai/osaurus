//
//  CompactionWatermark.swift
//  osaurus
//
//  Sticky compaction state for KV-prefix-stable history trimming.
//
//  `ContextBudgetManager.trimMessages` recomputes summaries each call, which
//  can rewrite the middle of the message array between agent-loop iterations
//  and bust paged-KV prefix reuse. A watermark makes those decisions
//  persistent: once a message is summarized, the exact summary string is
//  replayed on every later trim; once a message is dropped, it stays
//  dropped. The trimmed transcript is therefore monotonic — the rendered
//  token prefix stays byte-stable across iterations as long as the caller's
//  untrimmed history is append-only.
//

import Foundation

/// Session/request-scoped record of compaction decisions, keyed by index
/// into the caller's untrimmed message array.
///
/// Thread-safe via an internal lock so a single instance can be shared
/// across loop iterations regardless of which executor runs the
/// `buildMessages` hook (MainActor in chat, NIO event loop in HTTP).
public final class CompactionWatermark: @unchecked Sendable {

    enum Decision {
        case dropped
        case summarized(String)
        /// The message was sent to the model VERBATIM in a rendered request.
        /// Once a message has been part of the token stream, summarizing it
        /// later would rewrite mid-transcript bytes and bust the KV prefix —
        /// so verbatim messages are only ever DROPPED (a pure truncation at
        /// one point), never newly summarized.
        case verbatim
    }

    private let lock = NSLock()
    /// Decision per original-array index.
    private var decisions: [Int: Decision] = [:]
    /// Identity fingerprint of the original message at each decided index,
    /// used to detect history rewrites (regeneration, edits).
    private var identities: [Int: String] = [:]

    public init() {}

    /// Fingerprint that's cheap to compute and stable for identical
    /// messages: role, content length, and tool-call linkage.
    private static func identity(of message: ChatMessage) -> String {
        "\(message.role)|\(message.content?.count ?? -1)|\(message.tool_call_id ?? "")|\(message.tool_calls?.count ?? 0)"
    }

    /// Verify recorded decisions still line up with the caller's history.
    /// If any decided index is out of range or its message identity changed
    /// (history was rewritten, not appended), all decisions reset and the
    /// next trim recomputes from scratch.
    func validate(against messages: [ChatMessage]) {
        lock.lock()
        defer { lock.unlock() }
        for (index, identity) in identities {
            guard index < messages.count, Self.identity(of: messages[index]) == identity else {
                decisions.removeAll()
                identities.removeAll()
                return
            }
        }
    }

    func decision(at index: Int) -> Decision? {
        lock.lock()
        defer { lock.unlock() }
        return decisions[index]
    }

    func recordSummary(_ summary: String, at index: Int, original: ChatMessage) {
        lock.lock()
        defer { lock.unlock() }
        decisions[index] = .summarized(summary)
        identities[index] = Self.identity(of: original)
    }

    func recordDrop(at index: Int, original: ChatMessage) {
        lock.lock()
        defer { lock.unlock() }
        decisions[index] = .dropped
        identities[index] = Self.identity(of: original)
    }

    /// Record that the message at `index` was sent to the model verbatim.
    /// Never overwrites an existing summarize/drop decision (those are
    /// stronger); re-recording verbatim is a no-op.
    func recordVerbatim(at index: Int, original: ChatMessage) {
        lock.lock()
        defer { lock.unlock() }
        guard decisions[index] == nil else { return }
        decisions[index] = .verbatim
        identities[index] = Self.identity(of: original)
    }

    var droppedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return decisions.values.reduce(0) { count, decision in
            if case .dropped = decision { return count + 1 }
            return count
        }
    }

    /// Whether any COMPACTING decision (summary or drop) has been recorded
    /// (used by surfaces to decide if a "compacted" indicator should show).
    /// Verbatim send markers are bookkeeping, not compaction.
    public var hasCompacted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return decisions.values.contains { decision in
            switch decision {
            case .dropped, .summarized: return true
            case .verbatim: return false
            }
        }
    }
}
