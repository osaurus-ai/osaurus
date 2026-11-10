//
//  ShareAgentSheet.swift
//  osaurus
//
//  The one Share flow for an agent (agent header → Share…). First the
//  destination: a workspace (teammates, billed to workspace credits) or a
//  guest link (one person, revocable). A workspace hands off to that
//  workspace's Share agent sheet, which holds the billing choice. A guest
//  link shows remote access (with its consent), what guests get, the
//  signed `osaurus://…?pair=…` link as QR + copy + system share, and the
//  agent's live guests so a leaked link can be revoked from here.
//

import SwiftUI

// MARK: - Expiry options

private enum ShareInviteExpiry: String, CaseIterable, Identifiable {
    case hour1
    case day1
    case days7
    case days30

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hour1: return L("1 hour")
        case .day1: return L("1 day")
        case .days7: return L("7 days")
        case .days30: return L("30 days")
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .hour1: return 3600
        case .day1: return 86_400
        case .days7: return 7 * 86_400
        case .days30: return 30 * 86_400
        }
    }

    var date: Date {
        Date().addingTimeInterval(seconds)
    }
}

// MARK: - Sheet

struct ShareAgentSheet: View {
    enum Destination: Equatable {
        case choose
        case workspace
        case guestLink
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @ObservedObject private var relayManager = RelayTunnelManager.shared
    @ObservedObject private var workspacesService = WorkspacesService.shared
    @ObservedObject private var rosterStore = WorkspaceRosterStore.shared

    let agent: Agent

    @State private var destination: Destination
    @State private var expiry: ShareInviteExpiry = .days7
    @State private var generatedInvite: AgentInvite?
    @State private var generatedURL: URL?
    @State private var generationError: String?
    @State private var isGenerating = false
    @State private var ledgerToken = 0

    init(agent: Agent, initialDestination: Destination = .choose) {
        self.agent = agent
        _destination = State(initialValue: initialDestination)
    }

    private var relayStatus: AgentRelayStatus {
        relayManager.agentStatuses[agent.id] ?? .disconnected
    }

    private var relayBaseURL: String? {
        if case .connected(let url) = relayStatus { return url }
        return nil
    }

    private var shareableWorkspaces: [OsaurusRouterWorkspaceSummary] {
        guard OsaurusRouter.isEnabled, !agent.isBuiltIn else { return [] }
        return AgentSharedWithSection.shareableWorkspaces(
            for: agent,
            workspaces: workspacesService.workspaces,
            rosterStore: rosterStore
        )
    }

    /// Why the Workspace choice is off, or nil when it's available.
    private var workspaceUnavailableReason: String? {
        if agent.isBuiltIn { return L("Built-in agents can't be shared. Duplicate it first.") }
        if !OsaurusRouter.isEnabled { return L("Sign in to workspaces under Sharing → Workspaces first.") }
        if workspacesService.workspaces.isEmpty { return L("Create or join a workspace under Sharing → Workspaces first.") }
        if shareableWorkspaces.isEmpty { return L("Already shared with every workspace you can share to.") }
        return nil
    }

    private var subtitle: String {
        switch destination {
        case .choose: return L("Choose who gets to chat with \(agent.name).")
        case .workspace: return L("Pick the workspace to share \(agent.name) with.")
        case .guestLink: return L("Send one person a link to chat with \(agent.name).")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsSheetHeader(
                icon: "square.and.arrow.up.circle.fill",
                title: "Share Agent",
                subtitleText: subtitle,
                onClose: { dismiss() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s16) {
                    switch destination {
                    case .choose: chooseStep
                    case .workspace: workspaceStep
                    case .guestLink: guestLinkStep
                    }
                }
                .padding(theme.settingsSheetInset)
            }
            .background(theme.surface.overlay)

            SettingsSheetFooter(
                primary: SettingsSheetFooter.Action(label: "Done", handler: { dismiss() }),
                secondary: destination == .choose
                    ? nil
                    : SettingsSheetFooter.Action(label: "Back", handler: { destination = .choose })
            )
        }
        .fittedSheetFrame(width: 520, height: 640)
        .background(theme.surface.raised)
        .onChange(of: relayStatus) { _, newValue in
            if destination == .guestLink, case .connected = newValue, generatedInvite == nil {
                Task { await generateInvite() }
            }
        }
        .onChange(of: destination) { _, newValue in
            if newValue == .guestLink, relayBaseURL != nil, generatedInvite == nil {
                Task { await generateInvite() }
            }
        }
    }

    // MARK: Destination

    @ViewBuilder
    private var chooseStep: some View {
        ShareOptionRow(
            icon: "person.2.fill",
            title: L("Workspace"),
            detail: workspaceUnavailableReason
                ?? L("Teammates chat with it from their own Osaurus. Their chats use workspace credits."),
            isEnabled: workspaceUnavailableReason == nil,
            action: { destination = .workspace }
        )
        .accessibilityIdentifier("share-agent-workspace")
        ShareOptionRow(
            icon: "link",
            title: L("Guest Link"),
            detail: L("One person, one link. Chats run on this Mac and you can revoke the link anytime."),
            isEnabled: !agent.isBuiltIn,
            action: { destination = .guestLink }
        )
        .accessibilityIdentifier("share-agent-guest-link")
    }

    @ViewBuilder
    private var workspaceStep: some View {
        if shareableWorkspaces.isEmpty {
            SettingsEmptyState(
                inline: "person.2",
                title: "No workspace to share to",
                hint: workspaceUnavailableReason ?? ""
            )
        } else {
            ForEach(shareableWorkspaces, id: \.id) { workspace in
                ShareOptionRow(
                    icon: "person.2.fill",
                    title: workspace.name,
                    detail: L("Next: choose its display name and billing."),
                    action: { openWorkspaceShare(workspace.id) }
                )
            }
        }
    }

    // MARK: Guest link

    @ViewBuilder
    private var guestLinkStep: some View {
        SettingsSection(title: "Remote Access") {
            RemoteAccessRow(agent: agent, showsName: false)
        }

        SettingsCallout(
            icon: "person.badge.shield.checkmark",
            title: "What Guests Get",
            message:
                "Guests chat with this agent as you've set it up: its model, tools and folders, running on this Mac. They don't see your other agents or chats. Tools that need approval wait for you in the Inbox."
        )

        if relayBaseURL != nil {
            SettingsSection(
                title: "Guest Link",
                accessory: { expiryPicker }
            ) {
                inviteContent
            }
        }

        GuestAccessLedger(
            agents: [agent],
            activeOnly: true,
            reloadToken: ledgerToken,
            onRevoke: { row in
                if row.inviteNonce != nil, row.inviteNonce == generatedInvite?.nonce {
                    generatedInvite = nil
                    generatedURL = nil
                }
            }
        )
    }

    private var expiryPicker: some View {
        SettingsMenuPicker(
            selection: Binding(
                get: { expiry },
                set: { option in
                    expiry = option
                    if generatedInvite != nil {
                        Task { await generateInvite() }
                    }
                }
            )
        ) {
            ForEach(ShareInviteExpiry.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .help(L("Link expires after"))
    }

    @ViewBuilder
    private var inviteContent: some View {
        if let error = generationError {
            SheetHintRow(kind: .error, message: error)
        }
        if isGenerating {
            SettingsRow(title: "Signing link…", description: "", trailing: { ProgressView().controlSize(.small) })
        } else if let url = generatedURL {
            HStack(alignment: .top, spacing: theme.space.s16) {
                ShareQRCardView(text: url.absoluteString)
                    .frame(width: 124, height: 124)
                VStack(alignment: .leading, spacing: theme.space.s8) {
                    ShareCopyRow(label: L("Link"), value: url.absoluteString)
                    ShareLink(item: url) {
                        Label(L("Share…"), systemImage: "square.and.arrow.up")
                    }
                    .assignedSettingsButtonStyle(.secondary, size: .compact)
                }
            }
            if let invite = generatedInvite {
                Text(
                    "Single-use: once someone accepts, this link can't be used again. Expires \(invite.expirationDate.formatted(date: .abbreviated, time: .shortened)).",
                    bundle: .module
                )
                .textStyle(.footnote)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            SettingsRow(
                title: "Create a Guest Link",
                description: L("A signed, single-use link for one person."),
                trailing: {
                    SettingsButton(.primary, "Create Link", size: .compact) {
                        Task { await generateInvite() }
                    }
                }
            )
        }
    }

    // MARK: Behaviour

    private func openWorkspaceShare(_ workspaceId: String) {
        let agentId = agent.id
        dismiss()
        DispatchQueue.main.async {
            RemoteAgentWorkspaceAttribution.shareAgent(agentId, toWorkspace: workspaceId)
        }
    }

    private func generateInvite() async {
        guard let baseURL = relayBaseURL else { return }
        isGenerating = true
        defer { isGenerating = false }
        generationError = nil

        do {
            let invite = try AgentInviteIssuer.issue(
                for: agent,
                relayBaseURL: baseURL,
                expiresAt: expiry.date
            )
            AgentInviteStore.purgeOld(for: agent.id)
            AgentInviteStore.record(invite, for: agent.id)
            generatedInvite = invite
            generatedURL = try invite.deeplinkURL()
            ledgerToken += 1
        } catch let error as AgentInviteError {
            generationError = error.errorDescription
        } catch {
            generationError = L("Could not create the link: \(error.localizedDescription)")
        }
    }
}
