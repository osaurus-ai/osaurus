//
//  EmailAutomationMigration.swift
//  osaurus
//
//  Email automations became Email channel rules. At launch, before events
//  load, every event with an email trigger is rewritten in place (same id,
//  name, action and filter) as a channel rule on the mailboxes it watched,
//  its account joins the Email channel configuration (`email.json`), and
//  each mailbox's poll cursor moves to the channel's scope so mail already
//  handled does not run again.
//
//  The email trigger had no sender gate; the channel denies by default.
//  Senders from the automation's own sender filter are allowed; anything
//  else waits for the user to add allowed senders. Replies start as
//  "after approval", so nothing is sent until the user turns it on.
//  Idempotent: once rewritten, an event no longer has an email trigger.
//

import Foundation

enum EmailAutomationMigration {
    struct CursorMove: Equatable {
        var from: String
        var to: String
    }

    struct Plan: Equatable {
        var events: [OsaurusEvent]
        var configuration: EmailChannelConfiguration
        var cursorMoves: [CursorMove]
    }

    /// Nil when no event has an email trigger.
    static func plan(
        events: [OsaurusEvent], configuration current: EmailChannelConfiguration, now: Date = Date()
    ) -> Plan? {
        let email = events.compactMap { event in event.source.email.map { (event, $0) } }
        guard !email.isEmpty else { return nil }

        var configuration = current
        var moves: [CursorMove] = []
        for (event, source) in email {
            let mailboxes = source.effectiveMailboxes
            merge(source, mailboxes: mailboxes, into: &configuration)
            for mailbox in mailboxes {
                let move = CursorMove(
                    from: EmailEventSource.scopeKey(connectionId: source.connectionId, mailbox: mailbox),
                    to: EmailChannelTransportRuntime.scopeKey(connectionId: source.connectionId, mailbox: mailbox))
                if !moves.contains(move) { moves.append(move) }
            }
            if let index = configuration.accounts.firstIndex(where: { $0.connectionId == source.connectionId }) {
                configuration.accounts[index].senderAllowlist += event.filter.senderAllowlist
                if event.isEnabled { configuration.accounts[index].receiveEnabled = true }
            }
        }
        configuration = configuration.normalized

        var rewritten: [OsaurusEvent] = []
        for (event, source) in email {
            var rule = event
            rule.source = .channelMessage(
                ChannelMessageSourceConfig(
                    kind: .email,
                    connectionId: configuration.account(connectionId: source.connectionId)?.channelConnectionId
                        ?? AgentChannelConnection.nativeEmailConnectionId,
                    roomIds: source.effectiveMailboxes.map {
                        EmailChannelConfiguration.roomId(connectionId: source.connectionId, mailbox: $0)
                    }))
            rule.delivery = .defaults(for: .channelMessage)
            rule.reply = EventReplyPolicy()
            rule.updatedAt = now
            rewritten.append(rule)
        }
        return Plan(events: rewritten, configuration: configuration, cursorMoves: moves)
    }

    /// One account per connection: mailboxes add up; the most eager check
    /// interval, body and length settings win.
    private static func merge(
        _ source: EmailSourceConfig, mailboxes: [String], into configuration: inout EmailChannelConfiguration
    ) {
        let maxBody = min(source.maxBodyChars, EmailChannelAccount.maxBodyCharsRange.upperBound)
        guard let index = configuration.accounts.firstIndex(where: { $0.connectionId == source.connectionId }) else {
            configuration.accounts.append(
                EmailChannelAccount(
                    connectionId: source.connectionId, mailboxes: mailboxes,
                    pollIntervalSeconds: source.pollIntervalSeconds, unreadOnly: source.unreadOnly,
                    includeBody: source.includeBody, maxBodyChars: maxBody, catchUp: source.catchUp))
            return
        }
        var account = configuration.accounts[index]
        account.mailboxes = ChannelMessageSourceConfig.normalizedRooms(account.effectiveMailboxes + mailboxes)
        account.pollIntervalSeconds = min(account.pollIntervalSeconds, source.pollIntervalSeconds)
        account.unreadOnly = account.unreadOnly && source.unreadOnly
        account.includeBody = account.includeBody || source.includeBody
        account.maxBodyChars = max(account.maxBodyChars, maxBody)
        configuration.accounts[index] = account
    }

    /// Runs on the event ledger queue at launch, before events load.
    @discardableResult
    static func runIfNeeded(ledger: EventRunDatabase) -> Plan? {
        guard
            let plan = plan(events: EventStore.loadAll(), configuration: EmailChannelConfigurationStore.load())
        else { return nil }
        for move in plan.cursorMoves {
            let existing = (try? ledger.sourceState(scope: move.to)) ?? nil
            guard existing == nil, let state = (try? ledger.sourceState(scope: move.from)) ?? nil else { continue }
            try? ledger.setSourceState(state, scope: move.to, at: Date())
        }
        do {
            try EmailChannelConfigurationStore.save(plan.configuration)
        } catch {
            // Without the channel configuration the rules would watch
            // nothing; keep the automations for the next launch.
            print("[Osaurus] Email automation migration could not save email.json: \(error.localizedDescription)")
            return nil
        }
        for event in plan.events { EventStore.save(event) }
        for move in plan.cursorMoves { try? ledger.deleteSourceState(scope: move.from) }
        print("[Osaurus] Moved \(plan.events.count) email automation(s) to the Email channel")
        return plan
    }
}
