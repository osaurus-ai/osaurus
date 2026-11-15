//
//  ToolApprovalsChip.swift
//  osaurus
//
//  The composer's "Approvals Off" chip: shown while approval cards are
//  skipped for this chat's agent, by its Never Ask or by the global
//  Auto-Allow All Tool Calls switch. The popover says why, what still asks,
//  and offers to turn cards back on without leaving the chat.
//

import SwiftUI

struct ToolApprovalsChip: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared
    @AppStorage(ToolApprovalSettings.autoAllowAllDefaultsKey) private var globalAutoAllow = false

    let agentId: UUID
    let compact: Bool

    @State private var showsPopover = false
    @State private var isHovered = false

    var body: some View {
        if let reason = ToolApprovalResolver.chatSkipReason(agentId: agentId, globalAutoAllow: globalAutoAllow) {
            Button { showsPopover.toggle() } label: {
                SharedChipContent(spacing: theme.space.s4) {
                    Image(systemName: "hand.raised.slash.fill")
                        .glyphSize(.micro, weight: .medium)
                        .foregroundColor(theme.status.warning.foreground)
                    if !compact {
                        Text("Approvals Off", bundle: .module)
                            .textStyle(.caption, weight: 500)
                            .foregroundColor(theme.text.primary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, theme.space.s8)
                .padding(.vertical, theme.space.s4)
                .background(
                    Capsule().fill(isHovered ? theme.surface.hover : theme.status.warning.background)
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule().strokeBorder(theme.status.warning.border, lineWidth: theme.stroke.default)
                )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .onHover { isHovered = $0 }
            .help(ToolApprovalsChipPopover.cause(for: reason, agentName: agentName))
            .accessibilityLabel(Text("Approvals Off", bundle: .module))
            .accessibilityIdentifier("composer.approvalsOff")
            .popover(isPresented: $showsPopover, arrowEdge: .top) {
                ToolApprovalsChipPopover(
                    agentId: agentId,
                    agentName: agentName,
                    isCustomAgent: isCustomAgent,
                    reason: reason,
                    onDone: { showsPopover = false }
                )
                .environment(\.theme, theme)
            }
        }
    }

    private var agent: Agent? { agentManager.agent(for: agentId) }
    private var agentName: String { agent?.displayName ?? L("This agent") }
    private var isCustomAgent: Bool { agent?.isBuiltIn == false }
}

struct ToolApprovalsChipPopover: View {
    @Environment(\.theme) private var theme
    @AppStorage(ToolApprovalSettings.autoAllowAllDefaultsKey) private var globalAutoAllow = false

    let agentId: UUID
    let agentName: String
    let isCustomAgent: Bool
    let reason: ToolApprovalSkipReason
    let onDone: () -> Void

    static func cause(for reason: ToolApprovalSkipReason, agentName: String) -> String {
        switch reason {
        case .agentNeverAsk:
            return L("\(agentName) is set to Never Ask, so tool calls run without an approval card.")
        case .globalAutoAllow, .agentToolPolicy:
            return L("Auto-Allow All Tool Calls is on, so tool calls run without an approval card.")
        }
    }

    /// Never Ask goes back to the global setting, or to Ask when that would
    /// still skip cards. The global switch is turned off only where it is
    /// the agent's only setting (the built-in agents).
    private var turnBackOnTitle: String {
        reason == .agentNeverAsk || !isCustomAgent ? "Turn Back On" : "Ask for This Agent"
    }

    private var turnBackOnNote: String? {
        guard reason != .agentNeverAsk, !isCustomAgent else { return nil }
        return L("This turns off Auto-Allow All Tool Calls for every agent.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s6) {
                Image(systemName: "hand.raised.slash.fill")
                    .glyphSize(.tiny, weight: .semibold)
                    .foregroundColor(theme.status.warning.foreground)
                Text("Approvals are off", bundle: .module)
                    .textStyle(.body, weight: 600)
                    .foregroundColor(theme.text.primary)
            }

            Text(verbatim: Self.cause(for: reason, agentName: agentName))
                .textStyle(.footnote)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: theme.space.s4) {
                Text("Still asks:", bundle: .module)
                    .textStyle(.footnote, weight: 600)
                    .foregroundColor(theme.text.secondary)
                ForEach(ToolApprovalEducation.stillAsks, id: \.self) { line in
                    Text(verbatim: "• " + line)
                        .textStyle(.footnote)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(verbatim: ToolApprovalEducation.workflowNote)
                .textStyle(.footnote)
                .foregroundColor(theme.text.tertiary)

            if let turnBackOnNote {
                Text(verbatim: turnBackOnNote)
                    .textStyle(.footnote)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: theme.space.s8) {
                SettingsButton(.secondary, turnBackOnTitle, size: .compact, action: turnBackOn)
                    .accessibilityIdentifier("composer.approvalsOff.turnBackOn")
                Spacer(minLength: 0)
                SettingsButton(.tertiary, "Open Settings", icon: "gearshape", size: .compact, action: openSettings)
            }
            .padding(.top, theme.space.s4)
        }
        .padding(theme.space.s12)
        .frame(width: 320, alignment: .leading)
        .background(theme.surface.canvas)
    }

    private func turnBackOn() {
        if isCustomAgent {
            let mode: AgentToolApprovalMode =
                reason == .agentNeverAsk && !globalAutoAllow ? .useGlobal : .ask
            AgentManager.shared.updateToolApprovalMode(for: agentId, mode: mode)
        } else {
            globalAutoAllow = false
        }
        onDone()
    }

    private func openSettings() {
        onDone()
        if isCustomAgent {
            AppDelegate.shared?.showAgentDetail(agentId: agentId, tab: AgentsView.appleAppsLandingTabRaw)
            SettingsHighlightCoordinator.shared.request("agents.toolApprovals")
        } else {
            SettingsLanding.open(id: "tools.autoAllowAll")
        }
    }
}
