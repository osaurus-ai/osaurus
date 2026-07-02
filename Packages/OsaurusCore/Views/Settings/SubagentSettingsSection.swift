//
//  SubagentSettingsSection.swift
//  osaurus
//
//  System runtime knobs for bounded local helper jobs (spawn / image): the
//  local-handoff / RAM-safety behavior. There is no global master switch — each
//  agent (including the built-in main chat) opts into spawn / image and picks
//  its own models, permissions, and budgets from its Subagents tab. The global
//  image-generation settings (default models, permission, image load policy)
//  live in the dedicated Image Generation tab. This card hosts only the shared
//  GPU-residency / RAM knobs and lives inside the general Settings tab.
//

import SwiftUI

struct SubagentSettingsSection: View {
    @Binding var configuration: SubagentConfiguration

    var body: some View {
        // System runtime knobs only. Per-agent spawn/image config (targets,
        // models, permissions, budgets) — including the built-in main chat —
        // lives in each agent's Subagents tab, not here.
        systemSection
    }

    private var systemSection: some View {
        SettingsSection(title: "Subagents", icon: "wand.and.stars") {
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
}
