//
//  DelegationSettingsView.swift
//  osaurus
//
//  Settings → Agents → Delegation: which agents the Orchestrator hands work
//  to, whether it asks first, the per-subagent limits, and the local model
//  handoff and memory check every agent shares. The card is the shared
//  `SubagentSettingsSection`; its configuration saves immediately through
//  `SubagentConfigurationStore`.
//

import SwiftUI

struct DelegationSettingsView: View {
    @EnvironmentObject private var server: ServerController
    @ObservedObject private var themeManager = ThemeManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var configuration = SubagentConfigurationStore.snapshot()
    @State private var baseline = SubagentConfigurationStore.snapshot()

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Delegation",
                subtitle: "Choose which agents Osaurus hands work to and how much each may do"
            )
        } content: {
            SubagentSettingsSection(configuration: $configuration)
                .settingsLandingAnchor("settings.agents.delegation")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.canvas)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            let latest = SubagentConfigurationStore.snapshot()
            baseline = latest
            configuration = latest
        }
        .onChange(of: configuration) { _, newValue in
            // Only a direct edit of this form's batch limit may turn Server
            // Concurrent Sessions from Automatic into an explicit number;
            // store notifications update the baseline first, so mirrored
            // values compare equal and never echo back as a user override.
            let batchLimitWasExplicitlyEdited =
                SpawnBatchConcurrencyContract.configuredLimit(for: newValue)
                != SpawnBatchConcurrencyContract.configuredLimit(for: baseline)
            let saved = SubagentConfigurationStore.saveEditorSnapshot(newValue, loadedBaseline: baseline)
            baseline = saved
            if saved != newValue { configuration = saved }
            if batchLimitWasExplicitlyEdited {
                Task { @MainActor in
                    await server.applyMainChatBatchLimit(from: saved)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .subagentConfigurationChanged)) { _ in
            let latest = SubagentConfigurationStore.snapshot()
            let reconciled = SubagentConfiguration.mergingEditorSnapshot(
                configuration, loadedBaseline: baseline, live: latest)
            baseline = latest
            if reconciled != configuration { configuration = reconciled }
        }
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        DelegationSettingsView()
    }
#endif
