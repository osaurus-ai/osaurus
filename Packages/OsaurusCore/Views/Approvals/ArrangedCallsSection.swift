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
                // Relative times ("in 3 hours") move on their own.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let working = SyncAgentCalls.workingSessions()
                    ForEach(waiting, id: \.grant.id) { item in
                        ArrangedCallRow(
                            grant: item.grant,
                            status: item.ringing
                                ? .ringing : .waiting(working: working.contains(item.grant.sessionId)),
                            now: context.date
                        )
                    }
                    ForEach(showsAllEnded ? ended : Array(ended.prefix(Self.endedShown))) { grant in
                        ArrangedCallRow(grant: grant, status: .ended(grant.end ?? .expired), now: context.date)
                    }
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
    let now: Date

    @Environment(\.theme) private var theme
    @State private var confirmingCancel = false

    private var agentName: String {
        AgentManager.shared.agent(for: grant.agentId)?.name ?? L("An agent")
    }

    private var isComing: Bool {
        if case .ended = status { return false }
        return true
    }

    var body: some View {
        let chip = ArrangedCallPresentation.chip(status)
        LibraryRow(
            title: ArrangedCallPresentation.title(agentName: agentName, about: grant.about),
            subtitle: ArrangedCallPresentation.subtitle(grant, status: status, now: now),
            leading: {
                SettingsIconTile(icon: isComing ? "phone.arrow.down.left" : "phone", size: 28)
            },
            badges: {
                StatusChip(chip.text, tone: chip.tone, showsDot: status == .ringing, pulses: status == .ringing)
            },
            trailing: {
                HStack(spacing: theme.space.s8) {
                    SettingsButton(.secondary, "Open Chat", size: .compact) {
                        TaskControl.openChat(grant.sessionId, agentId: grant.agentId)
                    }
                    if isComing {
                        SettingsButton(.destructive, "Cancel Call", size: .compact) {
                            confirmingCancel = true
                        }
                    }
                }
            }
        )
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
