//
//  IMAPMailboxFetcher.swift
//  osaurus
//
//  Reads an IMAP mailbox with the `{uidvalidity, last_uid}` cursor RFC 3501
//  is built for: UIDs only grow within one UIDVALIDITY, so "after last_uid"
//  is exact. When the server changes UIDVALIDITY (a rebuilt mailbox) the
//  old UIDs mean nothing; the cursor restarts at the newest message and
//  the durable dedupe keys (Message-ID) keep anything already handled
//  from firing again.
//

import Foundation

struct IMAPMailboxFetcher: MailboxFetching {
    let connectionId: String
    let config: IMAPConnectionConfig
    var password: @Sendable () -> String? = { nil }
    var makeTransport: @Sendable (IMAPConnectionConfig) -> any IMAPTransport = {
        NetworkIMAPTransport(host: $0.host, port: $0.port, tls: $0.security == .tls)
    }

    /// Bytes read per message: enough for headers and a long body; the
    /// rest of a large message (attachments) stays on the server.
    static let bodyBytes = 256 * 1024
    static let headerBytes = 16 * 1024

    init(connectionId: String, config: IMAPConnectionConfig) {
        self.connectionId = connectionId
        self.config = config
        self.password = { SourceCredentialVault.read(connectionId: connectionId, field: SourceCredentialVault.passwordField) }
    }

    init(
        connectionId: String, config: IMAPConnectionConfig, password: @escaping @Sendable () -> String?,
        makeTransport: @escaping @Sendable (IMAPConnectionConfig) -> any IMAPTransport
    ) {
        self.connectionId = connectionId
        self.config = config
        self.password = password
        self.makeTransport = makeTransport
    }

    struct Cursor: Equatable {
        var uidValidity: UInt32
        var lastUID: UInt32
    }

    func mailboxes() async throws -> [String] {
        try await session { client in
            let names = try await client.list()
            let inbox = names.filter { $0.uppercased() == EmailSourceConfig.inbox }
            return (inbox.isEmpty ? [EmailSourceConfig.inbox] : inbox) + names.filter { $0.uppercased() != EmailSourceConfig.inbox }.sorted()
        }
    }

    func fetch(mailbox: String, cursor: JSONValue?, options: MailboxFetchOptions) async throws -> MailboxFetchResult {
        try await session { client in
            let status = try await client.examine(Self.wireName(mailbox))
            guard let state = cursor.flatMap(Self.decode), state.uidValidity == status.uidValidity else {
                let last = try await Self.newestUID(client, status: status)
                let baseline = Cursor(uidValidity: status.uidValidity, lastUID: last)
                return MailboxFetchResult(messages: [], cursor: Self.encode(baseline), position: Self.position(baseline))
            }
            let candidates = try await client.searchUIDs(after: state.lastUID, unseenOnly: options.unreadOnly)
            let batch = Array(candidates.prefix(max(1, options.limit)))
            let fetched = try await client.fetch(
                uids: batch, maxBytes: options.includeBody ? Self.bodyBytes : Self.headerBytes)
            let messages = fetched.map {
                message($0, mailbox: mailbox, uidValidity: status.uidValidity, includeBody: options.includeBody)
            }
            // UIDs that vanished between SEARCH and FETCH are skipped too.
            let next = Cursor(uidValidity: status.uidValidity, lastUID: max(state.lastUID, batch.max() ?? 0))
            return MailboxFetchResult(messages: messages, cursor: Self.encode(next), position: Self.position(next))
        }
    }

    func newest(mailbox: String, options: MailboxFetchOptions) async throws -> EmailMessage? {
        try await session { client in
            let status = try await client.examine(Self.wireName(mailbox))
            let uid: UInt32
            if options.unreadOnly {
                guard let last = try await client.searchUIDs(after: 0, unseenOnly: true).last else { return nil }
                uid = last
            } else {
                uid = try await Self.newestUID(client, status: status)
            }
            guard uid > 0 else { return nil }
            let fetched = try await client.fetch(
                uids: [uid], maxBytes: options.includeBody ? Self.bodyBytes : Self.headerBytes)
            return fetched.first.map {
                message($0, mailbox: mailbox, uidValidity: status.uidValidity, includeBody: options.includeBody)
            }
        }
    }

    // MARK: - Session

    private func session<T: Sendable>(_ body: (IMAPClient) async throws -> T) async throws -> T {
        if let problem = config.securityProblem { throw EmailFetchError.insecureConnection(problem) }
        guard let password = password(), !password.isEmpty else { throw EmailFetchError.passwordMissing }
        let client = IMAPClient(transport: makeTransport(config))
        do {
            let preauthenticated = try await client.connect()
            if !preauthenticated { try await client.login(username: config.username, password: password) }
            let result = try await body(client)
            await client.logout()
            return result
        } catch EmailFetchError.loginRefused(let detail) {
            await client.close()
            throw EmailFetchError.loginRefused([detail, config.passwordSignInNote].compactMap { $0 }.joined(separator: " "))
        } catch {
            await client.close()
            throw error
        }
    }

    /// The configured name as the server spells it: `INBOX` is
    /// case-insensitive, other names are sent modified UTF-7.
    static func wireName(_ mailbox: String) -> String {
        let trimmed = mailbox.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.uppercased() == EmailSourceConfig.inbox { return EmailSourceConfig.inbox }
        // Already-encoded names (from LIST) pass through unchanged.
        if trimmed.contains("&") && IMAPMailboxEncoding.decode(trimmed) != trimmed { return trimmed }
        return IMAPMailboxEncoding.encode(trimmed)
    }

    private static func newestUID(_ client: IMAPClient, status: IMAPMailboxStatus) async throws -> UInt32 {
        if let next = status.uidNext, next > 0 { return next - 1 }
        return try await client.highestUID()
    }

    private func message(_ fetched: IMAPFetchedMessage, mailbox: String, uidValidity: UInt32, includeBody: Bool)
        -> EmailMessage
    {
        EmailMIME.message(
            raw: fetched.raw, mailbox: mailbox, fallbackId: "imap:\(uidValidity):\(fetched.uid)",
            isRead: fetched.isRead, receivedAt: fetched.internalDate, sizeBytes: fetched.size, includeBody: includeBody)
    }

    // MARK: - Cursor

    static func position(_ cursor: Cursor) -> String {
        "UID \(cursor.lastUID)"
    }

    static func decode(_ value: JSONValue) -> Cursor? {
        guard case .object(let object) = value, case .number(let validity)? = object["uidvalidity"],
            case .number(let last)? = object["last_uid"], validity >= 0, last >= 0,
            validity <= Double(UInt32.max), last <= Double(UInt32.max)
        else { return nil }
        return Cursor(uidValidity: UInt32(validity), lastUID: UInt32(last))
    }

    static func encode(_ cursor: Cursor) -> JSONValue {
        .object(["uidvalidity": .number(Double(cursor.uidValidity)), "last_uid": .number(Double(cursor.lastUID))])
    }
}
