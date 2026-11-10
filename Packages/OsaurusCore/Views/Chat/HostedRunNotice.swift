//
//  HostedRunNotice.swift
//  osaurus
//
//  Composer-area notice for a conversation this instance hosts for a remote
//  caller (a workspace teammate or an invite-link peer driving one of our
//  shared agents). The normal composer is hidden for these rows, so this
//  notice is the tab's status line, its only Stop affordance, and the home
//  of `HostedOwnerComposer`:
//
//  - while the run is live: "Alice is using Research Agent · Writing…" with
//    a spinner and a Stop button (routes through `BackgroundTaskManager.
//    cancelTask`, which ends the SSE run on the host);
//  - afterwards: "Alice's chat with Research Agent through your workspace.
//    You can message them as yourself." (or "…through a guest link…").
//
//  On the user's other devices the chat names the Mac that served it, and
//  owner messages written there wait for that Mac to deliver them.
//
//  Kept as its own view so only it re-renders on background-task ticks.
//

import SwiftUI

struct HostedRunNotice: View {
    let sessionId: UUID?
    let callerName: String?
    let agentName: String
    let isWorkspace: Bool
    /// The owner's own chat from the paired iPhone, which runs through the
    /// shared-agent path: named as the iPhone's, not a teammate's.
    var isFromPairedPhone = false
    /// The Mac that served the chat, when it isn't this one.
    var servedBy: String?
    /// Owner turns this chat has from the user's devices.
    var ownerDeviceTurnIds: [UUID] = []
    #if OSAURUS_DESIGN_SYSTEM
    var inspectionStep: String? = nil
    var inspectionStop: (() -> Void)? = nil
    #endif

    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(40, authoritative: true) }
    @ObservedObject private var taskManager = BackgroundTaskManager.shared
    @ObservedObject private var servedChats = SyncServedChats.shared

    /// The live inbound-run task hosting this conversation, if any.
    private var liveTask: BackgroundTaskState? {
        guard let sessionId else { return nil }
        return taskManager.taskState(for: sessionId).flatMap { $0.isInboundRun && $0.status.isActive ? $0 : nil }
    }

    private var caller: String { callerName ?? L("a teammate") }
    private var activeRun: (step: String?, cancel: () -> Void)? {
        #if OSAURUS_DESIGN_SYSTEM
        if let inspectionStep { return (inspectionStep, inspectionStop ?? {}) }
        #endif
        guard let task = liveTask else { return nil }
        return (task.currentStep, { taskManager.cancelTask(task.id) })
    }

    var body: some View {
        VStack(spacing: 0) {
            statusRow
            if let servedBy, let sessionId, isAwaitingDelivery(sessionId) {
                ComposerNoticeRow(tone: theme.status.warning) {
                    Image(systemName: "clock")
                        .glyphSize(12, weight: .semibold)
                        .foregroundColor(theme.status.warning.foreground)
                    Text(String(format: L("Waiting for %@"), SyncHostedRunMonitor.shared.hostName(servedBy)))
                        .componentInspectionText(40, role: .body, fallback: .caption, weight: 500, theme: theme)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("served-chat-waiting")
            }
            if !isFromPairedPhone, let sessionId,
                InboundSharedRunBridge.shared.acceptsOwnerMessages(sessionId: sessionId)
            {
                HostedOwnerComposer(sessionId: sessionId, callerName: caller, servedBy: servedBy)
            }
        }
    }

    private func isAwaitingDelivery(_ sessionId: UUID) -> Bool {
        let delivered = servedChats.delivered[sessionId] ?? []
        return ownerDeviceTurnIds.contains { !delivered.contains($0.uuidString.lowercased()) }
    }

    @ViewBuilder
    private var statusRow: some View {
        if let run = activeRun {
            ComposerNoticeRow(tone: theme.status.info) {
                ProgressView()
                    .controlSize(.small)
                Text(liveText(step: run.step))
                    .componentInspectionText(40, role: .body, fallback: .caption, weight: 500, theme: theme)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: theme.space.s8)
                StopButton(action: run.cancel)
                    .localizedHelp("Stop this run — the caller sees it end")
                    .accessibilityIdentifier("hosted-run-stop")
            }
        } else {
            ComposerNoticeRow(tone: theme.status.info) {
                Image(
                    systemName: isFromPairedPhone ? "iphone" : isWorkspace ? "rectangle.3.group.fill" : "person.2.fill"
                )
                .glyphSize(12, weight: .semibold)
                .foregroundColor(theme.status.info.foreground)
                Text(readOnlyText)
                    .componentInspectionText(40, role: .body, fallback: .caption, weight: 500, theme: theme)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func liveText(step: String?) -> String {
        let base =
            isFromPairedPhone
            ? String(format: L("Your iPhone is using %@"), agentName)
            : String(format: L("%@ is using %@"), caller, agentName)
        if let step, !step.isEmpty { return "\(base) · \(step)" }
        return base
    }

    private var readOnlyText: String {
        if isFromPairedPhone {
            return L("This chat is from your iPhone. Continue it there.")
        }
        if let servedBy {
            return String(
                format: L("This is %@'s conversation with %@, served by %@."),
                caller,
                agentName,
                SyncHostedRunMonitor.shared.hostName(servedBy)
            )
        }
        let canMessage = sessionId.map { InboundSharedRunBridge.shared.acceptsOwnerMessages(sessionId: $0) } ?? false
        if isWorkspace {
            return String(
                format: canMessage
                    ? L("%@'s chat with %@ through your workspace. You can message them as yourself.")
                    : L("%@'s chat with %@ through your workspace."),
                caller,
                agentName
            )
        }
        return String(
            format: canMessage
                ? L("%@'s chat with %@ through a guest link. You can message them as yourself.")
                : L("%@'s chat with %@ through a guest link."),
            caller,
            agentName
        )
    }
}

/// The owner's line into a teammate's conversation with one of their agents.
/// What they write joins the transcript as theirs, reaches the agent at its
/// next step (or the next turn), and reaches the caller on their stream or
/// from the conversation mailbox.
struct HostedOwnerComposer: View {
    let sessionId: UUID
    let callerName: String
    /// The Mac that served the chat, which delivers what is written here.
    var servedBy: String?

    @Environment(\.theme) private var theme
    @State private var draft = ""
    @State private var isFocused = false

    private var trimmedCount: Int { draft.trimmingCharacters(in: .whitespacesAndNewlines).count }
    private var tooLong: Bool { trimmedCount > AttentionLimits.textCharacters }
    private var canSend: Bool { trimmedCount > 0 && !tooLong }

    var body: some View {
        VStack(alignment: .trailing, spacing: theme.space.s4) {
            // Another card (an approval) may own Return; Enter in the field
            // still sends.
            PromptReplyField(
                text: $draft,
                placeholder: "Message \(callerName) and your agent as yourself…",
                canSubmit: canSend,
                isFocused: $isFocused,
                chrome: .bubble,
                isDefaultAction: false,
                submitHelp: "Send as owner",
                fieldIdentifier: "hosted-owner-composer",
                submitIdentifier: "hosted-owner-send",
                onSubmit: send
            )
            if tooLong {
                Text(
                    String(
                        format: L("Too long to send. Keep it under %d characters."), AttentionLimits.textCharacters)
                )
                .textStyle(.footnote)
                .foregroundColor(theme.status.error.foreground)
            }
        }
        .padding(.bottom, theme.space.s8)
    }

    private func send() {
        guard canSend else { return }
        let sent =
            servedBy != nil
            ? SyncServedChats.shared.postOwnerMessage(sessionId: sessionId, text: draft) != nil
            : InboundSharedRunBridge.shared.postOwnerMessage(sessionId: sessionId, text: draft) != nil
        if sent { draft = "" }
    }
}
