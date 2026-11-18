//
//  ConversationMailbox.swift
//  osaurus
//
//  Messages someone other than the caller posts into a hosted shared-agent
//  conversation (today: the owner speaking in it), held for the caller to
//  collect when no run is live to carry them. A live run delivers them
//  inline as `osaurus_participant_message` chunks; the caller polls
//  `GET /conversations/{session_id}/events?after=N` otherwise
//  (docs/MOBILE_PROTOCOL.md §21.4).
//
//  Scoped to the caller plus its `session_id`: a workspace teammate by its
//  wallet (its access keys rotate every few minutes), any other caller by
//  its access key, the same key the hosted transcript is grouped by. A
//  caller only ever reads its own conversations. Kept in `~/.osaurus/attention/mailbox.json` (0600) so
//  sequence numbers keep rising across relaunches; a cursor ahead of the
//  log gets a reset instead of a silent empty list.
//

import Foundation

/// One message in a hosted conversation from a participant other than the
/// caller. Metadata plus the text the participant chose to send.
struct ParticipantMessage: Codable, Equatable, Sendable {
    let seq: Int
    let id: String
    let author: Participant
    let text: String
    let sentAt: Date

    /// The wire form (`osaurus_participant_message` and the mailbox).
    struct Wire: Encodable, Sendable, Equatable {
        let seq: Int
        let id: String
        let author: String
        let author_kind: String
        let author_handle: String?
        let author_wallet: String?
        let text: String
        let sent_at: String
    }

    /// The owner's full Osaurus ID stays on this Mac: callers (invite peers
    /// included) get the short form only.
    var wire: Wire {
        let isOwner = author.kind == .owner || author.kind == .ownerDevice
        return Wire(
            seq: seq,
            id: id,
            author: ParticipantFormatter.short(author, viewerIsOwner: false),
            author_kind: author.kind.rawValue,
            author_handle: author.handle,
            author_wallet: isOwner ? author.wallet.map(ParticipantFormatter.shortAddress) : author.wallet,
            text: text,
            sent_at: ISO8601DateFormatter().string(from: sentAt)
        )
    }
}

@MainActor
final class ConversationMailbox {
    static let shared = ConversationMailbox()

    /// Per conversation, the most recent messages kept for collection.
    static let capacity = 200
    /// Conversations kept; the least recently written go first.
    static let conversationCapacity = 500

    /// What a caller collects: the messages after its cursor, or a reset
    /// when its cursor is ahead of this log (it kept one from before the
    /// log was cleared). `lastSeq` is where to resume.
    struct Collection: Equatable {
        let messages: [ParticipantMessage]
        let reset: Bool
        let lastSeq: Int
    }

    private struct Stored: Codable {
        var version = 1
        var nextSeq = 1
        var messages: [String: [ParticipantMessage]] = [:]
        var scopeByTask: [String: String] = [:]
        /// Scope → last write, for eviction.
        var touched: [String: Date] = [:]
    }

    private var stored: Stored?
    var fileURL: URL?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    private var resolvedURL: URL {
        fileURL
            ?? OsaurusPaths.root()
            .appendingPathComponent("attention", isDirectory: true)
            .appendingPathComponent("mailbox.json")
    }

    static func scope(callerKey: String, sessionId: String) -> String { "\(callerKey.lowercased()):\(sessionId)" }

    /// Remember which caller conversation a hosted task belongs to, so a
    /// message posted into the task reaches that caller.
    func bind(taskId: UUID, callerKey: String, sessionId: String) {
        var state = loaded()
        let scope = Self.scope(callerKey: callerKey, sessionId: sessionId)
        guard state.scopeByTask[taskId.uuidString] != scope else { return }
        state.scopeByTask[taskId.uuidString] = scope
        state.touched[scope] = Date()
        commit(state)
    }

    /// Whether a hosted task has a caller to deliver to.
    func isBound(taskId: UUID) -> Bool {
        loaded().scopeByTask[taskId.uuidString] != nil
    }

    @discardableResult
    func post(taskId: UUID, author: Participant, text: String, at date: Date = Date()) -> ParticipantMessage {
        var state = loaded()
        let message = ParticipantMessage(
            seq: state.nextSeq, id: UUID().uuidString, author: author, text: text, sentAt: date)
        state.nextSeq += 1
        if let scope = state.scopeByTask[taskId.uuidString] {
            var list = state.messages[scope, default: []]
            list.append(message)
            if list.count > Self.capacity { list.removeFirst(list.count - Self.capacity) }
            state.messages[scope] = list
            state.touched[scope] = date
        }
        commit(state)
        return message
    }

    func collect(callerKey: String, sessionId: String, after: Int) -> Collection {
        let state = loaded()
        let lastSeq = state.nextSeq - 1
        if after > lastSeq { return Collection(messages: [], reset: true, lastSeq: lastSeq) }
        let cursor = max(0, after)
        let list = (state.messages[Self.scope(callerKey: callerKey, sessionId: sessionId)] ?? [])
            .filter { $0.seq > cursor }
        return Collection(messages: list, reset: false, lastSeq: lastSeq)
    }

    func messages(callerKey: String, sessionId: String, after: Int) -> [ParticipantMessage] {
        collect(callerKey: callerKey, sessionId: sessionId, after: after).messages
    }

    /// Drops a hosted conversation's binding and messages (the conversation
    /// was deleted on this Mac).
    func forget(taskId: UUID) {
        var state = loaded()
        guard let scope = state.scopeByTask.removeValue(forKey: taskId.uuidString) else { return }
        if !state.scopeByTask.values.contains(scope) {
            state.messages[scope] = nil
            state.touched[scope] = nil
        }
        commit(state)
    }

    func resetForTesting(fileURL: URL? = nil) {
        self.fileURL = fileURL
        stored = Stored()
    }

    // MARK: - Private

    private func loaded() -> Stored {
        if let stored { return stored }
        let state: Stored
        switch AttentionFileIO.read(Stored.self, from: resolvedURL, decoder: .mailbox) {
        case .loaded(let value): state = value
        case .missing, .corrupt: state = Stored()
        }
        stored = state
        return state
    }

    private func commit(_ state: Stored) {
        var state = state
        if state.touched.count > Self.conversationCapacity {
            let evict = state.touched.sorted { $0.value < $1.value }
                .prefix(state.touched.count - Self.conversationCapacity).map(\.key)
            for scope in evict {
                state.touched[scope] = nil
                state.messages[scope] = nil
                state.scopeByTask = state.scopeByTask.filter { $0.value != scope }
            }
        }
        stored = state
        AttentionFileIO.write(state, to: resolvedURL, encoder: .mailbox)
    }
}

extension JSONEncoder {
    fileprivate static let mailbox: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()
}

extension JSONDecoder {
    fileprivate static let mailbox: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
