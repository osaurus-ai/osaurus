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
    /// Delegation-tool names (Subagent `spawn` / `image` / … schemas) that
    /// were visible on the FIRST compose of this session, captured on the
    /// HTTP `/agents/{id}/run` path. Echoed on turn 2+ instead of
    /// re-resolving live: the live resolution reads mutable state (per-agent
    /// toggles, whether an image model has finished downloading), so a
    /// mid-session flip would add/remove `<tools>` entries and re-introduce
    /// tool-block byte drift. `nil` means "no snapshot yet" — the next
    /// compose resolves live and records one. An EMPTY array is a valid
    /// frozen snapshot (no delegation tools were visible on turn 1).
    var frozenDelegationTools: [String]?
    /// Whether the `image` delegation schema was narrowed to generation-only
    /// on the FIRST compose (no ready edit model at the time). Frozen with
    /// `frozenDelegationTools` for the same byte-stability reason: an edit
    /// model finishing a download mid-session must not rewrite the `image`
    /// schema between turns. `nil` means "no snapshot yet" — the tri-state
    /// is intentional (a frozen `false` must be distinguishable from
    /// "resolve live").
    var frozenImageGenerationOnly: Bool?  // swiftlint:disable:this discouraged_optional_boolean
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
        frozenDelegationTools: [String]? = nil,
        // swiftlint:disable:next discouraged_optional_boolean
        frozenImageGenerationOnly: Bool? = nil,
        frozenUserPrefixes: [String: String] = [:]
    ) {
        self.loadedToolNames = loadedToolNames
        self.initialAlwaysLoadedNames = initialAlwaysLoadedNames
        self.sessionFingerprint = sessionFingerprint
        self.frozenManifest = frozenManifest
        self.frozenSoul = frozenSoul
        self.frozenDelegationTools = frozenDelegationTools
        self.frozenImageGenerationOnly = frozenImageGenerationOnly
        self.frozenUserPrefixes = frozenUserPrefixes
    }

    /// Canonical fingerprint string for a (mode, toolSelectionMode) pair.
    /// Centralised so the read and write sides cannot drift in shape.
    /// The folder ROOT is part of the identity: folders are per chat
    /// session now, and switching this chat's folder (or restoring a
    /// session against a different root) must invalidate cached tool
    /// state — the composed folder sections and git-tool availability
    /// both depend on which root is mounted, and a stale entry from the
    /// old root would silently keep composing against it.
    static func fingerprint(executionMode: ExecutionMode, toolMode: ToolSelectionMode) -> String {
        let modeTag: String
        switch executionMode {
        case .hostFolder(let context):
            modeTag = "host@\(folderIdentity(context))"
        // Combined sandbox + host-read carries a different tool surface
        // (host read tools present) than plain sandbox, so it gets its
        // own fingerprint — toggling a folder on/off while sandbox stays
        // on must invalidate any cached tool state for the prior surface.
        // The write grant changes the surface again (`file_write` /
        // `file_edit` appear, `sandbox_write_file` hides), so it forks
        // the fingerprint too.
        case .sandbox(let hostRead, let hostWrite):
            if let hostRead = hostRead {
                let grant = hostWrite ? "sandbox+hostwrite" : "sandbox+hostread"
                modeTag = "\(grant)@\(folderIdentity(hostRead))"
            } else {
                modeTag = "sandbox"
            }
        case .none: modeTag = "none"
        }
        return "\(modeTag)/\(toolMode.rawValue)"
    }

    /// Stable, non-sensitive identity for a mounted folder: a short hash of
    /// the standardized root path (the raw path never enters logs that print
    /// fingerprints).
    private static func folderIdentity(_ context: FolderContext) -> String {
        let path = context.rootPath.standardizedFileURL.path
        // FNV-1a rather than `Hasher` — Swift's Hasher is randomly seeded
        // per process, and this identity must be stable across composes.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
