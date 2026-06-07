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

    private init() {}

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
        manifest: String? = nil
    ) {
        guard states[sessionId] == nil else { return }
        states[sessionId] = SessionToolState(
            initialAlwaysLoadedNames: alwaysLoadedNames,
            sessionFingerprint: fingerprint,
            frozenManifest: manifest
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

    // MARK: - Cache fingerprint

    /// Record this send's cache-hint, emit a one-line `[Cache]` log entry,
    /// and stamp the matching TTFT trace fields. Lives on the store so the
    /// turn counter + previous-hint comparison sit next to the state they
    /// describe instead of being duplicated at every call site.
    func recordSend(
        sessionId: String,
        cacheHint: String,
        trace: TTFTTrace?
    ) {
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
    }

    // MARK: - Invalidation

    /// Drop the session's record. Call from chat-window close or HTTP
    /// session teardown so old state doesn't leak between conversations.
    func invalidate(_ sessionId: String) {
        states.removeValue(forKey: sessionId)
        lastSendCacheHint.removeValue(forKey: sessionId)
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
    }

    /// Reset everything (test helper).
    func reset() {
        states.removeAll()
        lastSendCacheHint.removeAll()
    }
}
