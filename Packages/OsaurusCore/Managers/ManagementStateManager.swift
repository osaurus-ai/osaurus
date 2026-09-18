//
//  ManagementStateManager.swift
//  osaurus
//
//  Manages the session state for the management interface.
//

import Foundation
import Combine

/// Prefill for the MCP provider add sheet, carried when another flow (the
/// API provider form detecting an MCP URL) hands the user off to
/// Tools > Connections.
public struct MCPProviderDraft: Equatable, Sendable {
    public let name: String
    public let url: String
    public let bearerToken: String?

    public init(name: String, url: String, bearerToken: String?) {
        self.name = name
        self.url = url
        self.bearerToken = bearerToken
    }
}

/// Deep-link payload for the Knowledge tab's "Add Collection" sheet.
public struct PendingKnowledgeCreateRequest: Equatable, Sendable {
    /// Prefill for the sheet's Name field (may be empty).
    public let prefillName: String
    /// Project to grant the created collection to, when the request came
    /// from a project page's Add Collection shortcut.
    public let grantProjectId: UUID?

    public init(prefillName: String, grantProjectId: UUID? = nil) {
        self.prefillName = prefillName
        self.grantProjectId = grantProjectId
    }
}

/// Manages the session state for the management interface.
@MainActor
public final class ManagementStateManager: ObservableObject {
    public static let shared = ManagementStateManager()

    /// Persists the last selected tab within the current app session.
    @Published public var selectedTab: ManagementTab = .settings

    // MARK: - Minimum Window Size

    /// The size below which the settings layout stops working: the sidebar
    /// plus a content pane wide enough for the two-column panels, and
    /// enough height that the tallest tabs don't scroll immediately.
    /// Windows on screens that can show this much use it verbatim; see
    /// `minimumContentSize`.
    public static let designMinimumContentSize = CGSize(width: 940, height: 640)

    /// The effective minimum content size for the settings window: the
    /// design minimum, clamped to what its screen can actually show.
    /// `ManagementView` applies it as `.frame(minWidth:minHeight:)`, which
    /// the hosting controller mirrors into the window's `contentMinSize`.
    /// Without the clamp, a screen whose visible area is smaller than the
    /// design minimum (e.g. a 13" MacBook Air at "Larger Text", 1024x666)
    /// gets a window AppKit cannot shrink to fit, so its title bar hides
    /// under the menu bar and the bottom of the sidebar is cut off (#2761).
    /// Pushed by `WindowManager` on creation and whenever the window
    /// changes screen. Same scheme as `ChatWindowState.minimumContentSize`.
    @Published public private(set) var minimumContentSize: CGSize =
        ManagementStateManager.designMinimumContentSize

    /// Clamp the design minimum to `availableContentSize`, the largest
    /// content area the window's screen can show (visible frame minus the
    /// window's own titlebar chrome). An axis at or below zero means "no
    /// screen known" and keeps the design value, so a transient
    /// measurement can't collapse the floor.
    public func updateMinimumContentSize(availableContentSize available: CGSize) {
        let design = Self.designMinimumContentSize
        var next = design
        if available.width > 0 { next.width = min(design.width, floor(available.width)) }
        if available.height > 0 { next.height = min(design.height, floor(available.height)) }
        guard next != minimumContentSize else { return }
        minimumContentSize = next
    }

    /// One-shot request to focus a specific sub-tab inside `VoiceView`.
    /// VoiceView observes this and resets it to nil after applying.
    @Published public var voiceSubTabRequest: String?

    /// One-shot request to focus a specific sub-tab inside `MemoryView`
    /// (raw value of `MemoryTab`, e.g. "settings"). `MemoryView` observes
    /// this and resets it to nil after applying.
    @Published public var memorySubTabRequest: String?

    /// One-shot request to focus a specific sub-tab inside `ImageGenerationView`
    /// (raw value of `ImageGenerationTab`, e.g. "Models"). `ImageGenerationView`
    /// observes this and resets it to nil after applying.
    @Published public var imageGenerationSubTabRequest: String?

    /// One-shot request to focus a specific sub-tab inside `ComputerUseSettingsView`
    /// (raw value of `ComputerUseTab`, e.g. "Models"). `ComputerUseSettingsView`
    /// observes this and resets it to nil after applying.
    @Published public var computerUseSubTabRequest: String?

    /// One-shot request to open a specific section inside the Server → Settings
    /// pane (raw value of `ServerSettingsSection`). `ServerView` switches to its
    /// Settings tab and `ServerSettingsTabContent` scrolls to + glows it, then
    /// resets this to nil.
    @Published public var serverSectionRequest: String?

    /// One-shot request to open the detail page for a specific plugin id from a deeplink.
    /// `PluginsView` observes this and resets it to nil after applying.
    @Published public var pendingPluginDetailId: String?

    /// One-shot request to open the detail sheet for a specific model repo id
    /// on the Models tab — e.g. from a What's New announcement CTA.
    /// `ModelDownloadView` observes this and resets it to nil after applying.
    @Published public var pendingModelDetailId: String?

    /// One-shot request to pop the "Add Collection" sheet on the Knowledge
    /// tab — e.g. from the project page's Add Collection shortcut, so the
    /// user isn't dropped on the tab just to click the same button again.
    /// `KnowledgeView` observes this and resets it to nil after applying.
    @Published public var pendingKnowledgeCreate: PendingKnowledgeCreateRequest?

    /// One-shot request to open a specific collection's detail sheet on the
    /// Knowledge tab — e.g. from a project page's knowledge row chevron.
    /// `KnowledgeView` observes this and resets it to nil after applying.
    @Published public var pendingKnowledgeDetailId: UUID?

    /// One-shot request to open the detail page for a specific paired remote
    /// agent (`RemoteAgent.id`) — e.g. from the chat empty-state gear button.
    /// `AgentsView` observes this and resets it to nil after applying.
    @Published public var pendingRemoteAgentDetailId: UUID?

    /// One-shot request to open the Create Agent sheet — e.g. from the chat
    /// sidebar's New Agent button. `AgentsView` observes this and resets it
    /// to false after presenting.
    @Published public var pendingCreateAgent: Bool = false

    /// One-shot request to reveal a project's shared memory — the namespace
    /// key (`project-<uuid>`). `MemoryView` observes this, switches to its
    /// Agents subtab, opens the project's context preview, and resets it to
    /// nil. Set from a project page's memory section "Open in Memory" button.
    @Published public var pendingMemoryProjectPreview: String?

    /// One-shot request to open the schedule editor for a specific schedule id.
    /// `SchedulesView` observes this and resets it to nil after applying. Used
    /// by the Claude plugin import summary to deep-link to schedules that
    /// landed disabled because no cron expression was found.
    @Published public var pendingScheduleEditId: UUID?

    /// One-shot request to focus a specific sub-tab inside `ToolsManagerView`
    /// (`All`, `Connections`, or `Custom`; legacy `Available`/`Remote`/
    /// `Sandbox` values are still accepted). Used by the Claude plugin import
    /// summary to deep-link to the Connections tab after installing OAuth or
    /// bearer-token providers that need finishing touches.
    @Published public var pendingToolsSubTab: String?

    /// One-shot request to open the editor for a specific MCP provider id.
    /// `ProvidersView` observes this and resets it to nil after applying.
    /// Used by the Claude plugin import summary to land the user on the
    /// exact provider whose env vars or OAuth still need attention.
    @Published public var pendingMCPProviderEditId: UUID?

    /// One-shot request to open the MCP provider add sheet prefilled with a
    /// draft — used when the API provider connect test detects that the
    /// pasted URL is actually an MCP server and redirects the user to
    /// Tools > Connections. `ProvidersView` observes this and resets it to
    /// nil after presenting the sheet. The token only lives in memory here;
    /// it reaches the Keychain when the user saves the provider.
    @Published public var pendingMCPProviderDraft: MCPProviderDraft?

    /// One-shot request to install a theme by content hash from a deeplink
    /// (`osaurus://themes-install?hash=<sha256>`). `ThemesView` observes
    /// this and resets it to nil after presenting the import sheet.
    @Published public var pendingThemeInstallHash: String?

    private init() {}
}
