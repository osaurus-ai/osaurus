//
//  AgentToolApprovalsCard.swift
//  osaurus
//
//  The per-agent Tool Approvals mode (`AgentSettings.toolApprovalMode`,
//  `agents[].tool_approvals`) and the Per-Tool Policies summary, as two rows
//  of the Tool Settings group on a custom agent's Tools tab.
//  Use Global Setting follows Auto-Allow All Tool Calls; Ask keeps the
//  approval card even when that switch is on; Never Ask skips it within the
//  same limits. Choosing Never Ask goes through a confirm alert.
//

import SwiftUI

struct AgentToolApprovalsCard: View {
    let agentId: UUID

    @ObservedObject private var agentManager = AgentManager.shared
    @AppStorage(ToolApprovalSettings.autoAllowAllDefaultsKey)
    private var globalAutoAllow: Bool = false
    @State private var showNeverAskConfirm = false

    private var agent: Agent? { agentManager.agent(for: agentId) }
    private var mode: AgentToolApprovalMode { agent?.settings.toolApprovalMode ?? .useGlobal }

    private var skipsCards: Bool {
        mode == .neverAsk || (mode == .useGlobal && globalAutoAllow)
    }

    private var policyCount: Int { agent?.settings.toolPolicies.count ?? 0 }

    var body: some View {
        modeRow
            .themedAlert(
                ToolApprovalEducation.neverAskConfirmTitle(agentName: agent?.displayName ?? L("This Agent")),
                isPresented: $showNeverAskConfirm,
                message: ToolApprovalEducation.neverAskConfirmMessage(agentName: agent?.displayName ?? L("This agent")),
                primaryButton: .destructive(ToolApprovalEducation.neverAskConfirmButton) { set(.neverAsk) },
                secondaryButton: .cancel(L("Cancel"))
            )
        policiesRow
    }

    private var modeRow: some View {
        SettingsRow(
            title: "Tool Approvals",
            description: ToolApprovalEducation.caption(mode: mode, globalAutoAllow: globalAutoAllow),
            badge: skipsCards ? L("Not Asking") : nil,
            anchorId: "agents.toolApprovals",
            verbatimDescription: true
        ) {
            SettingsMenuPicker(
                selection: Binding(get: { mode }, set: { request($0) }),
                options: AgentToolApprovalMode.allCases.map { .init($0, $0.displayName, verbatim: true) }
            )
            .accessibilityLabel(Text("Tool Approvals", bundle: .module))
        }
    }

    private var policiesRow: some View {
        SettingsRow(
            title: "Per-Tool Policies",
            description: policiesSummary,
            anchorId: "agents.toolPolicies",
            verbatimDescription: true
        ) {
            if policyCount > 0 {
                SettingsButton(.tertiary, "Reset All", size: .compact) {
                    AgentManager.shared.resetToolPolicies(for: agentId)
                }
            }
        }
    }

    private var policiesSummary: String {
        switch policyCount {
        case 0: return L("Set Auto, Ask or Deny for this agent with the menu on an enabled tool's row.")
        case 1: return L("1 tool has its own policy for this agent. A tool set to Deny for every agent stays denied.")
        default:
            return L("\(policyCount) tools have their own policy for this agent. A tool set to Deny for every agent stays denied.")
        }
    }

    private func request(_ newMode: AgentToolApprovalMode) {
        guard newMode != mode else { return }
        if newMode == .neverAsk {
            showNeverAskConfirm = true
        } else {
            set(newMode)
        }
    }

    private func set(_ newMode: AgentToolApprovalMode) {
        AgentManager.shared.updateToolApprovalMode(for: agentId, mode: newMode)
    }
}
