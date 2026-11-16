//
//  EmailAutomationMigrationTests.swift
//  osaurusTests
//
//  Email automations → Email channel rules: same id, name, action and
//  filter on the mailboxes they watched, replies after approval; accounts
//  merged into `email.json` with their senders allowed; cursors moved so
//  handled mail does not run again; idempotent.
//

import Foundation
import Testing

@testable import OsaurusCore

struct EmailAutomationMigrationTests {
    static let agent = EventAction.agent(AgentEventAction(target: .local(UUID()), instructions: "File {{email.subject}}"))

    static func emailEvent(
        _ name: String, mailboxes: [String], enabled: Bool = true, unreadOnly: Bool = false, includeBody: Bool = true,
        maxBody: Int = 2_000, poll: Int = 300, senders: [String] = []
    ) -> OsaurusEvent {
        OsaurusEvent(
            name: name, isEnabled: enabled,
            source: .email(
                EmailSourceConfig(
                    connectionId: "c1", mailboxes: mailboxes, unreadOnly: unreadOnly, includeBody: includeBody,
                    maxBodyChars: maxBody, pollIntervalSeconds: poll)),
            filter: EventFilter(senderAllowlist: senders), action: agent)
    }

    @Test func eachEmailAutomationBecomesAnEmailChannelRule() throws {
        let invoices = Self.emailEvent(
            "Invoices", mailboxes: ["INBOX"], unreadOnly: true, includeBody: false, poll: 600,
            senders: ["@billing.example.com"])
        let receipts = Self.emailEvent("Receipts", mailboxes: ["Receipts"], enabled: false, maxBody: 20_000, poll: 120)
        let daily = OsaurusEvent(
            name: "Daily", source: .schedule(ScheduleSourceConfig(frequency: .daily(hour: 8, minute: 0))),
            action: Self.agent)
        let existing = EmailChannelConfiguration()

        let plan = try #require(
            EmailAutomationMigration.plan(events: [invoices, daily, receipts], configuration: existing))

        #expect(plan.events.map(\.id) == [invoices.id, receipts.id])
        let rule = plan.events[0]
        #expect(rule.name == "Invoices")
        #expect(rule.action == invoices.action)
        #expect(rule.filter == invoices.filter)
        #expect(rule.source.channelMessage?.kind == .email)
        #expect(rule.source.channelMessage?.connectionId == "email")
        #expect(rule.source.channelMessage?.roomIds == ["c1/INBOX"])
        #expect(plan.events[1].source.channelMessage?.roomIds == ["c1/Receipts"])
        #expect(!plan.events[1].isEnabled)
        #expect(rule.reply == EventReplyPolicy())
        #expect(!rule.reply.autoReply)
        #expect(rule.delivery == .defaults(for: .channelMessage))

        // One account; the most eager options win.
        let account = try #require(plan.configuration.accounts.only)
        #expect(account.connectionId == "c1")
        #expect(account.mailboxes == ["INBOX", "Receipts"])
        #expect(account.pollIntervalSeconds == 120)
        #expect(!account.unreadOnly)
        #expect(account.includeBody)
        #expect(account.maxBodyChars == EmailChannelAccount.maxBodyCharsRange.upperBound)
        #expect(account.channelConnectionId == "email")
        #expect(account.senderAllowlist == ["@billing.example.com"])
        #expect(account.receiveEnabled)
        #expect(!account.writeEnabled)

        #expect(
            plan.cursorMoves == [
                .init(from: "email:c1:INBOX", to: "emailchannel:c1:INBOX"),
                .init(from: "email:c1:Receipts", to: "emailchannel:c1:Receipts"),
            ])

        #expect(EmailAutomationMigration.plan(events: plan.events + [daily], configuration: plan.configuration) == nil)
    }

    @Test func onlyDisabledAutomationsLeaveReceiveOff() throws {
        let plan = try #require(
            EmailAutomationMigration.plan(
                events: [Self.emailEvent("Off", mailboxes: [], enabled: false)],
                configuration: EmailChannelConfiguration()))
        #expect(plan.configuration.accounts.first?.receiveEnabled == false)
        #expect(plan.configuration.accounts.first?.effectiveMailboxes == [EmailSourceConfig.inbox])
        #expect(plan.events.first?.source.channelMessage?.roomIds == ["c1/INBOX"])
        // No sender filter: nothing is allowed until the user adds senders.
        #expect(plan.configuration.accounts.first?.senderAllowlist.isEmpty == true)
    }

    @Test func runIfNeededMovesAutomationsConfigurationAndCursorsOnce() async throws {
        try await StoragePathsTestLock.shared.run {
            try await AgentChannelConfigurationTestLock.shared.run {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "osaurus-email-migration-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let previousRoot = OsaurusPaths.overrideRoot
                let previousEmail = EmailChannelConfigurationStore.overrideDirectory
                OsaurusPaths.overrideRoot = root
                EmailChannelConfigurationStore.overrideDirectory = root.appendingPathComponent("config")
                defer {
                    OsaurusPaths.overrideRoot = previousRoot
                    EmailChannelConfigurationStore.overrideDirectory = previousEmail
                    try? FileManager.default.removeItem(at: root)
                }

                let event = Self.emailEvent("Invoices", mailboxes: ["INBOX", "Receipts"], senders: ["ap@vendor.com"])
                EventStore.save(event)
                let ledger = EventRunDatabase()
                try ledger.openInMemory()
                try ledger.setSourceState(.number(7), scope: "email:c1:INBOX")
                try ledger.setSourceState(.number(1), scope: "email:c1:Receipts")
                try ledger.setSourceState(.number(99), scope: "emailchannel:c1:Receipts")

                let plan = try #require(EmailAutomationMigration.runIfNeeded(ledger: ledger))
                #expect(plan.events.count == 1)

                let stored = try #require(EventStore.loadAll().first { $0.id == event.id })
                #expect(stored.sourceKind == .channelMessage)
                #expect(stored.source.channelMessage?.roomIds == ["c1/INBOX", "c1/Receipts"])
                let saved = EmailChannelConfigurationStore.load()
                #expect(saved.accounts.map(\.connectionId) == ["c1"])
                #expect(saved.accounts.first?.senderAllowlist == ["ap@vendor.com"])
                #expect(saved.accounts.first?.receiveEnabled == true)

                #expect(try ledger.sourceState(scope: "emailchannel:c1:INBOX") == .number(7))
                // A cursor the channel already has is kept.
                #expect(try ledger.sourceState(scope: "emailchannel:c1:Receipts") == .number(99))
                #expect(try ledger.sourceState(scope: "email:c1:INBOX") == nil)
                #expect(try ledger.sourceState(scope: "email:c1:Receipts") == nil)

                #expect(EmailAutomationMigration.runIfNeeded(ledger: ledger) == nil)
            }
        }
    }
}

extension Collection {
    fileprivate var only: Element? { count == 1 ? first : nil }
}
