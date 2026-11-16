//
//  SettingsLanding.swift
//  osaurus
//
//  Opens a settings catalog row from anywhere: routes the destination's
//  inner navigation, arms the landing glow, and shows the tab. Search
//  results and discovery cards land the same way.
//

import Foundation

@MainActor
enum SettingsLanding {
    /// Routes `entry`'s sub-tab and arms its glow. Returns true when the
    /// destination is the Workflows surface, which this also shows.
    @discardableResult
    static func prepare(_ entry: SettingsSearchEntry, stateManager: ManagementStateManager = .shared) -> Bool {
        if let subTab = entry.subTab {
            switch entry.tab {
            case .voice: stateManager.voiceSubTabRequest = subTab
            case .server: stateManager.serverSectionRequest = subTab
            case .imageGeneration: stateManager.imageGenerationSubTabRequest = subTab
            case .memory: stateManager.memorySubTabRequest = subTab
            case .automations: stateManager.automationsSubTabRequest = subTab
            case .privacy: stateManager.privacySubTabRequest = subTab
            case .models:
                if let kind = LocalModelKind(rawValue: subTab) { stateManager.pendingLocalModelsKind = kind }
            case .keys: stateManager.keysSubTabRequest = subTab
            case .tools: stateManager.pendingToolsSubTab = subTab
            case .workspaces:
                if let tab = WorkspaceDetailView.Tab(subTab: subTab) {
                    WorkspacesService.shared.openFromSearch(tab: tab)
                }
            case .agents:
                // Agent detail tabs (`capabilities` for the Apple app groups)
                // are routed by `AgentsView.routeSettingsLanding` from the
                // landing id itself, because the destination also has to pick
                // an agent; the catalog's `subTab` documents the tab raw value
                // (`AgentDetailTabRoute`) for help/find consumers.
                break
            default: break
            }
        }
        // Arm the landing glow for the specific control; the destination tab
        // scrolls to its anchor and the control breathes once on arrival.
        SettingsHighlightCoordinator.shared.request(entry.id)
        if entry.tab == .workflows {
            ChatWindowManager.shared.showWorkflowsSurface(
                destination: entry.subTab.flatMap(ChatWindowState.WorkflowsDestination.init(subTab:))
            )
            return true
        }
        if entry.tab == .insights {
            ChatWindowManager.shared.showInsightsSurface()
            return true
        }
        return false
    }

    /// Opens the catalog row `id` in the management window.
    static func open(id: String) {
        guard let entry = SettingsSearchIndex.entries.first(where: { $0.id == id }) else { return }
        guard !prepare(entry) else { return }
        AppDelegate.shared?.showManagementWindow(initialTab: entry.tab)
    }
}
