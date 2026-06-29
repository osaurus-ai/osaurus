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

/// The model-bundle kinds the Agent Delegation model pickers resolve. Only the
/// two image kinds remain — text `spawn` uses the spawnable agent's own model,
/// so there is no separate text-delegate model to pick.
enum SubagentModelKind: String, Codable, CaseIterable, Sendable {
    case imageGeneration = "image_generation"
    case imageEdit = "image_edit"
}

/// Per-kind permission gates for the delegation sub-agents, keyed by each kind's
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

public struct SubagentBudgets: Codable, Equatable, Sendable {
    public var maxDelegateTokens: Int
    public var maxDelegateTurns: Int
    /// Reserved. Spawned subagents run text-only (`AgentSubagentRunner` passes
    /// `tools: nil` and rejects any tool call), so there are no nested tool calls
    /// to cap and nothing enforces this today. Kept for forward-compat for when a
    /// subagent kind gains tool use; intentionally NOT surfaced in Settings until
    /// then so the control isn't a no-op.
    public var maxToolCalls: Int
    public var maxElapsedSeconds: Int

    /// Accepted bounds for each budget — the single source of truth shared by
    /// `normalized` (the save-time clamp) and the Sub-agents UI steppers, so the
    /// editor can never offer a value the store would silently clamp away.
    public static let tokenBounds: ClosedRange<Int> = 256 ... 32_768
    public static let turnBounds: ClosedRange<Int> = 1 ... 8
    public static let toolCallBounds: ClosedRange<Int> = 0 ... 32
    public static let elapsedBounds: ClosedRange<Int> = 15 ... 1_800

    public init(
        maxDelegateTokens: Int = 2048,
        maxDelegateTurns: Int = 1,
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
    /// field governs the main chat only (edited in the main chat's Sub-agents tab).
    var spawnableAgentNames: [String]
    /// The DEFAULT / main-chat agent's `image` enable. Custom agents carry their
    /// own `AgentSettings.imageEnabled`; this governs the main chat only.
    var imageDelegationEnabled: Bool
    var defaultImageGenerationModelId: String?
    var defaultImageEditModelId: String?
    var imageJobLoadPolicy: SubagentImageLoadPolicy
    var permissionDefaults: SubagentPermissionDefaults
    var budgets: SubagentBudgets
    /// When true (default), a subagent/image job runs a refuse-before-evict RAM
    /// preflight: if the spawn model would not fit once the resident chat model
    /// is freed, the job is rejected instead of unloading the orchestrator and
    /// failing to load the spawn model. See `ChatResidencyHandoff.memoryPreflight`.
    var ramSafetyPreflightEnabled: Bool
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

    init(
        localTextDelegationEnabled: Bool = true,
        spawnableAgentNames: [String] = [],
        imageDelegationEnabled: Bool = false,
        defaultImageGenerationModelId: String? = nil,
        defaultImageEditModelId: String? = nil,
        imageJobLoadPolicy: SubagentImageLoadPolicy = .agentSingleResidency,
        permissionDefaults: SubagentPermissionDefaults = SubagentPermissionDefaults(),
        budgets: SubagentBudgets = SubagentBudgets(),
        ramSafetyPreflightEnabled: Bool = true,
        subagentModelOverrides: [String: String] = [:],
        spawnableModelNames: [String] = [],
        spawnableModelNotes: [String: String] = [:]
    ) {
        self.localTextDelegationEnabled = localTextDelegationEnabled
        self.spawnableAgentNames = spawnableAgentNames
        self.imageDelegationEnabled = imageDelegationEnabled
        self.defaultImageGenerationModelId = defaultImageGenerationModelId
        self.defaultImageEditModelId = defaultImageEditModelId
        self.imageJobLoadPolicy = imageJobLoadPolicy
        self.permissionDefaults = permissionDefaults
        self.budgets = budgets.normalized
        self.ramSafetyPreflightEnabled = ramSafetyPreflightEnabled
        self.subagentModelOverrides = Self.normalizedModelOverrides(subagentModelOverrides)
        let normalizedModelNames = Self.normalizedSpawnableModelNames(spawnableModelNames)
        self.spawnableModelNames = normalizedModelNames
        self.spawnableModelNotes = Self.normalizedSpawnableModelNotes(
            spawnableModelNotes,
            names: normalizedModelNames
        )
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
            permissionDefaults: permissionDefaults,
            budgets: budgets.normalized,
            // Preserve the user's RAM-safety choice across the save/load round-trip.
            // Omitting this dropped it back to the init default (`true`), making the
            // toggle un-disableable (the store runs `.normalized` on every save+load).
            ramSafetyPreflightEnabled: ramSafetyPreflightEnabled,
            subagentModelOverrides: subagentModelOverrides,
            // The init trims model names, drops blanks, and prunes notes to the
            // surviving pool members, so passing the raw values here is enough.
            spawnableModelNames: spawnableModelNames,
            spawnableModelNotes: spawnableModelNotes
        )
    }

    enum CodingKeys: String, CodingKey {
        case localTextDelegationEnabled
        case spawnableAgentNames
        case imageDelegationEnabled
        case defaultImageGenerationModelId
        case defaultImageEditModelId
        case imageJobLoadPolicy
        case permissionDefaults
        case budgets
        case ramSafetyPreflightEnabled
        case subagentModelOverrides
        case spawnableModelNames
        case spawnableModelNotes
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
            )) ?? [:]
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
