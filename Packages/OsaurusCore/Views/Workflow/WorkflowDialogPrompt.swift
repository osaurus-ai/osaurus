//
//  WorkflowDialogPrompt.swift
//  osaurus
//
//  Inline chat presentation of a workflow dialog. A chat whose tool call
//  started the run shows the dialog as a prompt card above the input bar.
//  The answer goes to `DialogCoordinator`; a dialog answered elsewhere
//  (workflow tab, relay client) is dropped from the queue.
//

import SwiftUI

@MainActor
public final class WorkflowDialogPromptState: ObservableObject {
    public let dialog: PendingDialog
    let hasSecretField: Bool
    let answer: WorkflowDialogAnswer

    init(dialog: PendingDialog) {
        self.dialog = dialog
        self.hasSecretField = dialog.fields.contains { $0.type == .secret }
        self.answer = WorkflowDialogAnswer(dialog: dialog)
    }

    /// The user cancelled the card: the dialog node fails as dismissed.
    func dismiss() {
        guard DialogCoordinator.shared.pending.contains(where: { $0.id == dialog.id }) else { return }
        DialogCoordinator.shared.dismiss(dialog.id)
    }
}

extension ChatSession {
    /// Mirrors the coordinator's presentable dialogs for this chat into the
    /// prompt queue. The only path that removes workflow cards, so a card
    /// answered here and one answered elsewhere leave the queue the same way.
    func syncWorkflowDialogs() {
        let pendingIDs = Set(DialogCoordinator.shared.pending.map(\.id))
        promptQueue.remove { item in
            if case .workflowDialog(let state) = item { return !pendingIDs.contains(state.dialog.id) }
            return false
        }
        guard let sessionID = sessionId?.uuidString else { return }
        let shown = Set(
            promptQueue.all.compactMap { item -> UUID? in
                if case .workflowDialog(let state) = item { return state.dialog.id }
                return nil
            })
        for dialog in DialogCoordinator.shared.presentable
        where dialog.caller.sessionID == sessionID && !dialog.caller.background && !shown.contains(dialog.id) {
            promptQueue.enqueue(.workflowDialog(WorkflowDialogPromptState(dialog: dialog)))
        }
    }
}

struct WorkflowDialogPromptOverlay: View {
    @ObservedObject var state: WorkflowDialogPromptState

    var body: some View {
        PromptOverlayHost(onCancelDismiss: cancel) {
            PromptCard(
                pillIcon: "flowchart",
                pillLabel: "Workflow needs input",
                title: state.dialog.title,
                descriptionMarkdown: state.dialog.message.isEmpty ? nil : state.dialog.message,
                footnote: PromptCardFootnote(
                    icon: "flowchart",
                    text: "From \(state.dialog.workflowName)"),
                onCancel: cancel
            ) {
                WorkflowDialogFields(answer: state.answer)
            } inputRow: {
                HStack {
                    Spacer()
                    WorkflowDialogContinueButton(answer: state.answer)
                }
            }
        }
    }

    private func cancel() {
        state.dismiss()
    }
}
