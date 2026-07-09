//
//  SessionToolState.swift
//  osaurus
//
//  Per-session record of the tools the agent is holding (always-loaded
//  baseline snapshot + every tool loaded mid-session via `capabilities_load`)
//  plus the frozen enabled-capabilities manifest. Keeps the rendered system
//  prompt + `<tools>` block byte-stable across turns to maximize KV-cache
//  reuse.
//

import Foundation

/// Per-session record of every tool the agent has loaded mid-session via
/// `capabilities_load`, the first-turn always-loaded snapshot, and the frozen
/// enabled-capabilities manifest. Stored on the chat window state (per
/// `sessionId`) and on the work session (per `issue.id`) so subsequent compose
/// calls feed the model the same tool union and the same static prompt prefix.
struct SessionToolState: Sendable {
    var loadedToolNames: LoadedTools
    /// Snapshot of always-loaded tool names from the FIRST compose of this
    /// session. On subsequent composes the resolver intersects the live
    /// always-loaded set against this snapshot so a tool that registers
    /// mid-session (e.g. sandbox_exec coming online a few seconds late)
    /// does NOT silently appear in turn 2's schema. Toolsets must stay
    /// stable mid-conversation — changing them breaks prompt caching and
    /// disorients the model. New tools only enter via the explicit
    /// `capabilities_load` path (which writes loadedToolNames).
    /// `nil` means "no snapshot yet" — the next compose will record one.
    var initialAlwaysLoadedNames: LoadedTools?
    /// Compact signature of the (executionMode, toolSelectionMode) that
    /// captured this state. The send path compares the live signature on
    /// every turn and invalidates on a flip, so dynamically-loaded tools
    /// from one mode cannot leak into another. `nil` only for legacy
    /// entries created before this field existed.
    var sessionFingerprint: String?
    /// Rendered enabled-capabilities manifest captured on the FIRST compose.
    /// Echoed back on turn 2+ via `ComposeRequest.frozenManifest` so the
    /// static system-prompt prefix stays byte-identical across the session
    /// (KV-cache reuse). `nil` means "no snapshot yet" — the next compose
    /// renders one fresh.
    var frozenManifest: String?
    /// Rendered SOUL.md content captured on the FIRST compose. Echoed back on
    /// turn 2+ via `ComposeRequest.frozenSoul` so a mid-session `SOUL.md`
    /// edit doesn't rewrite the static prefix — its own contract already says
    /// "edits apply on the next session", so freezing is semantically correct
    /// and keeps the cached prefix byte-stable. `nil` means "no snapshot yet"
    /// (or no SOUL content) — the next compose reads it fresh.
    var frozenSoul: String?
    /// Frozen per-user-message memory prefixes for surfaces whose history is
    /// client-owned (HTTP `/agents/{id}/run`, plugin host). Keyed by
    /// content-hash + occurrence of the ORIGINAL user message (see
    /// `SystemPromptComposer.applyFrozenMemoryPrefixes`); the value is the
    /// exact prefix bytes injected when that message was the latest. Later
    /// requests replay the prefix onto the matching history message so the
    /// wire bytes stay monotonic and the paged KV cache reuses the prior
    /// exchange. The chat surface doesn't use this — it freezes prefixes
    /// directly on its own `ChatTurn`s.
    var frozenUserPrefixes: [String: String] = [:]

    init(
        loadedToolNames: LoadedTools = [],
        initialAlwaysLoadedNames: LoadedTools? = nil,
        sessionFingerprint: String? = nil,
        frozenManifest: String? = nil,
        frozenSoul: String? = nil,
        frozenUserPrefixes: [String: String] = [:]
    ) {
        self.loadedToolNames = loadedToolNames
        self.initialAlwaysLoadedNames = initialAlwaysLoadedNames
        self.sessionFingerprint = sessionFingerprint
        self.frozenManifest = frozenManifest
        self.frozenSoul = frozenSoul
        self.frozenUserPrefixes = frozenUserPrefixes
    }

    /// Canonical fingerprint string for a (mode, toolSelectionMode) pair.
    /// Centralised so the read and write sides cannot drift in shape.
    static func fingerprint(executionMode: ExecutionMode, toolMode: ToolSelectionMode) -> String {
        let modeTag: String
        switch executionMode {
        case .hostFolder: modeTag = "host"
        // Combined sandbox + host-read carries a different tool surface
        // (host read tools present) than plain sandbox, so it gets its
        // own fingerprint — toggling a folder on/off while sandbox stays
        // on must invalidate any cached tool state for the prior surface.
        case .sandbox(let hostRead): modeTag = hostRead == nil ? "sandbox" : "sandbox+hostread"
        case .none: modeTag = "none"
        }
        return "\(modeTag)/\(toolMode.rawValue)"
    }
}
