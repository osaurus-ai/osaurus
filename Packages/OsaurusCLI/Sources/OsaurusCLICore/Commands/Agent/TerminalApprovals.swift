//
//  TerminalApprovals.swift
//  OsaurusCLICore
//
//  Tool approvals for `osaurus agent run` in a terminal. The run carries an
//  approval session id; its Ask cards show on the Mac as usual and are
//  listed by `GET /approvals?session=` for this terminal, which answers with
//  `POST /approvals/{id}`. Whichever answers first wins; a card answered on
//  the Mac drops out of the terminal prompt.
//

import Darwin
import Foundation

struct ApprovalCard: Equatable, Sendable {
    let id: String
    let tool: String
    let arguments: String
    let offersRunLease: Bool

    init?(_ object: [String: Any]) {
        guard let id = object["id"] as? String, let tool = object["tool"] as? String else { return nil }
        self.id = id
        self.tool = tool
        self.arguments = object["arguments"] as? String ?? ""
        self.offersRunLease = object["offers_run_lease"] as? Bool ?? false
    }
}

enum ApprovalDecision: String, Equatable, Sendable {
    case deny
    case allowOnce = "allow_once"
    case allowForRun = "allow_for_run"
    case alwaysAllow = "always_allow"

    /// `y`, `r`, `a` or `n` (or the words). Nil for anything else.
    static func parse(_ raw: String, offersRunLease: Bool) -> ApprovalDecision? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "y", "yes", "allow", "once": return .allowOnce
        case "r" where offersRunLease, "run" where offersRunLease: return .allowForRun
        case "a", "always": return .alwaysAllow
        case "n", "no", "deny": return .deny
        default: return nil
        }
    }
}

struct TerminalApprovals: Sendable {
    let server: LocalServerClient
    let session: String
    var poll: Duration = .seconds(1)

    /// Asks one card's question and returns the answer, or nil when the card
    /// went away before anyone answered (answered on the Mac, or the run
    /// ended). `stillPending` turns false the moment that happens.
    typealias Asker = @Sendable (_ card: ApprovalCard, _ stillPending: @escaping @Sendable () -> Bool) async -> ApprovalDecision?

    static func newSession() -> String { "cli-" + UUID().uuidString.lowercased() }

    func cards() async throws -> [ApprovalCard] {
        let (data, response) = try await server.data(
            for: server.request("/approvals?session=\(session)", timeout: 10))
        guard response.statusCode == 200,
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }
        return (object["approvals"] as? [[String: Any]] ?? []).compactMap(ApprovalCard.init)
    }

    /// True when Osaurus took the answer; false when the card was gone.
    func answer(_ card: ApprovalCard, _ decision: ApprovalDecision) async throws -> Bool {
        let request = server.jsonRequest(
            "/approvals/\(card.id)", body: ["decision": decision.rawValue, "session": session], timeout: 10)
        let (_, response) = try await server.data(for: request)
        return response.statusCode == 200
    }

    /// Watches for this run's cards until cancelled, asking each one once.
    func watch(ask: Asker, note: @escaping @Sendable (String) -> Void) async {
        var asked: Set<String> = []
        while !Task.isCancelled {
            if let card = try? await cards().first(where: { !asked.contains($0.id) }) {
                asked.insert(card.id)
                let pending = AtomicFlag(true)
                let watcher = Task {
                    while !Task.isCancelled, pending.value {
                        try? await Task.sleep(for: poll)
                        guard !Task.isCancelled else { return }
                        if let open = try? await cards(), !open.contains(where: { $0.id == card.id }) {
                            pending.value = false
                        }
                    }
                }
                let decision = await ask(card) { pending.value }
                watcher.cancel()
                if let decision, pending.value {
                    let taken = (try? await answer(card, decision)) ?? false
                    if !taken { note("That approval was already answered in Osaurus.") }
                } else if !pending.value {
                    note("Answered in Osaurus.")
                }
                continue
            }
            try? await Task.sleep(for: poll)
        }
    }

    // MARK: - Terminal

    /// Asks on `/dev/tty`, so a run whose stdin is piped still gets the
    /// question. Nil when there is no terminal to ask.
    static func terminalAsker(tty: Int32) -> Asker {
        { card, stillPending in
            await Task.detached {
                var question = "\nAllow \(card.tool)?"
                let arguments = card.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
                if !arguments.isEmpty, arguments != "{}" {
                    question += "\n  " + (arguments.count > 400 ? String(arguments.prefix(400)) + "…" : arguments)
                }
                let choices = card.offersRunLease
                    ? "[y] allow once  [r] allow for this run  [a] always  [n] deny"
                    : "[y] allow once  [a] always  [n] deny"
                write(tty, question + "\n  " + choices + "  (or answer in Osaurus): ")
                while true {
                    guard let line = readLine(tty: tty, cancelled: { !stillPending() }) else {
                        write(tty, "\n")
                        return nil
                    }
                    if let decision = ApprovalDecision.parse(line, offersRunLease: card.offersRunLease) {
                        return decision
                    }
                    write(tty, "  Type y, \(card.offersRunLease ? "r, " : "")a or n: ")
                }
            }.value
        }
    }

    static func openTerminal() -> Int32? {
        let fd = open("/dev/tty", O_RDWR | O_NOCTTY)
        return fd >= 0 ? fd : nil
    }

    private static func write(_ fd: Int32, _ text: String) {
        var bytes = Array(text.utf8)
        _ = Darwin.write(fd, &bytes, bytes.count)
    }

    /// One line from `fd`, waiting in short slices so the wait ends when
    /// `cancelled` turns true. Nil on cancel or end of input.
    static func readLine(tty fd: Int32, cancelled: () -> Bool) -> String? {
        var line: [UInt8] = []
        while !cancelled() {
            let ready = waitReadable(fd, milliseconds: 250)
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard ready > 0 else { continue }
            var byte: UInt8 = 0
            guard Darwin.read(fd, &byte, 1) == 1 else { return nil }
            if byte == UInt8(ascii: "\n") { return String(decoding: line, as: UTF8.self) }
            line.append(byte)
        }
        return nil
    }

    /// `select`, not `poll`: on macOS, `poll` on a `/dev/tty` descriptor
    /// reports POLLNVAL at once, and the `read` that follows blocks past the
    /// Mac answering the card.
    private static func waitReadable(_ fd: Int32, milliseconds: Int32) -> Int32 {
        guard fd >= 0, fd < FD_SETSIZE else { return -1 }
        var set = fd_set()
        withUnsafeMutableBytes(of: &set.fds_bits) { raw in
            let words = raw.bindMemory(to: Int32.self)
            words[Int(fd) / 32] |= Int32(bitPattern: UInt32(1) << UInt32(fd % 32))
        }
        var timeout = timeval(tv_sec: 0, tv_usec: milliseconds * 1000)
        return select(fd + 1, &set, nil, nil, &timeout)
    }
}

final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
