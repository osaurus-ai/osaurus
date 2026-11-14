//
//  AgentChannelN8nPendingContactCenter.swift
//  osaurus
//
//  Approve-on-first-contact for the `n8n` channel kind. An n8n workflow
//  chooses its own `conversation_id` and `sender.id`; asking the operator to
//  predict those strings before the workflow exists is how first events die
//  silently. Instead, the ingress records a *verified* (secret-checked,
//  well-formed) event whose conversation or sender is not allowlisted yet as
//  a pending contact request. The setup sheet and Connection Center show it
//  as "Workflow X (sender Y) wants to use <channel> — Allow / Deny";
//  approving appends the real values to the allowlists. Nothing dispatches
//  until then, so the policy is exactly as strict as before.
//
//  Session-scoped and in memory, like `AgentChannelInboundActivityCenter`:
//  the workflow is simply re-run after approval.
//

import Foundation

extension Notification.Name {
    /// Posted after the pending set for any connection changes so the sheet
    /// and Connection Center refresh without polling.
    public static let agentChannelN8nPendingContactsChanged =
        Notification.Name("AgentChannelN8nPendingContactsChanged")

    /// Posted once per *new* identity (not on repeats) so an app-level
    /// observer can prompt the operator even when Settings is closed. The
    /// `object` is the `AgentChannelN8nPendingContact`.
    public static let agentChannelN8nPendingContactRecorded =
        Notification.Name("AgentChannelN8nPendingContactRecorded")
}

/// One workflow identity waiting for the operator's decision.
struct AgentChannelN8nPendingContact: Codable, Equatable, Sendable, Identifiable {
    var connectionId: String
    var conversationId: String
    var senderId: String
    var senderDisplay: String?
    var firstSeenAt: Date
    var lastSeenAt: Date
    var eventCount: Int
    var lastEventId: String

    var id: String { Self.key(connectionId: connectionId, conversationId: conversationId, senderId: senderId) }

    static func key(connectionId: String, conversationId: String, senderId: String) -> String {
        "\(connectionId)\u{1F}\(conversationId)\u{1F}\(senderId)"
    }
}

actor AgentChannelN8nPendingContactCenter {
    static let shared = AgentChannelN8nPendingContactCenter()
    /// Upper bound per connection so a verified-but-noisy workflow cannot
    /// grow the set without bound; the oldest request is evicted first.
    static let maxPendingPerConnection = 20

    private var pendingByConnection: [String: [AgentChannelN8nPendingContact]] = [:]
    /// Identities the operator denied this session; not re-prompted.
    private var deniedKeys: Set<String> = []
    private let notify: @Sendable () -> Void
    private let announce: @Sendable (AgentChannelN8nPendingContact) -> Void

    init(
        notify: (@Sendable () -> Void)? = nil,
        announce: (@Sendable (AgentChannelN8nPendingContact) -> Void)? = nil
    ) {
        self.notify =
            notify ?? {
                NotificationCenter.default.post(name: .agentChannelN8nPendingContactsChanged, object: nil)
            }
        self.announce =
            announce ?? { contact in
                NotificationCenter.default.post(name: .agentChannelN8nPendingContactRecorded, object: contact)
            }
    }

    /// Records a verified event whose identity is not allowlisted. Returns
    /// false when the identity was denied earlier this session.
    @discardableResult
    func record(
        connectionId rawConnectionId: String,
        conversationId rawConversationId: String,
        senderId rawSenderId: String,
        senderDisplay: String?,
        eventId: String,
        at date: Date = Date()
    ) -> Bool {
        let connectionId = AgentChannelConnection.normalizedId(rawConnectionId)
        let conversationId = AgentChannelConnection.normalizedId(rawConversationId)
        let senderId = AgentChannelConnection.normalizedId(rawSenderId)
        guard !connectionId.isEmpty, !conversationId.isEmpty, !senderId.isEmpty else { return false }
        let key = AgentChannelN8nPendingContact.key(
            connectionId: connectionId,
            conversationId: conversationId,
            senderId: senderId
        )
        if deniedKeys.contains(key) { return false }

        var rows = pendingByConnection[connectionId] ?? []
        var newContact: AgentChannelN8nPendingContact?
        if let index = rows.firstIndex(where: { $0.id == key }) {
            rows[index].lastSeenAt = date
            rows[index].eventCount += 1
            rows[index].lastEventId = eventId
            if let senderDisplay, !senderDisplay.isEmpty { rows[index].senderDisplay = senderDisplay }
        } else {
            let contact = AgentChannelN8nPendingContact(
                connectionId: connectionId,
                conversationId: conversationId,
                senderId: senderId,
                senderDisplay: senderDisplay,
                firstSeenAt: date,
                lastSeenAt: date,
                eventCount: 1,
                lastEventId: eventId
            )
            rows.append(contact)
            newContact = contact
            if rows.count > Self.maxPendingPerConnection {
                rows.removeFirst(rows.count - Self.maxPendingPerConnection)
            }
        }
        pendingByConnection[connectionId] = rows
        notify()
        if let newContact { announce(newContact) }
        return true
    }

    func pending(connectionId rawConnectionId: String) -> [AgentChannelN8nPendingContact] {
        let connectionId = AgentChannelConnection.normalizedId(rawConnectionId)
        return (pendingByConnection[connectionId] ?? []).sorted { $0.firstSeenAt < $1.firstSeenAt }
    }

    func pendingCount(connectionId rawConnectionId: String) -> Int {
        pendingByConnection[AgentChannelConnection.normalizedId(rawConnectionId)]?.count ?? 0
    }

    /// Pending counts for every connection that has any, keyed by id.
    func pendingCounts() -> [String: Int] {
        pendingByConnection.compactMapValues { $0.isEmpty ? nil : $0.count }
    }

    /// Forgets the request once the allowlists were updated. The caller
    /// performs the persistence; this only clears the prompt.
    func resolve(_ contact: AgentChannelN8nPendingContact) {
        remove(key: contact.id, connectionId: contact.connectionId)
    }

    /// Forgets the request and suppresses further prompts for the identity
    /// this session.
    func deny(_ contact: AgentChannelN8nPendingContact) {
        deniedKeys.insert(contact.id)
        remove(key: contact.id, connectionId: contact.connectionId)
    }

    /// Drops every pending request whose conversation AND sender are now
    /// allowlisted (e.g. after a manual allowlist edit).
    func reconcile(connectionId rawConnectionId: String, roomAllowlist: [String], senderAllowlist: [String]) {
        let connectionId = AgentChannelConnection.normalizedId(rawConnectionId)
        guard var rows = pendingByConnection[connectionId] else { return }
        let before = rows.count
        rows.removeAll { roomAllowlist.contains($0.conversationId) && senderAllowlist.contains($0.senderId) }
        pendingByConnection[connectionId] = rows.isEmpty ? nil : rows
        if rows.count != before { notify() }
    }

    /// Forgets everything about one connection (pending rows *and* the
    /// session's denials, so a deleted-and-recreated id starts clean), or
    /// about every connection when no id is given.
    func clear(connectionId rawConnectionId: String? = nil) {
        if let rawConnectionId {
            let connectionId = AgentChannelConnection.normalizedId(rawConnectionId)
            pendingByConnection.removeValue(forKey: connectionId)
            let prefix = connectionId + "\u{1F}"
            deniedKeys = deniedKeys.filter { !$0.hasPrefix(prefix) }
        } else {
            pendingByConnection.removeAll()
            deniedKeys.removeAll()
        }
        notify()
    }

    private func remove(key: String, connectionId: String) {
        guard var rows = pendingByConnection[connectionId] else { return }
        rows.removeAll { $0.id == key }
        pendingByConnection[connectionId] = rows.isEmpty ? nil : rows
        notify()
    }
}
