//
//  AgentDelegationConfiguration.swift
//  osaurus
//
//  User policy for bounded local helper jobs launched by the main chat agent.
//

import Foundation

enum AgentDelegationPermissionPolicy: String, Codable, CaseIterable, Sendable {
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

enum AgentDelegationTextLoadPolicy: String, Codable, CaseIterable, Sendable {
    case unloadAfterJob = "unload_after_job"
    case keepWarmWhenSafe = "keep_warm_when_safe"
    case strictSingleJobResidency = "strict_single_job_residency"

    var displayName: String {
        switch self {
        case .unloadAfterJob: return L("Unload After Job")
        case .keepWarmWhenSafe: return L("Keep Warm When Safe")
        case .strictSingleJobResidency: return L("Strict Single Job")
        }
    }
}

enum AgentDelegationImageLoadPolicy: String, Codable, CaseIterable, Sendable {
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

enum AgentDelegationSharingPolicy: String, Codable, CaseIterable, Sendable {
    case compactResultOnly = "compact_result_only"
    case allowLocalTranscriptSummary = "allow_local_transcript_summary"
    case askBeforeExpandedSharing = "ask_before_expanded_sharing"

    var displayName: String {
        switch self {
        case .compactResultOnly: return L("Compact Result Only")
        case .allowLocalTranscriptSummary: return L("Allow Summary")
        case .askBeforeExpandedSharing: return L("Ask Before Expanded Sharing")
        }
    }
}

enum AgentDelegationModelKind: String, Codable, CaseIterable, Sendable {
    case localTextDelegate = "local_text_delegate"
    case imageGeneration = "image_generation"
    case imageEdit = "image_edit"
}

struct AgentDelegationPermissionDefaults: Codable, Equatable, Sendable {
    var localTextDelegate: AgentDelegationPermissionPolicy
    var localTextDelegateToolUse: AgentDelegationPermissionPolicy
    var imageGenerate: AgentDelegationPermissionPolicy
    var imageEdit: AgentDelegationPermissionPolicy

    init(
        localTextDelegate: AgentDelegationPermissionPolicy = .ask,
        localTextDelegateToolUse: AgentDelegationPermissionPolicy = .ask,
        imageGenerate: AgentDelegationPermissionPolicy = .ask,
        imageEdit: AgentDelegationPermissionPolicy = .ask
    ) {
        self.localTextDelegate = localTextDelegate
        self.localTextDelegateToolUse = localTextDelegateToolUse
        self.imageGenerate = imageGenerate
        self.imageEdit = imageEdit
    }

    private enum CodingKeys: String, CodingKey {
        case localTextDelegate, localTextDelegateToolUse, imageGenerate, imageEdit
    }

    /// Lenient per-field decode. A single invalid policy raw value (e.g. a
    /// hand-edited or version-migrated `"alwaysAllow"` where the enum expects
    /// `"always_allow"`) must NOT fail the decode of the whole struct — and,
    /// because the parent `AgentDelegationConfiguration` decodes this with
    /// `decodeIfPresent`, a throw here used to discard the ENTIRE delegation
    /// configuration and silently fall back to all-defaults (delegation OFF),
    /// invisibly disabling the feature. Each field instead falls back to the
    /// safe `.ask` default when absent or unparseable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func policy(_ key: CodingKeys) -> AgentDelegationPermissionPolicy {
            // `try?` flattens decodeIfPresent's optional: absent key -> nil,
            // present+valid -> value, present+invalid (throw) -> nil. All the
            // nil cases fall back to the safe `.ask` default.
            if let v = try? c.decodeIfPresent(AgentDelegationPermissionPolicy.self, forKey: key) {
                return v
            }
            return .ask
        }
        self.localTextDelegate = policy(.localTextDelegate)
        self.localTextDelegateToolUse = policy(.localTextDelegateToolUse)
        self.imageGenerate = policy(.imageGenerate)
        self.imageEdit = policy(.imageEdit)
    }
}

struct AgentDelegationBudgets: Codable, Equatable, Sendable {
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

    var normalized: AgentDelegationBudgets {
        AgentDelegationBudgets(
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

struct AgentDelegationConfiguration: Codable, Equatable, Sendable {
    var agentDelegationEnabled: Bool
    var cloudTextDelegationEnabled: Bool
    /// When true, a LOCAL orchestrator chat model may also delegate to a local
    /// text subagent: the orchestrator is unloaded for the job and reloaded after
    /// (single-residency handoff). Off by default — a cloud orchestrator never
    /// needs this. See LocalDelegateHandoff / ChatResidencyHandoff.
    var localTextDelegationEnabled: Bool
    /// Names of Agent personas the user has marked spawnable via `spawn`. Empty by
    /// default → every agent is off until explicitly opted in (per-agent gate).
    var spawnableAgentNames: [String]
    var imageDelegationEnabled: Bool
    var defaultLocalTextDelegateModelId: String?
    var defaultImageGenerationModelId: String?
    var defaultImageEditModelId: String?
    var textDelegateLoadPolicy: AgentDelegationTextLoadPolicy
    var imageJobLoadPolicy: AgentDelegationImageLoadPolicy
    var sharingPolicy: AgentDelegationSharingPolicy
    var permissionDefaults: AgentDelegationPermissionDefaults
    var budgets: AgentDelegationBudgets
    /// When true (default), a subagent/image job runs a refuse-before-evict RAM
    /// preflight: if the spawn model would not fit once the resident chat model
    /// is freed, the job is rejected instead of unloading the orchestrator and
    /// failing to load the spawn model. See `ChatResidencyHandoff.memoryPreflight`.
    var ramSafetyPreflightEnabled: Bool

    init(
        agentDelegationEnabled: Bool = false,
        cloudTextDelegationEnabled: Bool = false,
        localTextDelegationEnabled: Bool = false,
        spawnableAgentNames: [String] = [],
        imageDelegationEnabled: Bool = false,
        defaultLocalTextDelegateModelId: String? = nil,
        defaultImageGenerationModelId: String? = nil,
        defaultImageEditModelId: String? = nil,
        textDelegateLoadPolicy: AgentDelegationTextLoadPolicy = .unloadAfterJob,
        imageJobLoadPolicy: AgentDelegationImageLoadPolicy = .agentSingleResidency,
        sharingPolicy: AgentDelegationSharingPolicy = .compactResultOnly,
        permissionDefaults: AgentDelegationPermissionDefaults = AgentDelegationPermissionDefaults(),
        budgets: AgentDelegationBudgets = AgentDelegationBudgets(),
        ramSafetyPreflightEnabled: Bool = true
    ) {
        self.agentDelegationEnabled = agentDelegationEnabled
        self.cloudTextDelegationEnabled = cloudTextDelegationEnabled
        self.localTextDelegationEnabled = localTextDelegationEnabled
        self.spawnableAgentNames = spawnableAgentNames
        self.imageDelegationEnabled = imageDelegationEnabled
        self.defaultLocalTextDelegateModelId = defaultLocalTextDelegateModelId
        self.defaultImageGenerationModelId = defaultImageGenerationModelId
        self.defaultImageEditModelId = defaultImageEditModelId
        self.textDelegateLoadPolicy = textDelegateLoadPolicy
        self.imageJobLoadPolicy = imageJobLoadPolicy
        self.sharingPolicy = sharingPolicy
        self.permissionDefaults = permissionDefaults
        self.budgets = budgets.normalized
        self.ramSafetyPreflightEnabled = ramSafetyPreflightEnabled
    }

    static let `default` = AgentDelegationConfiguration()

    var localTextDelegationActive: Bool {
        agentDelegationEnabled && cloudTextDelegationEnabled
    }

    /// A local orchestrator may hand off to a local text subagent (unload/reload).
    var localOrchestratorTextHandoffActive: Bool {
        agentDelegationEnabled && localTextDelegationEnabled
    }

    /// The `local_delegate` tool is exposed when EITHER a cloud orchestrator may
    /// delegate, or a local orchestrator may hand off.
    var textDelegationToolAvailable: Bool {
        localTextDelegationActive || localOrchestratorTextHandoffActive
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

    var normalized: AgentDelegationConfiguration {
        AgentDelegationConfiguration(
            agentDelegationEnabled: agentDelegationEnabled,
            cloudTextDelegationEnabled: cloudTextDelegationEnabled,
            localTextDelegationEnabled: localTextDelegationEnabled,
            spawnableAgentNames: spawnableAgentNames,
            imageDelegationEnabled: imageDelegationEnabled,
            defaultLocalTextDelegateModelId: Self.normalizedModelId(defaultLocalTextDelegateModelId),
            defaultImageGenerationModelId: Self.normalizedModelId(defaultImageGenerationModelId),
            defaultImageEditModelId: Self.normalizedModelId(defaultImageEditModelId),
            textDelegateLoadPolicy: textDelegateLoadPolicy,
            imageJobLoadPolicy: imageJobLoadPolicy,
            sharingPolicy: sharingPolicy,
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
        case cloudTextDelegationEnabled
        case localTextDelegationEnabled
        case spawnableAgentNames
        case imageDelegationEnabled
        case defaultLocalTextDelegateModelId
        case defaultImageGenerationModelId
        case defaultImageEditModelId
        case textDelegateLoadPolicy
        case imageJobLoadPolicy
        case sharingPolicy
        case permissionDefaults
        case budgets
        case ramSafetyPreflightEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            agentDelegationEnabled: try container.decodeIfPresent(Bool.self, forKey: .agentDelegationEnabled) ?? false,
            cloudTextDelegationEnabled: try container.decodeIfPresent(Bool.self, forKey: .cloudTextDelegationEnabled) ?? false,
            localTextDelegationEnabled: try container.decodeIfPresent(Bool.self, forKey: .localTextDelegationEnabled) ?? false,
            spawnableAgentNames: try container.decodeIfPresent([String].self, forKey: .spawnableAgentNames) ?? [],
            imageDelegationEnabled: try container.decodeIfPresent(Bool.self, forKey: .imageDelegationEnabled) ?? false,
            defaultLocalTextDelegateModelId: try container.decodeIfPresent(
                String.self,
                forKey: .defaultLocalTextDelegateModelId
            ),
            defaultImageGenerationModelId: try container.decodeIfPresent(
                String.self,
                forKey: .defaultImageGenerationModelId
            ),
            defaultImageEditModelId: try container.decodeIfPresent(String.self, forKey: .defaultImageEditModelId),
            // Enum fields use `(try? …) ?? default` so a single invalid/renamed
            // raw value falls back to its default instead of throwing — a throw
            // here would discard the ENTIRE delegation config (see the lenient
            // decode note on AgentDelegationPermissionDefaults). `try?` flattens
            // decodeIfPresent's optional, so absent and unparseable both -> default.
            textDelegateLoadPolicy: (try? container.decodeIfPresent(
                AgentDelegationTextLoadPolicy.self,
                forKey: .textDelegateLoadPolicy
            )) ?? .unloadAfterJob,
            imageJobLoadPolicy: (try? container.decodeIfPresent(
                AgentDelegationImageLoadPolicy.self,
                forKey: .imageJobLoadPolicy
            )) ?? .agentSingleResidency,
            sharingPolicy: (try? container.decodeIfPresent(
                AgentDelegationSharingPolicy.self,
                forKey: .sharingPolicy
            )) ?? .compactResultOnly,
            permissionDefaults: (try? container.decodeIfPresent(
                AgentDelegationPermissionDefaults.self,
                forKey: .permissionDefaults
            )) ?? AgentDelegationPermissionDefaults(),
            budgets: try container.decodeIfPresent(AgentDelegationBudgets.self, forKey: .budgets)
                ?? AgentDelegationBudgets(),
            ramSafetyPreflightEnabled: try container.decodeIfPresent(
                Bool.self, forKey: .ramSafetyPreflightEnabled) ?? true
        )
    }

    private static func normalizedModelId(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
