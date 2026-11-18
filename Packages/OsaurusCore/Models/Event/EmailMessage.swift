//
//  EmailMessage.swift
//  osaurus
//
//  One message as an email source sees it, whichever account it came from
//  (Mail app or IMAP), and the mailbox-name helpers both share.
//

import Foundation

struct EmailAttachment: Codable, Equatable, Sendable {
    var name: String
    var size: Int?
    var mime: String?
}

struct EmailMessage: Equatable, Sendable {
    /// RFC 5322 Message-ID without angle brackets, or a per-account stand-in
    /// when the message has none. The dedupe id.
    var messageId: String
    /// The first id in `References` (or `In-Reply-To`), else the message's own.
    var threadId: String?
    var subject: String
    /// Sender address, lowercased.
    var from: String
    var fromName: String?
    var to: [String]
    var cc: [String]
    var date: Date?
    var mailbox: String
    /// The start of the body, whitespace collapsed.
    var snippet: String
    /// Plain text (HTML-only mail is converted); nil when not read.
    var body: String?
    var attachments: [EmailAttachment]
    var isRead: Bool
    var sizeBytes: Int?

    static let snippetLength = 200

    static func snippet(of text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > snippetLength else { return collapsed }
        return String(collapsed.prefix(snippetLength)) + "…"
    }

    /// `body` cut to `limit` characters.
    func trimmed(toBodyChars limit: Int) -> EmailMessage {
        guard let body, body.count > limit else { return self }
        var copy = self
        copy.body = String(body.prefix(limit)) + "\n[…truncated]"
        return copy
    }

    /// Placeholder for trigger-value examples and Run Now without mail.
    static func example(mailbox: String) -> EmailMessage {
        EmailMessage(
            messageId: "example-message@osaurus.local", threadId: nil, subject: L("Quarterly report"),
            from: "alex@example.com", fromName: L("Alex"), to: ["you@example.com"], cc: [], date: Date(),
            mailbox: mailbox, snippet: L("Hi, the report is attached. Can you summarize it?"),
            body: L("Hi, the report is attached. Can you summarize it?"),
            attachments: [EmailAttachment(name: "report.pdf", size: 120_000, mime: "application/pdf")],
            isRead: false, sizeBytes: 140_000)
    }
}

/// Mailbox names as shown: IMAP's modified UTF-7 decoded, Mail's escaped
/// `\/` unescaped.
enum EmailMailboxName {
    static func display(_ name: String) -> String {
        let decoded = IMAPMailboxEncoding.decode(name)
        if decoded.uppercased() == EmailSourceConfig.inbox { return L("Inbox") }
        return decoded.replacingOccurrences(of: "\\/", with: "/")
    }
}

/// RFC 3501 §5.1.3 modified UTF-7 for mailbox names.
enum IMAPMailboxEncoding {
    static func decode(_ name: String) -> String {
        guard name.contains("&") else { return name }
        var out = ""
        var index = name.startIndex
        while index < name.endIndex {
            let ch = name[index]
            guard ch == "&" else {
                out.append(ch)
                index = name.index(after: index)
                continue
            }
            guard let end = name[index...].firstIndex(of: "-") else {
                out += name[index...]
                break
            }
            let encoded = name[name.index(after: index)..<end]
            if encoded.isEmpty {
                out.append("&")
            } else {
                var base64 = encoded.replacingOccurrences(of: ",", with: "/")
                while base64.count % 4 != 0 { base64.append("=") }
                if let data = Data(base64Encoded: base64), let text = String(data: data, encoding: .utf16BigEndian) {
                    out += text
                } else {
                    out += name[index...end]
                }
            }
            index = name.index(after: end)
        }
        return out
    }

    static func encode(_ name: String) -> String {
        var out = ""
        var pending: [UInt16] = []
        func flush() {
            guard !pending.isEmpty else { return }
            let data = pending.reduce(into: Data()) { data, unit in
                data.append(UInt8(unit >> 8))
                data.append(UInt8(unit & 0xFF))
            }
            let base64 = data.base64EncodedString().replacingOccurrences(of: "/", with: ",")
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
            out += "&" + base64 + "-"
            pending.removeAll()
        }
        for scalar in name.unicodeScalars {
            if scalar.value >= 0x20 && scalar.value <= 0x7E {
                flush()
                out += scalar == "&" ? "&-" : String(scalar)
            } else {
                pending.append(contentsOf: String(scalar).utf16)
            }
        }
        flush()
        return out
    }
}
