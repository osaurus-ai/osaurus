//
//  ManagementTab.swift
//  osaurus
//
//  Defines all available tabs in the management sidebar, grouped into
//  labeled sections (General, Models, Agents & Automation, Server,
//  Privacy & Security, Account) that drive the sidebar's visual grouping.
//

import Foundation
import SwiftUI

// MARK: - Management Section

/// Labeled groups the sidebar renders tabs under, in display order.
public enum ManagementSection: String, CaseIterable, Identifiable, Sendable {
    case general
    case models
    case agentsAutomation
    case server
    case privacySecurity
    case account

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: L("General")
        case .models: L("Models")
        case .agentsAutomation: L("Agents & Automation")
        case .server: L("Server")
        case .privacySecurity: L("Privacy & Security")
        case .account: L("Account")
        }
    }

    /// Tabs belonging to this section, in display order.
    public var tabs: [ManagementTab] {
        switch self {
        case .general: [.settings, .chat, .voice, .themes]
        case .models: [.models, .providers, .imageGeneration]
        case .agentsAutomation:
            [
                .agents, .agentChannels, .memory, .tools, .skills, .commands, .plugins,
                .schedules, .watchers, .sandbox, .computerUse,
            ]
        case .server: [.server]
        case .privacySecurity: [.privacy, .permissions, .identity, .storage]
        case .account: [.credits, .insights]
        }
    }
}

// MARK: - Management Tab

/// Defines all available tabs in the management sidebar.
public enum ManagementTab: String, CaseIterable, Identifiable, Sendable {
    case settings
    case chat
    case voice
    case themes
    case models
    case providers
    case imageGeneration
    case agents
    case agentChannels
    case memory
    case tools
    case skills
    case commands
    case plugins
    case schedules
    case watchers
    case sandbox
    case computerUse
    case server
    case privacy
    case permissions
    case identity
    case storage
    case credits
    case insights

    public var id: String { rawValue }

    /// All tabs in sidebar display order (sections flattened).
    public static var visibleCases: [ManagementTab] {
        ManagementSection.allCases.flatMap(\.tabs)
    }

    /// The sidebar section this tab belongs to.
    public var section: ManagementSection {
        switch self {
        case .settings, .chat, .voice, .themes: .general
        case .models, .providers, .imageGeneration: .models
        case .agents, .agentChannels, .memory, .tools, .skills, .commands, .plugins,
            .schedules, .watchers, .sandbox, .computerUse:
            .agentsAutomation
        case .server: .server
        case .privacy, .permissions, .identity, .storage: .privacySecurity
        case .credits, .insights: .account
        }
    }

    /// Resolves a sidebar tab id, including legacy raw values whose destination
    /// has moved (`"dashboard"` → Credits, `"channels"` → Agent Channels).
    public static func resolved(from rawValue: String) -> ManagementTab? {
        switch rawValue {
        case "dashboard": .credits
        case "channels", "integrations", "agent-channels": .agentChannels
        default: ManagementTab(rawValue: rawValue)
        }
    }

    public var icon: String {
        switch self {
        case .credits: "creditcard.fill"
        case .models: "cube.box.fill"
        case .providers: "cloud.fill"
        case .agents: "person.2.fill"
        case .agentChannels: "bubble.left.and.bubble.right.fill"
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
        case .computerUse: "cursorarrow.rays"
        case .imageGeneration: "photo.artframe"
        case .privacy: "hand.raised.fill"
        case .identity: "person.badge.key.fill"
        case .storage: "externaldrive.fill.badge.checkmark"
        case .chat: "text.bubble.fill"
        case .settings: "gearshape.fill"
        }
    }

    public var label: String {
        switch self {
        case .credits: L("Credits")
        case .models: L("Models")
        case .providers: L("Providers")
        case .agents: L("Agents")
        case .agentChannels: L("Channels")
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
        case .computerUse: L("Computer Use")
        case .imageGeneration: L("Images")
        case .privacy: L("Privacy")
        case .identity: L("Identity")
        case .storage: L("Storage")
        case .chat: L("Chat")
        case .settings: L("General")
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
