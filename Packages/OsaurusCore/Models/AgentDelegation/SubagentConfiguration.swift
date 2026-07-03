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
/// Policy meaning: `.deny` blocks the kind's job; `.ask` prompts on first use
/// (spawn has no interactive prompt, so `.ask` simply allows there);
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

/// What tools a spawned subagent (the child worker) may reach. `none` keeps
/// spawn text-only (every child tool call is refused); `readOnly` exposes the
/// curated read-only set (`file_read` / `file_search`, plus the sandbox reads
/// when registered) so the worker can do its own bulk reading — the parent's
/// context is preserved instead of ferrying file contents through the digest.
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

    /// Accepted bounds for each budget — the single source of truth shared by
    /// `normalized` (the save-time clamp) and the Subagents UI steppers, so the
    /// editor can never offer a value the store would silently clamp away.
    public static let tokenBounds: ClosedRange<Int> = 256 ... 32_768
    public static let turnBounds: ClosedRange<Int> = 1 ... 8
    public static let toolCallBounds: ClosedRange<Int> = 0 ... 32
    public static let elapsedBounds: ClosedRange<Int> = 15 ... 1_800

    public init(
        maxDelegateTokens: Int = 2048,
        maxDelegateTurns: Int = 2,
        maxToolCalls: Int = 0,
        maxElapsedSeconds: Int = 120
    ) {
        self.maxDelegateTokens = maxDelegateTokens
        self.maxDelegateTurns = maxDelegateTurns
        self.maxToolCalls = maxToolCalls
        self.maxElapsedSeconds = maxElapsedSeconds
    }

    public var normalized: SubagentBudgets {
        SubagentBudgets(
            maxDelegateTokens: Self.clamp(maxDelegateTokens, to: Self.tokenBounds),
            maxDelegateTurns: Self.clamp(maxDelegateTurns, to: Self.turnBounds),
            maxToolCalls: Self.clamp(maxToolCalls, to: Self.toolCallBounds),
            maxElapsedSeconds: Self.clamp(maxElapsedSeconds, to: Self.elapsedBounds)
        )
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
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
    /// field governs the main chat only (edited in the main chat's Subagents tab).
    var spawnableAgentNames: [String]
    /// The DEFAULT / main-chat agent's `image` enable. Custom agents carry their
    /// own `AgentSettings.imageEnabled`; this governs the main chat only.
    var imageDelegationEnabled: Bool
    var defaultImageGenerationModelId: String?
    var defaultImageEditModelId: String?
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
        spawnableAgentNames: [String] = [],
        imageDelegationEnabled: Bool = false,
        defaultImageGenerationModelId: String? = nil,
        defaultImageEditModelId: String? = nil,
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
        self.spawnableAgentNames = spawnableAgentNames
        self.imageDelegationEnabled = imageDelegationEnabled
        self.defaultImageGenerationModelId = defaultImageGenerationModelId
        self.defaultImageEditModelId = defaultImageEditModelId
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

    /// A local orchestrator may hand off to a local text subagent (unload/reload).
    var localOrchestratorTextHandoffActive: Bool {
        localTextDelegationEnabled
    }

    /// Whether the named agent is reachable via `spawn` from the DEFAULT /
    /// main chat (the main-chat pool). Custom agents use their own per-agent list
    /// via `SubagentToolVisibility.spawnTargetAllowed`.
    func isAgentSpawnable(_ name: String) -> Bool {
        spawnableAgentNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Whether the DEFAULT / main chat has at least one spawnable agent.
    var anyAgentSpawnable: Bool {
        !spawnableAgentNames.isEmpty
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
            spawnableAgentNames: spawnableAgentNames,
            imageDelegationEnabled: imageDelegationEnabled,
            defaultImageGenerationModelId: Self.normalizedModelId(defaultImageGenerationModelId),
            defaultImageEditModelId: Self.normalizedModelId(defaultImageEditModelId),
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

    enum CodingKeys: String, CodingKey {
        case localTextDelegationEnabled
        case spawnableAgentNames
        case imageDelegationEnabled
        case defaultImageGenerationModelId
        case defaultImageEditModelId
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
        self.init(
            localTextDelegationEnabled: try container.decodeIfPresent(Bool.self, forKey: .localTextDelegationEnabled)
                ?? true,
            spawnableAgentNames: try container.decodeIfPresent([String].self, forKey: .spawnableAgentNames) ?? [],
            imageDelegationEnabled: try container.decodeIfPresent(Bool.self, forKey: .imageDelegationEnabled) ?? false,
            defaultImageGenerationModelId: try container.decodeIfPresent(
                String.self,
                forKey: .defaultImageGenerationModelId
            ),
            defaultImageEditModelId: try container.decodeIfPresent(String.self, forKey: .defaultImageEditModelId),
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

    private static func normalizedModelId(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
