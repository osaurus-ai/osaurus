//
//  SubagentSettingsSection.swift
//  osaurus
//
//  System-level settings for bounded local helper jobs (spawn / image). The
//  per-agent config — which personas an agent may spawn, its image models,
//  permissions, and budgets — lives in each agent's Sub-agents tab (including
//  the built-in main chat). This page is the engine + GPU-residency knobs only.
//

import SwiftUI

struct SubagentSettingsSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    @Binding var configuration: SubagentConfiguration

    var body: some View {
        // System-only. Per-agent spawn/image config (targets, models,
        // permissions, budgets) — including the built-in main chat — lives in
        // each agent's Sub-agents tab, not here.
        systemSection
    }

    private var systemSection: some View {
        SettingsSection(title: "System", icon: "gearshape.2") {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSubsection(label: "How It Works") {
                    VStack(alignment: .leading, spacing: 8) {
                        infoLine(
                            "A chat model can run a bounded helper job — a local text/coder sub-agent (`spawn`), or an image generate/edit (`image`) — and fold the compact result back into its reply."
                        )
                        infoLine(
                            "Local chat model: with handoff on, the orchestrator is unloaded, the helper model loads and runs, then the chat model reloads. RAM-Safety verifies it fits first."
                        )
                        infoLine(
                            "Cloud / API chat model: nothing is unloaded — the local helper model runs alongside and returns a compact result."
                        )
                        infoLine(
                            "These settings are system-wide. Each agent opts into spawn / image and picks its own models, permissions, and budgets from its Sub-agents tab — including the built-in main chat."
                        )
                    }
                }

                SettingsDivider()

                SettingsSubsection(label: "Enable") {
                    SettingsToggle(
                        title: "Enable Spawn & Delegation",
                        description:
                            "Master switch for the spawn and image helper tools. When off, both are removed from every agent's tool list regardless of per-agent settings.",
                        isOn: $configuration.agentDelegationEnabled
                    )
                }

                SettingsDivider()

                SettingsSubsection(label: "Local Handoff & RAM Safety") {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsToggle(
                            title: "Local Orchestrator Handoff",
                            description:
                                "When the main chat model is itself local, unload it to run the helper, then reload it afterward. Off keeps local-to-local handoff disabled to avoid double residency. (Cloud orchestrators never need this.)",
                            isOn: $configuration.localTextDelegationEnabled
                        )

                        SettingsToggle(
                            title: "RAM-Safety Preflight",
                            description:
                                "Before a spawned image or text job, verify the helper model fits in memory once the chat model is freed. If it won't fit, refuse the job instead of unloading the chat model and failing to load the helper.",
                            isOn: $configuration.ramSafetyPreflightEnabled
                        )
                    }
                    .disabled(!configuration.agentDelegationEnabled)
                }

                SettingsDivider()

                SettingsSubsection(label: "Load Policy") {
                    enumPicker(
                        title: "Image Jobs",
                        selection: $configuration.imageJobLoadPolicy,
                        values: SubagentImageLoadPolicy.allCases
                    )
                }
            }
        }
    }

    private func infoLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
                .font(.system(size: 11))
                .foregroundColor(themeManager.currentTheme.tertiaryText)
            Text(LocalizedStringKey(text), bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(themeManager.currentTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func enumPicker<T>(
        title: String,
        selection: Binding<T>,
        values: [T]
    ) -> some View where T: CaseIterable & Hashable, T: IdentifiableDisplay {
        SettingsField(label: title, hint: "") {
            Picker("", selection: selection) {
                ForEach(values, id: \.self) { value in
                    Text(LocalizedStringKey(value.displayName), bundle: .module).tag(value)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280, alignment: .leading)
        }
    }
}

protocol IdentifiableDisplay {
    var displayName: String { get }
}

extension SubagentImageLoadPolicy: IdentifiableDisplay {}
