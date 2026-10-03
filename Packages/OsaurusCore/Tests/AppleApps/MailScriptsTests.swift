//
//  MailScriptsTests.swift
//  OsaurusCoreTests — AppleApps
//
//  Pins the AppleScript object specifiers the Mail service emits. Mail's
//  `message id` is the RFC Message-ID *property*, so `message id <int>` does
//  not compile — the regression that broke every follow-up call after a
//  `mail_list`. No Mail access is touched.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("MailScripts")
struct MailScriptsTests {
    @Test("cached resolve uses `first message … whose id is <int>` and verifies the RFC id")
    func cachedResolveUsesWhoseId() throws {
        let script = try MailScripts.resolve(
            messageId: "<abc@example.com>", mailboxPath: nil, cached: (path: "iCloud/INBOX", internalId: 4242)
        )
        #expect(script.contains("first message of (mailbox \"INBOX\" of account \"iCloud\") whose id is 4242"))
        #expect(!script.contains("message id 4242"))
        #expect(script.contains("if (message id of msg) is not \"<abc@example.com>\" then set msg to missing value"))
        // Falls back to a whose-scan of the cached mailbox, then the inbox.
        #expect(script.contains("first message of (mailbox \"INBOX\" of account \"iCloud\") whose message id is \"<abc@example.com>\""))
        #expect(script.contains("first message of inbox whose message id is \"<abc@example.com>\""))
        #expect(script.hasSuffix("number -1728"))
    }

    @Test("uncached resolve scans the given mailbox before the inbox, once each")
    func uncachedResolveOrder() throws {
        let script = try MailScripts.resolve(messageId: "<x@y>", mailboxPath: "Work/Projects/Osaurus", cached: nil)
        let nested = "mailbox \"Osaurus\" of mailbox \"Projects\" of account \"Work\""
        let firstScan = try #require(script.range(of: nested))
        let inboxScan = try #require(script.range(of: "first message of inbox whose"))
        #expect(firstScan.lowerBound < inboxScan.lowerBound)
        #expect(script.components(separatedBy: "whose message id is").count == 3)  // mailbox + inbox
        #expect(!script.contains("whose id is"))
    }

    @Test("resolve does not scan the inbox twice when INBOX is the given path")
    func inboxNotScannedTwice() throws {
        let script = try MailScripts.resolve(messageId: "<x@y>", mailboxPath: "INBOX", cached: nil)
        #expect(script.components(separatedBy: "whose message id is").count == 2)
        #expect(script.contains("first message of (inbox) whose message id is"))
    }

    @Test("mailbox references: unified, account, Local (On My Mac), nesting and escaped slashes")
    func mailboxReferences() throws {
        #expect(try MailboxPath.reference("INBOX") == "inbox")
        #expect(try MailboxPath.reference("trash") == "trash mailbox")
        #expect(try MailboxPath.reference("iCloud/INBOX") == "mailbox \"INBOX\" of account \"iCloud\"")
        #expect(try MailboxPath.reference("Local/Receipts") == "mailbox \"Receipts\"")
        #expect(try MailboxPath.reference("Local/Receipts/2026") == "mailbox \"2026\" of mailbox \"Receipts\"")
        #expect(
            try MailboxPath.reference("Work/Clients/Acme\\/Beta")
                == "mailbox \"Acme/Beta\" of mailbox \"Clients\" of account \"Work\"")
        #expect(MailboxPath.segments("A\\/B/C") == ["A/B", "C"])
        #expect(MailboxPath.join(["A/B", "C"]) == "A\\/B/C")
        #expect(MailboxPath.isUnified("Junk"))
        #expect(!MailboxPath.isUnified("Work/Junk"))
        #expect(throws: AppleToolError.self) { try MailboxPath.reference("Archive") }
        #expect(throws: AppleToolError.self) { try MailboxPath.reference("  ") }
    }

    @Test("unfiltered listing uses an index range (never materialises every message) and picks the recent end")
    func selectRecentUnfiltered() {
        let script = MailScripts.selectRecent(ref: "inbox", conditions: [], limit: 5)
        #expect(script.contains("set c to count of messages of (inbox)"))
        #expect(script.contains("set msgs to messages 1 thru n of (inbox)"))
        #expect(script.contains("set msgs to messages (c - n + 1) thru c of (inbox)"))
        #expect(script.contains("date received of message 1 of (inbox)"))
        #expect(!script.contains("repeat with msg in messages of"))
    }

    @Test("filtered listing uses a whose clause and takeRecent")
    func selectRecentFiltered() {
        let script = MailScripts.selectRecent(ref: "inbox", conditions: ["read status is false", "subject contains \"x\""], limit: 3)
        #expect(script.contains("(messages of (inbox) whose read status is false and subject contains \"x\")"))
        #expect(script.contains("my takeRecent(hits, 3)"))
    }

    @Test("encodeRows resets text item delimiters before returning")
    func encodeRowsResetsDelimiters() {
        let script = MailScripts.encodeRows(knownPathExpression: "knownPath")
        #expect(script.contains("my encodeMessage(msg, FS, knownPath)"))
        let set = try? #require(script.range(of: "set AppleScript's text item delimiters to RS"))
        let reset = try? #require(script.range(of: "set AppleScript's text item delimiters to \"\""))
        if let set, let reset { #expect(set.lowerBound < reset.lowerBound) }
        #expect(script.hasSuffix("return outText"))
    }

    @Test("sortedNewestFirst orders by parsed date and sinks undated rows")
    func sortNewestFirst() {
        func row(_ id: String, _ date: String?) -> MailMessageSummary {
            MailMessageSummary(id: id, subject: "", sender: "", dateReceived: date, dateSent: nil, isRead: false, isFlagged: false, mailboxPath: "INBOX")
        }
        let sorted = AppleScriptMailService.sortedNewestFirst([
            row("old", "2026-01-01T10:00:00+00:00"), row("none", nil), row("new", "2026-03-01T10:00:00+00:00"),
        ])
        #expect(sorted.map(\.id) == ["new", "old", "none"])
    }

    @Test("normalizedSubject strips reply/forward prefixes")
    func normalizedSubject() {
        #expect(AppleScriptMailService.normalizedSubject("Re: Fwd: RE:  Hello ") == "hello")
        #expect(AppleScriptMailService.normalizedSubject("Hello") == "hello")
    }
}
