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
    /// The setup card each chat window is showing, so switching that
    /// window to another agent closes it instead of leaving one agent's
    /// prompt over another agent's chat.
    private var openCards: [ThemedAlertScope: (agentId: UUID, requestId: UUID)] = [:]

    private init() {}

    /// Called when `agentId` becomes the agent a chat window shows.
    public func agentShown(_ agentId: UUID, windowId: UUID) {
        let scope = ThemedAlertScope.chat(windowId)
        if let card = openCards[scope], card.agentId != agentId {
            closeCard(scope: scope, id: card.requestId)
        }
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
        present(report, for: agent, scope: scope)
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
    func resetForTesting() {
        promptedThisLaunch = []
        openCards = [:]
    }

    // MARK: - Presentation

    private func present(_ report: SetupReport, for agent: Agent, scope: ThemedAlertScope) {
        // Headless tests have no one to dismiss the card, and the shared
        // alert center would stay occupied for every later test.
        guard !RuntimeEnvironment.isUnderTests else { return }
        let requestId = UUID()
        openCards[scope] = (agent.id, requestId)
        if let folder = Self.waitingFolder(in: report, for: agent) {
            presentFolderAccess(folder, for: agent, scope: scope, requestId: requestId)
            return
        }
        let checklist = AgentSetupChecklistView(report: report)
        // An accessory, not custom content: custom content replaces the
        // button row, which left this card with no way forward.
        let request = ThemedAlertRequest(
            id: requestId,
            title: L("Finish setting up \(agent.name)"),
            message: report.hasBlockers
                ? L("This agent was created with settings this Mac cannot honour yet. It will not work as intended until these are fixed.")
                : L("A few things are worth confirming before you rely on this agent."),
            accessory: AnyView(checklist),
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
            onDismiss: { [weak self] in
                // Closing the card is "Later": the marker stays so the spawn
                // gate and the card badge keep pointing at the gap.
                self?.closeCard(scope: scope, id: requestId)
            }
        )
        ThemedAlertCenter.shared.present(request, scope: scope)
    }

    /// The alert host only calls `onDismiss`; the request stays in the
    /// center until removed, and a leftover renders again whenever the
    /// chat view rebuilds (every agent switch).
    private func closeCard(scope: ThemedAlertScope, id: UUID) {
        ThemedAlertCenter.shared.dismiss(scope: scope, id: id)
        if openCards[scope]?.requestId == id { openCards[scope] = nil }
    }

    // MARK: - A teammate's folder

    /// The folder a teammate waits on when it is the only thing missing:
    /// Downloads, Documents, or Desktop, which macOS guards and grants on
    /// the first read, so the prompt can ask for it in place.
    static func waitingFolder(in report: SetupReport, for agent: Agent) -> String? {
        guard agent.teammate != nil, let path = agent.workingFolderPath,
            let guarded = TeamSeeder.guardedFolder(path),
            !report.blocking.isEmpty,
            report.blocking.allSatisfy({ $0.kind == .workingFolder })
        else { return nil }
        return guarded
    }

    private func presentFolderAccess(
        _ path: String,
        for agent: Agent,
        scope: ThemedAlertScope,
        requestId: UUID
    ) {
        let folder = FileManager.default.displayName(atPath: path)
        let request = ThemedAlertRequest(
            id: requestId,
            title: L("Let \(agent.name) see your \(folder) folder?"),
            message: L("\(agent.name) works with the files in \(folder). macOS will ask you once to allow it."),
            buttons: [
                .cancel(L("Not Now")),
                .primary(L("Allow \(folder)")) { [weak self] in
                    Task { await self?.grantFolder(path, agentId: agent.id) }
                },
            ],
            onDismiss: { [weak self] in self?.closeCard(scope: scope, id: requestId) }
        )
        ThemedAlertCenter.shared.present(request, scope: scope)
    }

    /// Reads the folder, which raises macOS's dialog the first time, and
    /// bookmarks it on every teammate waiting for it.
    private func grantFolder(_ path: String, agentId: UUID) async {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let readable = await Task.detached {
            (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
        }.value
        guard readable else {
            ToastManager.shared.infoLocalized(
                "Folder access",
                message: "macOS did not allow it. Turn it on for Osaurus in System Settings, under Privacy & Security, Files & Folders."
            )
            return
        }
        TeamSeeder.bookmarkWaitingFolders(at: url)
        recheck(agentId)
    }
}

/// The checklist body shared by the first-run alert and (later) the wizard
/// review step.
struct AgentSetupChecklistView: View {
    @Environment(\.theme) private var theme

    let report: SetupReport

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            ForEach(report.items) { item in
                HStack(alignment: .top, spacing: theme.space.s10) {
                    Image(systemName: item.isBlocking ? "exclamationmark.circle.fill" : "info.circle")
                        .glyphSize(.label, weight: .semibold)
                        .foregroundColor(
                            item.isBlocking ? theme.status.warning.foreground : theme.status.info.foreground
                        )
                        .frame(width: 16)
                        .padding(.top, theme.space.s2)
                    VStack(alignment: .leading, spacing: theme.space.s2) {
                        HStack(spacing: theme.space.s6) {
                            Image(systemName: item.kind.icon)
                                .glyphSize(.micro, weight: .medium)
                                .foregroundColor(theme.text.tertiary)
                            Text(item.title)
                                .font(SettingsFont.caption.weight(.semibold))
                                .foregroundColor(theme.text.primary)
                        }
                        Text(item.detail)
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface.subtle, in: RoundedRectangle(cornerRadius: theme.radius.medium))
    }
}
