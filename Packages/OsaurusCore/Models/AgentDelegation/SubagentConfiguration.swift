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

/// When local model swapping is enabled for a different-model AppleScript
/// run, controls when its owned lease restores the invoking chat model.
/// Keep-warm can reuse the dedicated model for the same parent/session; it
/// cannot enable swapping when the global setting is off. A resident-parent
/// `mac_query` does not acquire a dedicated-model warm lease.
public enum AppleScriptLoadPolicy: String, Codable, CaseIterable, Sendable {
    /// Restore the chat model immediately after an authorized swap.
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
            return L("With local model swapping on, the chat model reloads right after each AppleScript run.")
        case .keepWarmAfterJob:
            return L(
                "With local model swapping on, the AppleScript model stays loaded briefly for same-session follow-up calls. Turning swapping off disables this warm hold."
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
/// from the map resolves to `defaultPolicy(for:)`.
///
/// Policy meaning: `.deny` blocks the kind's job; `.ask` prompts before
/// admission/model loading (several spawn calls in one message prompt once for
/// the whole wave); `.alwaysAllow` skips the prompt.
public struct SubagentPermissionDefaults: Codable, Equatable, Sendable {
    private var policies: [String: SubagentPermissionPolicy]

    /// Permission kind for delegating to a teammate's shared (workspace)
    /// agent. Separate from local `spawn` because a workspace run spends the
    /// teammate's pool and leaves this Mac, so it stays on Ask by default.
    public static let workspaceSpawnKindId = "spawn_workspace"

    public init(policies: [String: SubagentPermissionPolicy] = [:]) {
        self.policies = policies
    }

    /// The built-in policy for a kind that has no stored entry. Local `spawn`
    /// is Always Allow — a delegated worker runs on the user's own agents
    /// with their own permission cards for anything sensitive, so a second
    /// card on every delegation was pure friction. Every other kind (image,
    /// computer use, workspace spawn, …) keeps the safe `.ask`.
    public static func defaultPolicy(for kindId: String) -> SubagentPermissionPolicy {
        kindId == SubagentCapabilityRegistry.spawn.id ? .alwaysAllow : .ask
    }

    /// The policy for a kind id, falling back to `defaultPolicy(for:)`.
    public func policy(for kindId: String) -> SubagentPermissionPolicy {
        policies[kindId] ?? Self.defaultPolicy(for: kindId)
    }

    /// Whether the kind has an explicitly stored policy (vs. the default).
    public func hasExplicitPolicy(for kindId: String) -> Bool {
        policies[kindId] != nil
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

/// The per-launcher fan-out ceilings one wave of workers is checked against.
/// `local` mirrors Server Concurrent Sessions (GPU/RAM bound); `remote` is the
/// independent cloud/provider ceiling.
public struct SpawnFanOutLimits: Sendable, Equatable {
    public let local: Int
    public let remote: Int

    public init(local: Int, remote: Int) {
        self.local = local
        self.remote = remote
    }

    /// Most jobs a wave can carry before the local/remote split is known.
    public var total: Int { local + remote }
}

public struct SubagentBudgets: Codable, Equatable, Sendable {
    /// Maximum output tokens one delegated worker may produce per turn.
    public var maxDelegateTokens: Int
    /// Maximum model turns (tool-call rounds) one delegated worker may take.
    public var maxDelegateTurns: Int
    /// Wall-clock limit for one delegated worker, in seconds.
    public var maxElapsedSeconds: Int
    /// Maximum LOCAL workers one wave (several `spawn_agent` calls in one
    /// message) may run at once. Engine occupancy, continuous-batching
    /// settings, RAM safety, and model-residency grouping can lower actual
    /// concurrency; different local models are serialized.
    public var maxParallelSpawns: Int
    /// Maximum REMOTE (cloud / provider / workspace) workers one wave may fan
    /// out to. Remote workers consume no local GPU or RAM, so this is
    /// independent of `maxParallelSpawns`, which mirrors the Server
    /// Concurrent Sessions ceiling and governs LOCAL workers only.
    public var maxRemoteParallelSpawns: Int

    /// Built-in defaults. Sized so a worker can actually finish a real task
    /// (read a few files, run a tool loop, write a deliverable) instead of
    /// being cut off after two turns.
    public static let defaultMaxDelegateTokens = 8_192
    public static let defaultMaxDelegateTurns = 24
    public static let defaultMaxElapsedSeconds = 900
    public static let defaultMaxParallelSpawns = 3
    public static let defaultMaxRemoteParallelSpawns = 8

    /// The defaults shipped before the 2026 Orchestrator rework. A stored
    /// budget equal to these is treated as "never touched" and upgraded once
    /// (`migratingLegacyDefaults`).
    static let legacyDefaults = SubagentBudgets(
        maxDelegateTokens: 2_048,
        maxDelegateTurns: 2,
        maxElapsedSeconds: 120
    )

    /// Accepted bounds for each budget — the single source of truth shared by
    /// `normalized` (the save-time clamp) and the Subagents UI steppers, so the
    /// editor can never offer a value the store would silently clamp away.
    public static let tokenBounds: ClosedRange<Int> = 256 ... 65_536
    public static let turnBounds: ClosedRange<Int> = 1 ... 100
    public static let elapsedBounds: ClosedRange<Int> = 15 ... 3_600
    /// Matches the Server Concurrent Sessions contract. RAM admission,
    /// current engine occupancy, Continuous Batching, and model residency can
    /// still split a configured wave into smaller execution groups.
    public static let parallelSpawnBounds: ClosedRange<Int> = 1 ... 32
    public static let remoteParallelSpawnBounds: ClosedRange<Int> = 1 ... 32
    /// Hard ceiling on workers in one wave regardless of settings: every
    /// worker is either local or remote, so no wave can exceed both maxima
    /// combined.
    public static let jobCountUpperBound =
        parallelSpawnBounds.upperBound + remoteParallelSpawnBounds.upperBound

    public init(
        maxDelegateTokens: Int = SubagentBudgets.defaultMaxDelegateTokens,
        maxDelegateTurns: Int = SubagentBudgets.defaultMaxDelegateTurns,
        maxElapsedSeconds: Int = SubagentBudgets.defaultMaxElapsedSeconds,
        maxParallelSpawns: Int = SubagentBudgets.defaultMaxParallelSpawns,
        maxRemoteParallelSpawns: Int = SubagentBudgets.defaultMaxRemoteParallelSpawns
    ) {
        self.maxDelegateTokens = maxDelegateTokens
        self.maxDelegateTurns = maxDelegateTurns
        self.maxElapsedSeconds = maxElapsedSeconds
        self.maxParallelSpawns = maxParallelSpawns
        self.maxRemoteParallelSpawns = maxRemoteParallelSpawns
    }

    public var normalized: SubagentBudgets {
        SubagentBudgets(
            maxDelegateTokens: Self.clamp(maxDelegateTokens, to: Self.tokenBounds),
            maxDelegateTurns: Self.clamp(maxDelegateTurns, to: Self.turnBounds),
            maxElapsedSeconds: Self.clamp(maxElapsedSeconds, to: Self.elapsedBounds),
            maxParallelSpawns: Self.clamp(maxParallelSpawns, to: Self.parallelSpawnBounds),
            maxRemoteParallelSpawns: Self.clamp(
                maxRemoteParallelSpawns,
                to: Self.remoteParallelSpawnBounds
            )
        )
    }

    /// Whether the per-worker limits (tokens / turns / time) equal the
    /// pre-rework defaults. Fan-out limits are ignored: they did not change.
    var matchesLegacyWorkerDefaults: Bool {
        maxDelegateTokens == Self.legacyDefaults.maxDelegateTokens
            && maxDelegateTurns == Self.legacyDefaults.maxDelegateTurns
            && maxElapsedSeconds == Self.legacyDefaults.maxElapsedSeconds
    }

    /// One-time upgrade: a stored budget whose worker limits still equal the
    /// old 2048-token / 2-turn / 120-second defaults adopts the current
    /// defaults (fan-out limits untouched). Any other stored value is a user
    /// choice and is preserved exactly.
    var migratingLegacyDefaults: SubagentBudgets {
        guard matchesLegacyWorkerDefaults else { return self }
        var upgraded = self
        upgraded.maxDelegateTokens = Self.defaultMaxDelegateTokens
        upgraded.maxDelegateTurns = Self.defaultMaxDelegateTurns
        upgraded.maxElapsedSeconds = Self.defaultMaxElapsedSeconds
        return upgraded
    }

    /// Upper bound on the total number of workers one wave can carry before
    /// the local/remote split of its targets is known.
    public var maxTotalParallelSpawns: Int {
        let n = normalized
        return n.maxParallelSpawns + n.maxRemoteParallelSpawns
    }

    private enum CodingKeys: String, CodingKey {
        case maxDelegateTokens
        case maxDelegateTurns
        case maxElapsedSeconds
        case maxParallelSpawns
        case maxRemoteParallelSpawns
    }

    /// Backward-compatible decode. Each value falls back independently so a
    /// missing or malformed field never discards the rest of the delegation
    /// configuration. The removed `maxToolCalls` key is ignored.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maxDelegateTokens: (try? container.decodeIfPresent(
                Int.self,
                forKey: .maxDelegateTokens
            )) ?? Self.defaultMaxDelegateTokens,
            maxDelegateTurns: (try? container.decodeIfPresent(
                Int.self,
                forKey: .maxDelegateTurns
            )) ?? Self.defaultMaxDelegateTurns,
            maxElapsedSeconds: (try? container.decodeIfPresent(
                Int.self,
                forKey: .maxElapsedSeconds
            )) ?? Self.defaultMaxElapsedSeconds,
            maxParallelSpawns: (try? container.decodeIfPresent(
                Int.self,
                forKey: .maxParallelSpawns
            )) ?? Self.defaultMaxParallelSpawns,
            maxRemoteParallelSpawns: (try? container.decodeIfPresent(
                Int.self,
                forKey: .maxRemoteParallelSpawns
            )) ?? Self.defaultMaxRemoteParallelSpawns
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maxDelegateTokens, forKey: .maxDelegateTokens)
        try container.encode(maxDelegateTurns, forKey: .maxDelegateTurns)
        try container.encode(maxElapsedSeconds, forKey: .maxElapsedSeconds)
        try container.encode(maxParallelSpawns, forKey: .maxParallelSpawns)
        try container.encode(maxRemoteParallelSpawns, forKey: .maxRemoteParallelSpawns)
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
    /// Default-on: every custom agent joins on creation (`AgentManager`
    /// creation paths) and existing installs are seeded once (see
    /// `spawnPoolSeeded`); the user removes entries in Settings → Subagents
    /// and removals persist. Custom agents carry their OWN per-agent list in
    /// `AgentSettings`; this field governs the main chat only.
    var spawnableAgentIDs: [UUID]
    /// One-time migration sentinel: `true` once every existing custom agent
    /// has been seeded into `spawnableAgentIDs`
    /// (`SubagentConfigurationStore.seedSpawnPoolIfNeeded`). Seeding never
    /// re-runs, so a user's removal from the pool persists — an empty pool is
    /// NOT treated as "unseeded".
    var spawnPoolSeeded: Bool
    /// Decode-only compatibility payload. It is resolved against the complete
    /// live agent catalog, then cleared before the next save. New JSON never
    /// writes this field.
    var legacySpawnableAgentNames: [String]
    /// One-time migration sentinel: `true` once a stored budget equal to the
    /// pre-rework defaults (2048 / 2 / 120) has been upgraded to the current
    /// defaults. Never re-runs, so a user who later picks those exact values
    /// keeps them.
    var budgetDefaultsMigrated: Bool
    /// One-time migration sentinel: `true` once a stored `spawn` permission of
    /// `.ask` (the pre-rework default, which the editor persisted verbatim)
    /// has been flipped to the new Always Allow default. An explicit `.deny`
    /// is preserved, and once the sentinel is set a user-chosen Ask sticks.
    var spawnPermissionDefaultMigrated: Bool
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
    /// The global default AppleScript model id (`nil` → resolve to the first
    /// installed catalog model at run time). A custom agent's explicit
    /// `AgentSettings.appleScriptModelId` wins; "Choose automatically"
    /// inherits this. The Orchestrator itself has no AppleScript tools.
    var defaultAppleScriptModelId: String?
    /// The global default AppleScript execution mode (confirm each script vs
    /// auto-run with a warning), inherited by custom agents that leave theirs
    /// unset.
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
    /// The DEFAULT / main-chat agent's spawnable WORKSPACE agents: teammates'
    /// shared agents (by durable `(workspaceId, agentAddress)`) the main chat
    /// may delegate to over the relay. Shared agents on rosters the user
    /// belongs to auto-join here (`SubagentConfigurationStore
    /// .reconcileWorkspaceAgents`) unless tombstoned in
    /// `removedWorkspaceAgents` or their workspace has auto-join off. Custom
    /// agents carry their OWN list in `AgentSettings`. Membership here is
    /// durable configuration; live presence is probed at spawn time and never
    /// changes this list (or the prompt composed from it).
    var spawnableWorkspaceAgents: [WorkspaceAgentRef]
    /// Shared agents the user removed from the Orchestrator pool. Auto-join
    /// skips these so a removal survives roster refreshes and re-shares;
    /// re-adding an agent in the editor clears its tombstone. Pruned when the
    /// agent leaves every roster.
    var removedWorkspaceAgents: [WorkspaceAgentRef]
    /// Workspace ids whose "Let the Orchestrator delegate to shared agents in
    /// this workspace" toggle is OFF. Default (absent) is on for every
    /// workspace; turning it off prunes that workspace's refs from the pool
    /// and stops auto-joining them.
    var workspaceAutoJoinDisabledIds: [String]

    init(
        localTextDelegationEnabled: Bool = true,
        spawnableAgentIDs: [UUID] = [],
        spawnPoolSeeded: Bool = false,
        spawnableAgentNames: [String] = [],
        budgetDefaultsMigrated: Bool = true,
        spawnPermissionDefaultMigrated: Bool = true,
        defaultImageGenerationModelId: String? = nil,
        defaultImageGenerationTarget: MediaModelTarget? = nil,
        defaultImageEditModelId: String? = nil,
        videoDelegationEnabled: Bool = false,
        defaultTextToVideoTarget: MediaModelTarget? = nil,
        defaultImageToVideoTarget: MediaModelTarget? = nil,
        imageJobLoadPolicy: SubagentImageLoadPolicy = .agentSingleResidency,
        defaultAppleScriptModelId: String? = nil,
        defaultAppleScriptExecutionMode: AppleScriptExecutionMode = .default,
        appleScriptLoadPolicy: AppleScriptLoadPolicy = .default,
        appleScriptQueryPrefersResidentModel: Bool = true,
        permissionDefaults: SubagentPermissionDefaults = SubagentPermissionDefaults(),
        budgets: SubagentBudgets = SubagentBudgets(),
        ramSafetyPreflightEnabled: Bool = true,
        subagentCoexistenceEnabled: Bool = false,
        subagentModelOverrides: [String: String] = [:],
        spawnableWorkspaceAgents: [WorkspaceAgentRef] = [],
        removedWorkspaceAgents: [WorkspaceAgentRef] = [],
        workspaceAutoJoinDisabledIds: [String] = []
    ) {
        self.localTextDelegationEnabled = localTextDelegationEnabled
        self.spawnableAgentIDs = SpawnableAgentIdentity.normalizedIDs(spawnableAgentIDs)
        self.spawnableWorkspaceAgents = Self.normalizedWorkspaceAgents(spawnableWorkspaceAgents)
        // A ref cannot be both in the pool and tombstoned; the pool wins.
        let pool = Set(self.spawnableWorkspaceAgents)
        self.removedWorkspaceAgents = Self.normalizedWorkspaceAgents(removedWorkspaceAgents)
            .filter { !pool.contains($0) }
        self.workspaceAutoJoinDisabledIds = Self.normalizedWorkspaceIds(workspaceAutoJoinDisabledIds)
        self.spawnPoolSeeded = spawnPoolSeeded
        self.legacySpawnableAgentNames = spawnableAgentNames
        self.budgetDefaultsMigrated = budgetDefaultsMigrated
        self.spawnPermissionDefaultMigrated = spawnPermissionDefaultMigrated
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
        self.defaultAppleScriptModelId = Self.normalizedModelId(defaultAppleScriptModelId)
        self.defaultAppleScriptExecutionMode = defaultAppleScriptExecutionMode
        self.appleScriptLoadPolicy = appleScriptLoadPolicy
        self.appleScriptQueryPrefersResidentModel = appleScriptQueryPrefersResidentModel
        self.permissionDefaults = permissionDefaults
        self.budgets = budgets.normalized
        self.ramSafetyPreflightEnabled = ramSafetyPreflightEnabled
        self.subagentCoexistenceEnabled = subagentCoexistenceEnabled
        self.subagentModelOverrides = Self.normalizedModelOverrides(subagentModelOverrides)
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
            \.spawnableWorkspaceAgents,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        // Editors never touch the seed sentinel; without this merge a stale
        // editor save would revert it to `false` and re-seed agents the user
        // deliberately removed from the pool.
        mergeEditorField(
            \.spawnPoolSeeded,
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
            \.removedWorkspaceAgents,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        mergeEditorField(
            \.workspaceAutoJoinDisabledIds,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        mergeEditorField(
            \.budgetDefaultsMigrated,
            editor: editor,
            loadedBaseline: loadedBaseline,
            live: live,
            into: &merged
        )
        mergeEditorField(
            \.spawnPermissionDefaultMigrated,
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

    /// Whether the shared workspace agent is in the DEFAULT / main chat's
    /// spawn pool. Custom agents use their own list via
    /// `SubagentToolVisibility.spawnWorkspaceAgentAllowed`.
    func isWorkspaceAgentSpawnable(_ ref: WorkspaceAgentRef) -> Bool {
        spawnableWorkspaceAgents.contains(ref)
    }

    /// Whether the DEFAULT / main chat has at least one spawnable workspace agent.
    var anyWorkspaceAgentSpawnable: Bool {
        !spawnableWorkspaceAgents.isEmpty
    }

    /// Whether the Orchestrator auto-joins shared agents from this workspace.
    func workspaceAutoJoinEnabled(_ workspaceId: String) -> Bool {
        !workspaceAutoJoinDisabledIds.contains(workspaceId.lowercased())
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
            spawnPoolSeeded: spawnPoolSeeded,
            spawnableAgentNames: legacySpawnableAgentNames,
            budgetDefaultsMigrated: budgetDefaultsMigrated,
            spawnPermissionDefaultMigrated: spawnPermissionDefaultMigrated,
            defaultImageGenerationTarget: Self.normalizedTarget(defaultImageGenerationTarget),
            defaultImageEditModelId: Self.normalizedModelId(defaultImageEditModelId),
            videoDelegationEnabled: videoDelegationEnabled,
            defaultTextToVideoTarget: Self.normalizedTarget(defaultTextToVideoTarget),
            defaultImageToVideoTarget: Self.normalizedTarget(defaultImageToVideoTarget),
            imageJobLoadPolicy: imageJobLoadPolicy,
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
            spawnableWorkspaceAgents: spawnableWorkspaceAgents,
            removedWorkspaceAgents: removedWorkspaceAgents,
            workspaceAutoJoinDisabledIds: workspaceAutoJoinDisabledIds
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

    /// Drop every pool entry whose agent no longer exists. Runs on store load
    /// and after any agent deletion so a removed agent can never linger as a
    /// bare UUID in "Allowed subagents" (or be re-persisted by an open editor).
    func pruningMissingAgents(using agents: [Agent]) -> SubagentConfiguration {
        let live = Set(agents.map(\.id))
        guard spawnableAgentIDs.contains(where: { !live.contains($0) }) else { return self }
        var pruned = self
        pruned.spawnableAgentIDs = spawnableAgentIDs.filter { live.contains($0) }
        return pruned
    }

    /// Pure auto-join / prune step for shared workspace agents (see
    /// `SubagentConfigurationStore.reconcileWorkspaceAgents`).
    func reconcilingWorkspaceAgents(
        rosterRefs: [WorkspaceAgentRef],
        loadedWorkspaceIds: Set<String>
    ) -> SubagentConfiguration {
        let loaded = Set(loadedWorkspaceIds.map { $0.lowercased() })
        let onRoster = Set(Self.normalizedWorkspaceAgents(rosterRefs))
        var result = self
        // Prune: a ref in a LOADED workspace that the roster no longer lists
        // is gone (unshared / teammate left / workspace left). Refs in
        // workspaces that have not loaded yet are trusted as-is.
        func isStale(_ ref: WorkspaceAgentRef) -> Bool {
            loaded.contains(ref.workspaceId.lowercased()) && !onRoster.contains(ref)
        }
        result.spawnableWorkspaceAgents.removeAll(where: isStale)
        result.removedWorkspaceAgents.removeAll(where: isStale)
        // A workspace with auto-join off contributes nothing to the pool.
        result.spawnableWorkspaceAgents.removeAll { !workspaceAutoJoinEnabled($0.workspaceId) }
        // Join: every roster ref that is neither pooled nor tombstoned.
        let tombstoned = Set(result.removedWorkspaceAgents)
        var pooled = Set(result.spawnableWorkspaceAgents)
        for ref in Self.normalizedWorkspaceAgents(rosterRefs)
        where !pooled.contains(ref) && !tombstoned.contains(ref)
            && workspaceAutoJoinEnabled(ref.workspaceId)
        {
            result.spawnableWorkspaceAgents.append(ref)
            pooled.insert(ref)
        }
        return result
    }

    /// User removal from the editor: drop the ref and remember the removal so
    /// auto-join does not bring it back.
    mutating func removeWorkspaceAgent(_ ref: WorkspaceAgentRef) {
        spawnableWorkspaceAgents.removeAll { $0 == ref }
        if !removedWorkspaceAgents.contains(ref) {
            removedWorkspaceAgents.append(ref)
        }
    }

    /// User re-add from the editor: pool the ref and clear its tombstone.
    mutating func addWorkspaceAgent(_ ref: WorkspaceAgentRef) {
        removedWorkspaceAgents.removeAll { $0 == ref }
        if !spawnableWorkspaceAgents.contains(ref) {
            spawnableWorkspaceAgents.append(ref)
        }
    }

    /// Flip the per-workspace auto-join toggle. Turning it off prunes that
    /// workspace's refs from the pool immediately.
    mutating func setWorkspaceAutoJoin(_ enabled: Bool, workspaceId: String) {
        let id = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return }
        if enabled {
            workspaceAutoJoinDisabledIds.removeAll { $0 == id }
        } else {
            if !workspaceAutoJoinDisabledIds.contains(id) {
                workspaceAutoJoinDisabledIds.append(id)
            }
            spawnableWorkspaceAgents.removeAll { $0.workspaceId.lowercased() == id }
        }
    }

    /// One-time upgrades applied on store load (see the two sentinels).
    func migratingLegacyDefaults() -> SubagentConfiguration {
        var migrated = self
        if !migrated.budgetDefaultsMigrated {
            migrated.budgets = migrated.budgets.migratingLegacyDefaults
            migrated.budgetDefaultsMigrated = true
        }
        if !migrated.spawnPermissionDefaultMigrated {
            let spawnKind = SubagentCapabilityRegistry.spawn.id
            if migrated.permissionDefaults.hasExplicitPolicy(for: spawnKind),
                migrated.permissionDefaults.policy(for: spawnKind) == .ask
            {
                migrated.permissionDefaults.setPolicy(.alwaysAllow, for: spawnKind)
            }
            migrated.spawnPermissionDefaultMigrated = true
        }
        return migrated
    }

    enum CodingKeys: String, CodingKey {
        case localTextDelegationEnabled
        case spawnableAgentIDs
        case spawnPoolSeeded
        /// Legacy decode-only key.
        case spawnableAgentNames
        case budgetDefaultsMigrated
        case spawnPermissionDefaultMigrated
        case defaultImageGenerationTarget
        /// Legacy decode-only key.
        case defaultImageGenerationModelId
        case defaultImageEditModelId
        case videoDelegationEnabled
        case defaultTextToVideoTarget
        case defaultImageToVideoTarget
        case imageJobLoadPolicy
        case defaultAppleScriptModelId
        case defaultAppleScriptExecutionMode
        case appleScriptLoadPolicy
        case appleScriptQueryPrefersResidentModel
        case permissionDefaults
        case budgets
        case ramSafetyPreflightEnabled
        case subagentCoexistenceEnabled
        case subagentModelOverrides
        case spawnableWorkspaceAgents
        case removedWorkspaceAgents
        case workspaceAutoJoinDisabledIds
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
            // Lenient: configs written before the sentinel decode as
            // unseeded, which is exactly what triggers the one-time seed.
            spawnPoolSeeded: (try? container.decodeIfPresent(
                Bool.self,
                forKey: .spawnPoolSeeded
            )) ?? false,
            spawnableAgentNames: try container.decodeIfPresent([String].self, forKey: .spawnableAgentNames) ?? [],
            // Lenient: configs written before the sentinels decode as
            // unmigrated, which is exactly what triggers the one-time upgrade
            // in `SubagentConfigurationStore` (see `migratingLegacyDefaults`).
            budgetDefaultsMigrated: (try? container.decodeIfPresent(
                Bool.self,
                forKey: .budgetDefaultsMigrated
            )) ?? false,
            spawnPermissionDefaultMigrated: (try? container.decodeIfPresent(
                Bool.self,
                forKey: .spawnPermissionDefaultMigrated
            )) ?? false,
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
            // Lenient: a malformed ref list must never discard the whole
            // delegation config; absent (older config) → no workspace targets.
            // The removed `spawnableModelNames` / `spawnableModelNotes` /
            // `spawnToolAccess` / `imageDelegationEnabled` /
            // `appleScriptDelegationEnabled` keys are ignored.
            spawnableWorkspaceAgents: (try? container.decodeIfPresent(
                [WorkspaceAgentRef].self,
                forKey: .spawnableWorkspaceAgents
            )) ?? [],
            removedWorkspaceAgents: (try? container.decodeIfPresent(
                [WorkspaceAgentRef].self,
                forKey: .removedWorkspaceAgents
            )) ?? [],
            workspaceAutoJoinDisabledIds: (try? container.decodeIfPresent(
                [String].self,
                forKey: .workspaceAutoJoinDisabledIds
            )) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        let value = normalized
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.localTextDelegationEnabled, forKey: .localTextDelegationEnabled)
        try container.encode(value.spawnableAgentIDs, forKey: .spawnableAgentIDs)
        try container.encode(value.spawnPoolSeeded, forKey: .spawnPoolSeeded)
        try container.encode(value.budgetDefaultsMigrated, forKey: .budgetDefaultsMigrated)
        try container.encode(
            value.spawnPermissionDefaultMigrated,
            forKey: .spawnPermissionDefaultMigrated
        )
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
        // Only written when non-empty so an untouched config keeps its exact
        // legacy bytes (older builds ignore the keys either way).
        if !value.spawnableWorkspaceAgents.isEmpty {
            try container.encode(value.spawnableWorkspaceAgents, forKey: .spawnableWorkspaceAgents)
        }
        if !value.removedWorkspaceAgents.isEmpty {
            try container.encode(value.removedWorkspaceAgents, forKey: .removedWorkspaceAgents)
        }
        if !value.workspaceAutoJoinDisabledIds.isEmpty {
            try container.encode(
                value.workspaceAutoJoinDisabledIds,
                forKey: .workspaceAutoJoinDisabledIds
            )
        }
    }

    /// Lowercase, trim, drop blanks, de-dupe (order kept).
    static func normalizedWorkspaceIds(_ value: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in value {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }

    /// De-dupe workspace refs (first occurrence wins, order kept) and drop
    /// anything that is not a `<workspaceId>` + `0x…` address pair.
    static func normalizedWorkspaceAgents(_ value: [WorkspaceAgentRef]) -> [WorkspaceAgentRef] {
        var seen = Set<WorkspaceAgentRef>()
        var result: [WorkspaceAgentRef] = []
        for ref in value {
            guard !ref.workspaceId.isEmpty,
                WorkspaceAgentRef.looksLikeAddress(ref.agentAddress),
                seen.insert(ref).inserted
            else { continue }
            result.append(ref)
        }
        return result
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
    let spawnableWorkspaceAgents: [WorkspaceAgentRef]
    let permission: SubagentPermissionPolicy
    let workspacePermission: SubagentPermissionPolicy
    let budgets: SubagentBudgets
    let modelOverride: String?
}

/// Agent-owned launcher fields that can alter a custom agent's Spawn
/// execution. This projection intentionally excludes presentation metadata
/// and the Spawn permission: permission has its own scoped generation so the
/// approval panel's single Ask -> Always Allow write can be recognized without
/// weakening ABA protection for the rest of the launcher.
struct SpawnCustomLauncherAgentAuthority: Equatable, Sendable {
    let spawnDelegationEnabled: Bool
    let spawnableAgentIDs: [UUID]
    let spawnableWorkspaceAgents: [WorkspaceAgentRef]
    let budgets: SubagentBudgets
    let modelOverride: String?

    init(_ agent: Agent) {
        let settings = agent.settings
        spawnDelegationEnabled = settings.spawnDelegationEnabled
        spawnableAgentIDs = settings.spawnableAgentIDs
        spawnableWorkspaceAgents = settings.spawnableWorkspaceAgents
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
            spawnableWorkspaceAgents: spawnableWorkspaceAgents,
            permission: permissionDefaults.policy(
                for: SubagentCapabilityRegistry.spawn.id
            ),
            workspacePermission: permissionDefaults.policy(
                for: SubagentPermissionDefaults.workspaceSpawnKindId
            ),
            budgets: budgets.normalized,
            modelOverride: SubagentToolVisibility.effectiveSubagentModel(
                capabilityId: SubagentCapabilityRegistry.spawn.id,
                isDefault: true,
                config: self,
                settings: nil
            )
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
    let spawnableWorkspaceAgents: [WorkspaceAgentRef]
    let budgets: SubagentBudgets
    let modelOverride: String?

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
        self.spawnableWorkspaceAgents =
            SubagentToolVisibility.effectiveSpawnableWorkspaceAgents(
                isDefault: isDefault,
                config: configuration,
                perAgentEnabled:
                    settings?.spawnDelegationEnabled ?? false,
                perAgentTargets:
                    settings?.spawnableWorkspaceAgents ?? []
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
    let workingFolderBookmark: Data?
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
        workingFolderBookmark = agent.workingFolderBookmark
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
