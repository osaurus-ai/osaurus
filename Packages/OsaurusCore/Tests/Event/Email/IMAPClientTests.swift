//
//  IMAPClientTests.swift
//  osaurusTests
//
//  The IMAP client and fetcher against a scripted server: response
//  framing with literals split across reads, LOGIN quoting and literals,
//  read-only EXAMINE, UID search/fetch, the `{uidvalidity, last_uid}`
//  cursor, and the typed failures.
//

import Foundation
import Network
import Testing

@testable import OsaurusCore

/// A tiny IMAP server: enough of RFC 3501 to answer the client's commands.
final class FakeIMAPServer: @unchecked Sendable {
    struct Message {
        var uid: UInt32
        var seen = false
        var raw: String
    }

    private let lock = NSLock()
    var capabilities = "IMAP4rev1 AUTH=PLAIN"
    var password = "secret"
    var uidValidity: UInt32 = 7
    var messages: [Message] = []
    var mailboxes = ["INBOX", "Archive", "Re&AOc-us"]
    /// Every command's atoms and strings, tag stripped (lists left out).
    private(set) var commands: [String] = []
    /// Every command as sent.
    private(set) var rawCommands: [String] = []
    private var pending = Data()

    func reply(to data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        let text = String(decoding: pending, as: UTF8.self)
        if text.hasSuffix("}\r\n") { return ["+ go ahead\r\n"] }
        guard text.hasSuffix("\r\n") else { return [] }
        pending = Data()
        guard let response = try? IMAPResponseParser.parse(Array(text.utf8)) else { return [] }
        let tag = response.tag
        let words = response.tokens.compactMap(\.text)
        commands.append(words.joined(separator: " "))
        rawCommands.append(text)
        let verb = words.first?.uppercased() ?? ""
        switch verb {
        case "CAPABILITY":
            return ["* CAPABILITY \(capabilities)\r\n", "\(tag) OK done\r\n"]
        case "LOGIN":
            guard words.count >= 3, words[2] == password else { return ["\(tag) NO [AUTHENTICATIONFAILED] Invalid credentials\r\n"] }
            return ["\(tag) OK logged in\r\n"]
        case "LIST":
            return mailboxes.map { name in
                name == "Archive"
                    ? "* LIST (\\HasNoChildren) \"/\" {\(name.utf8.count)}\r\n\(name)\r\n"
                    : "* LIST (\\HasNoChildren) \"/\" \"\(name)\"\r\n"
            } + ["* LIST (\\Noselect \\HasChildren) \"/\" \"[Gmail]\"\r\n", "\(tag) OK listed\r\n"]
        case "EXAMINE":
            let name = words.count > 1 ? words[1] : ""
            guard mailboxes.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
                return ["\(tag) NO Mailbox doesn't exist\r\n"]
            }
            let next = (messages.map(\.uid).max() ?? 0) + 1
            return [
                "* \(messages.count) EXISTS\r\n", "* OK [UIDVALIDITY \(uidValidity)] UIDs valid\r\n",
                "* OK [UIDNEXT \(next)] Predicted next UID\r\n", "\(tag) OK [READ-ONLY] EXAMINE completed\r\n",
            ]
        case "UID":
            return uidCommand(tag: tag, words: Array(words.dropFirst()))
        case "LOGOUT":
            return ["* BYE logging out\r\n", "\(tag) OK bye\r\n"]
        default:
            return ["\(tag) BAD unknown\r\n"]
        }
    }

    private func uidCommand(tag: String, words: [String]) -> [String] {
        guard let sub = words.first?.uppercased() else { return ["\(tag) BAD\r\n"] }
        if sub == "SEARCH" {
            let unseen = words.contains { $0.uppercased() == "UNSEEN" }
            var pool = messages.filter { !unseen || !$0.seen }
            if let range = words.last, range.hasSuffix(":*"), let low = UInt32(range.dropLast(2)) {
                let above = pool.filter { $0.uid >= low }
                // RFC 3501: `n:*` includes the highest UID even below n.
                pool = above.isEmpty ? Array(pool.max { $0.uid < $1.uid }.map { [$0] } ?? []) : above
            }
            return ["* SEARCH" + pool.map { " \($0.uid)" }.joined() + "\r\n", "\(tag) OK search done\r\n"]
        }
        guard sub == "FETCH", words.count > 1 else { return ["\(tag) BAD\r\n"] }
        let wanted = Set(words[1].split(separator: ",").compactMap { UInt32($0) })
        var out: [String] = []
        for (index, message) in messages.enumerated() where wanted.contains(message.uid) {
            let raw = message.raw.replacingOccurrences(of: "\n", with: "\r\n")
            let flags = message.seen ? "(\\Seen)" : "()"
            out.append(
                "* \(index + 1) FETCH (UID \(message.uid) FLAGS \(flags) INTERNALDATE \"12-Oct-2026 09:00:00 +0000\" RFC822.SIZE \(raw.utf8.count) BODY[]<0> {\(raw.utf8.count)}\r\n\(raw))\r\n"
            )
        }
        return out + ["\(tag) OK fetch done\r\n"]
    }
}

final class ScriptedIMAPTransport: IMAPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let server: FakeIMAPServer
    private var inbox: [Data] = []
    private var waiting: CheckedContinuation<Data, Error>?
    private var closed = false
    let chunkSize: Int

    init(server: FakeIMAPServer, greeting: String = "* OK [CAPABILITY IMAP4rev1] ready\r\n", chunkSize: Int = 7) {
        self.server = server
        self.chunkSize = chunkSize
        inbox = Self.chunks(greeting, size: chunkSize)
    }

    static func chunks(_ text: String, size: Int) -> [Data] {
        let bytes = Array(text.utf8)
        return stride(from: 0, to: bytes.count, by: size).map { Data(bytes[$0..<min($0 + size, bytes.count)]) }
    }

    func open() async throws {}

    func send(_ data: Data) async throws {
        for reply in server.reply(to: data) {
            for chunk in Self.chunks(reply, size: chunkSize) { deliver(chunk) }
        }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !inbox.isEmpty {
                let next = inbox.removeFirst()
                lock.unlock()
                continuation.resume(returning: next)
            } else if closed {
                lock.unlock()
                continuation.resume(returning: Data())
            } else {
                waiting = continuation
                lock.unlock()
            }
        }
    }

    func deliver(_ data: Data) {
        lock.lock()
        if let waiting {
            self.waiting = nil
            lock.unlock()
            waiting.resume(returning: data)
        } else {
            inbox.append(data)
            lock.unlock()
        }
    }

    func close() {
        lock.lock()
        closed = true
        let waiting = self.waiting
        self.waiting = nil
        lock.unlock()
        waiting?.resume(returning: Data())
    }
}

struct IMAPResponseParserTests {
    @Test func literalsSpanReadsAndListsNest() throws {
        var parser = IMAPResponseParser()
        let body = "Subject: x\r\n\r\nHi)\r\n"
        let wire = "* 1 FETCH (UID 9 FLAGS (\\Seen \\Flagged) BODY[]<0> {\(body.utf8.count)}\r\n\(body))\r\nA1 OK done\r\n"
        var responses: [IMAPResponse] = []
        for chunk in ScriptedIMAPTransport.chunks(wire, size: 5) {
            parser.append(chunk)
            while let response = try parser.next() { responses.append(response) }
        }
        #expect(responses.count == 2)
        let fetch = responses[0]
        #expect(fetch.keyword == "FETCH")
        #expect(fetch.number == 1)
        let items = fetch.tokens.last?.items ?? []
        #expect(items.first == .atom("UID"))
        #expect(items[3].items == [.atom("\\Seen"), .atom("\\Flagged")])
        #expect(items[4] == .atom("BODY[]<0>"))
        #expect(items[5] == .string(Data(body.utf8)))
        #expect(responses[1].tag == "A1")
        #expect(responses[1].keyword == "OK")
    }

    @Test func statusCodesAndQuotedEscapes() throws {
        let status = try IMAPResponseParser.parse(Array("* OK [UIDVALIDITY 3857529045] UIDs valid\r\n".utf8))
        #expect(status.code("UIDVALIDITY") == "3857529045")
        #expect(status.message == "UIDs valid")
        let list = try IMAPResponseParser.parse(Array(#"* LIST () "/" "a \"b\" \\c""#.utf8) + [0x0D, 0x0A])
        #expect(list.tokens.last?.text == #"a "b" \c"#)
        let nilValue = try IMAPResponseParser.parse(Array("* LIST () NIL INBOX\r\n".utf8))
        #expect(nilValue.tokens[2] == .nilValue)
    }

    @Test func anOversizedLiteralIsRefused() {
        var parser = IMAPResponseParser()
        parser.append(Data("* 1 FETCH (BODY[] {\(IMAPResponseParser.maxLiteral + 1)}\r\n".utf8))
        #expect(throws: EmailFetchError.self) { _ = try parser.next() }
    }
}

struct IMAPClientTests {
    private func client(_ server: FakeIMAPServer) -> IMAPClient {
        IMAPClient(transport: ScriptedIMAPTransport(server: server), timeout: 5)
    }

    @Test func sessionUsesReadOnlyExamineAndPeek() async throws {
        let server = FakeIMAPServer()
        server.messages = [
            .init(uid: 10, seen: true, raw: "Subject: one\n\nfirst"),
            .init(uid: 12, raw: "Subject: two\n\nsecond"),
        ]
        let client = client(server)
        #expect(try await client.connect() == false)
        try await client.login(username: "me@example.com", password: "secret")
        let status = try await client.examine("INBOX")
        #expect(status == IMAPMailboxStatus(uidValidity: 7, uidNext: 13, exists: 2))
        #expect(try await client.searchUIDs(after: 10, unseenOnly: false) == [12])
        // `13:*` matches the highest UID (12); the client drops it.
        #expect(try await client.searchUIDs(after: 12, unseenOnly: false) == [])
        let fetched = try await client.fetch(uids: [10, 12], maxBytes: 4096)
        #expect(fetched.map(\.uid) == [10, 12])
        #expect(fetched.map(\.isRead) == [true, false])
        #expect(String(decoding: fetched[1].raw, as: UTF8.self) == "Subject: two\r\n\r\nsecond")
        #expect(fetched[0].internalDate == Date(timeIntervalSince1970: 1_791_795_600))
        await client.logout()

        #expect(server.commands.contains("EXAMINE INBOX"))
        #expect(!server.commands.contains { $0.hasPrefix("SELECT") })
        #expect(server.rawCommands.contains { $0.contains("BODY.PEEK[]<0.4096>") })
    }

    @Test func nonASCIIPasswordsGoAsALiteral() async throws {
        let server = FakeIMAPServer()
        server.password = "pässwörd"
        let transport = ScriptedIMAPTransport(server: server)
        let client = IMAPClient(transport: transport, timeout: 5)
        try await client.connect()
        try await client.login(username: "me", password: "pässwörd")
        #expect(server.commands.last == "LOGIN me pässwörd")
    }

    @Test func refusalsAreTyped() async throws {
        let server = FakeIMAPServer()
        let client = client(server)
        try await client.connect()
        await #expect(throws: EmailFetchError.loginRefused("Invalid credentials")) {
            try await client.login(username: "me", password: "wrong")
        }

        let strict = FakeIMAPServer()
        strict.capabilities = "IMAP4rev1 STARTTLS LOGINDISABLED"
        let other = self.client(strict)
        try await other.connect()
        await #expect(throws: EmailFetchError.loginDisabled) {
            try await other.login(username: "me", password: "secret")
        }

        let third = self.client(FakeIMAPServer())
        try await third.connect()
        try await third.login(username: "me", password: "secret")
        await #expect(throws: EmailFetchError.mailboxNotFound("Nope")) { _ = try await third.examine("Nope") }
    }

    @Test func listSkipsNoselectAndReadsLiteralNames() async throws {
        let server = FakeIMAPServer()
        let client = client(server)
        try await client.connect()
        try await client.login(username: "me", password: "secret")
        #expect(try await client.list() == ["INBOX", "Archive", "Re&AOc-us"])
    }

    @Test func aSilentServerTimesOut() async throws {
        final class Silent: IMAPTransport, @unchecked Sendable {
            func open() async throws {}
            func send(_ data: Data) async throws {}
            func receive() async throws -> Data {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return Data()
            }
            func close() {}
        }
        let client = IMAPClient(transport: Silent(), timeout: 0.2)
        await #expect(throws: EmailFetchError.timedOut) { try await client.connect() }
    }
}

/// `FakeIMAPServer` behind a real TCP listener on 127.0.0.1.
final class LoopbackIMAPServer: @unchecked Sendable {
    private let listener: NWListener
    private let server: FakeIMAPServer
    private let queue = DispatchQueue(label: "test.imap.loopback")
    /// Touched only on `queue`.
    private var connections: [NWConnection] = []
    private var listening = false
    private(set) var port: UInt16 = 0

    private init(server: FakeIMAPServer) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.server = server
    }

    static func start(_ server: FakeIMAPServer) async throws -> LoopbackIMAPServer {
        let loopback = try LoopbackIMAPServer(server: server)
        try await loopback.listen()
        return loopback
    }

    private func listen() async throws {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.listening else { return }
                switch state {
                case .ready:
                    self.listening = true
                    self.port = self.listener.port?.rawValue ?? 0
                    continuation.resume()
                case .failed(let error):
                    self.listening = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        connection.send(content: Data("* OK [CAPABILITY IMAP4rev1] ready\r\n".utf8), completion: .idempotent)
        read(connection)
    }

    private func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for line in self.server.reply(to: data) {
                    connection.send(content: Data(line.utf8), completion: .idempotent)
                }
            }
            if done || error != nil {
                connection.cancel()
            } else {
                self.read(connection)
            }
        }
    }

    func stop() {
        queue.sync {
            connections.forEach { $0.cancel() }
            connections = []
        }
        listener.cancel()
    }
}

struct IMAPMailboxFetcherTests {
    private func fetcher(_ server: FakeIMAPServer, security: IMAPSecurity = .tls, host: String = "imap.example.com")
        -> IMAPMailboxFetcher
    {
        IMAPMailboxFetcher(
            connectionId: "c1", config: IMAPConnectionConfig(host: host, security: security, username: "me"),
            password: { "secret" }, makeTransport: { _ in ScriptedIMAPTransport(server: server) })
    }

    private static func raw(_ id: String, _ subject: String) -> String {
        "Message-ID: <\(id)>\nFrom: Ann <ann@example.com>\nSubject: \(subject)\n\nBody of \(subject)"
    }

    @Test func firstFetchBaselinesThenReturnsOnlyNewMail() async throws {
        let server = FakeIMAPServer()
        server.messages = [.init(uid: 3, raw: Self.raw("old@x", "Old"))]
        let fetcher = fetcher(server)
        let options = MailboxFetchOptions()

        let first = try await fetcher.fetch(mailbox: "INBOX", cursor: nil, options: options)
        #expect(first.messages.isEmpty)
        #expect(IMAPMailboxFetcher.decode(first.cursor) == .init(uidValidity: 7, lastUID: 3))

        server.messages += [.init(uid: 4, raw: Self.raw("a@x", "A")), .init(uid: 6, seen: true, raw: Self.raw("b@x", "B"))]
        let second = try await fetcher.fetch(mailbox: "INBOX", cursor: first.cursor, options: options)
        #expect(second.messages.map(\.messageId) == ["a@x", "b@x"])
        #expect(second.messages.map(\.isRead) == [false, true])
        #expect(second.messages[0].body == "Body of A")
        #expect(second.messages[0].fromName == "Ann")
        #expect(IMAPMailboxFetcher.decode(second.cursor) == .init(uidValidity: 7, lastUID: 6))
        #expect(second.position == "UID 6")

        let third = try await fetcher.fetch(mailbox: "INBOX", cursor: second.cursor, options: options)
        #expect(third.messages.isEmpty)
        #expect(IMAPMailboxFetcher.decode(third.cursor)?.lastUID == 6)
    }

    @Test func unreadOnlyAndTheBatchLimit() async throws {
        let server = FakeIMAPServer()
        server.messages = (1...5).map { .init(uid: UInt32($0), seen: $0 == 2, raw: Self.raw("m\($0)@x", "M\($0)")) }
        let cursor = IMAPMailboxFetcher.encode(.init(uidValidity: 7, lastUID: 0))
        let result = try await fetcher(server).fetch(
            mailbox: "INBOX", cursor: cursor, options: MailboxFetchOptions(unreadOnly: true, includeBody: false, limit: 2))
        #expect(result.messages.map(\.messageId) == ["m1@x", "m3@x"])
        #expect(result.messages.allSatisfy { $0.body == nil })
        #expect(IMAPMailboxFetcher.decode(result.cursor)?.lastUID == 3)
        #expect(server.rawCommands.contains { $0.contains("BODY.PEEK[]<0.\(IMAPMailboxFetcher.headerBytes)>") })
    }

    @Test func aNewUIDValidityRebaselines() async throws {
        let server = FakeIMAPServer()
        server.uidValidity = 99
        server.messages = [.init(uid: 1, raw: Self.raw("x@x", "X")), .init(uid: 2, raw: Self.raw("y@x", "Y"))]
        let stale = IMAPMailboxFetcher.encode(.init(uidValidity: 7, lastUID: 500))
        let result = try await fetcher(server).fetch(mailbox: "INBOX", cursor: stale, options: MailboxFetchOptions())
        #expect(result.messages.isEmpty)
        #expect(IMAPMailboxFetcher.decode(result.cursor) == .init(uidValidity: 99, lastUID: 2))
    }

    @Test func plainIMAPOnlyToThisMacAndPasswordRequired() async throws {
        let server = FakeIMAPServer()
        await #expect(throws: EmailFetchError.insecureConnection(L("Without TLS, only a server on this Mac can be used."))) {
            _ = try await fetcher(server, security: .none).mailboxes()
        }
        #expect(try await fetcher(server, security: .none, host: "127.0.0.1").mailboxes().first == "INBOX")

        let noPassword = IMAPMailboxFetcher(
            connectionId: "c1", config: IMAPConnectionConfig(host: "imap.example.com", username: "me"),
            password: { nil }, makeTransport: { _ in ScriptedIMAPTransport(server: server) })
        await #expect(throws: EmailFetchError.passwordMissing) { _ = try await noPassword.mailboxes() }
    }

    @Test func realSocketsToALoopbackServer() async throws {
        let server = FakeIMAPServer()
        server.messages = [.init(uid: 1, raw: Self.raw("old@x", "Old"))]
        let loopback = try await LoopbackIMAPServer.start(server)
        defer { loopback.stop() }
        var fetcher = IMAPMailboxFetcher(
            connectionId: "c1",
            config: IMAPConnectionConfig(host: "127.0.0.1", port: Int(loopback.port), security: .none, username: "me"))
        fetcher.password = { "secret" }

        #expect(try await fetcher.mailboxes() == ["INBOX", "Archive", "Re&AOc-us"])
        let first = try await fetcher.fetch(mailbox: "INBOX", cursor: nil, options: MailboxFetchOptions())
        #expect(first.messages.isEmpty)
        let body = String(repeating: "line of text\n", count: 4_000)
        server.messages.append(.init(uid: 2, raw: "Message-ID: <big@x>\nSubject: Big\n\n" + body))
        let second = try await fetcher.fetch(mailbox: "INBOX", cursor: first.cursor, options: MailboxFetchOptions())
        #expect(second.messages.map(\.messageId) == ["big@x"])
        #expect(second.messages.first?.body?.count ?? 0 > 40_000)
        #expect(server.commands.contains { $0.hasPrefix("LOGOUT") })

        server.password = "changed"
        await #expect(throws: EmailFetchError.self) { _ = try await fetcher.mailboxes() }
    }

    @Test func aClosedPortFailsAsAConnectionError() async throws {
        let loopback = try await LoopbackIMAPServer.start(FakeIMAPServer())
        let port = loopback.port
        loopback.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        var fetcher = IMAPMailboxFetcher(
            connectionId: "c1",
            config: IMAPConnectionConfig(host: "127.0.0.1", port: Int(port), security: .none, username: "me"))
        fetcher.password = { "secret" }
        do {
            _ = try await fetcher.mailboxes()
            Issue.record("nothing listens on the port")
        } catch let error as EmailFetchError {
            guard case .connection = error else {
                Issue.record("expected a connection error, got \(error)")
                return
            }
        }
    }

    @Test func microsoftServersPointToTheMailApp() async throws {
        #expect(IMAPConnectionConfig(host: "Outlook.Office365.com").passwordSignInNote != nil)
        #expect(IMAPConnectionConfig(host: "imap-mail.outlook.com").passwordSignInNote != nil)
        #expect(IMAPConnectionConfig(host: "imap.gmail.com").passwordSignInNote == nil)

        let server = FakeIMAPServer()
        server.password = "something else"
        let refused = try await #require(throws: EmailFetchError.self) {
            _ = try await fetcher(server, host: "outlook.office365.com").mailboxes()
        }
        guard case .loginRefused(let detail) = refused else {
            Issue.record("expected loginRefused, got \(refused)")
            return
        }
        #expect(detail.contains("Mail app"))
    }

    @Test func newestAndMailboxNames() async throws {
        let server = FakeIMAPServer()
        server.messages = [.init(uid: 8, raw: Self.raw("n@x", "Newest"))]
        let fetcher = fetcher(server)
        #expect(try await fetcher.newest(mailbox: "inbox", options: MailboxFetchOptions())?.subject == "Newest")
        #expect(try await fetcher.mailboxes() == ["INBOX", "Archive", "Re&AOc-us"])
        #expect(IMAPMailboxFetcher.wireName("Reçus") == "Re&AOc-us")
        #expect(IMAPMailboxFetcher.wireName("Re&AOc-us") == "Re&AOc-us")
        #expect(IMAPMailboxFetcher.wireName("inbox") == "INBOX")
    }
}
