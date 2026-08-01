//
//  AgentCapabilityReadiness.swift
//  OsaurusCore
//
//  Shared presentation contract for the difference between a capability being
//  configured and being callable right now. Runtime authorization remains in
//  AgentConfigSnapshot/SystemPromptComposer/ToolRegistry; this value explains
//  those same gates to settings surfaces without creating another enablement
//  store.
//

import Foundation

public enum AgentCapabilityReadinessState: String, Sendable, Equatable {
    case disabled
    case active
    case paused
    case needsSetup = "needs_setup"
    case unavailable
}

public enum AgentCapabilityBlocker: String, Sendable, Hashable, CaseIterable {
    case notConfigured = "not_configured"
    case toolsDisabled = "tools_disabled"
    case globalToolsDisabled = "global_tools_disabled"
    case contextLimit = "context_limit"
    case noModelSelected = "no_model_selected"
    case noConfiguredTargets = "no_configured_targets"
    case noRunnableTargets = "no_runnable_targets"
    case checkingTargets = "checking_targets"
    case noImageModel = "no_image_model"
    case noAppleScriptModel = "no_applescript_model"
    case noKnowledgeCollections = "no_knowledge_collections"
    case permissionDenied = "permission_denied"
    case systemPermissionMissing = "system_permission_missing"
    case providerDisconnected = "provider_disconnected"
    case unsupportedSurface = "unsupported_surface"

    public var message: String {
        switch self {
        case .notConfigured:
            return L("Off")
        case .toolsDisabled:
            return L("Paused: Tools is off")
        case .globalToolsDisabled:
            return L("Paused: tools are disabled globally")
        case .contextLimit:
            return L("Paused: the selected model's context limit disables tools")
        case .noModelSelected:
            return L("Needs setup: choose a model")
        case .noConfiguredTargets:
            return L("Needs setup: add an allowed agent or model")
        case .noRunnableTargets:
            return L("Unavailable: no configured target can run right now")
        case .checkingTargets:
            return L("Checking configured targets…")
        case .noImageModel:
            return L("Needs setup: install a compatible image model")
        case .noAppleScriptModel:
            return L("Needs setup: install an AppleScript model")
        case .noKnowledgeCollections:
            return L("Needs setup: grant at least one knowledge collection")
        case .permissionDenied:
            return L("Unavailable: denied by policy")
        case .systemPermissionMissing:
            return L("Unavailable: required macOS permission is missing")
        case .providerDisconnected:
            return L("Unavailable: the configured provider is disconnected")
        case .unsupportedSurface:
            return L("Unavailable on this surface")
        }
    }

    fileprivate var state: AgentCapabilityReadinessState {
        switch self {
        case .notConfigured:
            return .disabled
        case .toolsDisabled, .globalToolsDisabled, .contextLimit:
            return .paused
        case .noModelSelected, .noConfiguredTargets, .noImageModel, .noAppleScriptModel,
            .noKnowledgeCollections:
            return .needsSetup
        case .noRunnableTargets, .checkingTargets, .permissionDenied,
            .systemPermissionMissing, .providerDisconnected, .unsupportedSurface:
            return .unavailable
        }
    }
}

public struct AgentCapabilityReadiness: Sendable, Equatable {
    public let configured: Bool
    public let state: AgentCapabilityReadinessState
    public let blockers: [AgentCapabilityBlocker]

    public var isCallable: Bool { state == .active }
    public var primaryBlocker: AgentCapabilityBlocker? { blockers.first }
    public var statusMessage: String? {
        state == .active ? L("Active") : primaryBlocker?.message
    }

    public static func resolve(
        configured: Bool,
        toolsEnabled: Bool,
        blockers requirements: [AgentCapabilityBlocker] = []
    ) -> AgentCapabilityReadiness {
        guard configured else {
            return AgentCapabilityReadiness(
                configured: false,
                state: .disabled,
                blockers: [.notConfigured]
            )
        }

        var blockers = requirements
        if !toolsEnabled {
            blockers.insert(.toolsDisabled, at: 0)
        }
        blockers = deduplicated(blockers)

        guard let primary = blockers.first else {
            return AgentCapabilityReadiness(configured: true, state: .active, blockers: [])
        }
        return AgentCapabilityReadiness(
            configured: true,
            state: primary.state,
            blockers: blockers
        )
    }

    public static func subagent(
        flag: SubagentCapability.PerAgentFlag,
        configured: Bool,
        toolsEnabled: Bool,
        hasResolvedModel: Bool,
        configuredSpawnTargetCount: Int = 0,
        runnableSpawnTargetCount: Int = 0,
        isCheckingSpawnTargets: Bool = false,
        hasReadyImageModel: Bool = false,
        hasReadyAppleScriptModel: Bool = false,
        permission: SubagentPermissionPolicy = .ask
    ) -> AgentCapabilityReadiness {
        var blockers: [AgentCapabilityBlocker] = []

        switch flag {
        case .computerUse, .browserUse:
            if !hasResolvedModel { blockers.append(.noModelSelected) }
        case .spawn:
            if configuredSpawnTargetCount == 0 {
                blockers.append(.noConfiguredTargets)
            } else if runnableSpawnTargetCount == 0 {
                blockers.append(isCheckingSpawnTargets ? .checkingTargets : .noRunnableTargets)
            }
            if permission == .deny { blockers.append(.permissionDenied) }
        case .image:
            if !hasReadyImageModel { blockers.append(.noImageModel) }
            if permission == .deny { blockers.append(.permissionDenied) }
        case .appleScript:
            if !hasReadyAppleScriptModel { blockers.append(.noAppleScriptModel) }
        }

        return resolve(
            configured: configured,
            toolsEnabled: toolsEnabled,
            blockers: blockers
        )
    }

    private static func deduplicated(
        _ blockers: [AgentCapabilityBlocker]
    ) -> [AgentCapabilityBlocker] {
        var seen = Set<AgentCapabilityBlocker>()
        return blockers.filter { seen.insert($0).inserted }
    }
}
