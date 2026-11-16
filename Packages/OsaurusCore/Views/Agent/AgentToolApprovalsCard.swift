//
//  AgentToolApprovalsCard.swift
//  osaurus
//
//  The per-agent Tool Approvals mode (`AgentSettings.toolApprovalMode`,
//  `agents[].tool_approvals`) at the top of a custom agent's Tools tab.
//  Use Global Setting follows Auto-Allow All Tool Calls; Ask keeps the
//  approval card even when that switch is on; Never Ask skips it within the
//  same limits. Choosing Never Ask goes through a confirm alert.
//

import SwiftUI

struct AgentToolApprovalsCard: View {
    let agentId: UUID

    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared
    @AppStorage(ToolApprovalSettings.autoAllowAllDefaultsKey)
    private var globalAutoAllow: Bool = false
    @State private var showNeverAskConfirm = false

    /// Matches the Auto-discover card beside it.
    private static let glyphTileSize: CGFloat = 26

    private var agent: Agent? { agentManager.agent(for: agentId) }
    private var mode: AgentToolApprovalMode { agent?.settings.toolApprovalMode ?? .useGlobal }

    private var skipsCards: Bool {
        mode == .neverAsk || (mode == .useGlobal && globalAutoAllow)
    }

    private var policyCount: Int { agent?.settings.toolPolicies.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            modeRow
            ThemeHairlineDivider()
            policiesRow
        }
        .padding(theme.space.s12)
        .settingsChrome(.surface)
        .themedAlert(
            ToolApprovalEducation.neverAskConfirmTitle(agentName: agent?.displayName ?? L("This Agent")),
            isPresented: $showNeverAskConfirm,
            message: ToolApprovalEducation.neverAskConfirmMessage(agentName: agent?.displayName ?? L("This agent")),
            primaryButton: .destructive(ToolApprovalEducation.neverAskConfirmButton) { set(.neverAsk) },
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    private var policiesRow: some View {
        HStack(spacing: theme.space.s12) {
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text("Per-Tool Policies", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Text(policiesSummary)
                .textStyle(.footnote)
                .foregroundColor(theme.text.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if policyCount > 0 {
                SettingsButton(.tertiary, "Reset All", size: .compact) {
                    AgentManager.shared.resetToolPolicies(for: agentId)
                }
            }
        }
        .padding(.leading, Self.glyphTileSize + theme.space.s12)
        .settingsLandingAnchor("agents.toolPolicies")
    }

    private var policiesSummary: String {
        switch policyCount {
        case 0: return L("Set Auto, Ask or Deny for this agent with the menu on an enabled tool's row.")
        case 1: return L("1 tool has its own policy for this agent. A tool set to Deny for every agent stays denied.")
        default:
            return L("\(policyCount) tools have their own policy for this agent. A tool set to Deny for every agent stays denied.")
        }
    }

    private var modeRow: some View {
        HStack(spacing: theme.space.s12) {
            Image(systemName: skipsCards ? "hand.raised.slash" : "hand.raised")
                .glyphSize(.label, weight: .semibold)
                .foregroundColor(skipsCards ? theme.status.warning.foreground : theme.text.secondary)
                .frame(width: Self.glyphTileSize, height: Self.glyphTileSize)
                .settingsChrome(.inset)

            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text("Tool Approvals", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Text(ToolApprovalEducation.caption(mode: mode, globalAutoAllow: globalAutoAllow))
                    .textStyle(.footnote)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            SettingsMenuPicker(
                selection: Binding(get: { mode }, set: { request($0) }),
                options: AgentToolApprovalMode.allCases.map { .init($0, $0.displayName, verbatim: true) }
            )
            .accessibilityLabel(Text("Tool Approvals", bundle: .module))
        }
        .settingsLandingAnchor("agents.toolApprovals")
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
