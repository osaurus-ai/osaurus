//
//  SessionToolStateStore.swift
//  osaurus
//
//  Process-wide store for per-session loaded-tool + always-loaded snapshots
//  and the frozen enabled-capabilities manifest. Replaces a duplicated
//  `[id: SessionToolState]` map that previously lived inside both `ChatView`
//  (UUID-keyed) and `PluginHostAPI` (String-keyed).
//
//  Keeping a single store means there is exactly one place to debug "why
//  didn't this tool show up on turn 2?" and one cache invalidation rule
//  when a chat ends. Keys are strings — chat callers pass `UUID.uuidString`,
//  HTTP/plugin callers already use the request `session_id` string.
//

import Foundation

/// Per-session record of the first-turn always-loaded snapshot, every tool the
/// agent has loaded mid-session via `capabilities_load`, and the frozen
/// enabled-capabilities manifest. The composer uses this to keep the rendered
/// system prompt + `<tools>` block byte-stable across turns (required for
/// KV-cache reuse).
actor SessionToolStateStore {
    static let shared = SessionToolStateStore()

    private var states: [String: SessionToolState] = [:]

    /// Per-session record of the most recent send: turn index + the
    /// cache-hint hex used as the prompt-prefix fingerprint. Lets the
    /// caller log a `[Cache] turn=N hint=... prevHint=... match=...` line
    /// per send so we can audit whether KV reuse is actually happening.
    private var lastSendCacheHint: [String: (turn: Int, hint: String)] = [:]

    /// Per-session per-message fingerprint of the most recent send's
    /// conversation (hash + estimated tokens per message). The next send
    /// diffs against it to report how many conversation tokens the paged KV
    /// cache could reuse vs how many re-prefill — the conversation-level
    /// counterpart of the static-prefix `cacheHint` match.
    private var lastConversationSend: [String: ConversationFingerprint] = [:]

    private init() {}

    // MARK: - Conversation reuse accounting (pure helpers)

    /// Message-level fingerprint of an outbound conversation: a stable
    /// content hash and an estimated token count per message.
    struct ConversationFingerprint: Sendable {
        let hashes: [String]
        let tokens: [Int]

        init(messages: [ChatMessage]) {
            var hashes: [String] = []
            var tokens: [Int] = []
            hashes.reserveCapacity(messages.count)
            tokens.reserveCapacity(messages.count)
            for msg in messages {
                hashes.append(SessionToolStateStore.messageIdentityHash(msg))
                tokens.append(ContextBudgetManager.estimateTokens(forMessage: msg))
            }
            self.hashes = hashes
            self.tokens = tokens
        }
    }

    /// Estimated (reused, reprefilled) conversation tokens for a send,
    /// given the previous send's fingerprint. KV reuse is a CONTIGUOUS
    /// byte-prefix property, so reuse counts only the leading run of
    /// messages whose identity matches the previous send — and only when
    /// the static system+tools prefix ahead of them was itself stable
    /// (`staticPrefixMatched`); a static-prefix change re-prefills the
    /// entire stream regardless of conversation overlap.
    static func conversationReuse(
        previous: ConversationFingerprint?,
        current: ConversationFingerprint,
        staticPrefixMatched: Bool
    ) -> (reusedTokens: Int, reprefilledTokens: Int, reusedMessages: Int) {
        let total = current.tokens.reduce(0, +)
        guard staticPrefixMatched, let previous else {
            return (0, total, 0)
        }
        var matching = 0
        let limit = min(previous.hashes.count, current.hashes.count)
        while matching < limit, previous.hashes[matching] == current.hashes[matching] {
            matching += 1
        }
        let reused = current.tokens.prefix(matching).reduce(0, +)
        return (reused, total - reused, matching)
    }

    /// Stable identity hash for one message: role, content bytes, tool
    /// linkage, and tool-call payloads (FNV-1a, mirroring
    /// `CompactionWatermark`'s identity style).
    static func messageIdentityHash(_ msg: ChatMessage) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func fold(_ text: String) {
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            // Field separator so ("ab","c") never collides with ("a","bc").
            hash ^= 0x1F
            hash = hash &* 0x0000_0100_0000_01b3
        }
        fold(msg.role)
        fold(msg.content ?? "")
        fold(msg.tool_call_id ?? "")
        for call in msg.tool_calls ?? [] {
            fold(call.id)
            fold(call.function.name)
            fold(call.function.arguments)
        }
        return String(hash, radix: 16)
    }

    // MARK: - Reads

    func get(_ sessionId: String) -> SessionToolState? {
        states[sessionId]
    }

    // MARK: - Writes

    /// Initialise a session entry on first send. Caller passes the freshly
    /// computed always-loaded snapshot, plus the optional (executionMode,
    /// toolSelectionMode) fingerprint that captured it so a later send can
    /// detect a flip and invalidate.
    /// Idempotent: if an entry already exists (e.g. another turn raced
    /// ahead) we leave it alone so the snapshot stays stable.
    func setInitial(
        _ sessionId: String,
        alwaysLoadedNames: LoadedTools?,
        fingerprint: String? = nil,
        manifest: String? = nil,
        soul: String? = nil
    ) {
        guard states[sessionId] == nil else { return }
        states[sessionId] = SessionToolState(
            initialAlwaysLoadedNames: alwaysLoadedNames,
            sessionFingerprint: fingerprint,
            frozenManifest: manifest,
            frozenSoul: soul
        )
    }

    /// Drop the cached state for a session if its recorded (mode, toolMode)
    /// fingerprint no longer matches the live one. Called on every send
    /// before reading the cache so dynamically-loaded tools from one mode
    /// cannot leak into another, and a manual-mode empty-preflight cache
    /// cannot survive a flip back to auto.
    /// Returns `true` if an invalidation actually happened.
    @discardableResult
    func invalidateIfFingerprintChanged(
        _ sessionId: String,
        liveFingerprint: String
    ) -> Bool {
        guard let entry = states[sessionId] else { return false }
        // Legacy entries (pre-fingerprint) get stamped on first inspection
        // instead of invalidated — the live mode is presumed to be what
        // they were running under; the next genuine flip will catch it.
        guard let recorded = entry.sessionFingerprint else {
            var updated = entry
            updated.sessionFingerprint = liveFingerprint
            states[sessionId] = updated
            return false
        }
        if recorded == liveFingerprint { return false }
        states.removeValue(forKey: sessionId)
        lastSendCacheHint.removeValue(forKey: sessionId)
        lastConversationSend.removeValue(forKey: sessionId)
        return true
    }

    /// Append tool names loaded mid-session (via `capabilities_load` /
    /// `sandbox_plugin_register`). Creates the entry if missing — the
    /// caller supplies a fallback always-loaded snapshot so we don't lose
    /// schema stability when the load happens before the first compose
    /// captured a snapshot.
    func appendLoadedTools(
        _ sessionId: String,
        names: [String],
        fallbackAlwaysLoadedNames: LoadedTools?
    ) {
        var entry =
            states[sessionId]
            ?? SessionToolState(
                initialAlwaysLoadedNames: fallbackAlwaysLoadedNames
            )
        for name in names { entry.loadedToolNames.insert(name) }
        states[sessionId] = entry
    }

    // MARK: - Frozen user-message prefixes (HTTP / plugin paths)

    /// The session's frozen per-user-message memory prefixes (empty when
    /// none recorded). See `SessionToolState.frozenUserPrefixes`.
    func frozenUserPrefixes(_ sessionId: String) -> [String: String] {
        states[sessionId]?.frozenUserPrefixes ?? [:]
    }

    /// Record the prefix injected into a user message so later requests in
    /// the same session replay the exact bytes. Creates the entry if the
    /// session hasn't composed yet (the injection can run before
    /// `setInitial`).
    func recordUserPrefix(_ sessionId: String, key: String, prefix: String) {
        var entry = states[sessionId] ?? SessionToolState()
        entry.frozenUserPrefixes[key] = prefix
        states[sessionId] = entry
    }

    // MARK: - Cache fingerprint

    /// Record this send's cache-hint, emit a one-line `[Cache]` log entry,
    /// and stamp the matching TTFT trace fields. Lives on the store so the
    /// turn counter + previous-hint comparison sit next to the state they
    /// describe instead of being duplicated at every call site.
    ///
    /// When `conversation` is supplied (the full outbound message array;
    /// leading system messages are excluded here), the store also diffs it
    /// against the previous send's per-message fingerprint and logs
    /// conversation-level reuse: how many history tokens the paged KV cache
    /// can reuse (contiguous matching prefix) vs how many re-prefill. This
    /// is the regression tripwire for cross-turn byte divergence — before
    /// the frozen-turn-prefix fix, the last exchange re-prefilled every
    /// turn and this line would have shown it immediately. The computed
    /// stats are returned for tests / callers that want them.
    @discardableResult
    func recordSend(
        sessionId: String,
        cacheHint: String,
        trace: TTFTTrace?,
        conversation: [ChatMessage]? = nil
    ) -> (reusedTokens: Int, reprefilledTokens: Int, reusedMessages: Int)? {
        let prev = lastSendCacheHint[sessionId]
        let turn = (prev?.turn ?? 0) + 1
        lastSendCacheHint[sessionId] = (turn: turn, hint: cacheHint)

        let prevHintForLog = prev?.hint ?? "-"
        let matchStr: String
        if let prevHint = prev?.hint {
            matchStr = (prevHint == cacheHint) ? "true" : "false"
        } else {
            matchStr = "n/a"
        }
        debugLog(
            "[Cache] turn=\(turn) hint=\(cacheHint) prevHint=\(prevHintForLog) match=\(matchStr)"
        )
        trace?.set("cacheHint", cacheHint)
        trace?.set("cacheTurn", turn)
        trace?.set("cacheHintMatched", matchStr == "true" ? "1" : (matchStr == "n/a" ? "n/a" : "0"))

        guard let conversation else { return nil }
        // The static system+tools prefix is accounted by the hint above;
        // the conversation diff starts after it. A first send (no previous
        // hint) counts everything as prefill, matching a cold cache.
        let nonSystem = conversation.filter { $0.role != "system" }
        let fingerprint = ConversationFingerprint(messages: nonSystem)
        let reuse = Self.conversationReuse(
            previous: lastConversationSend[sessionId],
            current: fingerprint,
            staticPrefixMatched: matchStr == "true"
        )
        lastConversationSend[sessionId] = fingerprint
        debugLog(
            "[Cache] conv turn=\(turn) reused≈\(reuse.reusedTokens)t "
                + "reprefill≈\(reuse.reprefilledTokens)t "
                + "msgs=\(reuse.reusedMessages)/\(nonSystem.count)"
        )
        trace?.set("convReusedTokens", reuse.reusedTokens)
        trace?.set("convReprefilledTokens", reuse.reprefilledTokens)
        return reuse
    }

    // MARK: - Invalidation

    /// Drop the session's record. Call from chat-window close or HTTP
    /// session teardown so old state doesn't leak between conversations.
    func invalidate(_ sessionId: String) {
        states.removeValue(forKey: sessionId)
        lastSendCacheHint.removeValue(forKey: sessionId)
        lastConversationSend.removeValue(forKey: sessionId)
    }

    /// Drop every cached session entry. Used when a process-wide signal
    /// (e.g. the user picked a different working folder) makes EVERY
    /// session's preflight snapshot stale at once — the per-session
    /// `invalidate` API would require enumerating live sessions, which
    /// the store doesn't track.
    ///
    /// Folder swap is rare enough that throwing away every session's
    /// `loadedToolNames` (mid-session `capabilities_load` history) is an
    /// acceptable cost; a stable but wrong toolset is worse than a clean
    /// one-turn refresh.
    func invalidateAll() {
        states.removeAll()
        lastSendCacheHint.removeAll()
        lastConversationSend.removeAll()
    }

    /// Reset everything (test helper).
    func reset() {
        states.removeAll()
        lastSendCacheHint.removeAll()
        lastConversationSend.removeAll()
    }
}
