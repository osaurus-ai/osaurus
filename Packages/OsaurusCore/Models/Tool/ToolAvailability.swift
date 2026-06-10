//
//  ToolAvailability.swift
//  osaurus
//
//  Human- and model-readable reason codes for tool availability.
//

import Foundation

enum ToolAvailabilityReasonCode: String, Codable, CaseIterable, Sendable {
    case available
    case alreadyLoaded = "already_loaded"
    case loadableViaCapabilitiesLoad = "loadable_via_capabilities_load"
    case disabled
    case hiddenByAgentScope = "hidden_by_agent_scope"
    case hiddenByExecutionMode = "hidden_by_execution_mode"
    case permissionBlocked = "permission_blocked"
    case missingPermission = "missing_permission"
    case notInstalled = "not_installed"
    case notRegistered = "not_registered"
    case pluginConfigRequired = "plugin_config_required"
    case notSelectedByPreflight = "not_selected_by_preflight"
}

struct ToolAvailability: Equatable, Sendable {
    let toolName: String
    let runtime: String?
    let groupName: String?
    let reasonCodes: [ToolAvailabilityReasonCode]
    let detail: String

    var primaryReason: ToolAvailabilityReasonCode {
        reasonCodes.first ?? .available
    }

    var isLoadableViaCapabilitiesLoad: Bool {
        reasonCodes.contains(.loadableViaCapabilitiesLoad)
    }

    var isCallableNow: Bool {
        reasonCodes.contains(.available) || reasonCodes.contains(.alreadyLoaded)
    }

    var compactSummary: String {
        let codes = reasonCodes.map(\.rawValue).joined(separator: ",")
        guard !detail.isEmpty else { return codes }
        return "\(codes) - \(detail)"
    }

    var displayLabel: String {
        switch primaryReason {
        case .available:
            return L("Available")
        case .alreadyLoaded:
            return L("Loaded")
        case .loadableViaCapabilitiesLoad:
            return L("Loadable")
        case .disabled:
            return L("Disabled")
        case .hiddenByAgentScope:
            return L("Agent off")
        case .hiddenByExecutionMode:
            return L("Mode hidden")
        case .permissionBlocked:
            return L("Blocked")
        case .missingPermission:
            return L("Needs permission")
        case .notInstalled:
            return L("Not installed")
        case .notRegistered:
            return L("Not registered")
        case .pluginConfigRequired:
            return L("Config needed")
        case .notSelectedByPreflight:
            return L("Not selected")
        }
    }

    var displayDetail: String {
        detail.isEmpty ? displayLabel : detail
    }
}
