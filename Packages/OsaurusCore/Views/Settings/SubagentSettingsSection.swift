//
//  SubagentSettingsSection.swift
//  osaurus
//
//  System runtime knobs for bounded local helper jobs (spawn / image): the
//  local-handoff / RAM-safety behavior and image load policy. There is no
//  global master switch — each agent (including the built-in main chat) opts
//  into spawn / image and picks its own models, permissions, and budgets from
//  its Sub-agents tab. This card hosts only the GPU-residency / RAM knobs and
//  lives inside the general Settings tab.
//

import SwiftUI

struct SubagentSettingsSection: View {
    @Binding var configuration: SubagentConfiguration

    var body: some View {
        // System runtime knobs only. Per-agent spawn/image config (targets,
        // models, permissions, budgets) — including the built-in main chat —
        // lives in each agent's Sub-agents tab, not here.
        systemSection
    }

    private var systemSection: some View {
        SettingsSection(title: "Sub-agents", icon: "wand.and.stars") {
            VStack(alignment: .leading, spacing: 16) {
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
                                "Before a spawned image or text job, verify the helper model fits in memory once the chat model is freed. If it won't fit, refuse the job instead of unloading the chat model and failing to load the helper.",
                            isOn: $configuration.ramSafetyPreflightEnabled
                        )
                    }
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
