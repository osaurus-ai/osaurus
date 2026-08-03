//
//  SubagentConfiguration.swift
//  osaurus
//
//  User policy for bounded local helper jobs launched by the main chat agent.
//

import Foundation

public enum SubagentPermissionPolicy: String, Codable, CaseIterable, Sendable {
    case ask
    case deny
    case alwaysAllow = "always_allow"

    public var displayName: String {
        switch self {
        case .ask: return L("Ask")
        case .deny: return L("Deny")
        case .alwaysAllow: return L("Always Allow")
        }
    }
}

enum SubagentImageLoadPolicy: String, Codable, CaseIterable, Sendable {
    case agentSingleResidency = "agent_single_residency"
    case unloadImageAfterAgentJob = "unload_image_after_agent_job"
    case manualPanelKeepsImageLoaded = "manual_panel_keeps_image_loaded"

    var displayName: String {
        switch self {
        case .agentSingleResidency: return L("Single Residency")
        case .unloadImageAfterAgentJob: return L("Unload After Agent Job")
        case .manualPanelKeepsImageLoaded: return L("Manual Panel Keeps Loaded")
        }
    }
}

/// How the AppleScript subagent's model is kept resident across calls. The
/// AppleScript bundle is always a DIFFERENT model than the chat model, so a
/// run must unload chat, load the AppleScript model, run, and reload chat
/// (single-GPU residency). Back-to-back `applescript` / `mac_query` calls pay
/// that whole round-trip each time under `.singleResidency`. `.keepWarmAfterJob`
/// instead keeps the AppleScript model resident for a short window after a run
/// (deferring the chat reload), so a follow-up call reuses it and skips the
/// swap — the biggest everyday latency win. Modeled on `SubagentImageLoadPolicy`.
public enum AppleScriptLoadPolicy: String, Codable, CaseIterable, Sendable {
    /// Restore the chat model immediately after every AppleScript run (the
    /// original behavior; one resident model at all times).
    case singleResidency = "single_residency"
    /// Keep the AppleScript model resident for `keepWarmSeconds` after a run so
    /// a follow-up AppleScript call reuses it. The chat model reload is deferred
    /// until the window elapses or a chat turn reloads it on demand.
    case keepWarmAfterJob = "keep_warm_after_job"

    public var displayName: String {
        switch self {
        case .singleResidency: return L("Single Residency")
        case .keepWarmAfterJob: return L("Keep Warm After Job")
        }
    }

    public var caption: String {
        switch self {
        case .singleResidency:
            return L("The chat model reloads right after each AppleScript run.")
        case .keepWarmAfterJob:
            return L(
                "The AppleScript model stays loaded briefly after a run so back-to-back automations are faster."
            )
        }
    }

    public static var `default`: AppleScriptLoadPolicy { .keepWarmAfterJob }

    /// How long the AppleScript model is kept resident after a run under
    /// `.keepWarmAfterJob` before the chat model is restored. Bounded so a warm
    /// hold can't strand the chat model unloaded indefinitely.
    public static let keepWarmSeconds = 90

    /// Tolerant decode so a malformed/legacy stored value resolves to the
    /// default rather than discarding the config.
    public init(storedValue raw: String?) {
        self = raw.flatMap(AppleScriptLoadPolicy.init(rawValue:)) ?? .default
    }

    /// The keep-warm window in seconds for this policy (`0` disables it).
    public var keepWarmSeconds: Int {
        self == .keepWarmAfterJob ? Self.keepWarmSeconds : 0
    }
}

/// The model-bundle kinds the Agent Delegation model pickers resolve. Only the
/// two image kinds remain — text `spawn` uses the spawnable agent's own model,
/// so there is no separate text-delegate model to pick.
enum SubagentModelKind: String, Codable, CaseIterable, Sendable {
    case imageGeneration = "image_generation"
    case imageEdit = "image_edit"
}

/// Per-kind permission gates for the delegation subagents, keyed by each kind's
/// capability id (`"spawn"`, `"image"`, …). Stored as a generic `[kindId:
/// policy]` map — NOT one field per kind — so a future permissioned kind needs
/// no new struct field: it reads/writes its own `capability.id`. A kind absent
/// from the map resolves to the safe `.ask` default.
///
/// Policy meaning: `.deny` blocks the kind's job; `.ask` prompts before
/// admission/model loading (`spawn_batch` prompts once for the whole batch);
/// `.alwaysAllow` skips the prompt.
public struct SubagentPermissionDefaults: Codable, Equatable, Sendable {
    private var policies: [String: SubagentPermissionPolicy]

    public init(policies: [String: SubagentPermissionPolicy] = [:]) {
        self.policies = policies
    }

    /// The policy for a kind id, defaulting to the safe `.ask` when unset.
    public func policy(for kindId: String) -> SubagentPermissionPolicy {
        policies[kindId] ?? .ask
    }

    /// Set the policy for a kind id.
    public mutating func setPolicy(_ policy: SubagentPermissionPolicy, for kindId: String) {
        policies[kindId] = policy
    }

    /// Three-way merge for a long-lived settings editor. Values the editor
    /// changed since its loaded baseline win; untouched values are refreshed
    /// from current persisted state. This prevents an unrelated debounced save
    /// from erasing an "Always Allow" decision persisted by a live permission
    /// prompt while the editor was already open.
    static func mergingEditorSnapshot(
        _ editor: SubagentPermissionDefaults,
        loadedBaseline: SubagentPermissionDefaults,
        live: SubagentPermissionDefaults
    ) -> SubagentPermissionDefaults {
        var merged = editor
        let kindIds =
            Set(editor.policies.keys)
            .union(loadedBaseline.policies.keys)
            .union(live.policies.keys)

        for kindId in kindIds
        where editor.policy(for: kindId) == loadedBaseline.policy(for: kindId) {
            if let livePolicy = live.policies[kindId] {
                merged.policies[kindId] = livePolicy
            } else {
                merged.policies.removeValue(forKey: kindId)
            }
        }
        return merged
    }

    private enum CodingKeys: String, CodingKey {
        /// Current schema: one `[kindId: rawValue]` map.
        case policies
        /// Legacy schema: top-level per-kind keys (pre-map). Decoded for
        /// migration only; never re-encoded — new writes use `policies`.
        case spawn, image
    }

    /// Lenient decode covering both the current map schema and the legacy
    /// per-field schema. A single invalid policy raw value (e.g. a hand-edited
    /// or version-migrated `"alwaysAllow"` where the enum expects
    /// `"always_allow"`) must NOT fail the decode of the whole struct — and,
    /// because the parent `SubagentConfiguration` decodes this with `try?`, a
    /// throw here used to discard the ENTIRE delegation configuration and
    /// silently fall back to all-defaults (delegation OFF), invisibly disabling
    /// the feature (BUG D). Each entry instead falls back to `.ask`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var merged: [String: SubagentPermissionPolicy] = [:]

        // Current schema: a `[kindId: rawValue]` map. Decode the raw strings and
        // map per-entry so one bad raw value is dropped (→ `.ask`) rather than
        // failing the whole map. `try?` flattens decodeIfPresent's optional.
        if let raw = try? c.decodeIfPresent([String: String].self, forKey: .policies) {
            for (kindId, rawPolicy) in raw {
                if let policy = SubagentPermissionPolicy(rawValue: rawPolicy) {
                    merged[kindId] = policy
                }
            }
        }

        // Legacy schema: top-level `spawn` / `image`. Only fill a key the current
        // map did not already provide (forward schema wins on conflict).
        func migrateLegacy(_ key: CodingKeys, _ kindId: String) {
            guard merged[kindId] == nil else { return }
            if let v = try? c.decodeIfPresent(SubagentPermissionPolicy.self, forKey: key) {
                merged[kindId] = v
            }
        }
        migrateLegacy(.spawn, SubagentCapabilityRegistry.spawn.id)
        migrateLegacy(.image, SubagentCapabilityRegistry.image.id)

        self.policies = merged
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(policies.mapValues(\.rawValue), forKey: .policies)
    }
}

/// Extra generic tools a spawned subagent (the child worker) may reach.
/// A configured target agent receives only the cancellation-audited subset of
/// its own enabled tools; a bare-model worker has no target-agent tools. `none`
/// adds nothing beyond that target contract. `readOnly` additionally exposes
/// the cancellation-audited subset of the curated generic read candidates
/// (currently host `file_read` / `file_search`) so the worker can do its own
/// bulk reading without ferrying file contents through the parent digest.
public enum SpawnToolAccess: String, Codable, CaseIterable, Sendable {
    case none
    case readOnly = "read_only"
}

public struct SubagentBudgets: Codable, Equatable, Sendable {
    public var maxDelegateTokens: Int
    public var maxDelegateTurns: Int
    /// Cap on child tool calls per spawn run when the launching agent grants
    /// tool access (`SpawnToolAccess.readOnly`). `0` means "use the built-in
    /// default cap" (`TextSubagentKind.defaultReadOnlyToolCallCap`) rather
    /// than zero calls, so enabling tool access is never silently inert.
    /// Ignored while tool access is `none` (text-only spawn refuses every
    /// call regardless).
    public var maxToolCalls: Int
    public var maxElapsedSeconds: Int
    /// Maximum number of jobs accepted by one `spawn_batch` call and an upper
    /// bound on concurrent workers. Engine occupancy, continuous-batching
    /// settings, RAM safety, and model-residency grouping can lower actual
    /// concurrency; different local models are serialized.
    public var maxParallelSpawns: Int

    /// Accepted bounds for each budget — the single source of truth shared by
    /// `normalized` (the save-time clamp) and the Subagents UI steppers, so the
    /// editor can never offer a value the store would silently clamp away.
    public static let tokenBounds: ClosedRange<Int> = 256 ... 32_768
    public static let turnBounds: ClosedRange<Int> = 1 ... 8
    public static let toolCallBounds: ClosedRange<Int> = 0 ... 32
    public static let elapsedBounds: ClosedRange<Int> = 15 ... 1_800
    /// Matches the Server Concurrent Sessions contract. RAM admission,
    /// current engine occupancy, Continuous Batching, and model residency can
    /// still split a configured batch into smaller execution waves.
    public static let parallelSpawnBounds: ClosedRange<Int> = 1 ... 32

    public init(
        maxDelegateTokens: Int = 2048,
        maxDelegateTurns: Int = 2,
        maxToolCalls: Int = 0,
        maxElapsedSeconds: Int = 120,
        maxParallelSpawns: Int = 3
    ) {
        self.maxDelegateTokens = maxDelegateTokens
        self.maxDelegateTurns = maxDelegateTurns
        self.maxToolCalls = maxToolCalls
        self.maxElapsedSeconds = maxElapsedSeconds
        self.maxParallelSpawns = maxParallelSpawns
    }

    public var normalized: SubagentBudgets {
        SubagentBudgets(
            maxDelegateTokens: Self.clamp(maxDelegateTokens, to: Self.tokenBounds),
            maxDelegateTurns: Self.clamp(maxDelegateTurns, to: Self.turnBounds),
            maxToolCalls: Self.clamp(maxToolCalls, to: Self.toolCallBounds),
            maxElapsedSeconds: Self.clamp(maxElapsedSeconds, to: Self.elapsedBounds),
            maxParallelSpawns: Self.clamp(maxParallelSpawns, to: Self.parallelSpawnBounds)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case maxDelegateTokens
        case maxDelegateTurns
        case maxToolCalls
        case maxElapsedSeconds
        case maxParallelSpawns
    }

    /// Backward-compatible decode for configurations written before batched
    /// spawning. Each value falls back independently so a missing or malformed
    /// field never discards the rest of the delegation configuration.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maxDelegateTokens: (try? container.decodeIfPresent(
                Int.self,
                forKey: .maxDelegateTokens
            )) ?? 2048,
            maxDelegateTurns: (try? container.decodeIfPresent(
                Int.self,
                forKey: .maxDelegateTurns
            )) ?? 2,
            maxToolCalls: (try? container.decodeIfPresent(
                Int.self,
                forKey: .maxToolCalls
            )) ?? 0,
            maxElapsedSeconds: (try? container.decodeIfPresent(
                Int.self,
                forKey: .maxElapsedSeconds
            )) ?? 120,
            maxParallelSpawns: (try? container.decodeIfPresent(
                Int.self,
                forKey: .maxParallelSpawns
            )) ?? 3
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maxDelegateTokens, forKey: .maxDelegateTokens)
        try container.encode(maxDelegateTurns, forKey: .maxDelegateTurns)
        try container.encode(maxToolCalls, forKey: .maxToolCalls)
        try container.encode(maxElapsedSeconds, forKey: .maxElapsedSeconds)
        try container.encode(maxParallelSpawns, forKey: .maxParallelSpawns)
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Stable identity and one-time migration helpers for spawnable agent pools.
///
/// Agent display names are user-editable and are not unique. Legacy name
/// entries therefore migrate only when exactly one current agent matches
/// case-insensitively. Missing and ambiguous names are deliberately dropped:
/// authorizing either `Helper` or `helper` by picking the first match would
/// silently grant the wrong model, prompt, and tool set.
enum SpawnableAgentIdentity {
    static func normalizedIDs(_ values: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return values.filter { seen.insert($0).inserted }
    }

    static func migratedIDs(
        ids: [UUID],
        legacyNames: [String],
        agents: [Agent]
    ) -> [UUID] {
        var result = normalizedIDs(ids)
        var seen = Set(result)

        for rawName in legacyNames {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let matches = agents.filter {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }
            guard matches.count == 1, seen.insert(matches[0].id).inserted else {
                continue
            }
            result.append(matches[0].id)
        }
        return result
    }
}

struct SubagentConfiguration: Codable, Equatable, Sendable {
    /// When true, a LOCAL orchestrator chat model may hand off to a local text
    /// `spawn` subagent: the orchestrator is unloaded for the job and reloaded
    /// after (single-residency handoff). On by default so enabling a capability
    /// on a local-model agent "just works"; the RAM-Safety preflight guards it,
    /// and a cloud orchestrator never needs it (nothing resident to unload).
    /// See `ChatResidencyHandoff` / `ResidencyHandoff`.
    var localTextDelegationEnabled: Bool
    /// The DEFAULT / main-chat agent's spawnable agents (its `spawn` pool).
    /// Empty by default → the main chat has nothing to spawn until opted in.
    /// Custom agents carry their OWN per-agent list in `AgentSettings`; this
    /// field governs the main chat only (edited in Settings → Subagents).
    var spawnableAgentIDs: [UUID]
    /// Decode-only compatibility payload. It is resolved against the complete
    /// live agent catalog, then cleared before the next save. New JSON never
    /// writes this field.
    var legacySpawnableAgentNames: [String]
    /// The DEFAULT / main-chat agent's `image` enable. Custom agents carry their
    /// own `AgentSettings.imageEnabled`; this governs the main chat only.
    var imageDelegationEnabled: Bool
    /// Backend-qualified generation selection. Bare legacy model ids decode as
    /// local targets so existing on-device selections keep working.
    var defaultImageGenerationTarget: MediaModelTarget?
    var defaultImageGenerationModelId: String? {
        get { defaultImageGenerationTarget?.modelID }
        set {
            defaultImageGenerationTarget = Self.normalizedModelId(newValue).map {
                MediaModelTarget(backend: .local, modelID: $0)
            }
        }
    }
    var defaultImageEditModelId: String?
    var videoDelegationEnabled: Bool
    var defaultTextToVideoTarget: MediaModelTarget?
    var defaultImageToVideoTarget: MediaModelTarget?
    var imageJobLoadPolicy: SubagentImageLoadPolicy
    /// The DEFAULT / main-chat agent's `applescript` enable. Custom agents carry
    /// their own `AgentSettings.appleScriptEnabled`; this governs the main chat
    /// only.
    var appleScriptDelegationEnabled: Bool
    /// The DEFAULT / main-chat agent's chosen AppleScript model id (`nil` →
    /// resolve to the first installed catalog model at run time). Custom agents
    /// use their own `AgentSettings.appleScriptModelId`.
    var defaultAppleScriptModelId: String?
    /// The DEFAULT / main-chat agent's AppleScript execution-mode (confirm each
    /// script vs auto-run with a warning). Custom agents use their own
    /// `AgentSettings.appleScriptExecutionMode`.
    var defaultAppleScriptExecutionMode: AppleScriptExecutionMode
    /// How the AppleScript model is kept resident across calls (single residency
    /// vs keep-warm-after-job). Global for every agent's AppleScript runs — the
    /// warm hold is a process-wide, single-GPU residency behavior, so it isn't
    /// per-agent. Defaults to keep-warm for the back-to-back latency win.
    var appleScriptLoadPolicy: AppleScriptLoadPolicy
    /// Read-model split: when true (default), a `mac_query` READ runs on the
    /// already-resident, tool-capable local chat model instead of swapping in
    /// the dedicated AppleScript model — skipping the multi-GB unload/reload
    /// round-trip on the most common path. Automation (`applescript`) always
    /// uses the dedicated model, and the query gate still blocks any mutation,
    /// so this trades only model quality (simple reads) for latency. The
    /// resolved model is always recorded in the run payload — never hidden.
    var appleScriptQueryPrefersResidentModel: Bool
    var permissionDefaults: SubagentPermissionDefaults
    var budgets: SubagentBudgets
    /// When true (default), a subagent/image job runs a refuse-before-evict RAM
    /// preflight: if the spawn model would not fit once the resident chat model
    /// is freed, the job is rejected instead of unloading the orchestrator and
    /// failing to load the spawn model. See `ChatResidencyHandoff.memoryPreflight`.
    var ramSafetyPreflightEnabled: Bool
    /// When true, a local spawn model may load ALONGSIDE the resident chat
    /// model instead of the unload→run→reload handoff — but only when the
    /// server eviction policy is Flexible (Multi Model) AND the live RAM
    /// projection says both fit (see `SubagentResidency.decidePlan`'s
    /// coexistence gate). Default OFF: two resident MLX graphs is the
    /// historical BUG G concurrent-GPU crash class, so single residency stays
    /// the default until the direction-matrix crash lane proves a machine's
    /// configuration safe. Strict eviction policy ignores this flag entirely.
    var subagentCoexistenceEnabled: Bool
    /// Per-capability model override for the DEFAULT / main-chat agent's subagent
    /// kinds, keyed by capability id (`"spawn"`, `"computer_use"`). An entry
    /// supersedes the kind's default model source; absent means "inherit". Custom
    /// agents carry their own `AgentSettings.subagentModelOverrides`.
    var subagentModelOverrides: [String: String]
    /// The DEFAULT / main-chat agent's spawnable MODELS (its `spawn_model` pool):
    /// raw model ids (local or remote) the main chat may hand a task to directly,
    /// no agent attached. Empty by default. Custom agents carry their OWN list
    /// in `AgentSettings`; this governs the main chat only.
    var spawnableModelNames: [String]
    /// Optional user-authored "when/how to use" note per spawnable model, keyed by
    /// model id. Pure descriptor metadata surfaced in the spawn guidance — the
    /// security gate stays on `spawnableModelNames`. Trimmed, blanks dropped, and
    /// pruned to current pool members on normalize.
    var spawnableModelNotes: [String: String]
    /// The DEFAULT / main-chat agent's child-tool grant for spawn runs. Custom
    /// agents carry their own `AgentSettings.spawnToolAccess`; this governs the
    /// main chat only. Default `.none` (text-only spawn).
    var spawnToolAccess: SpawnToolAccess

    init(
        localTextDelegationEnabled: Bool = true,
        spawnableAgentIDs: [UUID] = [],
        spawnableAgentNames: [String] = [],
        imageDelegationEnabled: Bool = false,
        defaultImageGenerationModelId: String? = nil,
        defaultImageGenerationTarget: MediaModelTarget? = nil,
        defaultImageEditModelId: String? = nil,
        videoDelegationEnabled: Bool = false,
        defaultTextToVideoTarget: MediaModelTarget? = nil,
        defaultImageToVideoTarget: MediaModelTarget? = nil,
        imageJobLoadPolicy: SubagentImageLoadPolicy = .agentSingleResidency,
        appleScriptDelegationEnabled: Bool = false,
        defaultAppleScriptModelId: String? = nil,
        defaultAppleScriptExecutionMode: AppleScriptExecutionMode = .default,
        appleScriptLoadPolicy: AppleScriptLoadPolicy = .default,
        appleScriptQueryPrefersResidentModel: Bool = true,
        permissionDefaults: SubagentPermissionDefaults = SubagentPermissionDefaults(),
        budgets: SubagentBudgets = SubagentBudgets(),
        ramSafetyPreflightEnabled: Bool = true,
        subagentCoexistenceEnabled: Bool = false,
        subagentModelOverrides: [String: String] = [:],
        spawnableModelNames: [String] = [],
        spawnableModelNotes: [String: String] = [:],
        spawnToolAccess: SpawnToolAccess = .none
    ) {
        self.localTextDelegationEnabled = localTextDelegationEnabled
        self.spawnableAgentIDs = SpawnableAgentIdentity.normalizedIDs(spawnableAgentIDs)
        self.legacySpawnableAgentNames = spawnableAgentNames
        self.imageDelegationEnabled = imageDelegationEnabled
        self.defaultImageGenerationTarget =
            Self.normalizedTarget(defaultImageGenerationTarget)
            ?? Self.normalizedModelId(defaultImageGenerationModelId).map {
                MediaModelTarget(backend: .local, modelID: $0)
            }
        self.defaultImageEditModelId = defaultImageEditModelId
        self.videoDelegationEnabled = videoDelegationEnabled
        self.defaultTextToVideoTarget = Self.normalizedTarget(defaultTextToVideoTarget)
        self.defaultImageToVideoTarget = Self.normalizedTarget(defaultImageToVideoTarget)
        self.imageJobLoadPolicy = imageJobLoadPolicy
        self.appleScriptDelegationEnabled = appleScriptDelegationEnabled
        self.defaultAppleScriptModelId = Self.normalizedModelId(defaultAppleScriptModelId)
        self.defaultAppleScriptExecutionMode = defaultAppleScriptExecutionMode
        self.appleScriptLoadPolicy = appleScriptLoadPolicy
        self.appleScriptQueryPrefersResidentModel = appleScriptQueryPrefersResidentModel
        self.permissionDefaults = permissionDefaults
        self.budgets = budgets.normalized
        self.ramSafetyPreflightEnabled = ramSafetyPreflightEnabled
        self.subagentCoexistenceEnabled = subagentCoexistenceEnabled
        self.subagentModelOverrides = Self.normalizedModelOverrides(subagentModelOverrides)
        let normalizedModelNames = Self.normalizedSpawnableModelNames(spawnableModelNames)
        self.spawnableModelNames = normalizedModelNames
        self.spawnableModelNotes = Self.normalizedSpawnableModelNotes(
            spawnableModelNotes,
            names: normalizedModelNames
        )
        self.spawnToolAccess = spawnToolAccess
    }

    static let `default` = SubagentConfiguration()

    /// Three-way merge for long-lived settings surfaces backed by the shared
    /// configuration document. A field changed by the editor since it loaded
    /// wins; an untouched field adopts the latest store value. This lets the
    /// main Spawn, AppleScript, and Image editors save their independent slices
    /// without erasing a concurrent permission decision or another open
    /// editor's update.
    static func mergingEditorSnapshot(
        _ editor: SubagentConfiguration,
        loadedBaseline: SubagentConfiguration,
        live: SubagentConfiguration
    ) -> SubagentConfiguration {
        var merged = editor
        mergeEditorField(
            \.localTextDelegationEnabled,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        mergeEditorField(
            \.spawnableAgentIDs,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        mergeEditorField(
            \.legacySpawnableAgentNames,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        mergeEditorField(
            \.imageDelegationEnabled,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        mergeEditorField(
            \.defaultImageGenerationModelId,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        mergeEditorField(
            \.defaultImageEditModelId,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        mergeEditorField(
            \.imageJobLoadPolicy,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        mergeEditorField(
            \.appleScriptDelegationEnabled,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        mergeEditorField(
            \.defaultAppleScriptModelId,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        mergeEditorField(
            \.defaultAppleScriptExecutionMode,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        mergeEditorField(
            \.appleScriptLoadPolicy,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        mergeEditorField(
            \.appleScriptQueryPrefersResidentModel,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        merged.permissionDefaults = SubagentPermissionDefaults.mergingEditorSnapshot(
            editor.permissionDefaults,
            loadedBaseline: loadedBaseline.permissionDefaults,
            live: live.permissionDefaults
        )
        mergeEditorField(
            \.budgets,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        mergeEditorField(
            \.ramSafetyPreflightEnabled,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        mergeEditorField(
            \.subagentCoexistenceEnabled,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        mergeEditorField(
            \.subagentModelOverrides,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        mergeEditorField(
            \.spawnableModelNames,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        mergeEditorField(
            \.spawnableModelNotes,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        mergeEditorField(
            \.spawnToolAccess,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        return merged.normalized
    }

    private static func mergeEditorField<Value: Equatable>(
        _ keyPath: WritableKeyPath<SubagentConfiguration, Value>,
        editor: SubagentConfiguration,
        loadedBaseline: SubagentConfiguration,
        live: SubagentConfiguration,
        into merged: inout SubagentConfiguration
    ) {
        if editor[keyPath: keyPath] == loadedBaseline[keyPath: keyPath] {
            merged[keyPath: keyPath] = live[keyPath: keyPath]
        }
    }

    /// A local orchestrator may hand off to a local text subagent (unload/reload).
    var localOrchestratorTextHandoffActive: Bool {
        localTextDelegationEnabled
    }

    /// Whether the identified agent is reachable via `spawn` from the DEFAULT /
    /// main chat (the main-chat pool). Custom agents use their own per-agent list
    /// via `SubagentToolVisibility.spawnTargetAllowed`.
    func isAgentSpawnable(_ id: UUID) -> Bool {
        spawnableAgentIDs.contains(id)
    }

    /// Whether the DEFAULT / main chat has at least one spawnable agent.
    var anyAgentSpawnable: Bool {
        !spawnableAgentIDs.isEmpty
    }

    /// Whether the raw model id is in the DEFAULT / main chat's `spawn_model`
    /// pool. Model ids are canonical, so this matches exactly (trimmed) rather
    /// than case-insensitively like agent names. Custom agents use their own list
    /// via `SubagentToolVisibility.spawnModelAllowed`.
    func isModelSpawnable(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return spawnableModelNames.contains(trimmed)
    }

    /// Whether the DEFAULT / main chat has at least one spawnable model.
    var anyModelSpawnable: Bool {
        !spawnableModelNames.isEmpty
    }

    /// The user's "when/how to use" note for a spawnable model id, or nil when
    /// none is set (after trimming). Surfaced in the spawn guidance descriptor.
    func modelNote(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let note = spawnableModelNotes[trimmed]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !note.isEmpty
        else { return nil }
        return note
    }

    /// Whether `image` is active for the DEFAULT / main chat (its image switch).
    /// Custom agents gate on their own `AgentSettings.imageEnabled`.
    var imageDelegationActive: Bool {
        imageDelegationEnabled
    }

    /// Whether `applescript` is active for the DEFAULT / main chat (its
    /// AppleScript switch). Custom agents gate on their own
    /// `AgentSettings.appleScriptEnabled`.
    var appleScriptDelegationActive: Bool {
        appleScriptDelegationEnabled
    }

    /// Whether an agent-launched image job must evict resident chat models for
    /// the duration of the job (single-GPU-residency handoff). The other load
    /// policies keep the chat model resident. Single source for the image
    /// residency decision (was `NativeImageChatResidencyPolicy`).
    var imageJobUnloadsChatModels: Bool {
        imageJobLoadPolicy == .agentSingleResidency
    }

    var normalized: SubagentConfiguration {
        SubagentConfiguration(
            localTextDelegationEnabled: localTextDelegationEnabled,
            spawnableAgentIDs: spawnableAgentIDs,
            spawnableAgentNames: legacySpawnableAgentNames,
            imageDelegationEnabled: imageDelegationEnabled,
            defaultImageGenerationTarget: Self.normalizedTarget(defaultImageGenerationTarget),
            defaultImageEditModelId: Self.normalizedModelId(defaultImageEditModelId),
            videoDelegationEnabled: videoDelegationEnabled,
            defaultTextToVideoTarget: Self.normalizedTarget(defaultTextToVideoTarget),
            defaultImageToVideoTarget: Self.normalizedTarget(defaultImageToVideoTarget),
            imageJobLoadPolicy: imageJobLoadPolicy,
            appleScriptDelegationEnabled: appleScriptDelegationEnabled,
            defaultAppleScriptModelId: Self.normalizedModelId(defaultAppleScriptModelId),
            defaultAppleScriptExecutionMode: defaultAppleScriptExecutionMode,
            appleScriptLoadPolicy: appleScriptLoadPolicy,
            appleScriptQueryPrefersResidentModel: appleScriptQueryPrefersResidentModel,
            permissionDefaults: permissionDefaults,
            budgets: budgets.normalized,
            // Preserve the user's RAM-safety choice across the save/load round-trip.
            // Omitting this dropped it back to the init default (`true`), making the
            // toggle un-disableable (the store runs `.normalized` on every save+load).
            ramSafetyPreflightEnabled: ramSafetyPreflightEnabled,
            subagentCoexistenceEnabled: subagentCoexistenceEnabled,
            subagentModelOverrides: subagentModelOverrides,
            // The init trims model names, drops blanks, and prunes notes to the
            // surviving pool members, so passing the raw values here is enough.
            spawnableModelNames: spawnableModelNames,
            spawnableModelNotes: spawnableModelNotes,
            spawnToolAccess: spawnToolAccess
        )
    }

    /// Resolve legacy name grants once the complete agent catalog is known.
    /// The result is UUID-only even when no legacy entry can be migrated.
    func migratingLegacyAgentNames(using agents: [Agent]) -> SubagentConfiguration {
        var migrated = self
        migrated.spawnableAgentIDs = SpawnableAgentIdentity.migratedIDs(
            ids: spawnableAgentIDs,
            legacyNames: legacySpawnableAgentNames,
            agents: agents
        )
        migrated.legacySpawnableAgentNames = []
        return migrated.normalized
    }

    enum CodingKeys: String, CodingKey {
        case localTextDelegationEnabled
        case spawnableAgentIDs
        /// Legacy decode-only key.
        case spawnableAgentNames
        case imageDelegationEnabled
        case defaultImageGenerationTarget
        /// Legacy decode-only key.
        case defaultImageGenerationModelId
        case defaultImageEditModelId
        case videoDelegationEnabled
        case defaultTextToVideoTarget
        case defaultImageToVideoTarget
        case imageJobLoadPolicy
        case appleScriptDelegationEnabled
        case defaultAppleScriptModelId
        case defaultAppleScriptExecutionMode
        case appleScriptLoadPolicy
        case appleScriptQueryPrefersResidentModel
        case permissionDefaults
        case budgets
        case ramSafetyPreflightEnabled
        case subagentCoexistenceEnabled
        case subagentModelOverrides
        case spawnableModelNames
        case spawnableModelNotes
        case spawnToolAccess
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedImageTarget =
            try? container.decodeIfPresent(
                MediaModelTarget.self,
                forKey: .defaultImageGenerationTarget
            )
        let legacyImageModelID =
            try container.decodeIfPresent(
                String.self,
                forKey: .defaultImageGenerationModelId
            )
        self.init(
            localTextDelegationEnabled: try container.decodeIfPresent(Bool.self, forKey: .localTextDelegationEnabled)
                ?? true,
            spawnableAgentIDs: (try? container.decodeIfPresent(
                [UUID].self,
                forKey: .spawnableAgentIDs
            )) ?? [],
            spawnableAgentNames: try container.decodeIfPresent([String].self, forKey: .spawnableAgentNames) ?? [],
            imageDelegationEnabled: try container.decodeIfPresent(Bool.self, forKey: .imageDelegationEnabled) ?? false,
            defaultImageGenerationModelId: nil,
            defaultImageGenerationTarget:
                decodedImageTarget
                ?? legacyImageModelID.flatMap { Self.normalizedModelId($0) }.map {
                    MediaModelTarget(backend: .local, modelID: $0)
                },
            defaultImageEditModelId: try container.decodeIfPresent(String.self, forKey: .defaultImageEditModelId),
            videoDelegationEnabled:
                try container.decodeIfPresent(Bool.self, forKey: .videoDelegationEnabled) ?? false,
            defaultTextToVideoTarget:
                try? container.decodeIfPresent(
                    MediaModelTarget.self,
                    forKey: .defaultTextToVideoTarget
                ),
            defaultImageToVideoTarget:
                try? container.decodeIfPresent(
                    MediaModelTarget.self,
                    forKey: .defaultImageToVideoTarget
                ),
            // Enum fields use `(try? …) ?? default` so a single invalid/renamed
            // raw value falls back to its default instead of throwing — a throw
            // here would discard the ENTIRE delegation config (see the lenient
            // decode note on SubagentPermissionDefaults). `try?` flattens
            // decodeIfPresent's optional, so absent and unparseable both -> default.
            imageJobLoadPolicy: (try? container.decodeIfPresent(
                SubagentImageLoadPolicy.self,
                forKey: .imageJobLoadPolicy
            )) ?? .agentSingleResidency,
            appleScriptDelegationEnabled: try container.decodeIfPresent(
                Bool.self,
                forKey: .appleScriptDelegationEnabled
            ) ?? false,
            defaultAppleScriptModelId: try container.decodeIfPresent(
                String.self,
                forKey: .defaultAppleScriptModelId
            ),
            // Enum field: `(try? …) ?? default` so an invalid/renamed raw value
            // falls back to the safe `confirmEach` rather than discarding the
            // whole delegation config.
            defaultAppleScriptExecutionMode: (try? container.decodeIfPresent(
                AppleScriptExecutionMode.self,
                forKey: .defaultAppleScriptExecutionMode
            )) ?? .default,
            // Enum field: lenient like the other enums (absent or unparseable →
            // the keep-warm default) so an old config gains the latency win.
            appleScriptLoadPolicy: (try? container.decodeIfPresent(
                AppleScriptLoadPolicy.self,
                forKey: .appleScriptLoadPolicy
            )) ?? .default,
            // Absent (old config) → true: the read-model split is a pure
            // latency win with the query gate still blocking mutations.
            appleScriptQueryPrefersResidentModel: try container.decodeIfPresent(
                Bool.self,
                forKey: .appleScriptQueryPrefersResidentModel
            ) ?? true,
            permissionDefaults: (try? container.decodeIfPresent(
                SubagentPermissionDefaults.self,
                forKey: .permissionDefaults
            )) ?? SubagentPermissionDefaults(),
            budgets: try container.decodeIfPresent(SubagentBudgets.self, forKey: .budgets)
                ?? SubagentBudgets(),
            ramSafetyPreflightEnabled: try container.decodeIfPresent(
                Bool.self,
                forKey: .ramSafetyPreflightEnabled
            ) ?? true,
            subagentCoexistenceEnabled: try container.decodeIfPresent(
                Bool.self,
                forKey: .subagentCoexistenceEnabled
            ) ?? false,
            // Lenient: a malformed map must never discard the whole delegation
            // config (same approach as `permissionDefaults`).
            subagentModelOverrides: (try? container.decodeIfPresent(
                [String: String].self,
                forKey: .subagentModelOverrides
            )) ?? [:],
            spawnableModelNames: (try? container.decodeIfPresent(
                [String].self,
                forKey: .spawnableModelNames
            )) ?? [],
            spawnableModelNotes: (try? container.decodeIfPresent(
                [String: String].self,
                forKey: .spawnableModelNotes
            )) ?? [:],
            // Enum field: lenient like the other enums so an invalid raw value
            // falls back to the safe text-only default.
            spawnToolAccess: (try? container.decodeIfPresent(
                SpawnToolAccess.self,
                forKey: .spawnToolAccess
            )) ?? .none
        )
    }

    func encode(to encoder: Encoder) throws {
        let value = normalized
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.localTextDelegationEnabled, forKey: .localTextDelegationEnabled)
        try container.encode(value.spawnableAgentIDs, forKey: .spawnableAgentIDs)
        try container.encode(value.imageDelegationEnabled, forKey: .imageDelegationEnabled)
        try container.encodeIfPresent(
            value.defaultImageGenerationTarget,
            forKey: .defaultImageGenerationTarget
        )
        try container.encodeIfPresent(
            value.defaultImageEditModelId,
            forKey: .defaultImageEditModelId
        )
        try container.encode(value.videoDelegationEnabled, forKey: .videoDelegationEnabled)
        try container.encodeIfPresent(
            value.defaultTextToVideoTarget,
            forKey: .defaultTextToVideoTarget
        )
        try container.encodeIfPresent(
            value.defaultImageToVideoTarget,
            forKey: .defaultImageToVideoTarget
        )
        try container.encode(value.imageJobLoadPolicy, forKey: .imageJobLoadPolicy)
        try container.encode(
            value.appleScriptDelegationEnabled,
            forKey: .appleScriptDelegationEnabled
        )
        try container.encodeIfPresent(
            value.defaultAppleScriptModelId,
            forKey: .defaultAppleScriptModelId
        )
        try container.encode(
            value.defaultAppleScriptExecutionMode,
            forKey: .defaultAppleScriptExecutionMode
        )
        try container.encode(value.appleScriptLoadPolicy, forKey: .appleScriptLoadPolicy)
        try container.encode(
            value.appleScriptQueryPrefersResidentModel,
            forKey: .appleScriptQueryPrefersResidentModel
        )
        try container.encode(value.permissionDefaults, forKey: .permissionDefaults)
        try container.encode(value.budgets, forKey: .budgets)
        try container.encode(
            value.ramSafetyPreflightEnabled,
            forKey: .ramSafetyPreflightEnabled
        )
        try container.encode(
            value.subagentCoexistenceEnabled,
            forKey: .subagentCoexistenceEnabled
        )
        try container.encode(value.subagentModelOverrides, forKey: .subagentModelOverrides)
        try container.encode(value.spawnableModelNames, forKey: .spawnableModelNames)
        try container.encode(value.spawnableModelNotes, forKey: .spawnableModelNotes)
        try container.encode(value.spawnToolAccess, forKey: .spawnToolAccess)
    }

    private static func normalizedModelId(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedTarget(_ value: MediaModelTarget?) -> MediaModelTarget? {
        guard let value, value.isValid else { return nil }
        return MediaModelTarget(backend: value.backend, modelID: value.modelID)
    }

    /// Trim values and drop blank entries so a cleared picker (empty string)
    /// round-trips as "no override" instead of an empty-string model id.
    private static func normalizedModelOverrides(_ value: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, raw) in value {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result[key] = trimmed }
        }
        return result
    }

    /// Trim spawnable model ids, drop blanks, and de-dupe (exact match, keeping
    /// first occurrence + order) so a model can't stack pool entries.
    static func normalizedSpawnableModelNames(_ value: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in value {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// Trim note keys/values, drop blank notes, and prune any note whose model id
    /// is not in the (already-normalized) pool so removing a model drops its note.
    static func normalizedSpawnableModelNotes(
        _ value: [String: String],
        names: [String]
    ) -> [String: String] {
        let allowed = Set(names)
        var result: [String: String] = [:]
        for (key, raw) in value {
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowed.contains(trimmedKey) else { continue }
            let trimmedNote = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedNote.isEmpty { result[trimmedKey] = trimmedNote }
        }
        return result
    }
}

/// Process-wide settings that can change whether or how any local Spawn job
/// reaches execution. Kept separate from the Default launcher's pool so a
/// Default-only edit does not invalidate an in-flight custom-agent spawn.
struct SpawnSharedConfigurationAuthority: Equatable, Sendable {
    let localTextDelegationEnabled: Bool
    let ramSafetyPreflightEnabled: Bool
    let subagentCoexistenceEnabled: Bool
    let maxParallelSpawns: Int
}

/// Spawn authority owned only by the Default / main-chat launcher.
///
/// Image and AppleScript settings deliberately do not appear here: saving
/// either sibling editor cannot change the target, model, permission, budget,
/// or tool grant of an already-approved Spawn operation.
struct SpawnDefaultConfigurationAuthority: Equatable, Sendable {
    let spawnableAgentIDs: [UUID]
    let spawnableModelNames: [String]
    let permission: SubagentPermissionPolicy
    let budgets: SubagentBudgets
    let modelOverride: String?
    let toolAccess: SpawnToolAccess
}

/// Agent-owned launcher fields that can alter a custom agent's Spawn
/// execution. This projection intentionally excludes presentation metadata
/// and the Spawn permission: permission has its own scoped generation so the
/// approval panel's single Ask -> Always Allow write can be recognized without
/// weakening ABA protection for the rest of the launcher.
struct SpawnCustomLauncherAgentAuthority: Equatable, Sendable {
    let spawnDelegationEnabled: Bool
    let spawnableAgentIDs: [UUID]
    let spawnableModelNames: [String]
    let budgets: SubagentBudgets
    let modelOverride: String?
    let toolAccess: SpawnToolAccess

    init(_ agent: Agent) {
        let settings = agent.settings
        spawnDelegationEnabled = settings.spawnDelegationEnabled
        spawnableAgentIDs = settings.spawnableAgentIDs
        spawnableModelNames = settings.spawnableModelNames
        budgets = settings.subagentBudgets.normalized
        let rawOverride = settings.subagentModelOverrides[
            SubagentCapabilityRegistry.spawn.id
        ]
        let trimmedOverride = rawOverride?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        modelOverride =
            (trimmedOverride?.isEmpty ?? true)
            ? nil : trimmedOverride
        toolAccess = settings.spawnToolAccess
    }
}

/// Per-agent monotonic generations captured together with an AgentManager
/// snapshot. Separate axes retain semantic narrowing while detecting an
/// edit-and-restore (ABA) during an asynchronous approval or preparation.
struct SpawnAgentAuthorityRevisions: Equatable, Sendable {
    let launcher: UInt64
    let permission: UInt64
    let target: UInt64
}

struct SpawnAgentAuthoritySnapshot: Sendable {
    let agent: Agent?
    let revisions: SpawnAgentAuthorityRevisions
}

extension SubagentConfiguration {
    var spawnSharedAuthority: SpawnSharedConfigurationAuthority {
        SpawnSharedConfigurationAuthority(
            localTextDelegationEnabled: localTextDelegationEnabled,
            ramSafetyPreflightEnabled: ramSafetyPreflightEnabled,
            subagentCoexistenceEnabled: subagentCoexistenceEnabled,
            maxParallelSpawns: budgets.normalized.maxParallelSpawns
        )
    }

    var spawnDefaultAuthority: SpawnDefaultConfigurationAuthority {
        SpawnDefaultConfigurationAuthority(
            spawnableAgentIDs: spawnableAgentIDs,
            spawnableModelNames: spawnableModelNames,
            permission: permissionDefaults.policy(
                for: SubagentCapabilityRegistry.spawn.id
            ),
            budgets: budgets.normalized,
            modelOverride: SubagentToolVisibility.effectiveSubagentModel(
                capabilityId: SubagentCapabilityRegistry.spawn.id,
                isDefault: true,
                config: self,
                settings: nil
            ),
            toolAccess: spawnToolAccess
        )
    }
}

/// Scoped monotonic generations captured with one configuration snapshot.
/// Custom launchers do not depend on the Default launcher's pool, so their
/// `defaultLauncher` generation is intentionally absent.
struct SpawnConfigurationAuthorityRevision: Equatable, Sendable {
    let shared: UInt64
    let defaultLauncher: UInt64?
}

/// The effective Spawn authority of the launching agent. This is deliberately
/// semantic rather than a whole-`Agent` comparison: presentation fields and
/// sibling Image / AppleScript settings cannot change an already-selected
/// Spawn job.
struct SpawnLauncherAuthority: Equatable, Sendable {
    let id: UUID
    let exists: Bool
    let localTextDelegationEnabled: Bool
    let ramSafetyPreflightEnabled: Bool
    let subagentCoexistenceEnabled: Bool
    let spawnableAgentIDs: [UUID]
    let spawnableModelNames: [String]
    let budgets: SubagentBudgets
    let modelOverride: String?
    let toolAccess: SpawnToolAccess

    init(
        id: UUID,
        isDefault: Bool,
        configuration: SubagentConfiguration,
        agent: Agent?,
        sharedParallelLimit: Int
    ) {
        let settings = agent?.settings
        self.id = id
        self.exists = isDefault || agent != nil
        self.localTextDelegationEnabled =
            configuration.localTextDelegationEnabled
        self.ramSafetyPreflightEnabled =
            configuration.ramSafetyPreflightEnabled
        self.subagentCoexistenceEnabled =
            configuration.subagentCoexistenceEnabled
        self.spawnableAgentIDs =
            SubagentToolVisibility.effectiveSpawnableAgents(
                isDefault: isDefault,
                config: configuration,
                perAgentEnabled:
                    settings?.spawnDelegationEnabled ?? false,
                perAgentTargets: settings?.spawnableAgentIDs ?? []
            )
        self.spawnableModelNames =
            SubagentToolVisibility.effectiveSpawnableModels(
                isDefault: isDefault,
                config: configuration,
                perAgentEnabled:
                    settings?.spawnDelegationEnabled ?? false,
                perAgentModelTargets:
                    settings?.spawnableModelNames ?? []
            )
        self.budgets = SubagentToolVisibility.effectiveBudgets(
            isDefault: isDefault,
            config: configuration,
            settings: settings,
            sharedParallelLimit: sharedParallelLimit
        )
        self.modelOverride =
            SubagentToolVisibility.effectiveSubagentModel(
                capabilityId: SubagentCapabilityRegistry.spawn.id,
                isDefault: isDefault,
                config: configuration,
                settings: settings
            )
        self.toolAccess =
            SubagentToolVisibility.effectiveSpawnToolAccess(
                isDefault: isDefault,
                config: configuration,
                settings: settings
            )
    }
}

/// Target fields consumed by the bounded child runtime. Display metadata,
/// Image / AppleScript configuration, and the target's own Spawn pool are not
/// part of the child that is already being launched.
struct SpawnTargetAuthority: Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let systemPrompt: String
    let defaultModel: String?
    let temperature: Float?
    let toolsEnabled: Bool
    let toolSelectionMode: ToolSelectionMode?
    let manualToolNames: [String]?
    let memoryEnabled: Bool
    let autonomousExec: AutonomousExecConfig?
    let hostWorkspaceBookmark: Data?
    let dbEnabled: Bool
    let schedule: AgentScheduleSettings
    let limits: AgentLimitsSettings
    let renderChartEnabled: Bool
    let speakEnabled: Bool
    let searchMemoryEnabled: Bool
    let webSearchEnabled: Bool
    let selfSchedulingEnabled: Bool
    let knowledgeEnabled: Bool
    let knowledgeCollectionIDs: [UUID]
    let knowledgeCuratorEnabled: Bool

    init(_ agent: Agent) {
        id = agent.id
        createdAt = agent.createdAt
        systemPrompt = agent.systemPrompt
        defaultModel = agent.defaultModel
        temperature = agent.temperature
        toolsEnabled = agent.toolsEnabled
        toolSelectionMode = agent.toolSelectionMode
        manualToolNames = agent.manualToolNames
        memoryEnabled = agent.memoryEnabled
        autonomousExec = agent.autonomousExec
        hostWorkspaceBookmark = agent.hostWorkspaceBookmark
        dbEnabled = agent.settings.dbEnabled
        schedule = agent.settings.schedule
        limits = agent.settings.limits
        renderChartEnabled = agent.settings.renderChartEnabled
        speakEnabled = agent.settings.speakEnabled
        searchMemoryEnabled = agent.settings.searchMemoryEnabled
        webSearchEnabled = agent.settings.webSearchEnabled
        selfSchedulingEnabled = agent.settings.selfSchedulingEnabled
        knowledgeEnabled = agent.settings.knowledgeEnabled
        knowledgeCollectionIDs = agent.settings.knowledgeCollectionIds
        knowledgeCuratorEnabled =
            agent.settings.knowledgeCuratorEnabled
    }
}
