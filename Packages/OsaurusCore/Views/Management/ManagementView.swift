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

    /// The chat window column the sidebar sits in.
    let column: SidebarNavigationColumn

    private var theme: ThemeProtocol { themeManager.currentTheme }

    // MARK: Body

    var body: some View {
        sidebarNavigation
            .environment(\.theme, themeManager.currentTheme)
            .tint(theme.action.primary.default.background)
            .onAppear(perform: handleAppear)
            .onChange(of: stateManager.selectedTab) { handleTabChange(from: $0, to: $1) }
            // The pairing deeplink router publishes an invite here when an
            // `osaurus://...?pair=...` URL is opened. Forwarding it through
            // a local @State (`presentingInvite`) gives the sheet a stable
            // identity to bind to even after the coordinator nils out, and
            // lets us route the user to the Agents tab on success.
            .onChange(of: pairCoordinator.pendingInvite, initial: true) { _, newValue in
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
            sections: sidebarSections,
            column: column
        ) { _ in
            Group {
                // A live query takes over the content pane with cross-tab
                // results; selecting one navigates to its tab (and clears
                // the query). Otherwise show the selected tab — a child tab
                // under a back bar to its category.
                if isSearching {
                    SettingsSearchResultsView(
                        query: searchText,
                        onSelect: { handleResultSelected($0) },
                        onOpenEntity: { entity in
                            searchText = ""
                            SettingsEntitySearch.open(entity)
                        }
                    )
                } else {
                    let tab = stateManager.selectedTab
                    ManagementChildContainer(tab: tab) {
                        contentView(for: tab)
                    }
                    .id(tab)
                    .transition(.opacity)
                }
            }
            .animation(theme.motion.quick, value: stateManager.selectedTab)
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

    /// Binding that converts between ManagementTab and String for
    /// SidebarNavigation. A child tab highlights its parent category.
    var selectedTabBinding: Binding<String> {
        Binding(
            get: { stateManager.selectedTab.sidebarTab.rawValue },
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
    func contentView(for tab: ManagementTab) -> some View {
        switch tab {
        case .modelDefaults:
            ModelDefaultsView()
        case .credits:
            CreditsView()
        case .workspaces:
            WorkspacesView()
        case .access:
            AccessView()
        case .devices:
            DevicesView()
        case .connect:
            OsaurusConnectView()
        case .models:
            LocalModelsView()
        case .imageGeneration:
            ImageGenerationView()
        case .providers:
            RemoteProvidersView()
        case .agents:
            AgentsView()
        case .agentChannels:
            AgentChannelConnectionCenterView()
        case .agentRuntimes:
            AgentRuntimesView()
        case .sandbox:
            SandboxView()
        case .tools:
            ToolsManagerView()
        case .search:
            SearchView()
        case .skills:
            SkillsView()
        case .commands:
            SlashCommandsView()
        case .memory:
            MemoryView()
        case .projects:
            ProjectsView()
        case .knowledge:
            KnowledgeView()
        case .workflows:
            // Workflows lives in the main window; `handleTabChange` sends it there.
            EmptyView()
        case .automations:
            EventsView()
        case .approvals:
            ApprovalsView()
        case .tasks:
            TasksView()
        case .voice:
            VoiceView()
        case .insights:
            // Insights lives in the main window; `handleTabChange` sends it there.
            EmptyView()
        case .server:
            ServerView()
        case .permissions:
            PermissionsView()
        case .computerUse:
            ComputerUseSettingsView()
        case .browser:
            BrowserSettingsView()
        case .privacy:
            PrivacyView()
        case .identity:
            IdentityView()
        case .chat:
            ChatSettingsView()
        case .orchestrator:
            OrchestratorSettingsView()
        case .architect:
            ArchitectSettingsView()
        case .configurator:
            ConfiguratorSettingsView()
        case .delegation:
            DelegationSettingsView()
        case .settings:
            ConfigurationView()
        case .keys:
            KeysView()
        case .help:
            HelpView()
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
                },
                // Developer Tools hides its tabs behind the header toggle so
                // the everyday sidebar stays lean.
                isCollapsible: section == .developers,
                // The pinned block (Agents, Automations, Approvals) is where
                // people spend their time; it reads as a distinct, larger
                // block above the settings groups.
                isProminent: section == .home
            )
        }
    }

    func badgeCount(for tab: ManagementTab) -> Int? {
        guard let count = badgeStore.snapshot.counts[tab] else { return nil }
        return count > 0 ? count : nil
    }

    /// A category glows when it or any of its child pages needs attention
    /// (e.g. a missing provider key under Vault).
    func badgeHighlight(for tab: ManagementTab) -> Bool {
        let highlights = badgeStore.snapshot.highlights
        return highlights.contains(tab) || tab.children.contains { highlights.contains($0) }
    }
}

// MARK: - Event Handlers

private extension ManagementView {

    func handleAppear() {
        if !ManagementTab.visibleCases.contains(stateManager.selectedTab) {
            stateManager.selectedTab = ManagementTab.defaultTab
        }

        // Delay fade-in to prevent initial layout jank
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(theme.motion.quick) {
                hasAppeared = true
            }
        }
    }

    func handleTabChange(from oldTab: ManagementTab, to newTab: ManagementTab) {
        if ManagementTab.mainWindowCases.contains(newTab) {
            // Settings stays on the page the link was on, so the title
            // bar's back button returns there.
            stateManager.selectedTab =
                ManagementTab.visibleCases.contains(oldTab) ? oldTab : ManagementTab.defaultTab
            if newTab == .workflows {
                ChatWindowManager.shared.showWorkflowsSurface()
            } else {
                ChatWindowManager.shared.showInsightsSurface()
            }
            return
        }
        guard ManagementTab.visibleCases.contains(newTab) else {
            stateManager.selectedTab = ManagementTab.defaultTab
            return
        }
        // Restored after a main-window redirect: nothing new was opened.
        guard !ManagementTab.mainWindowCases.contains(oldTab) else { return }

        // Leave a trail of which screen was on-screen so a layout-engine app
        // hang (no first-party frame in the stack) can be localized to a tab.
        CrashReportingService.recordBreadcrumb(
            category: "navigation",
            message: "management.tab \(newTab.rawValue)"
        )

        // Settings-engagement signal for tab switches while Settings is up;
        // opening Settings is counted in `ChatWindowState.showMainSurface`.
        FeatureTelemetry.settingsOpened(tab: newTab)

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
        guard !SettingsLanding.prepare(entry, stateManager: stateManager) else { return }
        withAnimation(theme.motion.quick) {
            stateManager.selectedTab = entry.tab
        }
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        ManagementView(column: SidebarNavigationColumn(topInset: 44, expandedWidth: 260, isCollapsed: false))
            .frame(minWidth: 1000, minHeight: 640)
    }
#endif
