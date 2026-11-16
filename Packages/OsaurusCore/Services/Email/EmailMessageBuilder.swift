//
//  EmailMessageBuilder.swift
//  osaurus
//
//  Builds the plain-text replies the Email channel sends over SMTP: the
//  reply headers that keep the thread together in the recipient's mail
//  app (`Re:` subject, `In-Reply-To`, `References`) and the RFC 5322
//  rendering with an RFC 2047 subject and a UTF-8 body.
//

import Foundation

struct EmailOutgoingMessage: Equatable, Sendable {
    var from: String
    var fromName: String?
    var to: [String]
    var cc: [String] = []
    var subject: String
    var body: String
    /// Message-IDs without angle brackets.
    var inReplyTo: String?
    var references: [String] = []
    var messageId: String
    var date: Date = Date()

    var recipients: [String] {
        var seen = Set<String>()
        return (to + cc).map { $0.lowercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

enum EmailMessageBuilder {
    /// A reply to `original`: to its sender (and, with `replyAll`, the other
    /// recipients except this account), threaded under it.
    static func reply(
        to original: EmailMessage, from: String, fromName: String? = nil, body: String, replyAll: Bool = false,
        date: Date = Date()
    ) -> EmailOutgoingMessage {
        let me = from.lowercased()
        var cc: [String] = []
        if replyAll {
            cc = (original.to + original.cc).map { $0.lowercased() }.filter { $0 != me && $0 != original.from }
        }
        let parent = isRealMessageId(original.messageId) ? original.messageId : nil
        var references: [String] = []
        if let root = original.threadId, isRealMessageId(root), root != parent { references.append(root) }
        if let parent { references.append(parent) }
        return EmailOutgoingMessage(
            from: me, fromName: fromName, to: [original.from], cc: cc, subject: replySubject(original.subject),
            body: body, inReplyTo: parent, references: references, messageId: newMessageId(from: me), date: date)
    }

    static func replySubject(_ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("re:") { return trimmed }
        return trimmed.isEmpty ? "Re:" : "Re: " + trimmed
    }

    /// Stand-in ids (`imap:<validity>:<uid>`) are not Message-IDs and must
    /// not be sent as one.
    static func isRealMessageId(_ id: String) -> Bool {
        id.contains("@") && !id.contains(" ")
    }

    static func newMessageId(from address: String) -> String {
        let domain = address.split(separator: "@").last.map(String.init) ?? "osaurus.local"
        return "\(UUID().uuidString.lowercased())@\(domain.isEmpty ? "osaurus.local" : domain)"
    }

    // MARK: - Rendering

    /// CRLF line endings throughout; not yet dot-stuffed.
    static func render(_ message: EmailOutgoingMessage) -> Data {
        var headers: [String] = []
        headers.append("Date: " + rfc5322Date(message.date))
        headers.append("From: " + mailbox(message.from, name: message.fromName))
        headers.append("To: " + message.to.joined(separator: ", "))
        if !message.cc.isEmpty { headers.append("Cc: " + message.cc.joined(separator: ", ")) }
        headers.append("Subject: " + encodedWord(message.subject))
        headers.append("Message-ID: <\(message.messageId)>")
        if let inReplyTo = message.inReplyTo { headers.append("In-Reply-To: <\(inReplyTo)>") }
        if !message.references.isEmpty {
            headers.append("References: " + message.references.map { "<\($0)>" }.joined(separator: " "))
        }
        headers.append("MIME-Version: 1.0")
        headers.append("Content-Type: text/plain; charset=utf-8")

        let normalized = message.body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let body: String
        if normalized.utf8.allSatisfy({ $0 < 0x80 }) && lines.allSatisfy({ $0.utf8.count <= 998 }) {
            headers.append("Content-Transfer-Encoding: 7bit")
            body = lines.joined(separator: "\r\n")
        } else {
            headers.append("Content-Transfer-Encoding: base64")
            body = Data(normalized.replacingOccurrences(of: "\n", with: "\r\n").utf8)
                .base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        }
        return Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + body + "\r\n").utf8)
    }

    /// RFC 5321 §4.5.2: a line starting with `.` gets one more.
    static func dotStuffed(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count + 16)
        var atLineStart = true
        for byte in data {
            if atLineStart, byte == 0x2E { out.append(0x2E) }
            out.append(byte)
            atLineStart = byte == 0x0A
        }
        return out
    }

    static func mailbox(_ address: String, name: String?) -> String {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return address }
        let plain = name.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        let display =
            plain
            ? "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            : encodedWord(name)
        return "\(display) <\(address)>"
    }

    /// RFC 2047 `=?UTF-8?B?…?=` when the text is not plain ASCII, split into
    /// folded words of at most 75 characters without cutting a character.
    static func encodedWord(_ text: String) -> String {
        let singleLine = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        guard !singleLine.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return singleLine }
        var chunks: [String] = []
        var current = ""
        for character in singleLine {
            if current.utf8.count + String(character).utf8.count > 45 {
                chunks.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.map { "=?UTF-8?B?" + Data($0.utf8).base64EncodedString() + "?=" }.joined(separator: "\r\n ")
    }

    static func rfc5322Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
