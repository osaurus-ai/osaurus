//
//  SubagentSettingsSection.swift
//  osaurus
//
//  Subagent policy for the built-in main chat (the Orchestrator) plus system
//  runtime knobs for local subagent jobs, on Settings → Agents → Delegation
//  (`DelegationSettingsView`). Custom agents edit the same delegation
//  controls in their Subagents tab; the built-in chat has no
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
        VStack(alignment: .leading, spacing: 20) {
            subagentsSection
            localModelsSection
        }
    }

    private var subagentsSection: some View {
        SettingsSection(
            title: "Subagents",
            subtitle:
                "The Orchestrator hands real work to these agents. Each runs as its own chat session with its own prompt, model, tools, and folder (it inherits the Orchestrator's folder when it has none). Media, AppleScript, Browser Use, and Computer Use live on custom agents — add such an agent here so the Orchestrator can delegate to it.",
            anchorId: "settings.agents.delegation.mainChat"
        ) {
            readinessChip(mainSpawnReadiness)
        } content: {
            SpawnConfigurationEditor(
                excludedAgentID: nil,
                localHandoffEnabled: configuration.localTextDelegationEnabled,
                modelOverride: mainChatSpawnModelOverride,
                spawnableAgentIDs: $configuration.spawnableAgentIDs,
                spawnableWorkspaceAgents: $configuration.spawnableWorkspaceAgents,
                removedWorkspaceAgents: $configuration.removedWorkspaceAgents,
                permissionDefaults: $configuration.permissionDefaults,
                budgets: $configuration.budgets,
                anchorPrefix: "settings.agents.delegation",
                onChange: {},
                layout: .groupRows
            )
        }
    }

    private var localModelsSection: some View {
        SettingsSection(
            title: "Local Models & Memory",
            subtitle:
                "Advanced. The defaults keep local delegation memory-safe; change these only if you know how your Mac's memory is being used.",
            anchorId: "settings.agents.delegation.handoff"
        ) {
            SettingsToggle(
                title: "Swap Local Models for Subagents",
                description:
                    "For text, Browser Use, Computer Use, AppleScript, local image jobs and context compaction using a different local model: On unloads the invoking model, runs the job, then reloads it. AppleScript keep-warm can defer the reload. Off keeps the invoking model loaded during the job, including under Server Strict. Memory checks still apply. Same-model and cloud jobs never swap.",
                isOn: $configuration.localTextDelegationEnabled
            )
            .settingsLandingAnchor("settings.agents.delegation.swapModels")

            SettingsToggle(
                title: "Check Memory Before Delegating",
                description:
                    "Applies to the Orchestrator and every agent. On: check available memory and child KV/activation costs, reusing resident weights once; split batches or refuse when needed. Off: bypass delegation memory checks, including elevated memory pressure. Allocations may fail or the app may crash. Separate Server Memory Safety load budgets and explicit concurrency limits still apply.",
                isOn: $configuration.ramSafetyPreflightEnabled
            )
            .settingsLandingAnchor("settings.agents.delegation.ramSafety")
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

    private func readinessChip(_ readiness: AgentCapabilityReadiness) -> some View {
        StatusChip(
            readiness.statusMessage ?? L("Off"),
            tone: readinessTone(readiness.state),
            icon: readiness.isCallable ? "checkmark.circle.fill" : "info.circle.fill"
        )
    }

    private func readinessTone(_ state: AgentCapabilityReadinessState) -> StatusChip.Tone {
        switch state {
        case .disabled: return .neutral
        case .active: return .success
        case .paused, .needsSetup: return .warning
        case .unavailable: return .error
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
