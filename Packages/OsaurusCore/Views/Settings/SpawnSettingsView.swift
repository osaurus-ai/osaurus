//
//  SpawnSettingsView.swift
//  OsaurusCore — Spawn & Delegation
//
//  Dedicated management page for spawn / agent delegation, promoted out of the
//  long Settings scroll so it's discoverable next to Computer Use. It is a thin
//  page wrapper around the existing `AgentDelegationSettingsSection`: same
//  backing store (`AgentDelegationConfigurationStore` → `agent-delegation.json`)
//  and the same `.agentDelegationConfigurationChanged` notification the Settings
//  copy uses, so the two stay two-way synced — edit here or there, both reflect.
//

import SwiftUI

struct SpawnSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var hasAppeared = false
    @State private var configuration = AgentDelegationConfigurationStore.snapshot()
    @State private var modelItems: [ModelPickerItem] = []

    var body: some View {
        VStack(spacing: 0) {
            ManagerHeader(
                title: L("Spawn & Delegation"),
                subtitle: L("Let the main chat spawn image and local-model helper jobs")
            )
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : -10)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AgentDelegationSettingsSection(
                        configuration: $configuration,
                        modelItems: modelItems
                    )
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            configuration = AgentDelegationConfigurationStore.snapshot()
            modelItems = ModelPickerItemCache.shared.items
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .onChange(of: configuration) { _, newValue in
            AgentDelegationConfigurationStore.save(newValue)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .agentDelegationConfigurationChanged)
        ) { _ in
            // Re-sync when the Settings copy (or anything else) saves a change.
            let latest = AgentDelegationConfigurationStore.snapshot()
            if latest != configuration { configuration = latest }
        }
        .onReceive(ModelPickerItemCache.shared.$items) { items in
            modelItems = items
        }
    }
}
