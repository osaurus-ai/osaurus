//
//  AgentSetupPromptCoordinator.swift
//  osaurus
//
//  Runs the first-run readiness check when a flagged agent is shown in a
//  chat window, and shows the setup checklist when something is missing.
//  Everything clean clears the marker silently, so a well-formed agent
//  never sees a prompt. Each agent is prompted at most once per launch so
//  switching tabs does not nag; the marker itself persists until the check
//  passes or the user finishes setup.
//
//  Phase 2.3 of the agent-templates plan: this alert is the interim
//  surface; the setup wizard replaces its body while keeping the trigger.
//

import AppKit
import Foundation
import SwiftUI

@MainActor
public final class AgentSetupPromptCoordinator {
    public static let shared = AgentSetupPromptCoordinator()

    private var promptedThisLaunch: Set<UUID> = []

    private init() {}

    /// Called when `agentId` becomes the agent a chat window shows.
    public func agentShown(_ agentId: UUID, windowId: UUID) {
        guard SetupStateStore.shared.needsSetup(agentId),
            let agent = AgentManager.shared.agent(for: agentId),
            !agent.isBuiltIn
        else { return }
        let report = SetupChecker.check(agent)
        if report.isClean {
            SetupStateStore.shared.clear(agentId)
            return
        }
        guard promptedThisLaunch.insert(agentId).inserted else { return }
        present(report, for: agent, scope: .chat(windowId))
    }

    /// Re-check an agent on demand (card menu "Run Setup", after the user
    /// grants something). Returns the report so callers can render it.
    @discardableResult
    public func recheck(_ agentId: UUID) -> SetupReport? {
        guard let agent = AgentManager.shared.agent(for: agentId) else { return nil }
        let report = SetupChecker.check(agent)
        if report.isClean { SetupStateStore.shared.clear(agentId) }
        return report
    }

    /// Test seam.
    func resetForTesting() { promptedThisLaunch = [] }

    // MARK: - Presentation

    private func present(_ report: SetupReport, for agent: Agent, scope: ThemedAlertScope) {
        // Headless tests have no one to dismiss the card, and the shared
        // alert center would stay occupied for every later test.
        guard !RuntimeEnvironment.isUnderTests else { return }
        let checklist = AgentSetupChecklistView(report: report)
        let request = ThemedAlertRequest(
            title: L("Finish setting up \(agent.name)"),
            message: report.hasBlockers
                ? L("This agent was created with settings this Mac cannot honour yet. It will not work as intended until these are fixed.")
                : L("A few things are worth confirming before you rely on this agent."),
            buttons: [
                .primary(L("Set Up Now")) {
                    // Land on the Agents tab and hand the wizard request to
                    // `AgentsView`, which presents the sheet once mounted.
                    AppDelegate.shared?.showManagementWindow(initialTab: .agents)
                    ManagementStateManager.shared.pendingAgentSetupId = agent.id
                },
                .cancel(L("Later")) {
                    // Keep the marker: the agent still needs setup. The
                    // orchestrator's spawn gate keeps refusing until then.
                },
            ],
            showsCloseButton: true,
            customContent: AnyView(checklist),
            onDismiss: {
                // Closing the card is "Later": the marker stays so the spawn
                // gate and the card badge keep pointing at the gap.
            }
        )
        ThemedAlertCenter.shared.present(request, scope: scope)
    }
}

/// The checklist body shared by the first-run alert and (later) the wizard
/// review step.
struct AgentSetupChecklistView: View {
    @Environment(\.theme) private var theme

    let report: SetupReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(report.items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.isBlocking ? "exclamationmark.circle.fill" : "info.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(item.isBlocking ? theme.warningColor : theme.infoColor)
                        .frame(width: 16)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: item.kind.icon)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(theme.tertiaryText)
                            Text(item.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                        }
                        Text(item.detail)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.tertiaryBackground.opacity(0.6)))
    }
}
