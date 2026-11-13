//
//  EmailMIMETests.swift
//  osaurusTests
//
//  Raw RFC 5322 messages to `EmailMessage`: headers, encoded words,
//  addresses, transfer encodings, charsets, multipart choice, attachments
//  and cut-off fetches.
//

import Foundation
import Testing

@testable import OsaurusCore

struct EmailMIMETests {
    private func parse(_ raw: String, includeBody: Bool = true) -> EmailMessage {
        parse(Data(raw.replacingOccurrences(of: "\n", with: "\r\n").utf8), includeBody: includeBody)
    }

    private func parse(_ raw: Data, includeBody: Bool = true) -> EmailMessage {
        EmailMIME.message(
            raw: raw, mailbox: "INBOX", fallbackId: "imap:7:42", isRead: false, receivedAt: nil, sizeBytes: raw.count,
            includeBody: includeBody)
    }

    @Test func plainMessageHeadersAndQuotedPrintable() {
        let message = parse(
            """
            From: =?UTF-8?Q?Ren=C3=A9_Dupont?= <Rene@Example.com>
            To: you@example.com, "Doe, Jane" <jane@example.com>
            Subject: =?ISO-8859-1?Q?Caf=E9?= menu
             for today
            Message-ID: <abc@mail.example.com>
            References: <root@x> <mid@x>
            In-Reply-To: <mid@x>
            Date: Mon, 12 Oct 2026 09:00:00 +0000 (UTC)
            Content-Type: text/plain; charset=utf-8
            Content-Transfer-Encoding: quoted-printable

            Hello =E2=9C=93 world=
             continues
            """)
        #expect(message.messageId == "abc@mail.example.com")
        #expect(message.threadId == "root@x")
        #expect(message.subject == "Café menu for today")
        #expect(message.from == "rene@example.com")
        #expect(message.fromName == "René Dupont")
        #expect(message.to == ["you@example.com", "jane@example.com"])
        #expect(message.cc.isEmpty)
        #expect(message.date == Date(timeIntervalSince1970: 1_791_795_600))
        #expect(message.body == "Hello ✓ world continues")
        #expect(message.snippet == "Hello ✓ world continues")
        #expect(message.attachments.isEmpty)
    }

    @Test func adjacentEncodedWordsJoinWithoutTheSpace() {
        #expect(EmailMIME.decodeWords("=?UTF-8?B?SGVs?= =?UTF-8?B?bG8=?= there") == "Hello there")
        #expect(EmailMIME.decodeWords("plain text") == "plain text")
        // An unknown charset is read as UTF-8 rather than dropped.
        #expect(EmailMIME.decodeWords("=?bogus?Q?x?=") == "x")
    }

    @Test func addressForms() {
        let list = EmailMIME.addresses(#"a@x.com, "Last, First" <B@Y.com>, c@z.com (Carol), <d@w.com>"#)
        #expect(list.map(\.address) == ["a@x.com", "b@y.com", "c@z.com", "d@w.com"])
        #expect(list.map(\.name) == [nil, "Last, First", "Carol", nil])
    }

    @Test func alternativePrefersPlainAndListsAttachments() {
        let pdf = Data("%PDF-1.4 fake".utf8).base64EncodedString()
        let message = parse(
            """
            From: ops@example.com
            Subject: Report
            Message-ID: <r1@example.com>
            Content-Type: multipart/mixed; boundary="outer"

            --outer
            Content-Type: multipart/alternative; boundary=inner

            --inner
            Content-Type: text/html; charset=utf-8

            <p>HTML <b>version</b></p>
            --inner
            Content-Type: text/plain; charset=utf-8

            Plain version
            --inner--
            --outer
            Content-Type: application/pdf; name="q3.pdf"
            Content-Disposition: attachment; filename*=utf-8''Q3%20report.pdf
            Content-Transfer-Encoding: base64

            \(pdf)
            --outer--
            """)
        #expect(message.body == "Plain version")
        #expect(message.attachments == [EmailAttachment(name: "Q3 report.pdf", size: 13, mime: "application/pdf")])
        #expect(message.threadId == "r1@example.com")
    }

    @Test func htmlOnlyBecomesText() {
        let message = parse(
            """
            From: news@example.com
            Subject: News
            Content-Type: text/html

            <html><head><style>p { color: red }</style></head><body><p>Line&nbsp;one</p><p>Tom &amp; Jerry</p>Line<br>three<script>alert(1)</script></body></html>
            """)
        #expect(message.body == "Line one\nTom & Jerry\nLine\nthree")
    }

    @Test func eightBitLatin1BodySurvivesTheBoundarySplit() {
        var raw = Data(
            """
            From: a@example.com\r
            Subject: Latin\r
            Content-Type: multipart/mixed; boundary=b\r
            \r
            --b\r
            Content-Type: text/plain; charset=iso-8859-1\r
            Content-Transfer-Encoding: 8bit\r
            \r
            Caf
            """.utf8)
        raw.append(0xE9)
        raw.append(contentsOf: Array(" au lait\r\n--b--\r\n".utf8))
        #expect(parse(raw).body == "Café au lait")
    }

    @Test func missingMessageIdUsesTheFallbackAndCutOffMailStillParses() {
        let message = parse(
            """
            From: someone@example.com
            Subject: Big one
            Content-Type: multipart/mixed; boundary=z

            --z
            Content-Type: text/plain

            First part
            --z
            Content-Type: image/png; name=shot.png
            Content-Transfer-Encoding: base64

            iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB
            """)
        #expect(message.messageId == "imap:7:42")
        #expect(message.threadId == "imap:7:42")
        #expect(message.body == "First part")
        #expect(message.attachments.map(\.name) == ["shot.png"])
    }

    @Test func withoutTheBodyOnlyTheSnippetIsKept() {
        let message = parse(
            """
            From: a@example.com
            Subject: Hi

            \(String(repeating: "word ", count: 100))
            """, includeBody: false)
        #expect(message.body == nil)
        #expect(message.snippet.count == EmailMessage.snippetLength + 1)
        #expect(message.snippet.hasSuffix("…"))
    }

    @Test func mailboxNamesRoundTripModifiedUTF7() {
        #expect(IMAPMailboxEncoding.encode("Reçus & Envoyés") == "Re&AOc-us &- Envoy&AOk-s")
        #expect(IMAPMailboxEncoding.decode("Re&AOc-us &- Envoy&AOk-s") == "Reçus & Envoyés")
        #expect(IMAPMailboxEncoding.decode("&ZeVnLIqe-") == "日本語")
        #expect(EmailMailboxName.display("INBOX") == L("Inbox"))
        #expect(EmailMailboxName.display(#"Work/Q\/A"#) == "Work/Q/A")
    }
}
