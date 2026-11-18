//
//  EmailEventSourceTests.swift
//  osaurusTests
//
//  The retired email trigger (no checks, no runs, a pointer to Channels →
//  Email), the fake mailbox and Mail app service shared with the Email
//  channel tests, and the Mail app fetcher's cursor.
//

import Foundation
import Testing

@testable import OsaurusCore

/// A mailbox whose cursor is the index of the next message.
final class FakeMailboxFetcher: MailboxFetching, @unchecked Sendable {
    struct Call {
        var mailbox: String
        var cursor: JSONValue?
        var options: MailboxFetchOptions
    }

    private let lock = NSLock()
    private var messages: [EmailMessage] = []
    private var _calls: [Call] = []
    private var _error: EmailFetchError?
    /// Ignore the cursor once and return everything again.
    private var _replay = false

    var calls: [Call] { lock.withLock { _calls } }

    func append(_ new: EmailMessage...) { lock.withLock { messages += new } }
    func fail(_ error: EmailFetchError?) { lock.withLock { _error = error } }
    func replayOnce() { lock.withLock { _replay = true } }

    func mailboxes() async throws -> [String] { ["INBOX", "Receipts"] }

    func fetch(mailbox: String, cursor: JSONValue?, options: MailboxFetchOptions) async throws -> MailboxFetchResult {
        try lock.withLock {
            _calls.append(Call(mailbox: mailbox, cursor: cursor, options: options))
            if let _error { throw _error }
            guard case .number(let raw)? = cursor else {
                return MailboxFetchResult(messages: [], cursor: .number(Double(messages.count)), position: "#\(messages.count)")
            }
            let start = _replay ? 0 : Int(raw)
            _replay = false
            let batch = Array(messages.dropFirst(start).prefix(options.limit))
            let next = start + batch.count
            return MailboxFetchResult(
                messages: batch.map { var m = $0; m.mailbox = mailbox; if !options.includeBody { m.body = nil }; return m },
                cursor: .number(Double(max(Int(raw), next))), position: "#\(max(Int(raw), next))")
        }
    }

    func newest(mailbox: String, options: MailboxFetchOptions) async throws -> EmailMessage? {
        lock.withLock { messages.last }
    }

    static func message(_ id: String, from: String = "ann@example.com", read: Bool = false, thread: String? = nil)
        -> EmailMessage
    {
        EmailMessage(
            messageId: id, threadId: thread ?? id, subject: "Subject \(id)", from: from, fromName: "Ann", to: ["me@x.com"],
            cc: [], date: Date(timeIntervalSince1970: 1_791_795_600), mailbox: "INBOX", snippet: "Body \(id)",
            body: "Body \(id) " + String(repeating: "x", count: 1000), attachments: [], isRead: read, sizeBytes: 1200)
    }
}

@MainActor
struct EmailEventSourceTests {
    @Test func aStoredEmailAutomationNeverChecksMailAndSaysWhereMailWent() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        let event = manager.create(
            OsaurusEvent(
                name: "Inbox", source: .email(EmailSourceConfig(connectionId: "c1")),
                action: EventPipelineFixtures.agentAction()))
        await manager.emailSource.reconcile([event])

        #expect(await manager.runtime.scopeKeys.isEmpty)
        let status = manager.status(of: event.id)
        #expect(status.phase == .paused)
        #expect(status.lastError == EmailEventSource.retiredMessage)

        let result = await manager.fireNow(event.id)
        #expect(!result.accepted)
        #expect(result.reason == "email_trigger_retired")
        #expect(runner.fired.isEmpty)
    }

    @Test func addAutomationNoLongerOffersEmail() {
        #expect(!EventSourceRegistry.pickerKinds.contains(.email))
    }
}

// MARK: - Mail app fetcher

final class FakeMailService: MailServicing, @unchecked Sendable {
    private let lock = NSLock()
    var rows: [MailMessageSummary] = []
    var reads: [String] = []
    var queries: [MailQuery] = []
    var failure: (any Error)?
    /// `reply` calls: message id, mailbox path, body, sent (false = a draft).
    var replies: [(id: String, mailboxPath: String?, body: String, send: Bool)] = []

    func mailboxes() async throws -> [MailboxInfo] {
        if let failure { throw failure }
        return [
            MailboxInfo(path: "Work/INBOX", name: "INBOX", account: "Work", unreadCount: 1),
            MailboxInfo(path: "Home/INBOX", name: "INBOX", account: "Home", unreadCount: 0),
        ]
    }

    func list(_ query: MailQuery) async throws -> [MailMessageSummary] {
        if let failure { throw failure }
        return lock.withLock {
            queries.append(query)
            let matching = rows.filter { row in
                let received = AppleDateParsing.parse(row.dateReceived ?? "")?.date ?? .distantPast
                if let since = query.since, received <= since { return false }
                if let until = query.until, received > until { return false }
                return true
            }
            let sorted = AppleScriptMailService.sortedNewestFirst(matching)
            return Array(sorted.prefix(query.limit))
        }
    }

    func read(id: String, mailboxPath: String?) async throws -> MailMessageContent {
        lock.withLock { reads.append(id) }
        return MailMessageContent(
            id: id, subject: "s", sender: "Ann <ann@example.com>", to: ["Me <me@x.com>"], cc: [], replyTo: nil,
            dateReceived: nil, dateSent: nil, isRead: false, isFlagged: false, isJunk: false, mailboxPath: "Work/INBOX",
            content: "Body of \(id)", attachments: [MailAttachmentInfo(name: "a.pdf", sizeBytes: 10, mimeType: nil)])
    }

    func search(_ query: MailSearchQuery) async throws -> [MailMessageSummary] { [] }
    func compose(_ draft: MailDraft) async throws -> (sent: Bool, subject: String) { (false, "") }
    func reply(id: String, mailboxPath: String?, body: String, replyAll: Bool, send: Bool) async throws -> (
        sent: Bool, subject: String
    ) {
        lock.withLock { replies.append((id, mailboxPath, body, send)) }
        return (send, "Re: Subject \(id)")
    }
    func move(id: String, mailboxPath: String?, to destinationPath: String) async throws -> MailMessageSummary {
        throw EmailFetchError.server("unused")
    }
    func setStatus(id: String, mailboxPath: String?, patch: MailStatusPatch) async throws -> MailMessageSummary {
        throw EmailFetchError.server("unused")
    }
    func thread(id: String, mailboxPath: String?, limit: Int) async throws -> [MailMessageSummary] { [] }

    static func row(_ id: String, at offset: TimeInterval, read: Bool = false) -> MailMessageSummary {
        let date = Date(timeIntervalSince1970: 1_791_795_600 + offset)
        return MailMessageSummary(
            id: id, subject: "Subject \(id)", sender: "Ann <Ann@Example.com>",
            dateReceived: ISO8601DateFormatter().string(from: date), dateSent: nil, isRead: read, isFlagged: false,
            mailboxPath: "Work/INBOX")
    }
}

struct MailAppMailboxFetcherTests {
    @Test func closedMailIsTypedAndPathsFollowTheAccount() async throws {
        let service = FakeMailService()
        let closed = MailAppMailboxFetcher(account: "Work", service: service, isMailRunning: { false })
        await #expect(throws: EmailFetchError.mailNotRunning) {
            _ = try await closed.fetch(mailbox: "INBOX", cursor: nil, options: MailboxFetchOptions())
        }
        #expect(service.queries.isEmpty)
        #expect(closed.path(for: "INBOX") == "Work/INBOX")
        #expect(closed.path(for: "Receipts") == "Work/Receipts")
        #expect(closed.path(for: "Home/Archive") == "Home/Archive")
        #expect(MailAppMailboxFetcher(account: nil).path(for: "INBOX") == "INBOX")
        #expect(try await closed.mailboxes() == ["INBOX", "Work/INBOX"])
    }

    @Test func overlapWindowSkipsWhatItAlreadyReturned() async throws {
        let service = FakeMailService()
        service.rows = [FakeMailService.row("old", at: 0)]
        let fetcher = MailAppMailboxFetcher(account: "Work", service: service, isMailRunning: { true })

        let baseline = try await fetcher.fetch(mailbox: "INBOX", cursor: nil, options: MailboxFetchOptions())
        #expect(baseline.messages.isEmpty)

        // `late` is filed with a received date before the cursor but inside
        // the overlap; `old` is inside it too and was already seen.
        service.rows += [FakeMailService.row("late", at: -30), FakeMailService.row("new", at: 60)]
        let next = try await fetcher.fetch(mailbox: "INBOX", cursor: baseline.cursor, options: MailboxFetchOptions())
        #expect(next.messages.map(\.messageId) == ["late", "new"])
        #expect(next.messages[0].from == "ann@example.com")
        #expect(next.messages[0].to == ["me@x.com"])
        #expect(next.messages[0].body == "Body of late")
        #expect(next.messages[0].attachments.map(\.name) == ["a.pdf"])
        #expect(service.reads == ["late", "new"])

        let again = try await fetcher.fetch(mailbox: "INBOX", cursor: next.cursor, options: MailboxFetchOptions())
        #expect(again.messages.isEmpty)
    }

    @Test func withoutTheBodyMailIsNotOpened() async throws {
        let service = FakeMailService()
        service.rows = [FakeMailService.row("first", at: 0)]
        let fetcher = MailAppMailboxFetcher(account: nil, service: service, isMailRunning: { true })
        let baseline = try await fetcher.fetch(mailbox: "INBOX", cursor: nil, options: MailboxFetchOptions())
        service.rows.append(FakeMailService.row("x", at: 10, read: true))
        let next = try await fetcher.fetch(
            mailbox: "INBOX", cursor: baseline.cursor, options: MailboxFetchOptions(unreadOnly: false, includeBody: false))
        #expect(next.messages.map(\.messageId) == ["x"])
        #expect(next.messages[0].body == nil)
        #expect(next.messages[0].isRead)
        #expect(service.reads.isEmpty)
        #expect(service.queries.last?.mailboxPath == "INBOX")
    }

    @Test func aBurstLargerThanOneListingIsPagedNotSkipped() async throws {
        let service = FakeMailService()
        service.rows = [FakeMailService.row("first", at: 0)]
        let fetcher = MailAppMailboxFetcher(account: nil, service: service, isMailRunning: { true })
        var cursor = try await fetcher.fetch(mailbox: "INBOX", cursor: nil, options: MailboxFetchOptions()).cursor

        let burst = MailAppMailboxFetcher.listLimit * 2 + 50
        service.rows += (1 ... burst).map { FakeMailService.row("m\($0)", at: TimeInterval($0)) }
        let options = MailboxFetchOptions(includeBody: false, limit: 60)
        var delivered: [String] = []
        for _ in 0 ..< 10 {
            service.queries = []
            let result = try await fetcher.fetch(mailbox: "INBOX", cursor: cursor, options: options)
            if result.messages.isEmpty { break }
            #expect(result.position?.contains("skipped") == false)
            delivered += result.messages.map(\.messageId)
            cursor = result.cursor
        }
        #expect(delivered == (1 ... burst).map { "m\($0)" })
    }

    @Test func aBurstPastThePageCapSaysOlderMailWasSkipped() async throws {
        let service = FakeMailService()
        service.rows = [FakeMailService.row("first", at: 0)]
        let fetcher = MailAppMailboxFetcher(account: nil, service: service, isMailRunning: { true })
        let baseline = try await fetcher.fetch(mailbox: "INBOX", cursor: nil, options: MailboxFetchOptions())

        let burst = MailAppMailboxFetcher.listLimit * MailAppMailboxFetcher.maxPages + 20
        service.rows += (1 ... burst).map { FakeMailService.row("m\($0)", at: TimeInterval($0)) }
        service.queries = []
        let result = try await fetcher.fetch(
            mailbox: "INBOX", cursor: baseline.cursor, options: MailboxFetchOptions(includeBody: false, limit: 5))
        #expect(service.queries.count == MailAppMailboxFetcher.maxPages)
        #expect(result.position?.contains("older ones were skipped") == true)
        // Each page after the first repeats its boundary row.
        let reached = MailAppMailboxFetcher.listLimit + (MailAppMailboxFetcher.maxPages - 1) * (MailAppMailboxFetcher.listLimit - 1)
        #expect(result.messages.first?.messageId == "m\(burst - reached + 1)")
    }

    @Test func mailFailuresAreTypedForTheDetail() async throws {
        let service = FakeMailService()
        let fetcher = MailAppMailboxFetcher(account: nil, service: service, isMailRunning: { true })
        let cases: [(AppleToolError, EmailFetchError)] = [
            (.permissionDenied(.automation), .automationDenied),
            (.unavailable("Mail is not running", retryable: true), .mailNotRunning),
            (.execution("Mail error [-10000]: boom"), .mailApp("Mail error [-10000]: boom")),
        ]
        for (thrown, expected) in cases {
            service.failure = thrown
            await #expect(throws: expected) { _ = try await fetcher.mailboxes() }
            await #expect(throws: expected) {
                _ = try await fetcher.fetch(mailbox: "INBOX", cursor: nil, options: MailboxFetchOptions())
            }
        }
        #expect(EmailFetchError.automationDenied.isWaitingOnTheUser)
        #expect(!EmailFetchError.automationDenied.haltsChecks)
        #expect(EmailFetchError.automationDenied.localizedDescription.contains("Automation"))
    }
}
