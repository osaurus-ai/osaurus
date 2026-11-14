//
//  MailAppMailboxFetcher.swift
//  osaurus
//
//  Reads the accounts already set up in the Mail app through
//  `MailServicing`. Mail has no stable per-mailbox counter, so the cursor
//  is the newest `date received` plus the ids seen in the last couple of
//  minutes: each check lists from slightly before the cursor (Mail
//  stores whole seconds and may file a message late) and skips the ids it
//  already returned.
//
//  Background checks never launch Mail; when it is closed the check fails
//  with `mailNotRunning` and the detail says so. Run Now and the editor
//  may launch it.
//

import Foundation

struct MailAppMailboxFetcher: MailboxFetching {
    /// Mail accounts; nil = every account (the unified mailboxes).
    let account: String?
    var service: any MailServicing = AppleScriptMailService()
    var isMailRunning: @Sendable () -> Bool = {
        AppleScriptBridge.isRunning(bundleIdentifier: AppleScriptMailService.bundleIdentifier)
    }

    /// How far before the cursor each check lists.
    static let overlap: TimeInterval = 120
    /// Ids remembered from the overlap window.
    static let recentCap = 200
    /// Rows asked of Mail per listing; Mail returns the newest end of the
    /// window, so a full page is followed by one ending at its oldest row.
    static let listLimit = 100
    /// Listings per check. Past this, the oldest mail of a burst is skipped
    /// and the position says so.
    static let maxPages = 10

    init(account: String?) {
        self.account = account
    }

    init(account: String?, service: any MailServicing, isMailRunning: @escaping @Sendable () -> Bool) {
        self.account = account
        self.service = service
        self.isMailRunning = isMailRunning
    }

    struct Cursor: Codable, Equatable {
        var received: Date
        var recent: [String]
    }

    /// The Mail path for a configured mailbox: `INBOX` is the account's
    /// inbox (or the unified one), a bare name is taken in the account, a
    /// path with `/` is used as is.
    func path(for mailbox: String) -> String {
        let trimmed = mailbox.trimmingCharacters(in: .whitespaces)
        if MailboxPath.segments(trimmed).count > 1 { return trimmed }
        guard let account else { return trimmed.isEmpty ? EmailSourceConfig.inbox : trimmed }
        return MailboxPath.join([account, trimmed.isEmpty ? EmailSourceConfig.inbox : trimmed])
    }

    func mailboxes() async throws -> [String] {
        let all = try await mail { try await service.mailboxes() }
        let scoped = account.map { name in all.filter { $0.account == name } } ?? all
        return [EmailSourceConfig.inbox] + scoped.map(\.path).filter { !$0.isEmpty }
    }

    func fetch(mailbox: String, cursor: JSONValue?, options: MailboxFetchOptions) async throws -> MailboxFetchResult {
        guard isMailRunning() else { throw EmailFetchError.mailNotRunning }
        let path = path(for: mailbox)
        guard let cursor, let state = decode(cursor) else {
            let newest = try await list(MailQuery(mailboxPath: path, unreadOnly: false, since: nil, limit: 1))
            let baseline = Cursor(
                received: newest.first.flatMap { date($0.dateReceived) } ?? Date(),
                recent: newest.map(\.id).filter { !$0.isEmpty })
            return MailboxFetchResult(messages: [], cursor: encode(baseline), position: position(baseline))
        }

        let since = state.received.addingTimeInterval(-Self.overlap)
        let (rows, complete) = try await listAll(path: path, since: since, unreadOnly: options.unreadOnly)
        let seen = Set(state.recent)
        let fresh = rows.filter { !seen.contains($0.id) }
            .sorted { (date($0.dateReceived) ?? .distantPast) < (date($1.dateReceived) ?? .distantPast) }
            .prefix(max(1, options.limit))

        var messages: [EmailMessage] = []
        for row in fresh {
            messages.append(try await message(row, mailbox: mailbox, includeBody: options.includeBody))
        }
        let newest = fresh.compactMap { date($0.dateReceived) }.max()
        let next = Cursor(
            received: max(state.received, newest ?? state.received),
            recent: Array((state.recent + fresh.map(\.id)).suffix(Self.recentCap)))
        var at = position(next)
        if !complete {
            at += " " + L("(over \(Self.maxPages * Self.listLimit) new messages at once; older ones were skipped)")
        }
        return MailboxFetchResult(messages: messages, cursor: encode(next), position: at)
    }

    /// Every message received after `since`, paging back from the newest.
    /// `complete` is false when `maxPages` ran out first.
    private func listAll(path: String, since: Date, unreadOnly: Bool) async throws
        -> (rows: [MailMessageSummary], complete: Bool)
    {
        var rows: [MailMessageSummary] = []
        var ids = Set<String>()
        var until: Date?
        for _ in 0 ..< Self.maxPages {
            let page = try await list(
                MailQuery(mailboxPath: path, unreadOnly: unreadOnly, since: since, until: until, limit: Self.listLimit))
            let added = page.filter { !$0.id.isEmpty && ids.insert($0.id).inserted }
            rows += added
            guard page.count >= Self.listLimit else { return (rows, true) }
            // A full page with nothing new (over a page of mail in one
            // second) or without dates can't be paged past.
            guard !added.isEmpty, let oldest = page.compactMap({ date($0.dateReceived) }).min() else {
                return (rows, false)
            }
            until = oldest
        }
        return (rows, false)
    }

    func newest(mailbox: String, options: MailboxFetchOptions) async throws -> EmailMessage? {
        let rows = try await list(
            MailQuery(mailboxPath: path(for: mailbox), unreadOnly: options.unreadOnly, since: nil, limit: 1))
        guard let row = rows.first else { return nil }
        return try await message(row, mailbox: mailbox, includeBody: options.includeBody)
    }

    // MARK: - Mapping

    private func list(_ query: MailQuery) async throws -> [MailMessageSummary] {
        try await mail { try await service.list(query) }
    }

    /// Mail's failures as `EmailFetchError`s the detail can show.
    private func mail<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as AppleToolError {
            switch error {
            case .permissionDenied: throw EmailFetchError.automationDenied
            case .unavailable: throw EmailFetchError.mailNotRunning
            default: throw EmailFetchError.mailApp(error.message)
            }
        }
    }

    private func message(_ row: MailMessageSummary, mailbox: String, includeBody: Bool) async throws -> EmailMessage {
        let sender = EmailMIME.addresses(row.sender).first
        var message = EmailMessage(
            messageId: EmailMIME.cleanId(row.id), threadId: nil, subject: row.subject,
            from: sender?.address ?? row.sender.lowercased(), fromName: sender?.name, to: [], cc: [],
            date: date(row.dateReceived), mailbox: mailbox, snippet: "", body: nil, attachments: [],
            isRead: row.isRead, sizeBytes: nil)
        guard includeBody else { return message }
        // A message deleted between the listing and the read still fires,
        // with the headers only.
        guard let content = try? await service.read(id: row.id, mailboxPath: row.mailboxPath.nonEmptyOrNil) else {
            return message
        }
        let body = content.content.trimmingCharacters(in: .whitespacesAndNewlines)
        message.to = content.to.map { EmailMIME.addresses($0).first?.address ?? $0.lowercased() }
        message.cc = content.cc.map { EmailMIME.addresses($0).first?.address ?? $0.lowercased() }
        message.body = body
        message.snippet = EmailMessage.snippet(of: body)
        message.attachments = content.attachments.map {
            EmailAttachment(name: $0.name, size: $0.sizeBytes, mime: $0.mimeType)
        }
        return message
    }

    private func date(_ iso: String?) -> Date? {
        iso.flatMap { AppleDateParsing.parse($0)?.date }
    }

    private func position(_ cursor: Cursor) -> String {
        cursor.received.formatted(date: .abbreviated, time: .shortened)
    }

    private func decode(_ value: JSONValue) -> Cursor? {
        guard case .object(let object) = value, case .string(let iso)? = object["received"],
            let received = ISO8601DateFormatter().date(from: iso)
        else { return nil }
        var recent: [String] = []
        if case .array(let ids)? = object["recent"] {
            recent = ids.compactMap { if case .string(let id) = $0 { id } else { nil } }
        }
        return Cursor(received: received, recent: recent)
    }

    private func encode(_ cursor: Cursor) -> JSONValue {
        .object([
            "received": .string(ISO8601DateFormatter().string(from: cursor.received)),
            "recent": .array(cursor.recent.map { .string($0) }),
        ])
    }
}
