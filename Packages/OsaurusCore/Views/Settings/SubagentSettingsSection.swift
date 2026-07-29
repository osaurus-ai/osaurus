//
//  SubagentSettingsSection.swift
//  osaurus
//
//  Spawn policy for the built-in main chat plus system runtime knobs for local
//  helper jobs. Custom agents edit the same Spawn controls in their Subagents
//  tab; the built-in chat has no AgentDetailView, so its persisted
//  SubagentConfiguration must remain reachable here.
//

import SwiftUI

struct SubagentSettingsSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Binding var configuration: SubagentConfiguration

    var body: some View {
        systemSection
    }

    private var systemSection: some View {
        SettingsSection(title: "Subagents", icon: "wand.and.stars") {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSubsection(label: "Main Chat Spawn") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(
                            "Choose the agents and local or cloud models the built-in chat may delegate to. The agent selects among this allow-list for each job; an empty allow-list keeps Spawn unavailable.",
                            bundle: .module
                        )
                        .font(.system(size: 11))
                        .foregroundColor(themeManager.currentTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)

                        SpawnConfigurationEditor(
                            excludedAgentID: nil,
                            localHandoffEnabled: configuration.localTextDelegationEnabled,
                            modelOverride: mainChatSpawnModelOverride,
                            spawnableAgentIDs: $configuration.spawnableAgentIDs,
                            spawnableModelNames: $configuration.spawnableModelNames,
                            spawnableModelNotes: $configuration.spawnableModelNotes,
                            permissionDefaults: $configuration.permissionDefaults,
                            budgets: $configuration.budgets,
                            toolAccess: $configuration.spawnToolAccess,
                            onChange: {}
                        )
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(themeManager.currentTheme.tertiaryBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(
                                            themeManager.currentTheme.inputBorder,
                                            lineWidth: 1
                                        )
                                )
                        )
                    }
                }

                Divider()
                    .overlay(themeManager.currentTheme.inputBorder)

                SettingsSubsection(label: "Local Handoff & RAM Safety") {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsToggle(
                            title: "Local Orchestrator Handoff",
                            description:
                                "When the main chat model is itself local, unload it to run the helper, then reload it afterward. On by default so a local agent can run a local helper; turn off to keep local-to-local handoff disabled and avoid double residency. (Cloud orchestrators never need this.)",
                            isOn: $configuration.localTextDelegationEnabled
                        )

                        SettingsToggle(
                            title: "RAM-Safety Preflight",
                            description:
                                "Before spawned image or text work, budget one target-model weight footprint plus architecture-aware KV, SSM, and activation headroom for every active child. Same-model batches are split into smaller waves when needed; if even one child cannot fit, refuse before unloading the chat model.",
                            isOn: $configuration.ramSafetyPreflightEnabled
                        )

                        SettingsToggle(
                            title: "Keep Chat Model Loaded (Coexistence)",
                            description:
                                "Experimental: when the server eviction policy is Flexible (Multi Model) and memory projections say both fit, load the helper model alongside the chat model instead of unloading and reloading it — skipping the swap round-trip on high-RAM Macs. Tight RAM or the Strict policy always falls back to the normal handoff.",
                            isOn: $configuration.subagentCoexistenceEnabled
                        )
                    }
                }
            }
        }
    }

    /// Default/main-chat model override for Spawn. The shared editor stores nil
    /// as "Use the agent's model" and trims any explicit local/remote model id.
    private var mainChatSpawnModelOverride: Binding<String?> {
        Binding(
            get: {
                configuration.subagentModelOverrides[
                    SubagentCapabilityRegistry.spawn.id
                ]
            },
            set: { newValue in
                var overrides = configuration.subagentModelOverrides
                let trimmed = newValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let trimmed, !trimmed.isEmpty {
                    overrides[SubagentCapabilityRegistry.spawn.id] = trimmed
                } else {
                    overrides.removeValue(forKey: SubagentCapabilityRegistry.spawn.id)
                }
                configuration.subagentModelOverrides = overrides
            }
        )
    }
}
