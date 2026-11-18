//
//  OwnerApprovalPrompt.swift
//  osaurus
//
//  The inline card in a hosted shared-agent conversation when the caller's
//  run waits on the owner to approve a tool (`OwnerApprovalService`). The
//  same request is on the desktop notification and the paired phone; the
//  first answer wins and this card goes away.
//

import SwiftUI

@MainActor
public final class OwnerApprovalPromptState: ObservableObject {
    let attentionId: UUID
    let caller: Participant
    let agentName: String
    let toolName: String
    let offersConversationLease: Bool
    let expiresAt: Date
    @Published private(set) var settled = false

    init(
        attentionId: UUID,
        caller: Participant,
        agentName: String,
        toolName: String,
        offersConversationLease: Bool,
        expiresAt: Date
    ) {
        self.attentionId = attentionId
        self.caller = caller
        self.agentName = agentName
        self.toolName = toolName
        self.offersConversationLease = offersConversationLease
        self.expiresAt = expiresAt
    }

    func answer(_ outcome: AttentionResolution.Outcome) {
        guard !settled else { return }
        settled = true
        AttentionCenter.shared.resolve(id: attentionId, with: AttentionProducers.inline(outcome))
    }

    /// Answered elsewhere, timed out, or the run ended.
    func settle() { settled = true }

    /// The card was torn down unanswered (queue drained, new chat): the
    /// caller's run is released instead of waiting out the timeout.
    func abandon() {
        guard !settled else { return }
        settled = true
        AttentionCenter.shared.resolve(id: attentionId, with: AttentionProducers.abandoned)
    }
}

struct OwnerApprovalPromptOverlay: View {
    @ObservedObject var state: OwnerApprovalPromptState
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        PromptOverlayHost(onCancelDismiss: deny) {
            // The header's Cancel (Esc) is Deny; the row holds the grants.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                PromptCard(
                    pillIcon: "checkmark.shield",
                    pillLabel: "Approval needed",
                    title: L(
                        "\(ParticipantFormatter.short(state.caller)) wants \(state.agentName) to use \(state.toolName)"),
                    descriptionMarkdown: L("Nothing runs until you answer. Cancel denies it."),
                    footnote: PromptCardFootnote(icon: "clock", text: expiryFootnote(now: context.date)),
                    onCancel: deny
                ) {
                    EmptyView()
                } inputRow: {
                    HStack(spacing: theme.space.s8) {
                        Button(action: deny) {
                            Text(localized: "Deny")
                        }
                        .buttonStyle(.settings(.secondary))
                        .accessibilityLabel(actionLabel("Deny"))
                        Spacer()
                        if state.offersConversationLease {
                            Button {
                                answer(.allowedForConversation)
                            } label: {
                                Text(localized: "Allow for This Conversation")
                            }
                            .buttonStyle(.settings(.secondary))
                            .help(L("Lets this caller use this tool again in this conversation without asking."))
                            .accessibilityLabel(actionLabel("Allow for This Conversation"))
                        }
                        Button {
                            answer(.approved)
                        } label: {
                            Text(localized: "Allow")
                        }
                        .buttonStyle(.settings(.primary))
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel(actionLabel("Allow"))
                    }
                    .disabled(state.settled)
                }
            }
        }
    }

    private func expiryFootnote(now: Date) -> LocalizedStringKey {
        let remaining = state.expiresAt.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
        return state.expiresAt > now
            ? "Denied \(remaining) if unanswered. You can also answer from the notification, the Inbox, or your iPhone."
            : "You can also answer from the notification, the Inbox, or your iPhone."
    }

    private func answer(_ outcome: AttentionResolution.Outcome) {
        state.answer(outcome)
        onDismiss()
    }

    private func deny() { answer(.denied) }

    /// VoiceOver: the action, the tool, and who asked.
    private func actionLabel(_ action: String.LocalizationValue) -> Text {
        Text(
            verbatim: [L(action), state.toolName, ParticipantFormatter.accessibilityLabel(state.caller)]
                .joined(separator: ", "))
    }
}
