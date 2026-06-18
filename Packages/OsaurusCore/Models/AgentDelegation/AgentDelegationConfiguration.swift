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
}

struct AgentDelegationBudgets: Codable, Equatable, Sendable {
    var maxDelegateTokens: Int
    var maxDelegateTurns: Int
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
    var cloudTextDelegationEnabled: Bool
    var defaultLocalTextDelegateModelId: String?
    var defaultImageGenerationModelId: String?
    var defaultImageEditModelId: String?
    var textDelegateLoadPolicy: AgentDelegationTextLoadPolicy
    var imageJobLoadPolicy: AgentDelegationImageLoadPolicy
    var sharingPolicy: AgentDelegationSharingPolicy
    var permissionDefaults: AgentDelegationPermissionDefaults
    var budgets: AgentDelegationBudgets

    init(
        cloudTextDelegationEnabled: Bool = false,
        defaultLocalTextDelegateModelId: String? = nil,
        defaultImageGenerationModelId: String? = nil,
        defaultImageEditModelId: String? = nil,
        textDelegateLoadPolicy: AgentDelegationTextLoadPolicy = .unloadAfterJob,
        imageJobLoadPolicy: AgentDelegationImageLoadPolicy = .agentSingleResidency,
        sharingPolicy: AgentDelegationSharingPolicy = .compactResultOnly,
        permissionDefaults: AgentDelegationPermissionDefaults = AgentDelegationPermissionDefaults(),
        budgets: AgentDelegationBudgets = AgentDelegationBudgets()
    ) {
        self.cloudTextDelegationEnabled = cloudTextDelegationEnabled
        self.defaultLocalTextDelegateModelId = defaultLocalTextDelegateModelId
        self.defaultImageGenerationModelId = defaultImageGenerationModelId
        self.defaultImageEditModelId = defaultImageEditModelId
        self.textDelegateLoadPolicy = textDelegateLoadPolicy
        self.imageJobLoadPolicy = imageJobLoadPolicy
        self.sharingPolicy = sharingPolicy
        self.permissionDefaults = permissionDefaults
        self.budgets = budgets.normalized
    }

    static let `default` = AgentDelegationConfiguration()

    var normalized: AgentDelegationConfiguration {
        AgentDelegationConfiguration(
            cloudTextDelegationEnabled: cloudTextDelegationEnabled,
            defaultLocalTextDelegateModelId: Self.normalizedModelId(defaultLocalTextDelegateModelId),
            defaultImageGenerationModelId: Self.normalizedModelId(defaultImageGenerationModelId),
            defaultImageEditModelId: Self.normalizedModelId(defaultImageEditModelId),
            textDelegateLoadPolicy: textDelegateLoadPolicy,
            imageJobLoadPolicy: imageJobLoadPolicy,
            sharingPolicy: sharingPolicy,
            permissionDefaults: permissionDefaults,
            budgets: budgets.normalized
        )
    }

    private static func normalizedModelId(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
