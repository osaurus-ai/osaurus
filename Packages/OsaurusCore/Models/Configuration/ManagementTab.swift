//
//  ManagementTab.swift
//  osaurus
//
//  Defines all available tabs in the management sidebar.
//

import Foundation
import SwiftUI

/// Defines all available tabs in the management sidebar.
public enum ManagementTab: String, CaseIterable, Identifiable {
    case models
    case providers
    case agents
    case plugins
    case sandbox
    case tools
    case skills
    case commands
    case memory
    case schedules
    case watchers
    case voice
    case themes
    case insights
    case server
    case permissions
    case identity
    case storage
    case settings

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .models: "cube.box.fill"
        case .providers: "cloud.fill"
        case .agents: "person.2.fill"
        case .plugins: "puzzlepiece.extension.fill"
        case .sandbox: "shippingbox.fill"
        case .tools: "wrench.and.screwdriver.fill"
        case .skills: "sparkles"
        case .commands: "command"
        case .memory: "brain.head.profile.fill"
        case .schedules: "calendar.badge.clock"
        case .watchers: "eye.fill"
        case .voice: "waveform"
        case .themes: "paintpalette.fill"
        case .insights: "chart.bar.doc.horizontal"
        case .server: "server.rack"
        case .permissions: "lock.shield.fill"
        case .identity: "person.badge.key.fill"
        case .storage: "externaldrive.fill.badge.checkmark"
        case .settings: "gearshape.fill"
        }
    }

    public var label: String {
        switch self {
        case .models: L("Models")
        case .providers: L("Providers")
        case .agents: L("Agents")
        case .plugins: L("Plugins")
        case .sandbox: L("Sandbox")
        case .tools: L("Tools")
        case .skills: L("Skills")
        case .commands: L("Commands")
        case .memory: L("Memory")
        case .schedules: L("Schedules")
        case .watchers: L("Watchers")
        case .voice: L("Voice")
        case .themes: L("Themes")
        case .insights: L("Insights")
        case .server: L("Server")
        case .permissions: L("Permissions")
        case .identity: L("Identity")
        case .storage: L("Storage")
        case .settings: L("Settings")
        }
    }

    /// Creates a sidebar item for this tab with an optional badge count and highlight state.
    func sidebarItem(badge: Int? = nil, badgeHighlight: Bool = false) -> SidebarItemData {
        SidebarItemData(
            id: rawValue,
            icon: icon,
            label: label,
            badge: badge,
            badgeHighlight: badgeHighlight
        )
    }
}
