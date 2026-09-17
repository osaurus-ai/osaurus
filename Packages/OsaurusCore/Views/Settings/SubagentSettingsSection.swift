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
                SettingsSubsection(
                    label: "Allowed subagents",
                    anchorId: "settings.orchestrator.delegation.mainChat"
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(
                            "The Orchestrator hands real work to these agents. Each runs as its own chat session with its own prompt, model, tools, and folder (it inherits the Orchestrator's folder when it has none). Media, AppleScript, Browser Use, and Computer Use live on custom agents — add such an agent here so the Orchestrator can delegate to it.",
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
                            removedWorkspaceAgents: $configuration.removedWorkspaceAgents,
                            permissionDefaults: $configuration.permissionDefaults,
                            budgets: $configuration.budgets,
                            anchorPrefix: "settings.orchestrator.delegation",
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
                        Text(
                            "Advanced. The defaults keep local delegation memory-safe; change these only if you know how your Mac's memory is being used.",
                            bundle: .module
                        )
                        .font(.system(size: 11))
                        .foregroundColor(themeManager.currentTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)

                        SettingsToggle(
                            title: "Swap local models for subagents",
                            description:
                                "For text, Browser Use, Computer Use and AppleScript subagents using a different local model: On unloads the invoking model, runs the subagent, then reloads it. AppleScript keep-warm can defer the reload. Off keeps the invoking model loaded during the job, including under Server Strict. Memory checks still apply. Same-model and cloud subagents never swap.",
                            isOn: $configuration.localTextDelegationEnabled
                        )
                        .settingsLandingAnchor("settings.orchestrator.delegation.swapModels")

                        SettingsToggle(
                            title: "Check memory before delegating",
                            description:
                                "Applies to the Orchestrator and every agent. On: check available memory and child KV/activation costs, reusing resident weights once; split batches or refuse when needed. Off: bypass delegation memory checks, including elevated memory pressure. Allocations may fail or the app may crash. Separate Server Memory Safety load budgets and explicit concurrency limits still apply.",
                            isOn: $configuration.ramSafetyPreflightEnabled
                        )
                        .settingsLandingAnchor("settings.orchestrator.delegation.ramSafety")
                    }
                }
            }
        }
    }

    private var mainSpawnReadiness: AgentCapabilityReadiness {
        let configuredAgentIDs = configuration.spawnableAgentIDs
        let configuredCount =
            configuredAgentIDs.count + configuration.spawnableWorkspaceAgents.count
        let availability = SpawnDescriptors.resolveForPreview(
            agentIDs: configuredAgentIDs,
            launcherModelOverride:
                configuration.subagentModelOverrides[SubagentCapabilityRegistry.spawn.id],
            workspaceAgents: configuration.spawnableWorkspaceAgents
        )
        let runnableCount =
            availability.runnableAgentIDs.count + availability.runnableWorkspaceAgents.count
        let checking = availability.agentTargets.contains { $0.state == .checking }

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
