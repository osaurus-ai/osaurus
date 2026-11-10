//
//  EmailChannelServiceTests.swift
//  osaurusTests
//
//  The Email channel service with an in-memory message store, a scripted
//  SMTP server and a fake Mail: who reaches an agent (allowlisted address
//  or @domain, default deny, no automated or own mail, once per
//  Message-ID), what the run gets (route, thread, `email.*`), and replies
//  (SMTP threading, Mail app, drafts, Allow Sending and the global switch).
//

import Foundation
import Testing

@testable import OsaurusCore

/// Channel messages handed to automations.
final class EmailDeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [ChannelInboundMessage] = []
    var messages: [ChannelInboundMessage] { lock.withLock { _messages } }

    func record(_ message: ChannelInboundMessage) -> AgentChannelInboundRelaySubmission {
        lock.withLock { _messages.append(message) }
        return .fired(eventNames: ["Rule"], rule: "default")
    }
}

@Suite(.serialized)
struct EmailChannelServiceTests {
    static let imap = SourceConnection(
        id: "c1", displayName: "Work",
        config: .imap(
            IMAPConnectionConfig(
                host: "imap.example.com", username: "me@example.com", smtpHost: "smtp.example.com")))
    static let noSMTP = SourceConnection(
        id: "c2", displayName: "Archive",
        config: .imap(IMAPConnectionConfig(host: "imap.example.com", username: "me@example.com")))
    static let mailApp = SourceConnection(
        id: "c3", displayName: "Home", config: .mailApp(MailAppConnectionConfig(account: "Home")))

    struct Fixture {
        let service: EmailChannelService
        let store: AgentChannelMessageStore
        let deliveries: EmailDeliveryRecorder
        let smtp: FakeSMTPServer
        let mail: FakeMailService
        let killSwitch: ChannelWriteKillSwitch
    }

    private func withService(
        _ configuration: EmailChannelConfiguration,
        _ body: @Sendable (Fixture) async throws -> Void
    ) async throws {
        try await AgentChannelConfigurationTestLock.shared.run {
            let previous = EmailChannelConfigurationStore.overrideDirectory
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-email-channel-\(UUID().uuidString)", isDirectory: true)
            EmailChannelConfigurationStore.overrideDirectory = directory
            defer {
                EmailChannelConfigurationStore.overrideDirectory = previous
                try? FileManager.default.removeItem(at: directory)
            }
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            let killSwitch = ChannelWriteKillSwitch(fileURL: directory.appendingPathComponent("kill-switch.json"))
            let service = EmailChannelService(messageStore: store, writeKillSwitch: killSwitch)
            let deliveries = EmailDeliveryRecorder()
            let smtp = FakeSMTPServer()
            let mail = FakeMailService()
            let connections = [Self.imap, Self.noSMTP, Self.mailApp]
            service.connectionLookup = { id in connections.first { $0.id == id } }
            service.password = { _ in "secret" }
            service.makeSMTPTransport = { _ in ScriptedSMTPTransport(server: smtp) }
            service.mailService = mail
            service.deliverToEvents = { deliveries.record($0) }
            try service.saveConfiguration(configuration)
            try await body(
                Fixture(service: service, store: store, deliveries: deliveries, smtp: smtp, mail: mail, killSwitch: killSwitch))
        }
    }

    private static func config(
        accounts: [EmailChannelAccount] = [EmailChannelAccount(connectionId: "c1", channelConnectionId: "email")],
        senders: [String] = ["@corp.com", "boss@home.org"],
        writeEnabled: Bool = false,
        drafts: Bool = true
    ) -> EmailChannelConfiguration {
        EmailChannelConfiguration(
            accounts: accounts.map { account in
                var account = account
                account.senderAllowlist = EmailChannelConfiguration.normalizedSenders(senders)
                account.receiveEnabled = true
                account.writeEnabled = writeEnabled
                account.draftUnsentReplies = drafts
                return account
            })
    }

    private static func mail(_ id: String, from: String, thread: String? = nil) -> EmailMessage {
        FakeMailboxFetcher.message(id, from: from, thread: thread)
    }

    @Test func onlyAllowlistedSendersReachAgentsOncePerMessage() async throws {
        try await withService(Self.config()) { f in
            let account = EmailChannelAccount(connectionId: "c1", channelConnectionId: "email", maxBodyChars: 500)
            let summary = try await f.service.ingest(
                [
                    Self.mail("m1", from: "Pat@Corp.com", thread: "t1"),
                    Self.mail("m2", from: "spam@corp.com.evil.net"),
                    Self.mail("m3", from: "boss@home.org"),
                    Self.mail("m4", from: "noreply@corp.com"),
                    Self.mail("m5", from: "me@example.com"),
                ],
                connection: Self.imap, account: account, mailbox: "INBOX")
            #expect(summary.received == 5)
            #expect(f.deliveries.messages.map(\.providerEventId) == ["email:c1:m1", "email:c1:m3"])

            // The same mail again (a resync, another check): not answered twice.
            _ = try await f.service.ingest(
                [Self.mail("m1", from: "pat@corp.com", thread: "t1")], connection: Self.imap, account: account,
                mailbox: "INBOX")
            #expect(f.deliveries.messages.count == 2)
            #expect(try f.store.messageCount(connectionId: "email", roomId: "c1/INBOX") == 2)

            let first = try #require(f.deliveries.messages.first)
            #expect(first.kind == .email)
            #expect(first.connectionId == "email")
            #expect(first.identity.installationId == "c1")
            #expect(first.identity.groupId == "c1/INBOX")
            #expect(first.identity.threadId == "t1")
            #expect(first.identity.sender.senderId == "pat@corp.com")
            #expect(first.providerRoute.conversationId == "c1/INBOX")
            #expect(first.providerRoute.replyAddress == "pat@corp.com")
            #expect(first.providerRoute.displayName == "Work · Inbox")
            #expect(first.content.contains("Subject m1"))
            let email = try #require(first.extraPayload["email"])
            #expect(email.value(atPath: "subject")?.stringValue == "Subject m1")
            #expect(email.value(atPath: "account")?.stringValue == "Work")
            #expect(email.value(atPath: "body")?.stringValue?.hasSuffix("[…truncated]") == true)
            // IMAP accounts have no draft hand-off.
            #expect(first.draftReply == nil)
        }
    }

    @Test func anEmptyAllowlistLetsNothingThrough() async throws {
        try await withService(Self.config(senders: [])) { f in
            _ = try await f.service.ingest(
                [Self.mail("m1", from: "pat@corp.com")], connection: Self.imap,
                account: EmailChannelAccount(connectionId: "c1", channelConnectionId: "email"), mailbox: "INBOX")
            #expect(f.deliveries.messages.isEmpty)
            #expect(try f.store.messageCount(connectionId: "email") == 0)
            #expect(!(await f.service.diagnostics()).receiveReady)
        }
    }

    @Test func unwatchedMailboxesAreRefused() async throws {
        try await withService(Self.config()) { f in
            _ = try await f.service.ingest(
                [Self.mail("m1", from: "pat@corp.com")], connection: Self.imap,
                account: EmailChannelAccount(connectionId: "c1", channelConnectionId: "email"), mailbox: "Receipts")
            #expect(f.deliveries.messages.isEmpty)
            #expect(throws: EmailChannelServiceError.roomNotReadable("c1/Receipts")) {
                _ = try f.service.readMailbox(roomId: "c1/Receipts", limit: nil)
            }
        }
    }

    @Test func repliesGoOutOverSMTPInTheThreadOnlyWhenAllowed() async throws {
        try await withService(Self.config()) { f in
            let account = EmailChannelAccount(connectionId: "c1", channelConnectionId: "email")
            _ = try await f.service.ingest(
                [Self.mail("m1", from: "pat@corp.com", thread: "t1"), Self.mail("m2", from: "boss@home.org", thread: "t1")],
                connection: Self.imap, account: account, mailbox: "INBOX")

            // Allow Sending is off.
            await #expect(throws: EmailChannelServiceError.writeDisabled) {
                _ = try await f.service.replyToThread(threadId: "t1", content: "On it", confirmSend: true)
            }
            try f.service.saveConfiguration(Self.config(writeEnabled: true))
            await #expect(throws: EmailChannelServiceError.sendConfirmationRequired) {
                _ = try await f.service.replyToThread(threadId: "t1", content: "On it", confirmSend: false)
            }
            // The global switch wins.
            _ = try f.killSwitch.disableWrites()
            await #expect(throws: EmailChannelServiceError.globalWritesDisabled) {
                _ = try await f.service.replyToThread(threadId: "t1", content: "On it", confirmSend: true)
            }
            #expect(f.smtp.commands.isEmpty)
            _ = try f.killSwitch.enableWrites()

            let sent = try await f.service.replyToThread(threadId: "t1", content: "On it", confirmSend: true)
            #expect(sent["via"] as? String == "smtp")
            #expect(sent["to"] as? String == "boss@home.org")
            #expect(sent["in_reply_to"] as? String == "m2")
            #expect(f.smtp.commands.contains("MAIL FROM:<me@example.com>"))
            #expect(f.smtp.commands.contains("RCPT TO:<boss@home.org>"))
            #expect(!f.smtp.commands.contains("RCPT TO:<pat@corp.com>"))
            let data = try #require(f.smtp.data.first)
            #expect(data.contains("Subject: Re: Subject m2"))
            #expect(data.contains("On it"))

            // The reply is kept with the thread, so reading it shows both sides.
            let thread = try f.service.readThread(threadId: "t1", limit: nil)
            let directions = (thread["messages"] as? [[String: Any]])?.compactMap { $0["direction"] as? String }
            #expect(directions == ["inbound", "inbound", "outbound"])

            await #expect(throws: EmailChannelServiceError.threadNotFound("nope")) {
                _ = try await f.service.replyToThread(threadId: "nope", content: "x", confirmSend: true)
            }
        }
    }

    @Test func anAccountWithoutAReplyServerCannotSend() async throws {
        let accounts = [EmailChannelAccount(connectionId: "c2", channelConnectionId: "email")]
        try await withService(Self.config(accounts: accounts, writeEnabled: true)) { f in
            #expect((await f.service.diagnostics()).accountsWithoutSending == ["Archive"])
            await #expect(throws: EmailChannelServiceError.accountCannotSend("Archive")) {
                try await f.service.sendReply(
                    to: Self.mail("m1", from: "pat@corp.com"), connectionId: "c2", mailbox: "INBOX", body: "hi")
            }
            #expect(f.smtp.commands.isEmpty)
        }
    }

    @Test func mailAppAccountsSendThroughMailAndKeepUnsentRepliesAsDrafts() async throws {
        let accounts = [EmailChannelAccount(connectionId: "c3", channelConnectionId: "email")]
        try await withService(Self.config(accounts: accounts)) { f in
            _ = try await f.service.ingest(
                [Self.mail("m1", from: "pat@corp.com")], connection: Self.mailApp, account: accounts[0],
                mailbox: "INBOX")
            let message = try #require(f.deliveries.messages.first)

            // Replies held for approval open in Mail as a draft; nothing is sent.
            let draft = try #require(message.draftReply)
            try await draft("Draft text")
            #expect(f.mail.replies.count == 1)
            #expect(f.mail.replies[0].send == false)
            #expect(f.mail.replies[0].mailboxPath == "Home/INBOX")

            // Sending needs Allow Sending.
            let reply = try #require(message.reply)
            await #expect(throws: EmailChannelServiceError.writeDisabled) { try await reply("Sent text") }
            try f.service.saveConfiguration(Self.config(accounts: accounts, writeEnabled: true))
            try await reply("Sent text")
            #expect(f.mail.replies.last?.send == true)
            #expect(f.mail.replies.last?.body == "Sent text")
            #expect(f.smtp.commands.isEmpty)
        }

        let noDrafts = Self.config(accounts: accounts, drafts: false)
        try await withService(noDrafts) { f in
            _ = try await f.service.ingest(
                [Self.mail("m1", from: "pat@corp.com")], connection: Self.mailApp, account: noDrafts.accounts[0],
                mailbox: "INBOX")
            #expect(f.deliveries.messages.first?.draftReply == nil)
        }
    }

    @Test func discoveryListsWatchedAccountsAndMailboxes() async throws {
        let accounts = [EmailChannelAccount(connectionId: "c1", channelConnectionId: "email", mailboxes: ["INBOX", "Receipts"])]
        try await withService(Self.config(accounts: accounts, writeEnabled: true)) { f in
            let spaces = await f.service.listSpaces()
            #expect(spaces.map { $0["id"] as? String } == ["c1"])
            #expect(spaces.first?["can_send"] as? Bool == true)
            let rooms = await f.service.listRooms(spaceId: "c1")
            #expect(rooms.compactMap { $0["id"] as? String } == ["c1/INBOX", "c1/Receipts"])
            #expect(rooms.allSatisfy { $0["write_allowed"] as? Bool == true })
            let diagnostics = await f.service.diagnostics()
            #expect(diagnostics.receiveReady)
            #expect(diagnostics.status == "connected_read_write")
        }
    }
}
