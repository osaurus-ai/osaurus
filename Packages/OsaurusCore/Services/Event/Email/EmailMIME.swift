//
//  EmailMIME.swift
//  osaurus
//
//  Just enough RFC 5322 / 2045 / 2047 to turn a raw message (possibly cut
//  off after the first N bytes) into an `EmailMessage`: unfolded headers,
//  encoded words, address lists, the first text part (HTML converted to
//  text), and the attachment list. Anything it cannot decode is kept as
//  text rather than dropped.
//

import Foundation

enum EmailMIME {
    struct Headers: Equatable, Sendable {
        /// Lowercased name → values in order.
        var fields: [(name: String, value: String)] = []

        func first(_ name: String) -> String? {
            let lowered = name.lowercased()
            return fields.first { $0.name == lowered }?.value
        }

        static func == (lhs: Headers, rhs: Headers) -> Bool {
            lhs.fields.map(\.name) == rhs.fields.map(\.name) && lhs.fields.map(\.value) == rhs.fields.map(\.value)
        }
    }

    struct Part {
        var headers: Headers
        var body: Data
    }

    // MARK: - Message

    /// `raw` is the message as fetched, possibly only its first bytes.
    static func message(
        raw: Data, mailbox: String, fallbackId: String, isRead: Bool, receivedAt: Date?, sizeBytes: Int?,
        includeBody: Bool
    ) -> EmailMessage {
        let (headerData, bodyData) = split(raw)
        let headers = parseHeaders(headerData)
        let from = addresses(headers.first("from") ?? "").first
        let messageId = headers.first("message-id").map(cleanId).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackId
        let references = (headers.first("references") ?? "").split(whereSeparator: \.isWhitespace).map {
            cleanId(String($0))
        }
        let threadId = references.first ?? headers.first("in-reply-to").map(cleanId) ?? messageId

        var text = ""
        var attachments: [EmailAttachment] = []
        collect(Part(headers: headers, body: bodyData), text: &text, attachments: &attachments, depth: 0)
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return EmailMessage(
            messageId: messageId,
            threadId: threadId.isEmpty ? nil : threadId,
            subject: decodeWords(headers.first("subject") ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            from: from?.address ?? "",
            fromName: from?.name,
            to: addresses(headers.first("to") ?? "").map(\.address),
            cc: addresses(headers.first("cc") ?? "").map(\.address),
            date: headers.first("date").flatMap(parseDate) ?? receivedAt,
            mailbox: mailbox,
            snippet: EmailMessage.snippet(of: body),
            body: includeBody ? body : nil,
            attachments: attachments,
            isRead: isRead,
            sizeBytes: sizeBytes)
    }

    /// Message-IDs without angle brackets or whitespace.
    static func cleanId(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Headers

    /// Header block and body, split at the first empty line.
    static func split(_ raw: Data) -> (Data, Data) {
        let bytes = [UInt8](raw)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0A {
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A {
                    return (Data(bytes[0..<i]), Data(bytes[(i + 2)...]))
                }
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A {
                    return (Data(bytes[0..<i]), Data(bytes[(i + 3)...]))
                }
            }
            i += 1
        }
        return (raw, Data())
    }

    static func parseHeaders(_ data: Data) -> Headers {
        let text = String(decoding: data, as: UTF8.self)
        var headers = Headers()
        var current: (String, String)?
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if let first = line.first, first == " " || first == "\t" {
                if current != nil { current!.1 += " " + line.trimmingCharacters(in: .whitespaces) }
                continue
            }
            if let current { headers.fields.append((current.0, current.1)) }
            current = nil
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { continue }
            current = (name, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        if let current { headers.fields.append((current.0, current.1)) }
        return headers
    }

    /// A header value's main token and its `;`-separated parameters
    /// (`text/plain; charset=utf-8`).
    static func parameters(_ value: String) -> (value: String, params: [String: String]) {
        var parts: [String] = []
        var current = ""
        var quoted = false
        for ch in value {
            if ch == "\"" { quoted.toggle() }
            if ch == ";" && !quoted {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        var params: [String: String] = [:]
        for part in parts.dropFirst() {
            guard let eq = part.firstIndex(of: "=") else { continue }
            var key = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var raw = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 { raw = String(raw.dropFirst().dropLast()) }
            // RFC 2231 `filename*=utf-8''name`
            if key.hasSuffix("*") {
                key.removeLast()
                if let quote = raw.range(of: "''") {
                    raw = String(raw[quote.upperBound...]).removingPercentEncoding ?? raw
                }
            }
            params[key] = decodeWords(raw)
        }
        return (parts[0].trimmingCharacters(in: .whitespaces).lowercased(), params)
    }

    // MARK: - Encoded words (RFC 2047)

    static func decodeWords(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        // swiftlint:disable:next force_try
        let pattern = try! NSRegularExpression(pattern: #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#)
        let ns = value as NSString
        var out = ""
        var cursor = 0
        var lastWasWord = false
        for match in pattern.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
            let gap = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            // Whitespace between two encoded words is dropped.
            if !(lastWasWord && gap.trimmingCharacters(in: .whitespaces).isEmpty) { out += gap }
            let charset = ns.substring(with: match.range(at: 1))
            let encoding = ns.substring(with: match.range(at: 2)).uppercased()
            let text = ns.substring(with: match.range(at: 3))
            let bytes: Data? =
                encoding == "B"
                ? base64(Data(text.utf8))
                : quotedPrintable(Data(text.replacingOccurrences(of: "_", with: " ").utf8))
            if let bytes, let decoded = string(bytes, charset: charset) {
                out += decoded
            } else {
                out += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
            lastWasWord = true
        }
        out += ns.substring(from: cursor)
        return out
    }

    // MARK: - Addresses

    struct Address: Equatable {
        var name: String?
        var address: String
    }

    static func addresses(_ value: String) -> [Address] {
        var items: [String] = []
        var current = ""
        var quoted = false
        var angle = 0
        for ch in value {
            switch ch {
            case "\"": quoted.toggle()
            case "<" where !quoted: angle += 1
            case ">" where !quoted: angle = max(0, angle - 1)
            default: break
            }
            if ch == "," && !quoted && angle == 0 {
                items.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        items.append(current)
        return items.compactMap { item in
            let trimmed = item.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
                let address = trimmed[trimmed.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                var name = decodeWords(String(trimmed[..<open])).trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
                return Address(name: name.isEmpty ? nil : name, address: address.lowercased())
            }
            // `addr (Name)`
            if let open = trimmed.firstIndex(of: "("), let close = trimmed.lastIndex(of: ")"), open < close {
                let name = trimmed[trimmed.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                let address = trimmed[..<open].trimmingCharacters(in: .whitespaces)
                return Address(name: name.isEmpty ? nil : decodeWords(name), address: address.lowercased())
            }
            return Address(name: nil, address: trimmed.lowercased())
        }
    }

    // MARK: - Dates

    static func parseDate(_ value: String) -> Date? {
        // Drop a trailing comment: `… +0000 (UTC)`.
        var text = value.trimmingCharacters(in: .whitespaces)
        if let paren = text.firstIndex(of: "(") { text = text[..<paren].trimmingCharacters(in: .whitespaces) }
        for format in dateFormats {
            if let date = formatter(format).date(from: text) { return date }
        }
        return nil
    }

    private static let dateFormats = [
        "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z",
        "EEE, d MMM yy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "d-MMM-yyyy HH:mm:ss Z",
    ]

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    // MARK: - Body

    /// Appends the first text part to `text` (plain preferred over HTML) and
    /// every named part to `attachments`.
    private static func collect(_ part: Part, text: inout String, attachments: inout [EmailAttachment], depth: Int) {
        guard depth < 8 else { return }
        let (type, params) = parameters(part.headers.first("content-type") ?? "text/plain")
        let disposition = parameters(part.headers.first("content-disposition") ?? "")
        let filename = disposition.params["filename"] ?? params["name"]

        if type.hasPrefix("multipart/"), let boundary = params["boundary"] {
            let children = split(part.body, boundary: boundary)
            if type == "multipart/alternative" {
                // One text: the plain part when there is one, else the first.
                let plain = children.first { parameters($0.headers.first("content-type") ?? "text/plain").value == "text/plain" }
                if let chosen = plain ?? children.first, text.isEmpty {
                    collect(chosen, text: &text, attachments: &attachments, depth: depth + 1)
                }
                for child in children where child.headers.first("content-disposition")?.lowercased().hasPrefix("attachment") == true {
                    collect(child, text: &text, attachments: &attachments, depth: depth + 1)
                }
            } else {
                for child in children { collect(child, text: &text, attachments: &attachments, depth: depth + 1) }
            }
            return
        }
        if disposition.value == "attachment" || (filename != nil && !type.hasPrefix("text/")) {
            let decoded = decodeTransfer(part.body, encoding: part.headers.first("content-transfer-encoding"))
            attachments.append(
                EmailAttachment(name: filename ?? L("Untitled"), size: decoded.isEmpty ? nil : decoded.count, mime: type))
            return
        }
        guard text.isEmpty, type == "text/plain" || type == "text/html" else { return }
        let decoded = decodeTransfer(part.body, encoding: part.headers.first("content-transfer-encoding"))
        let string = string(decoded, charset: params["charset"]) ?? String(decoding: decoded, as: UTF8.self)
        text = type == "text/html" ? htmlToText(string) : string
    }

    /// The parts between `--boundary` lines, on bytes so 8-bit parts in
    /// other charsets survive. A cut-off message yields its complete parts
    /// plus the partial last one.
    static func split(_ body: Data, boundary: String) -> [Part] {
        let bytes = [UInt8](body)
        let delimiter = [UInt8](("--" + boundary).utf8)
        guard let lead = delimiter.first else { return [] }
        var starts: [Int] = []
        var i = 0
        while i + delimiter.count <= bytes.count {
            if bytes[i] == lead, i == 0 || bytes[i - 1] == 0x0A,
                bytes[i..<(i + delimiter.count)].elementsEqual(delimiter)
            {
                starts.append(i)
                i += delimiter.count
            } else {
                i += 1
            }
        }
        var parts: [Part] = []
        for (n, start) in starts.enumerated() {
            var s = start + delimiter.count
            if s + 1 < bytes.count, bytes[s] == 0x2D, bytes[s + 1] == 0x2D { break }
            while s < bytes.count, bytes[s] != 0x0A { s += 1 }
            s += 1
            var e = n + 1 < starts.count ? starts[n + 1] : bytes.count
            if e > s, bytes[e - 1] == 0x0A {
                e -= 1
                if e > s, bytes[e - 1] == 0x0D { e -= 1 }
            }
            guard s <= e, s <= bytes.count else { continue }
            let (headerData, bodyData) = split(Data(bytes[s..<e]))
            parts.append(Part(headers: parseHeaders(headerData), body: bodyData))
        }
        return parts
    }

    static func decodeTransfer(_ body: Data, encoding: String?) -> Data {
        switch encoding?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64": base64(body) ?? body
        case "quoted-printable": quotedPrintable(body) ?? body
        default: body
        }
    }

    /// Base64 that tolerates line breaks and a cut-off tail.
    static func base64(_ data: Data) -> Data? {
        var cleaned = String(decoding: data, as: UTF8.self).filter { !$0.isWhitespace }
        cleaned = String(cleaned.prefix(cleaned.count - cleaned.count % 4))
        return Data(base64Encoded: cleaned)
    }

    static func quotedPrintable(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var out = Data(capacity: bytes.count)
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: b - 0x30
            case 0x41...0x46: b - 0x41 + 10
            case 0x61...0x66: b - 0x61 + 10
            default: nil
            }
        }
        while i < bytes.count {
            let b = bytes[i]
            guard b == 0x3D else {
                out.append(b)
                i += 1
                continue
            }
            // Soft line break.
            if i + 1 < bytes.count, bytes[i + 1] == 0x0A {
                i += 2
                continue
            }
            if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A {
                i += 3
                continue
            }
            if i + 2 < bytes.count, let high = hex(bytes[i + 1]), let low = hex(bytes[i + 2]) {
                out.append(high << 4 | low)
                i += 3
                continue
            }
            out.append(b)
            i += 1
        }
        return out
    }

    static func string(_ data: Data, charset: String?) -> String? {
        let name = (charset ?? "utf-8").trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
        if name == "utf-8" || name == "utf8" || name == "us-ascii" {
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return String(data: data, encoding: .utf8) }
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        return String(data: data, encoding: encoding)
    }

    // MARK: - HTML

    static func htmlToText(_ html: String) -> String {
        var text = html
        for tag in ["script", "style", "head"] {
            text = text.replacingOccurrences(
                of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(
            of: "<(br|/p|/div|/li|/tr|/h[1-6])[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
        ]
        for (entity, replacement) in entities { text = text.replacingOccurrences(of: entity, with: replacement) }
        let lines = text.components(separatedBy: "\n").map {
            $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        }
        var out: [String] = []
        for line in lines where !(line.isEmpty && (out.last?.isEmpty ?? true)) { out.append(line) }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
