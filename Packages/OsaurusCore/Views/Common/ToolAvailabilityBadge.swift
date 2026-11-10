//
//  ToolAvailabilityBadge.swift
//  osaurus
//
//  Compact availability status marker shared by tool diagnostics surfaces.
//

import SwiftUI

struct ToolAvailabilityBadge: View {
    let availability: ToolAvailability

    @Environment(\.theme) private var theme

    private var tint: Color {
        switch availability.primaryReason {
        case .available, .alreadyLoaded, .loadableViaCapabilitiesLoad:
            return theme.action.primary.default.background
        case .disabled, .hiddenByAgentScope, .hiddenByExecutionMode, .notSelectedByPreflight:
            return theme.text.secondary
        case .permissionBlocked, .missingPermission, .notInstalled, .notRegistered, .pluginConfigRequired:
            return theme.status.warning.foreground
        }
    }

    var body: some View {
        StatusChip(availability.displayLabel, tint: tint, help: availability.compactSummary)
    }
}
