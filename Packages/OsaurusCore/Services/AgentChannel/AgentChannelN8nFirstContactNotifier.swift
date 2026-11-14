//
//  AgentChannelN8nFirstContactNotifier.swift
//  osaurus
//
//  The pending-contact center is UI-free and session-scoped; the n8n sheet
//  and the Connection Center only show its rows while Settings is open. A
//  first workflow run usually happens with Settings closed, so this small
//  app-level observer turns each *new* pending identity into one toast with
//  an "Open Settings" action. Repeats of the same identity do not re-toast;
//  the center only announces new keys.
//

import Foundation

@MainActor
final class AgentChannelN8nFirstContactNotifier {
    static let shared = AgentChannelN8nFirstContactNotifier()

    private var observer: NSObjectProtocol?
    private let connectionName: (String) -> String?

    init(connectionName: @escaping (String) -> String? = { id in
        AgentChannelConnectionManager.shared.connection(id: id)?.name
    }) {
        self.connectionName = connectionName
    }

    /// Starts listening. Idempotent.
    func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .agentChannelN8nPendingContactRecorded,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let contact = notification.object as? AgentChannelN8nPendingContact else { return }
            MainActor.assumeIsolated {
                self?.show(contact)
            }
        }
    }

    func uninstall() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// The toast copy for one new identity, exposed for tests.
    func message(for contact: AgentChannelN8nPendingContact) -> (title: String, body: String) {
        let channel = connectionName(contact.connectionId).flatMap { $0.isEmpty ? nil : $0 } ?? contact.connectionId
        return (
            title: L("n8n workflow '\(contact.conversationId)' wants to use \(channel)"),
            body: L(
                "Sender '\(contact.senderId)'. Nothing reached the agent yet. Allow or deny it under Channels → \(channel) → Prove it, then run the workflow again."
            )
        )
    }

    private func show(_ contact: AgentChannelN8nPendingContact) {
        let text = message(for: contact)
        _ = ToastManager.shared.action(
            text.title,
            message: text.body,
            action: .openSettings(tab: "channels"),
            buttonTitle: L("Open Channels"),
            timeout: 12
        )
    }
}
