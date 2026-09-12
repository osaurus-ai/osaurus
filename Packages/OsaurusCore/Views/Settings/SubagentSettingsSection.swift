//
//  SubagentSettingsSection.swift
//  osaurus
//
//  Subagent policy for the built-in main chat (the Orchestrator) plus system
//  runtime knobs for local subagent jobs. Custom agents edit the same
//  delegation controls in their Subagents tab; the built-in chat has no
//  AgentDetailView, so its persisted SubagentConfiguration must remain
//  reachable here.
//
//  Vocabulary (matches Claude Code / Cursor / Codex / Gemini CLI): the noun
//  is "subagent", the verb is "delegate". `spawn_*` survive only as tool ids.
//

import SwiftUI

struct SubagentSettingsSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var modelPickerCache = ModelPickerItemCache.shared
    @Binding var configuration: SubagentConfiguration

    var body: some View {
        systemSection
    }

    private var systemSection: some View {
        SettingsSection(title: "Subagents", icon: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSubsection(label: "Orchestrator Capabilities") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(
                            "The Orchestrator may delegate to these model-backed subagents. Browser Use and Computer Use remain custom-agent-only.",
                            bundle: .module
                        )
                        .font(.system(size: 11))
                        .foregroundColor(themeManager.currentTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)

                        // The Orchestrator never gets `computer_use` /
                        // `browser_use`, and an ephemeral spawned worker
                        // strips them too. The only paths are chatting with
                        // the custom agent directly or adding it to the spawn
                        // allow-list below (delegated runs keep the agent's
                        // full tool surface). Say so here, where users look
                        // when Computer Use "does nothing" in the main chat.
                        Text(
                            "To drive apps or the browser, chat with a custom agent that has Computer Use or Browser Use enabled (Agents → Configure → Subagents), or add that agent to the Main Chat Spawn allow-list below so the Orchestrator can delegate to it.",
                            bundle: .module
                        )
                        .font(.system(size: 11))
                        .foregroundColor(themeManager.currentTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)

                        mainCapabilityToggle(
                            title: "Image",
                            description:
                                "Generate or edit images with an installed local image model.",
                            isOn: $configuration.imageDelegationEnabled,
                            readiness: mainImageReadiness
                        )

                        mainCapabilityToggle(
                            title: "AppleScript",
                            description:
                                "Use an installed AppleScript model for Mac queries and approved automation.",
                            isOn: $configuration.appleScriptDelegationEnabled,
                            readiness: mainAppleScriptReadiness
                        )
                    }
                }

                Divider()
                    .overlay(themeManager.currentTheme.inputBorder)

                SettingsSubsection(
                    label: "Subagents the Orchestrator can delegate to",
                    anchorId: "settings.orchestrator.delegation.mainChat"
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(
                            "Choose the agents and local or cloud models the Orchestrator may delegate a task to. It picks from this list for each task; an empty list keeps delegation off.",
                            bundle: .module
                        )
                        .font(.system(size: 11))
                        .foregroundColor(themeManager.currentTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)

                        readinessLabel(mainSpawnReadiness)

                        SpawnConfigurationEditor(
                            excludedAgentID: nil,
                            localHandoffEnabled: configuration.localTextDelegationEnabled,
                            modelOverride: mainChatSpawnModelOverride,
                            spawnableAgentIDs: $configuration.spawnableAgentIDs,
                            spawnableWorkspaceAgents: $configuration.spawnableWorkspaceAgents,
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

                SettingsSubsection(
                    label: "Local Models & Memory",
                    anchorId: "settings.orchestrator.delegation.handoff"
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsToggle(
                            title: "Swap local models for subagents",
                            description:
                                "Memory-safe sequence whenever a subagent uses a different local model than the chat: unload the chat model → load the subagent's model → run → unload it → load the chat model back → continue the turn. Applies whether or not the chat model was loaded at the start, and to every agent that delegates. Same-model subagents never swap. Off: the subagent runs without this sequence and the server eviction policy decides what stays loaded. (Cloud subagents never need this.)",
                            isOn: $configuration.localTextDelegationEnabled
                        )

                        SettingsToggle(
                            title: "Check memory before delegating",
                            description:
                                "Before delegating image or text work, budget one model weight footprint plus architecture-aware KV, SSM, and activation headroom for every subagent that will run. Same-model groups are split into smaller waves when needed; if even one subagent cannot fit, refuse before unloading the chat model.",
                            isOn: $configuration.ramSafetyPreflightEnabled
                        )

                        SettingsToggle(
                            title: "Keep the chat model loaded alongside subagents (experimental)",
                            description:
                                "Only while \"Swap local models for subagents\" is off: when the server eviction policy is Flexible (Multi Model) and memory projections say both fit, load the subagent's model next to the chat model, skipping the swap round-trip on high-RAM Macs. With swapping on, the unload/reload sequence always runs instead.",
                            isOn: $configuration.subagentCoexistenceEnabled
                        )
                    }
                }
            }
        }
    }

    private var mainSpawnReadiness: AgentCapabilityReadiness {
        let configuredAgentIDs = configuration.spawnableAgentIDs
        let configuredCount =
            configuredAgentIDs.count + configuration.spawnableModelNames.count
            + configuration.spawnableWorkspaceAgents.count
        let availability = SpawnDescriptors.resolveForPreview(
            agentIDs: configuredAgentIDs,
            modelNames: configuration.spawnableModelNames,
            modelNotes: configuration.spawnableModelNotes,
            launcherModelOverride:
                configuration.subagentModelOverrides[SubagentCapabilityRegistry.spawn.id],
            workspaceAgents: configuration.spawnableWorkspaceAgents
        )
        let runnableCount =
            availability.runnableAgentIDs.count + availability.runnableModelIds.count
            + availability.runnableWorkspaceAgents.count
        let checking =
            availability.agentTargets.contains { $0.state == .checking }
            || availability.modelTargets.contains { $0.state == .checking }

        return AgentCapabilityReadiness.subagent(
            flag: .spawn,
            configured: configuredCount > 0,
            toolsEnabled: true,
            hasResolvedModel: true,
            configuredSpawnTargetCount: configuredCount,
            runnableSpawnTargetCount: runnableCount,
            isCheckingSpawnTargets: checking,
            permission: configuration.permissionDefaults.policy(
                for: SubagentCapabilityRegistry.spawn.id
            )
        )
    }

    private var mainImageReadiness: AgentCapabilityReadiness {
        AgentCapabilityReadiness.subagent(
            flag: .image,
            configured: configuration.imageDelegationEnabled,
            toolsEnabled: true,
            hasResolvedModel: true,
            hasReadyImageModel: modelPickerCache.hasReadyImageModel,
            permission: configuration.permissionDefaults.policy(
                for: SubagentCapabilityRegistry.image.id
            )
        )
    }

    private var mainAppleScriptReadiness: AgentCapabilityReadiness {
        AgentCapabilityReadiness.subagent(
            flag: .appleScript,
            configured: configuration.appleScriptDelegationEnabled,
            toolsEnabled: true,
            hasResolvedModel: true,
            hasReadyAppleScriptModel: modelPickerCache.hasReadyAppleScriptModel
        )
    }

    private func mainCapabilityToggle(
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        isOn: Binding<Bool>,
        readiness: AgentCapabilityReadiness
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title, bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                Text(description, bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if readiness.configured {
                    readinessLabel(readiness)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(themeManager.currentTheme.tertiaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(readinessColor(readiness.state).opacity(0.45), lineWidth: 1)
                )
        )
    }

    private func readinessLabel(_ readiness: AgentCapabilityReadiness) -> some View {
        let message = readiness.statusMessage ?? L("Off")
        return HStack(spacing: 5) {
            Image(systemName: readiness.isCallable ? "checkmark.circle.fill" : "info.circle.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(verbatim: message)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(readinessColor(readiness.state))
    }

    private func readinessColor(_ state: AgentCapabilityReadinessState) -> Color {
        switch state {
        case .disabled:
            return themeManager.currentTheme.tertiaryText
        case .active:
            return themeManager.currentTheme.successColor
        case .paused, .needsSetup:
            return themeManager.currentTheme.warningColor
        case .unavailable:
            return themeManager.currentTheme.errorColor
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
