//
//  ManagementStateManager.swift
//  osaurus
//
//  Manages the session state for the management interface.
//

import Foundation
import Combine

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
    /// (`available`, `remote`, or `sandbox`). Used by the Claude plugin
    /// import summary to deep-link to the Remote MCP providers tab after
    /// installing OAuth or bearer-token providers that need finishing touches.
    @Published public var pendingToolsSubTab: String?

    /// One-shot request to open the editor for a specific MCP provider id.
    /// `ProvidersView` observes this and resets it to nil after applying.
    /// Used by the Claude plugin import summary to land the user on the
    /// exact provider whose env vars or OAuth still need attention.
    @Published public var pendingMCPProviderEditId: UUID?

    /// One-shot request to install a theme by content hash from a deeplink
    /// (`osaurus://themes-install?hash=<sha256>`). `ThemesView` observes
    /// this and resets it to nil after presenting the import sheet.
    @Published public var pendingThemeInstallHash: String?

    private init() {}
}
