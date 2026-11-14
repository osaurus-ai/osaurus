//
//  IMAPClient.swift
//  osaurus
//
//  The handful of IMAP4rev1 (RFC 3501) commands an email source needs:
//  CAPABILITY, LOGIN, LIST, EXAMINE (read-only, so checking never marks
//  mail read), UID SEARCH, UID FETCH with BODY.PEEK, LOGOUT. One
//  connection per check; no IDLE.
//
//  TLS from the first byte only. STARTTLS is not offered: a server that
//  refuses LOGIN before it (LOGINDISABLED) gets a typed error, and plain
//  connections are allowed only to this Mac (`IMAPConnectionConfig`).
//

import Foundation
import Network

// MARK: - Transport

protocol IMAPTransport: Sendable {
    func open() async throws
    func send(_ data: Data) async throws
    /// Whatever bytes are available next; empty means the server closed.
    func receive() async throws -> Data
    func close()
}

final class NetworkIMAPTransport: IMAPTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ai.osaurus.imap")
    private let lock = NSLock()
    private var opened = false

    init(host: String, port: Int, tls: Bool) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 20
        let parameters = tls ? NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp) : NWParameters(tls: nil, tcp: tcp)
        let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .imaps
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                let result: Result<Void, Error>?
                switch state {
                case .ready: result = .success(())
                case .failed(let error), .waiting(let error):
                    result = .failure(EmailFetchError.connection(error.localizedDescription))
                case .cancelled: result = .failure(EmailFetchError.connection(L("The connection was closed.")))
                default: result = nil
                }
                guard let result else { return }
                self.lock.lock()
                let first = !self.opened
                self.opened = true
                self.lock.unlock()
                if first { continuation.resume(with: result) }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: EmailFetchError.connection(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: EmailFetchError.connection(error.localizedDescription))
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    func close() {
        connection.cancel()
    }
}

// MARK: - Responses

indirect enum IMAPToken: Equatable, Sendable {
    case atom(String)
    case string(Data)
    case list([IMAPToken])
    case nilValue

    var text: String? {
        switch self {
        case .atom(let value): value
        case .string(let data): String(decoding: data, as: UTF8.self)
        case .nilValue, .list: nil
        }
    }

    var data: Data? {
        switch self {
        case .string(let data): data
        case .atom(let value): Data(value.utf8)
        case .nilValue, .list: nil
        }
    }

    var items: [IMAPToken] {
        if case .list(let items) = self { return items }
        return []
    }
}

struct IMAPResponse: Equatable, Sendable {
    /// `*`, `+`, or the command tag.
    var tag: String
    var tokens: [IMAPToken]
    /// The first line, for status text and response codes.
    var text: String

    var isUntagged: Bool { tag == "*" }
    var isContinuation: Bool { tag == "+" }

    /// `OK`, `NO`, `BAD`, `BYE`, `PREAUTH`, or for untagged data the kind
    /// (`SEARCH`, `LIST`, `FETCH` after a number, `EXISTS`).
    var keyword: String {
        guard let first = tokens.first?.text?.uppercased() else { return "" }
        if Int(first) != nil, tokens.count > 1, let second = tokens[1].text { return second.uppercased() }
        return first
    }

    /// The number before `EXISTS` / `FETCH`.
    var number: Int? { tokens.first?.text.flatMap { Int($0) } }

    /// `[CODE value]` from a status line.
    func code(_ name: String) -> String? {
        guard let open = text.range(of: "[" + name + " ", options: .caseInsensitive),
            let close = text[open.upperBound...].firstIndex(of: "]")
        else { return nil }
        return String(text[open.upperBound..<close])
    }

    /// Human text after the status keyword and any response code.
    var message: String {
        var rest = text
        if let space = rest.firstIndex(of: " ") { rest = String(rest[rest.index(after: space)...]) }
        if let space = rest.firstIndex(of: " ") { rest = String(rest[rest.index(after: space)...]) } else { rest = "" }
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            rest = String(rest[rest.index(after: close)...])
        }
        return rest.trimmingCharacters(in: .whitespaces)
    }
}

/// Buffers bytes and cuts them into complete responses, literals included.
struct IMAPResponseParser {
    static let maxLiteral = 2 * 1024 * 1024
    private(set) var buffer: [UInt8] = []

    mutating func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    /// The next complete response, or nil until more bytes arrive.
    mutating func next() throws -> IMAPResponse? {
        guard let end = try completeEnd() else { return nil }
        let bytes = Array(buffer[0..<end])
        buffer.removeFirst(end)
        return try Self.parse(bytes)
    }

    /// Index just past the CRLF that ends the first response.
    private func completeEnd() throws -> Int? {
        var i = 0
        while true {
            guard let lf = buffer[i...].firstIndex(of: 0x0A) else { return nil }
            if let length = literalLength(endingBefore: lf) {
                guard length <= Self.maxLiteral else {
                    throw EmailFetchError.server(L("A message part was larger than Osaurus reads."))
                }
                let after = lf + 1 + length
                guard after <= buffer.count else { return nil }
                i = after
                continue
            }
            return lf + 1
        }
    }

    /// `{123}` (or `{123+}`) right before the line break at `lf`.
    private func literalLength(endingBefore lf: Int) -> Int? {
        var close = lf - 1
        if close >= 0, buffer[close] == 0x0D { close -= 1 }
        guard close >= 0, buffer[close] == 0x7D else { return nil }
        var digitsEnd = close
        if digitsEnd > 0, buffer[digitsEnd - 1] == 0x2B { digitsEnd -= 1 }
        var open = digitsEnd - 1
        while open >= 0, buffer[open] >= 0x30, buffer[open] <= 0x39 { open -= 1 }
        guard open >= 0, buffer[open] == 0x7B, open + 1 < digitsEnd else { return nil }
        return Int(String(decoding: buffer[(open + 1)..<digitsEnd], as: UTF8.self))
    }

    static func parse(_ bytes: [UInt8]) throws -> IMAPResponse {
        var tokenizer = Tokenizer(bytes: bytes)
        guard let tag = tokenizer.atom(), !tag.isEmpty else {
            throw EmailFetchError.server(L("The server sent something Osaurus couldn't read."))
        }
        var tokens: [IMAPToken] = []
        if tag == "+" {
            tokenizer.skipSpaces()
        } else {
            tokens = tokenizer.tokens(until: nil)
        }
        return IMAPResponse(tag: tag, tokens: tokens, text: tokenizer.text)
    }

    struct Tokenizer {
        let bytes: [UInt8]
        var index = 0
        /// The first line, so status text never includes literal contents.
        let text: String

        init(bytes: [UInt8]) {
            self.bytes = bytes
            let lineEnd = bytes.firstIndex(where: { $0 == 0x0D || $0 == 0x0A }) ?? bytes.count
            text = String(decoding: bytes[0..<lineEnd], as: UTF8.self)
        }

        mutating func skipSpaces() {
            while index < bytes.count, bytes[index] == 0x20 { index += 1 }
        }

        mutating func atom() -> String? {
            skipSpaces()
            let start = index
            while index < bytes.count, !Self.isDelimiter(bytes[index]) { index += 1 }
            guard index > start else { return nil }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func tokens(until close: UInt8?) -> [IMAPToken] {
            var out: [IMAPToken] = []
            while true {
                skipSpaces()
                guard index < bytes.count else { return out }
                let b = bytes[index]
                if b == 0x0D || b == 0x0A {
                    if close == nil { return out }
                    index += 1
                    continue
                }
                if let close, b == close {
                    index += 1
                    return out
                }
                switch b {
                case 0x28:
                    index += 1
                    out.append(.list(tokens(until: 0x29)))
                case 0x29:
                    // Stray close paren at top level.
                    index += 1
                case 0x22:
                    out.append(.string(quoted()))
                case 0x7B:
                    if let literal = literal() { out.append(.string(literal)) } else { index += 1 }
                default:
                    if let value = atomWithBrackets() {
                        out.append(value.uppercased() == "NIL" ? .nilValue : .atom(value))
                    } else {
                        index += 1
                    }
                }
            }
        }

        /// An atom that may hold a `[...]` section (`BODY[]<0>`,
        /// `[UIDVALIDITY`); spaces inside brackets stay in the atom.
        private mutating func atomWithBrackets() -> String? {
            let start = index
            var depth = 0
            while index < bytes.count {
                let b = bytes[index]
                if b == 0x5B { depth += 1 }
                if b == 0x5D { depth = max(0, depth - 1) }
                if depth == 0, Self.isDelimiter(b) { break }
                if b == 0x0D || b == 0x0A { break }
                index += 1
            }
            guard index > start else { return nil }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        private mutating func quoted() -> Data {
            index += 1
            var out: [UInt8] = []
            while index < bytes.count {
                let b = bytes[index]
                index += 1
                if b == 0x5C, index < bytes.count {
                    out.append(bytes[index])
                    index += 1
                    continue
                }
                if b == 0x22 { break }
                out.append(b)
            }
            return Data(out)
        }

        private mutating func literal() -> Data? {
            var i = index + 1
            var digits = ""
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                digits.append(Character(UnicodeScalar(bytes[i])))
                i += 1
            }
            if i < bytes.count, bytes[i] == 0x2B { i += 1 }
            guard i < bytes.count, bytes[i] == 0x7D, let length = Int(digits) else { return nil }
            i += 1
            if i < bytes.count, bytes[i] == 0x0D { i += 1 }
            if i < bytes.count, bytes[i] == 0x0A { i += 1 }
            let end = min(bytes.count, i + length)
            index = end
            return Data(bytes[i..<end])
        }

        static func isDelimiter(_ b: UInt8) -> Bool {
            b == 0x20 || b == 0x28 || b == 0x29 || b == 0x22 || b == 0x0D || b == 0x0A || b == 0x7B
        }
    }
}

// MARK: - Client

struct IMAPMailboxStatus: Equatable, Sendable {
    var uidValidity: UInt32
    var uidNext: UInt32?
    var exists: Int
}

struct IMAPFetchedMessage: Equatable, Sendable {
    var uid: UInt32
    var flags: [String]
    var internalDate: Date?
    var size: Int?
    var raw: Data

    var isRead: Bool { flags.contains { $0.caseInsensitiveCompare("\\Seen") == .orderedSame } }
}

actor IMAPClient {
    private let transport: any IMAPTransport
    private var parser = IMAPResponseParser()
    private var counter = 0
    let timeout: TimeInterval

    init(transport: any IMAPTransport, timeout: TimeInterval = 30) {
        self.transport = transport
        self.timeout = timeout
    }

    /// Opens the connection and reads the greeting. Returns true when the
    /// server already authenticated the session (PREAUTH).
    @discardableResult
    func connect() async throws -> Bool {
        let transport = transport
        try await withTimeout { try await transport.open() }
        let greeting = try await readResponse()
        switch greeting.keyword {
        case "OK": return false
        case "PREAUTH": return true
        case "BYE": throw EmailFetchError.server(greeting.message)
        default: throw EmailFetchError.server(greeting.text)
        }
    }

    func capabilities() async throws -> Set<String> {
        let (untagged, _) = try await command([.text("CAPABILITY")])
        var out = Set<String>()
        for response in untagged where response.keyword == "CAPABILITY" {
            for token in response.tokens.dropFirst() { if let text = token.text { out.insert(text.uppercased()) } }
        }
        return out
    }

    func login(username: String, password: String) async throws {
        if try await capabilities().contains("LOGINDISABLED") { throw EmailFetchError.loginDisabled }
        do {
            _ = try await command([.text("LOGIN "), Self.astring(username), .text(" "), Self.astring(password)])
        } catch EmailFetchError.server(let detail) {
            throw EmailFetchError.loginRefused(detail)
        }
    }

    /// Mailbox names, modified UTF-7 as the server sends them.
    func list() async throws -> [String] {
        let (untagged, _) = try await command([.text("LIST \"\" \"*\"")])
        return untagged.compactMap { response -> String? in
            guard response.keyword == "LIST", response.tokens.count >= 4 else { return nil }
            let flags = response.tokens[1].items.compactMap(\.text).map { $0.lowercased() }
            guard !flags.contains("\\noselect"), !flags.contains("\\nonexistent") else { return nil }
            return response.tokens[3].text
        }
    }

    func examine(_ mailbox: String) async throws -> IMAPMailboxStatus {
        let untagged: [IMAPResponse]
        do {
            (untagged, _) = try await command([.text("EXAMINE "), Self.astring(mailbox)])
        } catch EmailFetchError.server {
            throw EmailFetchError.mailboxNotFound(IMAPMailboxEncoding.decode(mailbox))
        }
        var validity: UInt32?
        var next: UInt32?
        var exists = 0
        for response in untagged {
            if let value = response.code("UIDVALIDITY").flatMap({ UInt32($0) }) { validity = value }
            if let value = response.code("UIDNEXT").flatMap({ UInt32($0) }) { next = value }
            if response.keyword == "EXISTS", let count = response.number { exists = count }
        }
        guard let validity else { throw EmailFetchError.server(L("The server didn't report UIDVALIDITY.")) }
        return IMAPMailboxStatus(uidValidity: validity, uidNext: next, exists: exists)
    }

    /// UIDs above `after`, ascending.
    func searchUIDs(after: UInt32, unseenOnly: Bool) async throws -> [UInt32] {
        let criteria = (unseenOnly ? "UNSEEN " : "") + "UID \(UInt64(after) + 1):*"
        let (untagged, _) = try await command([.text("UID SEARCH " + criteria)])
        var uids: [UInt32] = []
        for response in untagged where response.keyword == "SEARCH" {
            uids += response.tokens.dropFirst().compactMap { $0.text.flatMap { UInt32($0) } }
        }
        // `n:*` always matches the highest UID, even when it is below n.
        return Array(Set(uids.filter { $0 > after })).sorted()
    }

    /// The highest UID in the selected mailbox, 0 when empty.
    func highestUID() async throws -> UInt32 {
        let (untagged, _) = try await command([.text("UID SEARCH ALL")])
        var highest: UInt32 = 0
        for response in untagged where response.keyword == "SEARCH" {
            for token in response.tokens.dropFirst() {
                if let uid = token.text.flatMap({ UInt32($0) }) { highest = max(highest, uid) }
            }
        }
        return highest
    }

    /// The first `maxBytes` of each message, without setting `\Seen`.
    func fetch(uids: [UInt32], maxBytes: Int) async throws -> [IMAPFetchedMessage] {
        guard !uids.isEmpty else { return [] }
        let set = uids.map(String.init).joined(separator: ",")
        let (untagged, _) = try await command([
            .text("UID FETCH \(set) (UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[]<0.\(max(1, maxBytes))>)")
        ])
        var out: [IMAPFetchedMessage] = []
        for response in untagged where response.keyword == "FETCH" {
            guard let items = response.tokens.last?.items else { continue }
            var uid: UInt32?
            var flags: [String] = []
            var internalDate: Date?
            var size: Int?
            var raw = Data()
            var index = 0
            while index + 1 < items.count {
                let key = items[index].text?.uppercased() ?? ""
                let value = items[index + 1]
                switch key {
                case "UID": uid = value.text.flatMap { UInt32($0) }
                case "FLAGS": flags = value.items.compactMap(\.text)
                case "INTERNALDATE": internalDate = value.text.flatMap(Self.parseInternalDate)
                case "RFC822.SIZE": size = value.text.flatMap { Int($0) }
                default: if key.hasPrefix("BODY[") { raw = value.data ?? Data() }
                }
                index += 2
            }
            if let uid { out.append(IMAPFetchedMessage(uid: uid, flags: flags, internalDate: internalDate, size: size, raw: raw)) }
        }
        return out.sorted { $0.uid < $1.uid }
    }

    func logout() async {
        _ = try? await command([.text("LOGOUT")])
        transport.close()
    }

    func close() {
        transport.close()
    }

    // MARK: Plumbing

    enum Part {
        case text(String)
        case literal(Data)
    }

    /// Quoted when the value is plain ASCII, otherwise a literal.
    static func astring(_ value: String) -> Part {
        let bytes = Array(value.utf8)
        let plain = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        guard plain else { return .literal(Data(bytes)) }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return .text("\"" + escaped + "\"")
    }

    /// Sends one command and reads to its tagged completion. A NO or BAD
    /// throws `EmailFetchError.server` with the server's text.
    private func command(_ parts: [Part]) async throws -> ([IMAPResponse], IMAPResponse) {
        counter += 1
        let tag = "A\(counter)"
        var pending = Data((tag + " ").utf8)
        for part in parts {
            switch part {
            case .text(let text):
                pending.append(Data(text.utf8))
            case .literal(let data):
                pending.append(Data("{\(data.count)}\r\n".utf8))
                try await send(pending)
                pending = Data()
                let reply = try await readResponse()
                guard reply.isContinuation else {
                    throw EmailFetchError.server(reply.message.isEmpty ? reply.text : reply.message)
                }
                pending.append(data)
            }
        }
        pending.append(Data("\r\n".utf8))
        try await send(pending)

        var untagged: [IMAPResponse] = []
        while true {
            let response = try await readResponse()
            if response.tag == tag {
                switch response.keyword {
                case "OK": return (untagged, response)
                default: throw EmailFetchError.server(response.message.isEmpty ? response.text : response.message)
                }
            }
            if response.isUntagged, response.keyword == "BYE", parts.first.map(Self.isLogout) != true {
                throw EmailFetchError.server(response.message)
            }
            untagged.append(response)
        }
    }

    private static func isLogout(_ part: Part) -> Bool {
        if case .text(let text) = part { return text == "LOGOUT" }
        return false
    }

    private func send(_ data: Data) async throws {
        let transport = transport
        try await withTimeout { try await transport.send(data) }
    }

    private func readResponse() async throws -> IMAPResponse {
        let transport = transport
        while true {
            if let response = try parser.next() { return response }
            let data = try await withTimeout { try await transport.receive() }
            guard !data.isEmpty else { throw EmailFetchError.connection(L("The server closed the connection.")) }
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
                throw EmailFetchError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw EmailFetchError.timedOut }
            return first
        }
    }

    /// `17-Jul-1996 02:44:25 -0700`
    static func parseInternalDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return formatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }
}
