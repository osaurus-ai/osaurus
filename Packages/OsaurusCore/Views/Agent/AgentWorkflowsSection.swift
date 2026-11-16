//
//  AgentWorkflowsSection.swift
//  osaurus
//
//  Agents ▸ (custom agent) ▸ Abilities: which installed workflows this agent
//  can call. Each enabled workflow becomes a `workflow_<slug>` tool whose
//  arguments are the workflow's input schema. Workflows are installed for
//  every agent; this only grants access. When the agent calls one, its own
//  keys override the shared ones. Workflows added from a workspace that run
//  on a teammate's Mac list here too, on the same terms.
//

import SwiftUI

struct AgentWorkflowsSection: View {
    let agentId: UUID

    @ObservedObject private var store = InstalledWorkflowStore.shared
    @ObservedObject private var agents = AgentManager.shared
    @ObservedObject private var links = HostedWorkflowLinkStore.shared

    private var enabled: Set<UUID> {
        Set(agents.agent(for: agentId)?.settings.enabledWorkflowIDs ?? [])
    }

    var body: some View {
        SettingsSection(
            title: "Workflows",
            subtitle: "Each workflow you turn on becomes a tool this agent can call."
        ) {
            if store.workflows.isEmpty && links.links.isEmpty {
                SettingsEmptyState(
                    inline: "flowchart",
                    title: "No workflows installed yet.",
                    action: .init(title: L("Browse Workflows"), icon: "") {
                        ManagementStateManager.shared.selectedTab = .workflows
                    }
                )
            } else {
                ForEach(store.workflows) { workflow in
                    SettingsAbilityRow(
                        title: workflow.name,
                        description: workflow.toolName,
                        icon: "flowchart",
                        isOn: binding(for: workflow.id),
                        pausedNote: pausedNote(workflow),
                        onPausedNoteTap: workflow.needsSetup
                            ? nil
                            : {
                                CredentialRegistry.shared.focusAgentId = agentId
                                ManagementStateManager.shared.selectedTab = .keys
                            },
                        verbatim: true
                    )
                }
                ForEach(links.links) { link in
                    SettingsAbilityRow(
                        title: link.name,
                        description: L("\(link.toolName) · Runs on \(link.hostLabel)"),
                        icon: "person.2",
                        isOn: binding(for: link.id),
                        verbatim: true
                    )
                }
            }
        }
        .settingsLandingAnchor("agents.workflows")
    }

    /// Setup the workflow lacks, else keys this agent has no value for
    /// (neither its own nor a shared one).
    private func pausedNote(_ workflow: InstalledWorkflow) -> String? {
        if workflow.needsSetup { return L("Needs setup") }
        let missing = WorkflowCredentials.missingKeys(workflow, agentId: agentId)
        return missing.isEmpty ? nil : L("Missing keys: \(missing.joined(separator: ", "))")
    }

    private func binding(for workflowID: UUID) -> Binding<Bool> {
        Binding(
            get: { enabled.contains(workflowID) },
            set: { isOn in
                var ids = agents.agent(for: agentId)?.settings.enabledWorkflowIDs ?? []
                if isOn {
                    if !ids.contains(workflowID) { ids.append(workflowID) }
                } else {
                    ids.removeAll { $0 == workflowID }
                }
                agents.updateEnabledWorkflowIDs(ids, for: agentId)
            }
        )
    }
}
