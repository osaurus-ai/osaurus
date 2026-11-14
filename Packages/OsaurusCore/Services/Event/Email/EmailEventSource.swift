//
//  EmailEventSource.swift
//  osaurus
//
//  The retired email trigger. Mail reaches agents through the Email channel
//  (`EmailChannelTransportRuntime`), and `EmailAutomationMigration` turns
//  email automations into Email channel rules at launch. An email event
//  that is still stored (a failed migration, a restored backup) never
//  checks mail; it reports where mail went instead.
//

import Foundation

@MainActor
final class EmailEventSource: EventSourceAdapter {
    let kind: EventSourceKind = .email

    /// The old poll scopes, `email:<connection>:<mailbox>`; the migration
    /// moves their cursors to the channel's scopes.
    nonisolated static let ownerPrefix = "email:"

    nonisolated static func scopeKey(connectionId: String, mailbox: String) -> String {
        ownerPrefix + connectionId + ":" + mailbox
    }

    static var retiredMessage: String {
        L("Email automations moved to Channels → Email. Set up the account and allowed senders there.")
    }

    init(manager: EventManager) {}

    func stop() {}
    func reconcile(_ events: [OsaurusEvent]) async {}

    func status(_ eventId: UUID) -> EventSourceStatus {
        var status = EventSourceStatus()
        status.phase = .paused
        status.lastError = Self.retiredMessage
        return status
    }

    func fireNow(_ event: OsaurusEvent, sample: JSONValue?) async -> EventFireResult {
        EventFireResult(runId: UUID(), status: .suppressed, reason: "email_trigger_retired")
    }
}
