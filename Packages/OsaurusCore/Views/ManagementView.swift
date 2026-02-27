//
//  ManagementView.swift
//  osaurus
//
//  Main settings/management interface with sidebar navigation.
//  Provides access to all configuration panels: models, tools, themes, etc.
//

import Foundation
import OsaurusRepository
import SwiftUI

// MARK: - Management Tab

/// Defines all available tabs in the management sidebar.
public enum ManagementTab: String, CaseIterable, Identifiable {
    case models
    case providers
    case agents
    case plugins
    case tools
    case skills
    case memory
    case schedules
    case watchers
    case voice
    case themes
    case insights
    case server
    case permissions
    case identity
    case settings

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .models: "cube.box.fill"
        case .providers: "cloud.fill"
        case .agents: "person.2.fill"
        case .plugins: "puzzlepiece.extension.fill"
        case .tools: "wrench.and.screwdriver.fill"
        case .skills: "sparkles"
        case .memory: "brain.head.profile.fill"
        case .schedules: "calendar.badge.clock"
        case .watchers: "eye.fill"
        case .voice: "waveform"
        case .themes: "paintpalette.fill"
        case .insights: "chart.bar.doc.horizontal"
        case .server: "server.rack"
        case .permissions: "lock.shield.fill"
        case .identity: "person.badge.key.fill"
        case .settings: "gearshape.fill"
        }
    }

    public var label: String {
        switch self {
        case .models: "Models"
        case .providers: "Providers"
        case .agents: "Agents"
        case .plugins: "Plugins"
        case .tools: "Tools"
        case .skills: "Skills"
        case .memory: "Memory"
        case .schedules: "Schedules"
        case .watchers: "Watchers"
        case .voice: "Voice"
        case .themes: "Themes"
        case .insights: "Insights"
        case .server: "Server"
        case .permissions: "Permissions"
        case .identity: "Identity"
        case .settings: "Settings"
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

// MARK: - Management View

struct ManagementView: View {

    // MARK: State Objects

    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var repoService = PluginRepositoryService.shared
    @ObservedObject private var remoteProviderManager = RemoteProviderManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var skillManager = SkillManager.shared
    @ObservedObject private var scheduleManager = ScheduleManager.shared
    @ObservedObject private var watcherManager = WatcherManager.shared
    @ObservedObject private var modelManager = ModelManager.shared
    @ObservedObject private var speechModelManager = SpeechModelManager.shared

    @EnvironmentObject private var updater: UpdaterViewModel

    // MARK: Local State

    @State private var selectedTab: ManagementTab
    @State private var hasAppeared = false
    @State private var searchText = ""

    // MARK: Properties

    let deeplinkModelId: String?
    let deeplinkFile: String?

    private var theme: ThemeProtocol { themeManager.currentTheme }

    // MARK: Initialization

    init(
        initialTab: ManagementTab = .models,
        deeplinkModelId: String? = nil,
        deeplinkFile: String? = nil
    ) {
        _selectedTab = State(initialValue: initialTab)
        self.deeplinkModelId = deeplinkModelId
        self.deeplinkFile = deeplinkFile
    }

    // MARK: Body

    var body: some View {
        sidebarNavigation
            .frame(minWidth: 900, minHeight: 640)
            .background(theme.primaryBackground)
            .environment(\.theme, themeManager.currentTheme)
            .tint(theme.accentColor)
            .themedAlertScope(.management)
            .overlay(ThemedAlertHost(scope: .management))
            .onAppear(perform: handleAppear)
            .onChange(of: selectedTab) { handleTabChange(to: $1) }
            .onChange(of: searchText) { handleSearchChange(to: $1) }
    }
}

// MARK: - Subviews

private extension ManagementView {

    var sidebarNavigation: some View {
        SidebarNavigation(
            selection: selectedTabBinding,
            searchText: $searchText,
            items: sidebarItems
        ) { tabId in
            contentView(for: tabId)
                .opacity(hasAppeared ? 1 : 0)
        } footer: {
            updateButton
        }
    }

    var updateButton: some View {
        SidebarUpdateButton(
            updateAvailable: updater.updateAvailable,
            availableVersion: updater.availableVersion,
            action: updater.checkForUpdates
        )
    }

    /// Binding that converts between ManagementTab and String for SidebarNavigation.
    var selectedTabBinding: Binding<String> {
        Binding(
            get: { selectedTab.rawValue },
            set: { newValue in
                if let tab = ManagementTab(rawValue: newValue) {
                    selectedTab = tab
                }
            }
        )
    }

    @ViewBuilder
    func contentView(for tabId: String) -> some View {
        let tab = ManagementTab(rawValue: tabId)
        switch tab {
        case .models:
            ModelDownloadView(
                deeplinkModelId: deeplinkModelId,
                deeplinkFile: deeplinkFile
            )
        case .providers:
            RemoteProvidersView()
        case .agents:
            AgentsView()
        case .plugins:
            PluginsView()
        case .tools:
            ToolsManagerView()
        case .skills:
            SkillsView()
        case .memory:
            MemoryView()
        case .schedules:
            SchedulesView()
        case .watchers:
            WatchersView()
        case .voice:
            VoiceView()
        case .themes:
            ThemesView()
        case .insights:
            InsightsView()
        case .server:
            ServerView()
        case .permissions:
            PermissionsView()
        case .identity:
            IdentityView()
        case .settings:
            ConfigurationView(searchText: $searchText)
        case .none:
            Text("Unknown tab")
        }
    }
}

// MARK: - Sidebar Items

private extension ManagementView {

    var sidebarItems: [SidebarItemData] {
        ManagementTab.allCases.map { tab in
            tab.sidebarItem(
                badge: badgeCount(for: tab),
                badgeHighlight: badgeHighlight(for: tab)
            )
        }
    }

    func badgeCount(for tab: ManagementTab) -> Int? {
        let count: Int
        switch tab {
        case .models:
            count = modelManager.availableModels.filter { $0.isDownloaded }.count
        case .providers:
            count = remoteProviderManager.providerStates.values.filter(\.isConnected).count
        case .plugins:
            count = repoService.plugins.filter { $0.isInstalled }.count
        case .tools:
            count = ToolRegistry.shared.listTools().count
        case .skills:
            count = skillManager.skills.count
        case .memory:
            count = (try? MemoryDatabase.shared.activeEntryCount()) ?? 0
        case .agents:
            count = agentManager.agents.filter { !$0.isBuiltIn }.count
        case .schedules:
            count = scheduleManager.schedules.count
        case .watchers:
            count = watcherManager.watchers.count
        case .voice:
            count = speechModelManager.downloadedModelsCount
        case .themes:
            count = themeManager.installedThemes.filter { !$0.isBuiltIn }.count
        default:
            return nil
        }
        return count > 0 ? count : nil
    }

    func badgeHighlight(for tab: ManagementTab) -> Bool {
        switch tab {
        case .plugins:
            return repoService.updatesAvailableCount > 0
        default:
            return false
        }
    }
}

// MARK: - Event Handlers

private extension ManagementView {

    func handleAppear() {
        // Delay fade-in to prevent initial layout jank
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.2)) {
                hasAppeared = true
            }
        }
        updater.checkForUpdatesInBackground()
    }

    func handleTabChange(to newTab: ManagementTab) {
        // Clear search when navigating away from settings
        if newTab != .settings && !searchText.isEmpty {
            searchText = ""
        }
    }

    func handleSearchChange(to newValue: String) {
        // Auto-navigate to settings when searching
        if !newValue.isEmpty && selectedTab != .settings {
            withAnimation(.easeOut(duration: 0.2)) {
                selectedTab = .settings
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ManagementView()
}
