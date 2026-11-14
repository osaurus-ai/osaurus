//
//  ManagementTab.swift
//  osaurus
//
//  Settings' information architecture, declared once:
//  group (`ManagementSection`) > category (a sidebar `ManagementTab`) >
//  item (a child `ManagementTab` reached from its parent's page, or a
//  page's own inner items). The sidebar, the category pages' drill-in
//  rows, settings search breadcrumbs and telemetry all read from here.
//

import Foundation
import SwiftUI

// MARK: - Management Section

/// Groups the sidebar renders categories under, in display order. `home` is
/// the unlabeled block pinned at the top (where people build: agents,
/// automations, and what needs the owner); the labeled groups
/// below it are settings.
public enum ManagementSection: String, CaseIterable, Identifiable, Sendable {
    case home
    case general
    case sharing
    case models
    case capabilities
    case context
    case developers

    public var id: String { rawValue }

    /// Empty for the pinned `home` block, which renders without a header.
    public var title: String {
        switch self {
        case .home: ""
        case .general: L("General")
        case .sharing: L("Sharing")
        case .models: L("Models")
        case .capabilities: L("Capabilities")
        case .context: L("Context")
        case .developers: L("Developer Tools")
        }
    }

    /// Sidebar categories in this group, in display order. Child tabs are
    /// not listed here; they hang off their parent (`ManagementTab.children`).
    public var tabs: [ManagementTab] {
        switch self {
        case .home: [.agents, .automations, .approvals]
        case .general: [.settings, .chat, .keys, .identity, .privacy]
        case .sharing: [.workspaces, .access, .devices]
        case .models: [.models, .providers, .modelDefaults]
        case .capabilities:
            [.tools, .agentChannels, .agentRuntimes, .search, .voice, .imageGeneration, .computerUse]
        case .context: [.memory, .projects, .knowledge, .skills]
        case .developers: [.server, .sandbox, .tasks]
        }
    }
}

// MARK: - Management Tab

/// Every addressable destination in Settings. Sidebar
/// categories have no `parent`; child tabs are items of their parent's page
/// and open with a back bar to it. Raw values are persisted / deep-linked
/// and must stay stable.
public enum ManagementTab: String, CaseIterable, Identifiable, Sendable {
    case settings
    case chat
    case voice
    case orchestrator
    case architect
    case configurator
    case delegation
    case models
    case providers
    case modelDefaults
    case imageGeneration
    case agents
    case agentChannels
    case agentRuntimes
    case memory
    case projects
    case knowledge
    case tools
    case search
    case skills
    case commands
    case workflows
    case automations
    case approvals
    case tasks
    case sandbox
    case computerUse
    case browser
    case server
    case privacy
    case permissions
    case identity
    case credits
    case workspaces
    case access
    case devices
    case connect
    case insights
    case keys

    public var id: String { rawValue }

    /// The window's landing tab when nothing was visited before.
    public static let defaultTab: ManagementTab = .agents

    /// Sidebar categories in display order (sections flattened).
    public static var sidebarCases: [ManagementTab] {
        ManagementSection.allCases.flatMap(\.tabs)
    }

    /// Every reachable tab in display order: each sidebar category followed
    /// by its children.
    public static var visibleCases: [ManagementTab] {
        sidebarCases.flatMap { [$0] + $0.children }
    }

    /// Destinations that open as their own surface of the main window rather
    /// than a Settings sidebar row. Their raw values still deep-link and search
    /// still lands on them (`showManagementWindow` redirects).
    public static let mainWindowCases: [ManagementTab] = [.workflows, .insights]

    /// The category whose page lists this tab as an item. `nil` for sidebar
    /// categories.
    public var parent: ManagementTab? {
        switch self {
        case .orchestrator, .architect, .configurator, .delegation: .agents
        case .commands: .chat
        case .credits: .identity
        case .permissions: .privacy
        case .browser: .computerUse
        case .connect: .devices
        default: nil
        }
    }

    /// Items of this category that open as their own page, in display order.
    public var children: [ManagementTab] {
        switch self {
        case .agents: [.orchestrator, .architect, .configurator, .delegation]
        case .chat: [.commands]
        case .identity: [.credits]
        case .privacy: [.permissions]
        case .computerUse: [.browser]
        case .devices: [.connect]
        default: []
        }
    }

    /// The sidebar row that is highlighted while this tab is shown.
    public var sidebarTab: ManagementTab { parent ?? self }

    /// The sidebar group this tab belongs to (children inherit their parent's).
    public var section: ManagementSection {
        let category = sidebarTab
        return ManagementSection.allCases.first { $0.tabs.contains(category) } ?? .general
    }

    /// Resolves a tab id, including legacy raw values whose destination has
    /// moved (`"dashboard"` → Credits, `"channels"` → Channels, `"storage"`
    /// → Privacy & Security, whose Data & Storage page hosts encryption and
    /// file history (see `legacySubTab(from:)`), `"themes"` → General's
    /// Appearance, `"schedules"` / `"watchers"` / `"events"` → Automations,
    /// `"teams"` → Workspaces, `"sync"` → Devices, `"mobile"` → Devices →
    /// Mobile, `"relays"` → Access).
    /// The inner page a legacy tab id opens when it became a drill-in inside
    /// another tab. Pair with `resolved(from:)`.
    public static func legacySubTab(from rawValue: String) -> String? {
        switch rawValue {
        case "storage": PrivacyTab.storage.rawValue
        default: nil
        }
    }

    public static func resolved(from rawValue: String) -> ManagementTab? {
        switch rawValue {
        case "dashboard": .credits
        case "channels", "integrations", "agent-channels": .agentChannels
        case "runtimes", "agent-runtimes", "harnesses": .agentRuntimes
        case "storage": .privacy
        case "themes": .settings
        case "teams": .workspaces
        case "sync": .devices
        case "mobile": .connect
        case "relays", "relay", "remote-access": .access
        case "events", "schedules", "watchers": .automations
        case "defaults", "model-defaults": .modelDefaults
        case "needsYou", "needs-you", "inbox": .approvals
        default: ManagementTab(rawValue: rawValue)
        }
    }

    public var icon: String {
        switch self {
        case .credits: "creditcard.fill"
        case .workspaces: "rectangle.3.group.fill"
        case .access: "person.badge.key.fill"
        case .devices: "laptopcomputer.and.iphone"
        case .connect: "iphone.radiowaves.left.and.right"
        case .models: "cube.box.fill"
        case .providers: "cloud.fill"
        case .modelDefaults: "slider.horizontal.3"
        case .agents: "person.2.fill"
        case .agentChannels: "bubble.left.and.bubble.right.fill"
        case .agentRuntimes: "terminal.fill"
        case .sandbox: "shippingbox.fill"
        case .tools: "wrench.and.screwdriver.fill"
        case .search: "globe"
        case .skills: "sparkles"
        case .commands: "command"
        case .memory: "brain.head.profile.fill"
        case .projects: "folder.fill"
        case .knowledge: "books.vertical.fill"
        case .workflows: "flowchart.fill"
        case .automations: "bolt.fill"
        case .approvals: "tray.full.fill"
        case .tasks: "checklist"
        case .voice: "waveform"
        case .insights: "chart.bar.doc.horizontal"
        case .server: "server.rack"
        case .permissions: "checkmark.shield.fill"
        case .computerUse: "cursorarrow.rays"
        case .browser: "safari.fill"
        case .imageGeneration: "photo.on.rectangle.angled"
        case .privacy: "hand.raised.fill"
        case .identity: "person.crop.circle.fill"
        case .chat: "text.bubble.fill"
        case .settings: "gearshape.fill"
        case .orchestrator: "point.3.connected.trianglepath.dotted"
        case .architect: "pencil.and.ruler.fill"
        case .configurator: "gearshape.2.fill"
        case .delegation: "arrow.triangle.branch"
        case .keys: "key.fill"
        }
    }

    public var label: String {
        switch self {
        case .credits: L("Wallet & Credits")
        case .workspaces: L("Workspaces")
        case .access: L("Access")
        case .devices: L("Devices")
        case .connect: L("Mobile")
        case .models: L("Local Models")
        case .providers: L("Providers")
        case .modelDefaults: L("Model Defaults")
        case .agents: L("Agents")
        case .agentChannels: L("Channels")
        case .agentRuntimes: L("Agent Runtimes")
        case .sandbox: L("Sandbox")
        case .tools: L("Tools & MCP")
        case .search: L("Web Search")
        case .skills: L("Skills")
        case .commands: L("Commands")
        case .memory: L("Memory")
        case .projects: L("Projects")
        case .knowledge: L("Knowledge")
        case .workflows: L("Workflows")
        case .automations: L("Automations")
        case .approvals: L("Inbox")
        case .tasks: L("Tasks")
        case .voice: L("Voice")
        case .insights: L("Insights")
        case .server: L("Server")
        case .permissions: L("Permissions")
        case .computerUse: L("Computer & Browser Use")
        case .browser: L("Browser Use")
        case .imageGeneration: L("Images & Video")
        case .privacy: L("Privacy & Security")
        case .identity: L("Osaurus ID")
        case .chat: L("Chat")
        case .settings: L("General")
        case .orchestrator: L("Orchestrator")
        case .architect: L("Architect")
        case .configurator: L("Configurator")
        case .delegation: L("Delegation")
        case .keys: L("Vault")
        }
    }

    /// One-line summary shown under a child tab's row on its parent's page.
    public var subtitle: String {
        switch self {
        case .orchestrator: L("The built-in agent every chat starts with: identity, model and folder.")
        case .delegation: L("Which agents Osaurus hands work to, whether it asks first, limits, and local model handoff.")
        case .architect: L("The built-in workflow designer: instructions, model and permissions.")
        case .configurator: L("The built-in helper that explains Osaurus and changes settings: instructions, model and temperature.")
        case .commands: L("Your / commands: reusable prompts you type in the composer.")
        case .credits: L("Osaurus Router, balance, top-ups and search credits.")
        case .permissions: L("macOS access Osaurus has been granted: Accessibility, Microphone, Calendar and more.")
        case .browser: L("Browser sessions agents drive on your behalf.")
        case .connect: L("Pair an iPhone app that doesn't offer Sync yet with a 6-digit code.")
        default: ""
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
