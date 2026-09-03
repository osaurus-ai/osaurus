//
//  ManagementTab.swift
//  osaurus
//
//  Defines all available tabs in the management sidebar, grouped into
//  labeled sections (General, Models, Agents, Capabilities, Automation,
//  Developers) that drive the sidebar's visual grouping.
//

import Foundation
import SwiftUI

// MARK: - Management Section

/// Labeled groups the sidebar renders tabs under, in display order.
public enum ManagementSection: String, CaseIterable, Identifiable, Sendable {
    case general
    case models
    case agents
    case capabilities
    case automation
    case developers

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: L("General")
        case .models: L("Models")
        case .agents: L("Agents")
        case .capabilities: L("Capabilities")
        case .automation: L("Automation")
        case .developers: L("Developer Tools")
        }
    }

    /// Tabs belonging to this section, in display order.
    public var tabs: [ManagementTab] {
        switch self {
        case .general:
            [.settings, .chat, .voice, .themes, .credits, .identity, .permissions, .privacy]
        case .models: [.models, .providers, .imageGeneration]
        case .agents: [.orchestrator, .agents, .agentChannels]
        case .capabilities: [.search, .knowledge, .memory, .tools, .skills, .commands]
        case .automation: [.schedules, .watchers, .computerUse, .browser]
        case .developers: [.server, .sandbox, .insights]
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
    case orchestrator
    case models
    case providers
    case imageGeneration
    case agents
    case agentChannels
    case memory
    case knowledge
    case tools
    case search
    case skills
    case commands
    case schedules
    case watchers
    case sandbox
    case computerUse
    case browser
    case server
    case privacy
    case permissions
    case identity
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
        case .settings, .chat, .voice, .themes, .credits, .identity, .permissions, .privacy:
            .general
        case .models, .providers, .imageGeneration: .models
        case .orchestrator, .agents, .agentChannels: .agents
        case .search, .knowledge, .memory, .tools, .skills, .commands: .capabilities
        case .schedules, .watchers, .computerUse, .browser: .automation
        case .server, .sandbox, .insights: .developers
        }
    }

    /// Resolves a sidebar tab id, including legacy raw values whose destination
    /// has moved (`"dashboard"` → Credits, `"channels"` → Agent Channels,
    /// `"storage"` → Privacy, which now hosts the storage-encryption panel).
    public static func resolved(from rawValue: String) -> ManagementTab? {
        switch rawValue {
        case "dashboard": .credits
        case "channels", "integrations", "agent-channels": .agentChannels
        case "storage": .privacy
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
        case .sandbox: "shippingbox.fill"
        case .tools: "wrench.and.screwdriver.fill"
        case .search: "globe"
        case .skills: "sparkles"
        case .commands: "command"
        case .memory: "brain.head.profile.fill"
        case .knowledge: "books.vertical.fill"
        case .schedules: "calendar.badge.clock"
        case .watchers: "eye.fill"
        case .voice: "waveform"
        case .themes: "paintpalette.fill"
        case .insights: "chart.bar.doc.horizontal"
        case .server: "server.rack"
        case .permissions: "lock.shield.fill"
        case .computerUse: "cursorarrow.rays"
        case .browser: "globe"
        case .imageGeneration: "photo.artframe"
        case .privacy: "hand.raised.fill"
        case .identity: "person.badge.key.fill"
        case .chat: "text.bubble.fill"
        case .settings: "gearshape.fill"
        case .orchestrator: "point.3.connected.trianglepath.dotted"
        }
    }

    public var label: String {
        switch self {
        case .credits: L("Credits")
        case .models: L("Local Models")
        case .providers: L("Cloud Models")
        case .agents: L("Agents")
        case .agentChannels: L("Channels")
        case .sandbox: L("Sandbox")
        case .tools: L("Tools")
        case .search: L("Web Search")
        case .skills: L("Skills")
        case .commands: L("Commands")
        case .memory: L("Memory")
        case .knowledge: L("Knowledge")
        case .schedules: L("Schedules")
        case .watchers: L("Watchers")
        case .voice: L("Voice")
        case .themes: L("Themes")
        case .insights: L("Insights")
        case .server: L("Server")
        case .permissions: L("Permissions")
        case .computerUse: L("Computer Use")
        case .browser: L("Browser Use")
        case .imageGeneration: L("Media")
        case .privacy: L("Privacy")
        case .identity: L("Identity")
        case .chat: L("Chat")
        case .settings: L("General")
        case .orchestrator: L("Orchestrator")
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
