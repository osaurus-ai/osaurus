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

// MARK: - Management View

struct ManagementView: View {

    // MARK: State Objects

    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var stateManager = ManagementStateManager.shared
    @ObservedObject private var pairCoordinator = IncomingPairCoordinator.shared
    // Single fan-in for every sidebar-badge data source. Replaced
    // direct `@ObservedObject` references to ModelManager,
    // RemoteProviderManager, AgentManager, PluginRepositoryService,
    // SandboxPluginLibrary, and SpeechModelManager — each of which
    // would otherwise re-render the entire settings shell on every
    // publish (e.g. per model-download progress chunk). The store
    // throttles these into a single coalesced snapshot and hoists
    // the expensive Memory SQLite / Keychain probes off the body.
    @ObservedObject private var badgeStore = ManagementBadgeStore.shared

    @EnvironmentObject private var updater: UpdaterViewModel

    // MARK: Local State

    @State private var hasAppeared = false
    @State private var searchText = ""

    /// Captured at sheet-presentation time so the sheet body keeps a stable
    /// reference even after the coordinator clears `pendingInvite` on dismiss.
    @State private var presentingInvite: AgentInvite?

    // MARK: Properties

    let deeplinkModelId: String?
    let deeplinkFile: String?
    let deeplinkAgentId: UUID?

    private var theme: ThemeProtocol { themeManager.currentTheme }

    // MARK: Initialization

    init(
        initialTab: ManagementTab? = nil,
        deeplinkModelId: String? = nil,
        deeplinkFile: String? = nil,
        deeplinkAgentId: UUID? = nil
    ) {
        // Use provided initialTab if any, otherwise fall back to the last selected tab in this session.
        if let tab = initialTab {
            ManagementStateManager.shared.selectedTab = tab
        }
        self.deeplinkModelId = deeplinkModelId
        self.deeplinkFile = deeplinkFile
        self.deeplinkAgentId = deeplinkAgentId
    }

    // MARK: Body

    var body: some View {
        sidebarNavigation
            .frame(minWidth: 900, maxWidth: .infinity, minHeight: 640, maxHeight: .infinity)
            .background(theme.primaryBackground)
            .environment(\.theme, themeManager.currentTheme)
            .tint(theme.accentColor)
            .themedAlertScope(.management)
            .overlay(ThemedAlertHost(scope: .management))
            .onAppear(perform: handleAppear)
            .onChange(of: stateManager.selectedTab) { handleTabChange(to: $1) }
            .onChange(of: searchText) { handleSearchChange(to: $1) }
            // The pairing deeplink router publishes an invite here when an
            // `osaurus://...?pair=...` URL is opened. Forwarding it through
            // a local @State (`presentingInvite`) gives the sheet a stable
            // identity to bind to even after the coordinator nils out, and
            // lets us route the user to the Agents tab on success.
            .onChange(of: pairCoordinator.pendingInvite) { _, newValue in
                if let invite = newValue {
                    presentingInvite = invite
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { presentingInvite != nil },
                    set: { newValue in
                        if !newValue {
                            presentingInvite = nil
                            pairCoordinator.pendingInvite = nil
                        }
                    }
                )
            ) {
                if let invite = presentingInvite {
                    IncomingPairSheet(
                        invite: invite,
                        onCompleted: { _ in
                            stateManager.selectedTab = .agents
                        }
                    )
                    .environment(\.theme, themeManager.currentTheme)
                }
            }
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
            get: { stateManager.selectedTab.rawValue },
            set: { newValue in
                if let tab = ManagementTab(rawValue: newValue) {
                    stateManager.selectedTab = tab
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
            AgentsView(deeplinkAgentId: deeplinkAgentId)
        case .plugins:
            PluginsView()
        case .sandbox:
            SandboxView()
        case .tools:
            ToolsManagerView()
        case .skills:
            SkillsView()
        case .commands:
            SlashCommandsView()
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
        case .privacy:
            PrivacyView()
        case .identity:
            IdentityView()
        case .storage:
            StorageSettingsView()
        case .settings:
            ConfigurationView(searchText: $searchText)
        case .none:
            Text("Unknown tab", bundle: .module)
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
        guard let count = badgeStore.snapshot.counts[tab] else { return nil }
        return count > 0 ? count : nil
    }

    func badgeHighlight(for tab: ManagementTab) -> Bool {
        badgeStore.snapshot.highlights.contains(tab)
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
        // Leave a trail of which screen was on-screen so a layout-engine app
        // hang (no first-party frame in the stack) can be localized to a tab.
        CrashReportingService.recordBreadcrumb(
            category: "navigation", message: "management.tab \(newTab.rawValue)")

        // Clear search when navigating away from settings
        if newTab != .settings && !searchText.isEmpty {
            searchText = ""
        }
    }

    func handleSearchChange(to newValue: String) {
        // Auto-navigate to settings when searching
        if !newValue.isEmpty && stateManager.selectedTab != .settings {
            withAnimation(.easeOut(duration: 0.2)) {
                stateManager.selectedTab = .settings
            }
        }
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        ManagementView()
    }
#endif
