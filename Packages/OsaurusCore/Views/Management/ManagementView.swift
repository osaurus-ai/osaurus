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
    /// Observed so the pending landing anchor reaches every tab via the
    /// environment, re-rendering their glow targets when a result lands.
    @ObservedObject private var highlightCoordinator = SettingsHighlightCoordinator.shared

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

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var sidebarNavigation: some View {
        SidebarNavigation(
            selection: selectedTabBinding,
            searchText: $searchText,
            sections: sidebarSections
        ) { tabId in
            Group {
                // A live query takes over the content pane with cross-tab
                // results; selecting one navigates to its tab (and clears
                // the query). Otherwise show the selected tab as usual.
                if isSearching {
                    SettingsSearchResultsView(query: searchText) { entry in
                        handleResultSelected(entry)
                    }
                } else {
                    contentView(for: tabId)
                }
            }
            .opacity(hasAppeared ? 1 : 0)
            // Propagate the pending landing anchor to every tab so the matched
            // control glows wherever it lives.
            .environment(\.settingsLandingPending, highlightCoordinator.pending)
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
                if let tab = ManagementTab.resolved(from: newValue),
                    ManagementTab.visibleCases.contains(tab)
                {
                    stateManager.selectedTab = tab
                }
            }
        )
    }

    @ViewBuilder
    func contentView(for tabId: String) -> some View {
        let tab = ManagementTab.resolved(from: tabId)
        switch tab {
        case .credits:
            CreditsView()
        case .models:
            ModelDownloadView(
                deeplinkModelId: deeplinkModelId,
                deeplinkFile: deeplinkFile
            )
        case .imageGeneration:
            ImageGenerationView()
        case .providers:
            RemoteProvidersView()
        case .agents:
            AgentsView(deeplinkAgentId: deeplinkAgentId)
        case .agentChannels:
            AgentChannelConnectionCenterView()
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
        case .computerUse:
            ComputerUseSettingsView()
        case .privacy:
            PrivacyView()
        case .identity:
            IdentityView()
        case .storage:
            StorageSettingsView()
        case .chat:
            ChatSettingsView()
        case .settings:
            ConfigurationView(searchText: $searchText)
        case .none:
            Text("Unknown tab", bundle: .module)
        }
    }
}

// MARK: - Sidebar Items

private extension ManagementView {

    var sidebarSections: [SidebarSectionData] {
        ManagementSection.allCases.map { section in
            SidebarSectionData(
                id: section.rawValue,
                title: section.title,
                items: section.tabs.map { tab in
                    tab.sidebarItem(
                        badge: badgeCount(for: tab),
                        badgeHighlight: badgeHighlight(for: tab)
                    )
                }
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
        if !ManagementTab.visibleCases.contains(stateManager.selectedTab) {
            stateManager.selectedTab = ManagementTab.visibleCases.first ?? .settings
        }

        // Delay fade-in to prevent initial layout jank
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.2)) {
                hasAppeared = true
            }
        }
        updater.checkForUpdatesInBackground()
    }

    func handleTabChange(to newTab: ManagementTab) {
        guard ManagementTab.visibleCases.contains(newTab) else {
            stateManager.selectedTab = ManagementTab.visibleCases.first ?? .settings
            return
        }

        // Leave a trail of which screen was on-screen so a layout-engine app
        // hang (no first-party frame in the stack) can be localized to a tab.
        CrashReportingService.recordBreadcrumb(
            category: "navigation",
            message: "management.tab \(newTab.rawValue)"
        )

        // Changing tabs exits search so the chosen tab shows in full (the
        // cross-tab results pane only stands in while a query is active).
        if !searchText.isEmpty {
            searchText = ""
        }
    }

    /// Navigate to the tab owning a chosen search result, then scroll to and
    /// glow the matching control. Clearing the query first dismisses the results
    /// pane so the destination tab renders normally.
    func handleResultSelected(_ entry: SettingsSearchEntry) {
        searchText = ""
        // Route inner navigation before the tab appears, so the destination
        // opens directly on the right section.
        if let subTab = entry.subTab {
            switch entry.tab {
            case .voice: stateManager.voiceSubTabRequest = subTab
            case .server: stateManager.serverSectionRequest = subTab
            case .imageGeneration: stateManager.imageGenerationSubTabRequest = subTab
            case .memory: stateManager.memorySubTabRequest = subTab
            default: break
            }
        }
        // Arm the landing glow for the specific control; the destination tab
        // scrolls to its anchor and the control breathes once on arrival.
        SettingsHighlightCoordinator.shared.request(entry.id)
        withAnimation(.easeOut(duration: 0.2)) {
            stateManager.selectedTab = entry.tab
        }
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        ManagementView()
    }
#endif
