//
//  SubagentConfiguration.swift
//  osaurus
//
//  User policy for bounded local helper jobs launched by the main chat agent.
//

import Foundation

enum SubagentPermissionPolicy: String, Codable, CaseIterable, Sendable {
    case ask
    case deny
    case alwaysAllow = "always_allow"

    var displayName: String {
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

struct SubagentPermissionDefaults: Codable, Equatable, Sendable {
    /// Policy gate for the `spawn` text sub-agent. `.deny` blocks spawning;
    /// `.ask`/`.alwaysAllow` permit it (spawn has no interactive prompt, so
    /// both allow).
    var spawn: SubagentPermissionPolicy
    /// Policy gate for the unified `image` tool (generate + edit). `.deny`
    /// blocks image jobs; `.ask` prompts on first use; `.alwaysAllow` skips the
    /// prompt. One gate now that the two image tools merged into `image`.
    var image: SubagentPermissionPolicy

    init(
        spawn: SubagentPermissionPolicy = .ask,
        image: SubagentPermissionPolicy = .ask
    ) {
        self.spawn = spawn
        self.image = image
    }

    private enum CodingKeys: String, CodingKey {
        case spawn, image
    }

    /// Lenient per-field decode. A single invalid policy raw value (e.g. a
    /// hand-edited or version-migrated `"alwaysAllow"` where the enum expects
    /// `"always_allow"`) must NOT fail the decode of the whole struct — and,
    /// because the parent `SubagentConfiguration` decodes this with
    /// `decodeIfPresent`, a throw here used to discard the ENTIRE delegation
    /// configuration and silently fall back to all-defaults (delegation OFF),
    /// invisibly disabling the feature. Each field instead falls back to the
    /// safe `.ask` default when absent or unparseable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func policy(_ key: CodingKeys) -> SubagentPermissionPolicy {
            // `try?` flattens decodeIfPresent's optional: absent key -> nil,
            // present+valid -> value, present+invalid (throw) -> nil. All the
            // nil cases fall back to the safe `.ask` default.
            if let v = try? c.decodeIfPresent(SubagentPermissionPolicy.self, forKey: key) {
                return v
            }
            return .ask
        }
        self.spawn = policy(.spawn)
        self.image = policy(.image)
    }
}

struct SubagentBudgets: Codable, Equatable, Sendable {
    var maxDelegateTokens: Int
    var maxDelegateTurns: Int
    /// Reserved. Spawned subagents run text-only (`AgentSubagentRunner` passes
    /// `tools: nil` and rejects any tool call), so there are no nested tool calls
    /// to cap and nothing enforces this today. Kept for forward-compat for when a
    /// subagent kind gains tool use; intentionally NOT surfaced in Settings until
    /// then so the control isn't a no-op.
    var maxToolCalls: Int
    var maxElapsedSeconds: Int

    init(
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

    var normalized: SubagentBudgets {
        SubagentBudgets(
            maxDelegateTokens: Self.clamp(maxDelegateTokens, to: 256 ... 32_768),
            maxDelegateTurns: Self.clamp(maxDelegateTurns, to: 1 ... 8),
            maxToolCalls: Self.clamp(maxToolCalls, to: 0 ... 32),
            maxElapsedSeconds: Self.clamp(maxElapsedSeconds, to: 15 ... 1_800)
        )
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

struct SubagentConfiguration: Codable, Equatable, Sendable {
    var agentDelegationEnabled: Bool
    /// When true, a LOCAL orchestrator chat model may hand off to a local text
    /// `spawn` subagent: the orchestrator is unloaded for the job and reloaded
    /// after (single-residency handoff). Off by default — a cloud orchestrator
    /// never needs this. See `ChatResidencyHandoff` / `ResidencyHandoff`.
    var localTextDelegationEnabled: Bool
    /// Names of Agent personas the user has marked spawnable via `spawn`. Empty by
    /// default → every agent is off until explicitly opted in (per-agent gate).
    var spawnableAgentNames: [String]
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

    init(
        agentDelegationEnabled: Bool = false,
        localTextDelegationEnabled: Bool = false,
        spawnableAgentNames: [String] = [],
        imageDelegationEnabled: Bool = false,
        defaultImageGenerationModelId: String? = nil,
        defaultImageEditModelId: String? = nil,
        imageJobLoadPolicy: SubagentImageLoadPolicy = .agentSingleResidency,
        permissionDefaults: SubagentPermissionDefaults = SubagentPermissionDefaults(),
        budgets: SubagentBudgets = SubagentBudgets(),
        ramSafetyPreflightEnabled: Bool = true
    ) {
        self.agentDelegationEnabled = agentDelegationEnabled
        self.localTextDelegationEnabled = localTextDelegationEnabled
        self.spawnableAgentNames = spawnableAgentNames
        self.imageDelegationEnabled = imageDelegationEnabled
        self.defaultImageGenerationModelId = defaultImageGenerationModelId
        self.defaultImageEditModelId = defaultImageEditModelId
        self.imageJobLoadPolicy = imageJobLoadPolicy
        self.permissionDefaults = permissionDefaults
        self.budgets = budgets.normalized
        self.ramSafetyPreflightEnabled = ramSafetyPreflightEnabled
    }

    static let `default` = SubagentConfiguration()

    /// A local orchestrator may hand off to a local text subagent (unload/reload).
    var localOrchestratorTextHandoffActive: Bool {
        agentDelegationEnabled && localTextDelegationEnabled
    }

    /// Whether the named Agent persona is reachable via `spawn` (global gate + the
    /// per-agent opt-in, default off).
    func isAgentSpawnable(_ name: String) -> Bool {
        agentDelegationEnabled
            && spawnableAgentNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    var anyAgentSpawnable: Bool {
        agentDelegationEnabled && !spawnableAgentNames.isEmpty
    }

    var imageDelegationActive: Bool {
        agentDelegationEnabled && imageDelegationEnabled
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
            agentDelegationEnabled: agentDelegationEnabled,
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
            ramSafetyPreflightEnabled: ramSafetyPreflightEnabled
        )
    }

    enum CodingKeys: String, CodingKey {
        case agentDelegationEnabled
        case localTextDelegationEnabled
        case spawnableAgentNames
        case imageDelegationEnabled
        case defaultImageGenerationModelId
        case defaultImageEditModelId
        case imageJobLoadPolicy
        case permissionDefaults
        case budgets
        case ramSafetyPreflightEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            agentDelegationEnabled: try container.decodeIfPresent(Bool.self, forKey: .agentDelegationEnabled) ?? false,
            localTextDelegationEnabled: try container.decodeIfPresent(Bool.self, forKey: .localTextDelegationEnabled)
                ?? false,
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
            ) ?? true
        )
    }

    private static func normalizedModelId(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
