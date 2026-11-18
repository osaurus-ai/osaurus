//
//  ApprovalsView.swift
//  osaurus
//
//  The Inbox (sidebar "Inbox", tab id `approvals`): three sections.
//
//  - Needs You: every request waiting on the owner's answer (tool calls, a
//    teammate's tool call on a shared agent, an agent's question, a
//    workflow form, a configuration change, a secret) from every agent and
//    teammate. Answering here is the same `resolve` the inline card and the
//    notification make; the first answer wins.
//  - Waiting on Others: your chats with someone else's agent that are paused
//    while its owner decides (`WaitingOnOthers`).
//  - Live Now: people using your agents right now, from a workspace, a guest
//    link, or another of your devices.
//
//  Messages and notices are not requests: they stay notifications and
//  Insights rows. What was answered is in Insights → Interactions.
//

import OsaurusSync
import SwiftUI

struct ApprovalsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var center: AttentionCenter
    @ObservedObject private var waitingOnOthers = WaitingOnOthers.shared
    @ObservedObject private var inbound = InboundSharedRunBridge.shared
    @ObservedObject private var hostRunner = SyncHostRunner.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }


    init(center: AttentionCenter = .shared) {
        self.center = center
    }

    /// Oldest first: the request that has waited longest is on top.
    private var waiting: [AttentionItem] { ApprovalPresentation.waiting(in: center) }

    private var liveRows: [InboxLiveRow] {
        InboxLiveRow.rows(
            inbound: inbound.liveRuns,
            hosted: hostRunner.runningFor,
            devices: SyncService.shared.devices
        )
    }

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Inbox",
                subtitle: "What's waiting on you, what you're waiting on, and who's using your agents",
                count: waiting.count
            )
        } content: {
            SettingsSection(
                title: "Needs You",
                caption: waiting.isEmpty ? nil : "\(waiting.count)",
                anchorId: "approvals.overview"
            ) {
                if waiting.isEmpty {
                    SettingsEmptyState(inline: "checkmark.shield", title: "Nothing is waiting on you.")
                } else {
                    ForEach(waiting) { item in
                        ApprovalRow(item: item, center: center)
                    }
                }
            }
            SettingsSection(
                title: "Waiting on Others",
                caption: waitingOnOthers.items.isEmpty ? nil : "\(waitingOnOthers.items.count)",
                anchorId: "approvals.waitingOnOthers"
            ) {
                if waitingOnOthers.items.isEmpty {
                    SettingsEmptyState(
                        inline: "hourglass",
                        title: "You're not waiting on anyone.",
                        hint: "When someone else's agent needs its owner to allow a tool in your chat, the chat shows here until they answer."
                    )
                } else {
                    ForEach(waitingOnOthers.items) { item in
                        WaitingOnOthersRow(item: item)
                    }
                }
            }
            SettingsSection(
                title: "Live Now",
                caption: liveRows.isEmpty ? nil : "\(liveRows.count)",
                anchorId: "approvals.liveNow"
            ) {
                if liveRows.isEmpty {
                    SettingsEmptyState(
                        inline: "person.2",
                        title: "No one is using your agents right now.",
                        hint: "Teammates, guests and your other devices show here while they chat with an agent on this Mac."
                    )
                } else {
                    ForEach(liveRows) { row in
                        LiveNowRow(row: row)
                    }
                }
            }
            SettingsSection {
                SettingsLinkRow(
                    title: "Past Requests",
                    description: L("What you answered, and what timed out, in Insights → Interactions"),
                    icon: "chart.bar.xaxis",
                    actionTitle: "Show",
                    anchorId: "approvals.history"
                ) {
                    InsightsService.shared.showInteractions()
                    ChatWindowManager.shared.showInsightsSurface()
                }
            }
        }
    }
}

/// One row of Live Now: who, which agent, since when.
struct InboxLiveRow: Identifiable, Equatable {
    let id: String
    let who: String
    /// Monogram seed: a wallet, handle or device key.
    let avatarSeed: String
    let agentId: UUID
    let sessionId: UUID
    let startedAt: Date
    let isOwnDevice: Bool

    @MainActor
    static func rows(
        inbound: [InboundSharedRunBridge.LiveRun],
        hosted: [UUID: SyncHostRunner.HostedRequest],
        devices: [Device]
    ) -> [InboxLiveRow] {
        let people = inbound.map { run in
            InboxLiveRow(
                id: "run-\(run.runKey)",
                who: ParticipantFormatter.short(run.caller),
                avatarSeed: run.caller.wallet ?? run.caller.handle ?? ParticipantFormatter.short(run.caller),
                agentId: run.agentId,
                sessionId: run.taskId,
                startedAt: run.startedAt,
                isOwnDevice: false
            )
        }
        let own = hosted.map { sessionId, request in
            let device = devices.first { $0.id == request.deviceKey }
            let name = device?.name ?? L("Another device")
            let who = device?.devicePlatform == .iPhone ? String(format: L("Your iPhone (%@)"), name) : name
            return InboxLiveRow(
                id: "sync-\(sessionId.uuidString)",
                who: who,
                avatarSeed: request.deviceKey,
                agentId: request.agentId,
                sessionId: sessionId,
                startedAt: request.startedAt,
                isOwnDevice: true
            )
        }
        return (people + own).sorted { $0.startedAt < $1.startedAt }
    }
}

private struct LiveNowRow: View {
    let row: InboxLiveRow
    @Environment(\.theme) private var theme

    private var agentName: String {
        AgentManager.shared.agent(for: row.agentId)?.name ?? L("An agent")
    }

    var body: some View {
        LibraryRow(
            title: String(format: L("%@ is using %@"), row.who, agentName),
            subtitle: String(
                format: L("Started %@"), row.startedAt.formatted(.relative(presentation: .named))
            ),
            leading: {
                if row.isOwnDevice {
                    SettingsIconTile(icon: "laptopcomputer.and.iphone", size: 28)
                } else {
                    ParticipantAvatar(name: row.who, seed: row.avatarSeed)
                }
            },
            trailing: {
                SettingsButton(.secondary, "Open", size: .compact) {
                    TaskControl.openChat(row.sessionId, agentId: row.agentId)
                }
            }
        )
    }
}

private struct WaitingOnOthersRow: View {
    let item: WaitingOnOthers.Item

    var body: some View {
        LibraryRow(
            title: String(format: L("Waiting for %@ to allow %@"), item.owner, item.tool),
            subtitle: String(
                format: L("%@ · asked %@"), item.agentName, item.since.formatted(.relative(presentation: .named))
            ),
            leading: {
                SettingsIconTile(icon: "hourglass", size: 28)
            },
            trailing: {
                if let sessionId = item.sessionId {
                    SettingsButton(.secondary, "Open Chat", size: .compact) {
                        TaskControl.openChat(sessionId, agentId: nil)
                    }
                }
            }
        )
    }
}

/// One waiting request: what is asked as a sentence, who asked and when,
/// one primary answer and the rest in the ⋯ menu.
private struct ApprovalRow: View {
    let item: AttentionItem
    let center: AttentionCenter

    @Environment(\.theme) private var theme
    @State private var reply = ""

    private var trimmedReply: String { reply.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canReply: Bool { !trimmedReply.isEmpty && trimmedReply.count <= AttentionLimits.textCharacters }
    private func offers(_ action: AttentionAction) -> Bool { item.actions.contains(action) }
    private var canOpen: Bool { offers(.open) || item.effectiveLink != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            LibraryRow(
                title: ApprovalPresentation.title(item),
                subtitle: ApprovalPresentation.subtitle(item),
                leading: {
                    if let requester = item.requester, ParticipantAvatar.isPerson(requester) {
                        ParticipantAvatar(requester)
                            .help(ParticipantFormatter.short(requester))
                    } else {
                        SettingsIconTile(icon: ApprovalPresentation.icon(for: item.kind), size: 28)
                    }
                },
                trailing: { actions }
            )
            if let arguments = item.argumentsPreview {
                Text(verbatim: arguments)
                    .textStyle(.code)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .help(arguments)
                    .padding(.leading, 28 + theme.space.s12)
            }
            if offers(.reply) {
                HStack(alignment: .bottom, spacing: theme.space.s8) {
                    SettingsTextField(
                        placeholder: L("Your answer"),
                        text: $reply,
                        axis: .vertical,
                        lineLimit: 3,
                        onSubmit: sendReply
                    )
                    .accessibilityIdentifier("approvals-reply")
                    SettingsButton(.primary, "Reply", size: .compact, action: sendReply)
                        .disabled(!canReply)
                        .accessibilityIdentifier("approvals-reply-send")
                }
                .padding(.leading, 28 + theme.space.s12)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: theme.space.s6) {
            if hasMenu {
                SettingsOverflowMenu(help: "More Answers", size: .compact) { menu }
                    .accessibilityIdentifier("approvals-more")
            }
            if offers(.approve) {
                if offers(.deny) {
                    SettingsButton(.secondary, "Deny", size: .compact) { answer(.denied) }
                        .accessibilityLabel(ApprovalPresentation.actionLabel("Deny", item: item))
                        .accessibilityIdentifier("approvals-deny")
                }
                SettingsButton(.primary, "Allow", size: .compact) { answer(.approved) }
                    .accessibilityLabel(ApprovalPresentation.actionLabel("Allow", item: item))
                    .accessibilityIdentifier("approvals-approve")
            } else if !offers(.reply), canOpen {
                SettingsButton(.primary, ApprovalPresentation.openTitle(item.kind), size: .compact) {
                    AttentionOpener.open(item)
                }
                .accessibilityIdentifier("approvals-open")
            }
        }
    }

    /// Whatever isn't the primary answer.
    private var hasMenu: Bool {
        offers(.allowForConversation) || (offers(.deny) && !offers(.approve)) || offers(.dismiss)
            || (canOpen && (offers(.approve) || offers(.reply)))
    }

    @ViewBuilder
    private var menu: some View {
        if offers(.allowForConversation) {
            Button(L("Allow for This Conversation")) { answer(.allowedForConversation) }
        }
        if offers(.deny), !offers(.approve) {
            Button(L("Deny")) { answer(.denied) }
        }
        if offers(.dismiss), !offers(.deny) {
            Button(L("Dismiss")) { answer(.dismissed) }
        }
        if canOpen, offers(.approve) || offers(.reply) {
            Divider()
            Button(L("Open Conversation")) { AttentionOpener.open(item) }
        }
    }

    private func answer(_ outcome: AttentionResolution.Outcome) {
        center.resolve(id: item.id, with: AttentionProducers.inline(outcome))
    }

    private func sendReply() {
        guard canReply else { return }
        center.resolve(id: item.id, with: AttentionProducers.inline(.replied, replyText: trimmedReply))
        reply = ""
    }
}

/// Words and symbols for the Inbox and its sidebar badge.
@MainActor
enum ApprovalPresentation {
    /// The requests the page lists: blocking items only, oldest first.
    static func waiting(in center: AttentionCenter) -> [AttentionItem] {
        center.pending.filter(\.kind.isBlocking).sorted { $0.createdAt < $1.createdAt }
    }

    static func icon(for kind: AttentionKind) -> String {
        switch kind {
        case .toolApproval, .ownerApproval, .configApproval, .computerUse: return "checkmark.shield"
        case .clarification: return "questionmark.bubble"
        case .workflowDialog, .elicitation: return "list.bullet.rectangle"
        case .secretRequest: return "key"
        case .privacyReview: return "eye.slash"
        case .inboundMessage: return "bubble.left"
        case .inboundSharedRun: return "person.2"
        case .agentNotice: return "bell"
        }
    }

    /// What is asked, as a sentence: "Research Agent wants to use
    /// web_fetch", or the question itself.
    static func title(_ item: AttentionItem) -> String {
        switch item.kind {
        case .toolApproval:
            guard let tool = item.toolName else { return item.title }
            let agent = item.agent?.agentName ?? L("An agent")
            return L("\(agent) wants to use \(tool)")
        case .clarification:
            return item.body.isEmpty ? item.title : item.body
        default:
            return item.title
        }
    }

    /// "From @alice · 0x9c3e…11aa · 2 minutes ago · Declined in 8 minutes
    /// if unanswered", led by the request's own detail when the title
    /// doesn't already carry it. Names the title already gives are left out.
    static func subtitle(_ item: AttentionItem, now: Date = Date()) -> String {
        var parts: [String] = []
        switch item.kind {
        case .toolApproval:
            break
        case .ownerApproval:
            if let requester = item.requester { parts.append(L("From \(ParticipantFormatter.short(requester))")) }
        case .clarification:
            if let who = whoLine(item) { parts.append(L("Asked by \(who)")) }
        default:
            if let who = whoLine(item) { parts.append(who) }
        }
        parts.append(item.createdAt.formatted(.relative(presentation: .named)))
        if let expiry = item.expiresAt, expiry > now {
            let remaining = expiry.formatted(.relative(presentation: .named))
            parts.append(L("Declined \(remaining) if unanswered"))
        }
        let line = parts.joined(separator: " · ")
        guard showsBody(item.kind), !item.body.isEmpty else { return line }
        return "\(item.body)\n\(line)"
    }

    /// A tool approval's body is the tool's own description and a
    /// question's body is its title, so neither repeats under the title.
    private static func showsBody(_ kind: AttentionKind) -> Bool {
        kind != .toolApproval && kind != .clarification
    }

    static func whoLine(_ item: AttentionItem) -> String? {
        let requester = item.requester.map { ParticipantFormatter.short($0) }
        let agent = item.agent.map { ParticipantFormatter.short($0) }
        switch (requester, agent) {
        case (let r?, let a?): return "\(r) → \(a)"
        case (let r?, nil): return r
        case (nil, let a?): return a
        case (nil, nil): return nil
        }
    }

    /// The primary button of a request answered in its own form.
    static func openTitle(_ kind: AttentionKind) -> String {
        switch kind {
        case .workflowDialog, .elicitation: return "Fill In Form"
        case .secretRequest: return "Enter Secret"
        default: return "Open"
        }
    }

    /// VoiceOver: the action plus what it applies to.
    static func actionLabel(_ action: String.LocalizationValue, item: AttentionItem) -> Text {
        var parts = [L(action)]
        if let tool = item.toolName { parts.append(tool) }
        if let requester = item.requester { parts.append(ParticipantFormatter.accessibilityLabel(requester)) }
        return Text(verbatim: parts.joined(separator: ", "))
    }
}
