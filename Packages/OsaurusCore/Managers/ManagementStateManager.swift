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

/// Manages the session state for the management interface.
@MainActor
public final class ManagementStateManager: ObservableObject {
    public static let shared = ManagementStateManager()

    /// Persists the last selected tab within the current app session.
    @Published public var selectedTab: ManagementTab = .settings

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

    /// One-shot request to open the detail page for a specific paired remote
    /// agent (`RemoteAgent.id`) — e.g. from the chat empty-state gear button.
    /// `AgentsView` observes this and resets it to nil after applying.
    @Published public var pendingRemoteAgentDetailId: UUID?

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
