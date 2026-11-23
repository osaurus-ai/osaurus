//
//  SMTPClientTests.swift
//  osaurusTests
//
//  The SMTP client against a scripted server: sign-in mechanisms, the
//  envelope, dot-stuffing, typed refusals; and the reply builder's
//  threading headers.
//

import Foundation
import Testing

@testable import OsaurusCore

/// A minimal SMTP server: one reply per command, DATA collected to the dot.
final class FakeSMTPServer: @unchecked Sendable {
    private let lock = NSLock()
    var capabilities = ["AUTH PLAIN LOGIN", "8BITMIME"]
    var username = "me@example.com"
    var password = "secret"
    var rejectRecipients: Set<String> = []
    private(set) var commands: [String] = []
    private(set) var data: [String] = []
    private var pending = ""
    private var inData = false
    private var dataBuffer = ""
    private var loginStep = 0
    private var loginUser = ""

    func reply(to bytes: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending += String(decoding: bytes, as: UTF8.self)
        var out: [String] = []
        while true {
            if inData {
                guard let end = pending.range(of: "\r\n.\r\n") else { return out }
                dataBuffer = String(pending[..<end.lowerBound])
                pending = String(pending[end.upperBound...])
                data.append(dataBuffer)
                inData = false
                out.append("250 2.0.0 queued\r\n")
                continue
            }
            guard let end = pending.range(of: "\r\n") else { return out }
            let line = String(pending[..<end.lowerBound])
            pending = String(pending[end.upperBound...])
            commands.append(line)
            out.append(respond(line))
        }
    }

    private func respond(_ line: String) -> String {
        if loginStep == 1 {
            loginUser = String(decoding: Data(base64Encoded: line) ?? Data(), as: UTF8.self)
            loginStep = 2
            return "334 UGFzc3dvcmQ6\r\n"
        }
        if loginStep == 2 {
            loginStep = 0
            let typed = String(decoding: Data(base64Encoded: line) ?? Data(), as: UTF8.self)
            return loginUser == username && typed == password ? "235 ok\r\n" : "535 5.7.8 bad credentials\r\n"
        }
        let upper = line.uppercased()
        if upper.hasPrefix("EHLO") {
            let lines = ["smtp.example.com"] + capabilities
            return lines.enumerated().map { i, text in "250\(i == lines.count - 1 ? " " : "-")\(text)\r\n" }.joined()
        }
        if upper.hasPrefix("AUTH PLAIN ") {
            let token = String(line.dropFirst("AUTH PLAIN ".count))
            let parts = String(decoding: Data(base64Encoded: token) ?? Data(), as: UTF8.self)
                .split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
            let ok = parts.count == 3 && parts[1] == username && parts[2] == password
            return ok ? "235 2.7.0 accepted\r\n" : "535 5.7.8 bad credentials\r\n"
        }
        if upper == "AUTH LOGIN" {
            loginStep = 1
            return "334 VXNlcm5hbWU6\r\n"
        }
        if upper.hasPrefix("MAIL FROM:") { return "250 ok\r\n" }
        if upper.hasPrefix("RCPT TO:") {
            let address = line.dropFirst("RCPT TO:<".count).dropLast()
            return rejectRecipients.contains(String(address)) ? "550 5.1.1 no such user\r\n" : "250 ok\r\n"
        }
        if upper == "DATA" {
            inData = true
            return "354 go ahead\r\n"
        }
        if upper == "QUIT" { return "221 bye\r\n" }
        return "502 unknown\r\n"
    }
}

final class ScriptedSMTPTransport: IMAPTransport, @unchecked Sendable {
    private let server: FakeSMTPServer
    private let inner: ScriptedIMAPTransport

    init(server: FakeSMTPServer) {
        self.server = server
        inner = ScriptedIMAPTransport(server: FakeIMAPServer(), greeting: "220 smtp.example.com ESMTP\r\n", chunkSize: 9)
    }

    func open() async throws {}

    func send(_ data: Data) async throws {
        for reply in server.reply(to: data) {
            for chunk in ScriptedIMAPTransport.chunks(reply, size: 9) { inner.deliver(chunk) }
        }
    }

    func receive() async throws -> Data { try await inner.receive() }
    func close() { inner.close() }
}

struct SMTPClientTests {
    private func client(_ server: FakeSMTPServer, password: String = "secret", tls: Bool = true) -> SMTPClient {
        SMTPClient(
            config: SMTPClient.Config(
                host: "smtp.example.com", port: 465, tls: tls, username: "me@example.com", password: password,
                fromAddress: "me@example.com"),
            timeout: 5,
            makeTransport: { _ in ScriptedSMTPTransport(server: server) })
    }

    private func message(body: String = "Thanks!\n.hidden line\nBye") -> EmailOutgoingMessage {
        EmailOutgoingMessage(
            from: "me@example.com", fromName: "Me", to: ["ann@example.com"], cc: ["bob@example.com"],
            subject: "Re: Plans", body: body, inReplyTo: "m1@example.com", references: ["root@example.com", "m1@example.com"],
            messageId: "new@example.com", date: Date(timeIntervalSince1970: 1_791_795_600))
    }

    @Test func sendsWithAuthPlainAndDotStuffing() async throws {
        let server = FakeSMTPServer()
        try await client(server).send(message())
        #expect(server.commands.first == "EHLO osaurus.local")
        #expect(server.commands.contains { $0.hasPrefix("AUTH PLAIN ") })
        #expect(server.commands.contains("MAIL FROM:<me@example.com>"))
        #expect(server.commands.contains("RCPT TO:<ann@example.com>"))
        #expect(server.commands.contains("RCPT TO:<bob@example.com>"))
        #expect(server.commands.last == "QUIT")
        let data = try #require(server.data.first)
        #expect(data.contains("In-Reply-To: <m1@example.com>"))
        #expect(data.contains("References: <root@example.com> <m1@example.com>"))
        #expect(data.contains("Subject: Re: Plans"))
        #expect(data.contains("\r\n..hidden line\r\n"))
    }

    @Test func fallsBackToAuthLogin() async throws {
        let server = FakeSMTPServer()
        server.capabilities = ["AUTH LOGIN"]
        try await client(server).verifySignIn()
        #expect(server.commands.contains("AUTH LOGIN"))
        #expect(!server.commands.contains { $0.hasPrefix("MAIL FROM") })
    }

    @Test func refusalsAreTyped() async throws {
        let server = FakeSMTPServer()
        await #expect(throws: SMTPError.authRefused("535 5.7.8 bad credentials")) {
            try await client(server, password: "wrong").verifySignIn()
        }

        let startTLS = FakeSMTPServer()
        startTLS.capabilities = ["STARTTLS", "8BITMIME"]
        await #expect(throws: SMTPError.startTLSRequired) { try await client(startTLS).verifySignIn() }

        let rejecting = FakeSMTPServer()
        rejecting.rejectRecipients = ["bob@example.com"]
        await #expect(throws: SMTPError.rejected("550 5.1.1 no such user")) { try await client(rejecting).send(message()) }
        #expect(rejecting.data.isEmpty)
    }

    @Test func plainConnectionsOnlyToThisMac() async throws {
        let server = FakeSMTPServer()
        await #expect(throws: SMTPError.self) { try await client(server, tls: false).verifySignIn() }
        #expect(server.commands.isEmpty)
    }

    @Test func multiLineRepliesParseAcrossChunks() throws {
        var parser = SMTPReplyParser()
        for chunk in ScriptedIMAPTransport.chunks("250-smtp.example.com\r\n250-AUTH PLAIN\r\n250 SIZE 100\r\n", size: 4) {
            parser.append(chunk)
        }
        let reply = try #require(try parser.next())
        #expect(reply.code == 250)
        #expect(reply.lines == ["smtp.example.com", "AUTH PLAIN", "SIZE 100"])
        #expect(try parser.next() == nil)
    }
}

struct EmailMessageBuilderTests {
    private func original(messageId: String = "m2@example.com", threadId: String? = "root@example.com") -> EmailMessage {
        EmailMessage(
            messageId: messageId, threadId: threadId, subject: "Plans", from: "ann@example.com", fromName: "Ann",
            to: ["me@example.com", "carol@example.com"], cc: ["dan@example.com"], date: nil, mailbox: "INBOX",
            snippet: "", body: "hi", attachments: [], isRead: false, sizeBytes: nil)
    }

    @Test func replyThreadsUnderTheOriginal() {
        let reply = EmailMessageBuilder.reply(to: original(), from: "Me@Example.com", body: "ok")
        #expect(reply.to == ["ann@example.com"])
        #expect(reply.cc.isEmpty)
        #expect(reply.subject == "Re: Plans")
        #expect(reply.inReplyTo == "m2@example.com")
        #expect(reply.references == ["root@example.com", "m2@example.com"])
        #expect(reply.messageId.hasSuffix("@example.com"))

        let all = EmailMessageBuilder.reply(to: original(), from: "me@example.com", body: "ok", replyAll: true)
        #expect(all.cc == ["carol@example.com", "dan@example.com"])
    }

    @Test func standInIdsAreNotSentAsMessageIds() {
        let reply = EmailMessageBuilder.reply(
            to: original(messageId: "imap:7:12", threadId: "imap:7:12"), from: "me@example.com", body: "ok")
        #expect(reply.inReplyTo == nil)
        #expect(reply.references.isEmpty)
    }

    @Test func subjectsAreNotDoublePrefixed() {
        #expect(EmailMessageBuilder.replySubject("RE: Plans") == "RE: Plans")
        #expect(EmailMessageBuilder.replySubject("") == "Re:")
    }

    @Test func nonASCIIIsEncoded() {
        var message = EmailMessageBuilder.reply(to: original(), from: "me@example.com", body: "Grüße")
        message.subject = "Re: Grüße"
        let rendered = String(decoding: EmailMessageBuilder.render(message), as: UTF8.self)
        #expect(rendered.contains("Subject: =?UTF-8?B?"))
        #expect(rendered.contains("Content-Transfer-Encoding: base64"))
        #expect(!rendered.contains("\n\n"))
    }
}
