//
//  SMTPClient.swift
//  osaurus
//
//  Sends Email channel replies from IMAP accounts (RFC 5321): EHLO, AUTH
//  PLAIN or LOGIN, MAIL FROM, RCPT TO, DATA, QUIT. One connection per
//  message.
//
//  TLS from the first byte only (port 465). STARTTLS on 587 is not
//  offered, and plain connections are allowed only to this Mac
//  (`IMAPConnectionConfig.securityProblem`). Sent mail is not copied to
//  the account's Sent mailbox.
//

import Foundation

enum SMTPError: LocalizedError, Equatable {
    case passwordMissing
    case insecureConnection(String)
    case noFromAddress
    case noRecipients
    case startTLSRequired
    case authRefused(String)
    case rejected(String)
    case server(String)
    case connection(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .passwordMissing: L("No password is saved for this account. Edit the account and enter it again.")
        case .insecureConnection(let reason): reason
        case .noFromAddress: L("The account has no From address for replies.")
        case .noRecipients: L("The reply has no recipient.")
        case .startTLSRequired:
            L("The reply server only allows sign-in after STARTTLS, which Osaurus doesn't support. Use TLS on port 465.")
        case .authRefused(let detail): L("The reply server refused the sign-in: \(detail)")
        case .rejected(let detail): L("The reply server didn't accept the message: \(detail)")
        case .server(let detail): L("The reply server answered: \(detail)")
        case .connection(let detail): L("Could not reach the reply server: \(detail)")
        case .timedOut: L("The reply server stopped answering.")
        }
    }

    /// The account itself is wrong; retrying with the same details fails the same way.
    var isAccountProblem: Bool {
        switch self {
        case .passwordMissing, .insecureConnection, .noFromAddress, .startTLSRequired, .authRefused: true
        default: false
        }
    }
}

struct SMTPReply: Equatable, Sendable {
    var code: Int
    var lines: [String]

    var text: String { lines.joined(separator: " ") }
    var isPositive: Bool { (200..<400).contains(code) }
}

/// Cuts received bytes into complete (possibly multi-line) replies.
struct SMTPReplyParser {
    private(set) var buffer: [UInt8] = []
    private var pendingLines: [String] = []

    mutating func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    mutating func next() throws -> SMTPReply? {
        while let lf = buffer.firstIndex(of: 0x0A) {
            var line = String(decoding: buffer[0..<lf], as: UTF8.self)
            buffer.removeFirst(lf + 1)
            if line.hasSuffix("\r") { line.removeLast() }
            guard line.count >= 3, let code = Int(line.prefix(3)) else {
                throw SMTPError.server(L("The server sent something Osaurus couldn't read."))
            }
            let rest = line.dropFirst(3)
            let more = rest.first == "-"
            pendingLines.append(String(rest.dropFirst()).trimmingCharacters(in: .whitespaces))
            if !more {
                let reply = SMTPReply(code: code, lines: pendingLines)
                pendingLines = []
                return reply
            }
        }
        return nil
    }
}

struct SMTPClient: Sendable {
    struct Config: Equatable, Sendable {
        var host: String
        var port: Int
        var tls: Bool
        var username: String
        var password: String
        var fromAddress: String?
        /// The EHLO name.
        var clientName = "osaurus.local"

        init(
            host: String, port: Int, tls: Bool, username: String, password: String, fromAddress: String?,
            clientName: String = "osaurus.local"
        ) {
            self.host = host
            self.port = port
            self.tls = tls
            self.username = username
            self.password = password
            self.fromAddress = fromAddress
            self.clientName = clientName
        }

        init(imap: IMAPConnectionConfig, password: String) {
            self.init(
                host: imap.smtpHost, port: imap.smtpPort, tls: imap.smtpSecurity == .tls, username: imap.username,
                password: password, fromAddress: imap.effectiveFromAddress)
        }
    }

    let config: Config
    var timeout: TimeInterval = 30
    var makeTransport: @Sendable (Config) -> any IMAPTransport = {
        NetworkIMAPTransport(host: $0.host, port: $0.port, tls: $0.tls)
    }

    init(config: Config) {
        self.config = config
    }

    init(config: Config, timeout: TimeInterval = 30, makeTransport: @escaping @Sendable (Config) -> any IMAPTransport) {
        self.config = config
        self.timeout = timeout
        self.makeTransport = makeTransport
    }

    /// Connects and signs in, without sending anything.
    func verifySignIn() async throws {
        try await session { _ in }
    }

    /// Sends one rendered message to every recipient.
    func send(_ message: EmailOutgoingMessage) async throws {
        let recipients = message.recipients
        guard !recipients.isEmpty else { throw SMTPError.noRecipients }
        let data = EmailMessageBuilder.render(message)
        try await session { smtp in
            try await smtp.expect([250], "MAIL FROM:<\(message.from)>", failure: SMTPError.rejected)
            for recipient in recipients {
                try await smtp.expect([250, 251], "RCPT TO:<\(recipient)>", failure: SMTPError.rejected)
            }
            try await smtp.expect([354], "DATA", failure: SMTPError.rejected)
            try await smtp.sendData(EmailMessageBuilder.dotStuffed(data))
        }
    }

    private func session(_ body: (SMTPSession) async throws -> Void) async throws {
        if !config.tls, !IMAPConnectionConfig.isLoopback(config.host) {
            throw SMTPError.insecureConnection(L("Without TLS, only an SMTP server on this Mac can be used."))
        }
        let smtp = SMTPSession(transport: makeTransport(config), timeout: timeout)
        do {
            try await smtp.connect()
            let capabilities = try await smtp.ehlo(config.clientName)
            try await smtp.authenticate(
                username: config.username, password: config.password, capabilities: capabilities, tls: config.tls)
            try await body(smtp)
            await smtp.quit()
        } catch {
            smtp.close()
            throw Self.mapped(error)
        }
    }

    private static func mapped(_ error: Error) -> Error {
        guard let fetch = error as? EmailFetchError else { return error }
        switch fetch {
        case .connection(let detail): return SMTPError.connection(detail)
        case .timedOut: return SMTPError.timedOut
        default: return SMTPError.server(fetch.localizedDescription)
        }
    }
}

/// One SMTP connection.
actor SMTPSession {
    private let transport: any IMAPTransport
    private var parser = SMTPReplyParser()
    let timeout: TimeInterval

    init(transport: any IMAPTransport, timeout: TimeInterval) {
        self.transport = transport
        self.timeout = timeout
    }

    func connect() async throws {
        let transport = transport
        try await withTimeout { try await transport.open() }
        let greeting = try await readReply()
        guard greeting.code == 220 else { throw SMTPError.server("\(greeting.code) \(greeting.text)") }
    }

    /// Capability keywords, uppercased (`AUTH PLAIN LOGIN`, `SIZE 35882577`).
    func ehlo(_ name: String) async throws -> [String] {
        let reply = try await command("EHLO \(name)")
        guard reply.code == 250 else { throw SMTPError.server("\(reply.code) \(reply.text)") }
        return reply.lines.dropFirst().map { $0.uppercased() }
    }

    func authenticate(username: String, password: String, capabilities: [String], tls: Bool) async throws {
        let mechanisms = Set(
            capabilities.filter { $0.hasPrefix("AUTH ") || $0.hasPrefix("AUTH=") }
                .flatMap { $0.dropFirst(5).split(separator: " ").map(String.init) })
        if mechanisms.isEmpty {
            if capabilities.contains("STARTTLS") { throw SMTPError.startTLSRequired }
            // A local relay that accepts mail without signing in.
            if !tls { return }
            throw SMTPError.authRefused(L("the server offers no sign-in method Osaurus supports."))
        }
        guard !password.isEmpty else { throw SMTPError.passwordMissing }
        if mechanisms.contains("PLAIN") {
            let token = Data("\u{0}\(username)\u{0}\(password)".utf8).base64EncodedString()
            try await expect([235], "AUTH PLAIN \(token)", failure: SMTPError.authRefused)
        } else if mechanisms.contains("LOGIN") {
            try await expect([334], "AUTH LOGIN", failure: SMTPError.authRefused)
            try await expect([334], Data(username.utf8).base64EncodedString(), failure: SMTPError.authRefused)
            try await expect([235], Data(password.utf8).base64EncodedString(), failure: SMTPError.authRefused)
        } else {
            throw SMTPError.authRefused(L("the server offers no sign-in method Osaurus supports."))
        }
    }

    func expect(_ codes: Set<Int>, _ line: String, failure: @Sendable (String) -> SMTPError) async throws {
        let reply = try await command(line)
        guard codes.contains(reply.code) else { throw failure("\(reply.code) \(reply.text)") }
    }

    /// The message body, already dot-stuffed, then the terminating `.`.
    func sendData(_ data: Data) async throws {
        var payload = data
        if !payload.isEmpty, !payload.ends(with: Data("\r\n".utf8)) { payload.append(Data("\r\n".utf8)) }
        payload.append(Data(".\r\n".utf8))
        try await send(payload)
        let reply = try await readReply()
        guard reply.code == 250 else { throw SMTPError.rejected("\(reply.code) \(reply.text)") }
    }

    func quit() async {
        _ = try? await command("QUIT")
        transport.close()
    }

    nonisolated func close() {
        transport.close()
    }

    private func command(_ line: String) async throws -> SMTPReply {
        try await send(Data((line + "\r\n").utf8))
        return try await readReply()
    }

    private func send(_ data: Data) async throws {
        let transport = transport
        try await withTimeout { try await transport.send(data) }
    }

    private func readReply() async throws -> SMTPReply {
        let transport = transport
        while true {
            if let reply = try parser.next() { return reply }
            let data = try await withTimeout { try await transport.receive() }
            guard !data.isEmpty else { throw SMTPError.connection(L("The server closed the connection.")) }
            parser.append(data)
        }
    }

    private func withTimeout<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let limit = timeout
        let transport = transport
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                transport.close()
                throw SMTPError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw SMTPError.timedOut }
            return first
        }
    }
}

extension Data {
    fileprivate func ends(with suffix: Data) -> Bool {
        count >= suffix.count && self[(endIndex - suffix.count)...] == suffix
    }
}
