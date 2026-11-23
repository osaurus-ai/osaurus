//
//  ArrangedCallsSection.swift
//  osaurus
//
//  The Inbox's Arranged Calls: each call the user arranged in a chat
//  (`arrange_callback`), still to come or ended in the last week, and how it
//  went. One still to come can be called off; the iPhone's Inbox lists the
//  same calls (`callback_inbox`).
//

import SwiftUI

struct ArrangedCallsSection: View {
    @ObservedObject private var policy = AgentCallPolicy.shared
    @State private var showsAllEnded = false

    /// Ended calls shown before "Show All".
    private static let endedShown = 5

    private var waiting: [(grant: AgentCallPolicy.Grant, ringing: Bool)] { policy.waiting }
    private var ended: [AgentCallPolicy.Grant] { policy.history }

    var body: some View {
        SettingsSection(
            title: "Arranged Calls",
            caption: waiting.isEmpty ? nil : "\(waiting.count)",
            anchorId: "approvals.arrangedCalls"
        ) {
            if waiting.isEmpty && ended.isEmpty {
                SettingsEmptyState(
                    inline: "phone.arrow.down.left",
                    title: "No calls arranged.",
                    hint: "When you ask an agent to call you back on your iPhone, the call shows here until it's made."
                )
            } else {
                // One subview per row, so the section's group spaces and divides them as it does other
                // lists; a single TimelineView around them all made them one block with no gaps between.
                let working = SyncAgentCalls.workingSessions()
                ForEach(waiting, id: \.grant.id) { item in
                    ArrangedCallRow(
                        grant: item.grant,
                        status: item.ringing
                            ? .ringing : .waiting(working: working.contains(item.grant.sessionId))
                    )
                }
                ForEach(showsAllEnded ? ended : Array(ended.prefix(Self.endedShown))) { grant in
                    ArrangedCallRow(grant: grant, status: .ended(grant.end ?? .expired))
                }
                if ended.count > Self.endedShown {
                    SettingsButton(.tertiary, showsAllEnded ? "Show Fewer" : "Show All", size: .compact) {
                        showsAllEnded.toggle()
                    }
                }
            }
        }
    }
}

/// What a row says about one arranged call. Pure, for tests.
enum ArrangedCallPresentation {
    enum Status: Equatable {
        case waiting(working: Bool)
        case ringing
        case ended(AgentCallPolicy.End)
    }

    static func title(agentName: String, about: String) -> String {
        String(format: L("%@ will call you %@"), agentName, about)
    }

    static func chip(_ status: Status) -> (text: String, tone: StatusChip.Tone) {
        switch status {
        case .waiting: return (L("Waiting"), .info)
        case .ringing: return (L("Ringing"), .accent)
        case .ended(let end):
            switch end {
            case .answered: return (L("Answered"), .success)
            case .missed: return (L("Missed"), .warning)
            case .declined: return (L("Declined"), .neutral)
            case .calledOff: return (L("Stopped"), .neutral)
            case .cancelled: return (L("Cancelled"), .neutral)
            case .expired: return (L("Not Called"), .warning)
            case .replaced: return (L("Replaced"), .neutral)
            }
        }
    }

    struct Fact: Equatable {
        let label: String
        let value: String
    }

    /// The sheet's lines, label and value, in order; only those that apply.
    static func facts(_ grant: AgentCallPolicy.Grant, status: Status) -> [Fact] {
        let date: (Int64) -> String = { ms in
            Date(timeIntervalSince1970: TimeInterval(ms) / 1000).formatted(date: .abbreviated, time: .shortened)
        }
        var facts = [Fact(label: L("Status"), value: chip(status).text)]
        if let created = grant.createdMs { facts.append(Fact(label: L("Arranged"), value: date(created))) }
        switch status {
        case .waiting(let working):
            facts.append(Fact(label: L("Expires"), value: date(grant.expiresMs)))
            facts.append(Fact(label: L("Agent's Work"), value: working ? L("Still running") : L("Finished")))
        case .ringing:
            facts.append(Fact(label: L("Expires"), value: date(grant.expiresMs)))
        case .ended:
            facts.append(Fact(label: L("Ended"), value: date(grant.endedMs ?? grant.expiresMs)))
        }
        for (index, attempt) in (grant.attempts ?? []).enumerated() {
            let why: String
            switch attempt.outcome {
            case "busy": why = L("Another call was on")
            case "unavailable": why = L("No iPhone could take it")
            default: why = L("The call couldn't be sent")
            }
            let label = String(format: L("Try %lld"), index + 1)
            facts.append(Fact(label: label, value: "\(date(attempt.atMs)) · \(why)"))
        }
        return facts
    }

    static func subtitle(_ grant: AgentCallPolicy.Grant, status: Status, now: Date) -> String {
        func relative(_ ms: Int64) -> String {
            let formatter = RelativeDateTimeFormatter()
            formatter.dateTimeStyle = .named
            return formatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(ms) / 1000), relativeTo: now)
        }
        switch status {
        case .waiting(let working):
            var parts: [String] = []
            if let created = grant.createdMs { parts.append(String(format: L("Arranged %@"), relative(created))) }
            parts.append(String(format: L("Expires %@"), relative(grant.expiresMs)))
            if working { parts.append(L("Work still running")) }
            let tries = grant.attempts?.count ?? 0
            if tries == 1 {
                parts.append(L("1 try didn't reach you"))
            } else if tries > 1 {
                parts.append(String(format: L("%lld tries didn't reach you"), tries))
            }
            return parts.joined(separator: " · ")
        case .ringing:
            return L("Ringing your iPhone now")
        case .ended(let end):
            let when = relative(grant.endedMs ?? grant.expiresMs)
            switch end {
            case .answered: return String(format: L("You answered %@"), when)
            case .missed: return String(format: L("Rang %@, nobody answered"), when)
            case .declined: return String(format: L("You declined %@"), when)
            case .calledOff: return String(format: L("The agent stopped while it rang, %@"), when)
            case .cancelled: return String(format: L("You cancelled it %@"), when)
            case .expired: return String(format: L("The agent didn't call in time. Expired %@"), when)
            case .replaced: return String(format: L("A newer call was arranged in the chat %@"), when)
            }
        }
    }
}

private struct ArrangedCallRow: View {
    let grant: AgentCallPolicy.Grant
    let status: ArrangedCallPresentation.Status

    @Environment(\.theme) private var theme
    @State private var confirmingCancel = false
    @State private var showsDetails = false
    /// Open Chat spins while the chat is looked up, rather than seeming not to work.
    @State private var openingChat = false

    private var agentName: String {
        AgentManager.shared.agent(for: grant.agentId)?.name ?? L("An agent")
    }

    private var isComing: Bool {
        if case .ended = status { return false }
        return true
    }

    var body: some View {
        // Relative times ("in 3 hours") move on their own.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            row(now: context.date)
        }
    }

    private func row(now: Date) -> some View {
        let chip = ArrangedCallPresentation.chip(status)
        return LibraryRow(
            title: ArrangedCallPresentation.title(agentName: agentName, about: grant.about),
            subtitle: ArrangedCallPresentation.subtitle(grant, status: status, now: now),
            // The whole of it, as the iPhone's Inbox shows a tapped call.
            action: { showsDetails = true },
            leading: {
                SettingsIconTile(icon: isComing ? "phone.arrow.down.left" : "phone", size: 28)
            },
            // The chip sits with the buttons, not beside the title: taller than the title's line, it pushed the
            // subtitle further from the title than one row is from the next.
            trailing: {
                HStack(spacing: theme.space.s8) {
                    StatusChip(chip.text, tone: chip.tone, showsDot: status == .ringing, pulses: status == .ringing)
                    // The spinner in place of the label, inside the button and at its width, while the chat is
                    // found.
                    Button {
                        guard !openingChat else { return }
                        openingChat = true
                        Task {
                            await TaskControl.openChatNow(grant.sessionId, agentId: grant.agentId)
                            openingChat = false
                        }
                    } label: {
                        Text("Open Chat", bundle: .module)
                            .opacity(openingChat ? 0 : 1)
                            .overlay {
                                if openingChat { SettingsSpinner(size: .mini) }
                            }
                    }
                    .assignedSettingsButtonStyle(.secondary, size: .compact)
                    .accessibilityLabel(Text("Open Chat", bundle: .module))
                    if isComing {
                        SettingsButton(.destructive, "Cancel Call", size: .compact) {
                            confirmingCancel = true
                        }
                    }
                }
            }
        )
        // The subtitle close under its title, one call's two lines read as one.
        .subtitleGap(theme.space.s2)
        .sheet(isPresented: $showsDetails) {
            ArrangedCallSheet(
                grant: grant,
                status: status,
                agentName: agentName,
                onCancelCall: {
                    showsDetails = false
                    confirmingCancel = true
                },
                onClose: { showsDetails = false }
            )
        }
        .confirmationDialog(L("Cancel this call?"), isPresented: $confirmingCancel) {
            Button(L("Cancel Call"), role: .destructive) {
                AgentCallPolicy.shared.cancel(grant.id, nowMs: SyncHostedRunContract.nowMs())
            }
            Button(L("Keep Call"), role: .cancel) {}
        } message: {
            Text(verbatim: String(format: L("%@ won't call you about this."), agentName))
        }
    }
}

/// A tapped arranged call: what it's about and how it stands (when it was arranged, when it expires or ended, the
/// agent's work, tries that didn't reach the iPhone), with Open Chat and, while it's still to come, Cancel Call.
private struct ArrangedCallSheet: View {
    let grant: AgentCallPolicy.Grant
    let status: ArrangedCallPresentation.Status
    let agentName: String
    let onCancelCall: () -> Void
    let onClose: () -> Void

    private var isComing: Bool {
        if case .ended = status { return false }
        return true
    }

    private var openChat: SettingsSheetFooter.Action {
        SettingsSheetFooter.Action(label: "Open Chat") {
            onClose()
            TaskControl.openChat(grant.sessionId, agentId: grant.agentId)
        }
    }

    var body: some View {
        SettingsSheet(
            icon: isComing ? "phone.arrow.down.left" : "phone",
            title: "Arranged Call",
            primary: isComing
                ? SettingsSheetFooter.Action(label: "Cancel Call", isDestructive: true, handler: onCancelCall)
                : openChat,
            secondary: isComing ? openChat : nil,
            onClose: onClose
        ) {
            Text(verbatim: ArrangedCallPresentation.title(agentName: agentName, about: grant.about))
                .assignedTypography("component.library.14.label", fallback: SettingsFont.rowTitle)
                .fixedSize(horizontal: false, vertical: true)
            SettingsGroup {
                ForEach(ArrangedCallPresentation.facts(grant, status: status), id: \.label) { fact in
                    SettingsRow(
                        title: fact.label,
                        verbatimTitle: true,
                        leading: { EmptyView() },
                        description: { EmptyView() },
                        trailing: {
                            Text(verbatim: fact.value)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    )
                }
            }
        }
    }
}
