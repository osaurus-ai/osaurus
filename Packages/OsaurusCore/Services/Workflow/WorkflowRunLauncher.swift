//
//  WorkflowRunLauncher.swift
//  osaurus
//
//  Opens a workflow where the user can run it, watch a run, and answer its
//  forms: its run page in a chat window's Workflows view, scoped to the
//  agent the run executed on (the Orchestrator for runs started outside a
//  chat).
//
//  Workflows belong to no agent. A run the person starts uses the keys
//  shared by all agents, unless the window's agent is a custom agent that
//  has the workflow enabled: then the run is that agent's, and its own
//  keys override the shared ones.
//

import Foundation

@MainActor
enum WorkflowRunLauncher {
    static func openTab(workflowID: UUID, runID: UUID? = nil, agentId: UUID = Agent.defaultId) {
        ChatWindowManager.shared.openWorkflowTab(workflowID: workflowID, runID: runID, agentId: agentId)
    }

    /// The agent a run started from `windowAgent`'s window runs as: that
    /// agent when it is a custom agent with the workflow enabled, else none.
    static func runAgent(for workflowID: UUID, windowAgent: UUID) -> UUID? {
        guard let agent = AgentManager.shared.agent(for: windowAgent), !agent.isBuiltIn,
            agent.settings.enabledWorkflowIDs.contains(workflowID)
        else { return nil }
        return agent.id
    }

    /// Settings → Vault, on `agentId`'s view when given.
    static func openKeys(agentId: UUID? = nil) {
        if let agentId { CredentialRegistry.shared.focusAgentId = agentId }
        AppDelegate.shared?.showManagementWindow(initialTab: .keys)
    }

    /// A recorded run. Test runs belong to an Architect draft, which has
    /// no run page of its own; they open the Architect's chat.
    static func open(runID: UUID) {
        guard let run = WorkflowRunStore.shared.run(id: runID) else { return }
        guard !run.isTest, InstalledWorkflowStore.shared.workflow(id: run.workflowID) != nil else {
            ChatWindowManager.shared.openChat(withAgentId: run.caller.agentID ?? Agent.architectId)
            return
        }
        openTab(workflowID: run.workflowID, runID: runID, agentId: run.caller.agentID ?? Agent.defaultId)
    }

    /// Runs one of the template's examples in a new workflow tab, only on
    /// the user's request from the setup wizard.
    static func runExample(_ example: WorkflowExample, of workflow: InstalledWorkflow) {
        let runID = WorkflowRunService.shared.start(
            workflow, input: example.input, caller: WorkflowCaller(kind: .user, agentID: nil))
        openTab(workflowID: workflow.id, runID: runID)
    }

    private static var stagedPrefill: [UUID: [String: JSONValue]] = [:]

    /// Input the workflow's run form starts with the next time it opens,
    /// instead of the last run's.
    static func stagePrefill(_ input: [String: JSONValue], for workflowID: UUID) {
        stagedPrefill[workflowID] = input
    }

    static func takePrefill(for workflowID: UUID) -> [String: JSONValue]? {
        stagedPrefill.removeValue(forKey: workflowID)
    }

    /// The setup wizard in Main window ▸ Workflows.
    static func openSetup(_ workflow: InstalledWorkflow) {
        ManagementStateManager.shared.pendingSetupSubject = .workflow(.setup(workflow))
        AppDelegate.shared?.showManagementWindow(initialTab: .workflows)
    }
}
