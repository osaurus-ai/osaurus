//
//  FirstRunEdgeCaseTests.swift
//  OsaurusCoreTests — AppleApps
//
//  First-run states that used to read as an empty, ordinary answer: a Mail
//  with no account ("no unread mail") and a Calendar with no calendars ("a
//  free day"). Each now says what is missing and how to fix it.
//

import Foundation
import Testing

@testable import OsaurusCore

private final class EmptyMailService: MailServicing, @unchecked Sendable {
    let accounts: Int?
    var boxes: [MailboxInfo] = []

    init(accounts: Int?) { self.accounts = accounts }

    func accountCount() async throws -> Int? { accounts }
    func mailboxes() async throws -> [MailboxInfo] { boxes }
    func list(_ query: MailQuery) async throws -> [MailMessageSummary] { [] }
    func search(_ query: MailSearchQuery) async throws -> [MailMessageSummary] { [] }
    func read(id: String, mailboxPath: String?) async throws -> MailMessageContent {
        throw AppleToolError.notFound("No message `\(id)`.")
    }
    func compose(_ draft: MailDraft) async throws -> (sent: Bool, subject: String) { (false, "") }
    func reply(id: String, mailboxPath: String?, body: String, replyAll: Bool, send: Bool) async throws -> (
        sent: Bool, subject: String
    ) { (false, "") }
    func move(id: String, mailboxPath: String?, to destinationPath: String) async throws -> MailMessageSummary {
        throw AppleToolError.notFound("No message `\(id)`.")
    }
    func setStatus(id: String, mailboxPath: String?, patch: MailStatusPatch) async throws -> MailMessageSummary {
        throw AppleToolError.notFound("No message `\(id)`.")
    }
    func thread(id: String, mailboxPath: String?, limit: Int) async throws -> [MailMessageSummary] { [] }
}

private func envelope(_ raw: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
}

@Suite("First-run edge cases: empty answers say what is missing")
struct FirstRunEdgeCaseTests {

    @Test("Mail with no account says so instead of reporting an empty inbox", arguments: ["mail_mailboxes", "mail_list", "mail_search"])
    func mailWithNoAccount(toolName: String) async throws {
        let tools = MailToolFactory.makeTools(service: EmptyMailService(accounts: 0))
        let tool = try #require(tools.first { $0.name == toolName })
        let args = toolName == "mail_search" ? #"{"query":"invoice"}"# : "{}"
        let env = try envelope(await tool.execute(argumentsJSON: args))
        #expect(env["ok"] as? Bool == false)
        #expect(env["kind"] as? String == "unavailable")
        #expect((env["message"] as? String)?.contains("no account set up") == true)
    }

    @Test("an empty inbox on a Mail with an account is an ordinary empty result")
    func mailWithAccount_emptyIsEmpty() async throws {
        let tools = MailToolFactory.makeTools(service: EmptyMailService(accounts: 1))
        let list = try #require(tools.first { $0.name == "mail_list" })
        let env = try envelope(await list.execute(argumentsJSON: "{}"))
        #expect(env["ok"] as? Bool == true)
    }

    @Test("a service that cannot count accounts keeps today's empty result")
    func mailWithUnknownAccounts_emptyIsEmpty() async throws {
        let tools = MailToolFactory.makeTools(service: EmptyMailService(accounts: nil))
        let list = try #require(tools.first { $0.name == "mail_list" })
        let env = try envelope(await list.execute(argumentsJSON: "{}"))
        #expect(env["ok"] as? Bool == true)
    }

    @Test("Calendar with no calendars says what to turn on, not that the day is free")
    func calendarWithNoCalendars() throws {
        #expect(throws: AppleToolError.unavailable(EventKitCalendarService.noCalendarsMessage, retryable: false)) {
            try EventKitCalendarService.requireSomeCalendar(count: 0)
        }
        try EventKitCalendarService.requireSomeCalendar(count: 1)
        #expect(EventKitCalendarService.noCalendarsMessage.contains("Internet Accounts"))
    }
}
