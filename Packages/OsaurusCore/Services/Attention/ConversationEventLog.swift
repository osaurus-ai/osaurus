//
//  ConversationEventLog.swift
//  osaurus
//
//  Event rows in a conversation's transcript: "You allowed web_fetch for
//  @alice · Phone", "No answer to web_fetch for @alice in time",
//  "@alice started a conversation with Research Agent". They are display
//  only — kept beside the transcript, never turns, so no model ever reads
//  them — and each links to its Insights row.
//
//  One versioned JSON file (`~/.osaurus/attention/conversation-events.json`,
//  0600): the newest `perConversationCapacity` events of each conversation,
//  and at most `capacity` overall. A file that doesn't decode is moved aside.
//

import Foundation

struct ConversationEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let sessionId: UUID
    let at: Date
    let text: String
    /// SF Symbol name.
    let icon: String
    /// The attention item the event settled, for "View in Insights".
    let attentionId: UUID?
    /// Dedupe key for one-time events ("joined:<participant key>").
    let key: String?
}

@MainActor
final class ConversationEventLog {
    static let shared = ConversationEventLog()

    /// Events kept per conversation; a busy conversation can't push out
    /// another conversation's history.
    static let perConversationCapacity = 200
    /// Events kept overall; past this the oldest go first.
    static let capacity = 20_000

    private struct Stored: Codable {
        var version = 2
        var events: [ConversationEvent]
    }

    private var events: [ConversationEvent]?
    var fileURL: URL = OsaurusPaths.root()
        .appendingPathComponent("attention", isDirectory: true)
        .appendingPathComponent("conversation-events.json")

    func events(for sessionId: UUID) -> [ConversationEvent] {
        loaded().filter { $0.sessionId == sessionId }
    }

    /// Records an event and refreshes the conversation if it is open. A
    /// `key` already recorded for the conversation is not recorded again.
    @discardableResult
    func record(
        sessionId: UUID,
        text: String,
        icon: String,
        attentionId: UUID? = nil,
        key: String? = nil,
        at: Date = Date()
    ) -> ConversationEvent? {
        var all = loaded()
        if let key, all.contains(where: { $0.sessionId == sessionId && $0.key == key }) { return nil }
        let event = ConversationEvent(
            id: UUID(), sessionId: sessionId, at: at, text: text, icon: icon, attentionId: attentionId, key: key
        )
        all.append(event)
        let inConversation = all.lazy.filter { $0.sessionId == sessionId }.count
        if inConversation > Self.perConversationCapacity,
            let oldest = all.firstIndex(where: { $0.sessionId == sessionId })
        {
            all.remove(at: oldest)
        }
        if all.count > Self.capacity { all.removeFirst(all.count - Self.capacity) }
        events = all
        save(all)
        refresh(sessionId)
        return event
    }

    /// Drops a deleted conversation's events.
    func forget(sessionId: UUID) {
        var all = loaded()
        let before = all.count
        all.removeAll { $0.sessionId == sessionId }
        guard all.count != before else { return }
        events = all
        save(all)
    }

    func resetForTesting(fileURL: URL? = nil) {
        if let fileURL { self.fileURL = fileURL }
        events = []
    }

    /// Forgets the in-memory copy so the next read comes from disk (tests).
    func reloadForTesting() { events = nil }

    // MARK: - Transcript placement

    /// `blocks` with an event row before the first block of the first turn
    /// created after each event; later events go at the end.
    static func interleave(
        _ events: [ConversationEvent],
        into blocks: [ContentBlock],
        turnDates: [UUID: Date]
    ) -> [ContentBlock] {
        guard !events.isEmpty else { return blocks }
        var result: [ContentBlock] = []
        result.reserveCapacity(blocks.count + events.count)
        var pending = events.sorted { $0.at < $1.at }[...]
        var lastTurn: UUID?
        for block in blocks {
            if block.turnId != lastTurn {
                lastTurn = block.turnId
                if let date = turnDates[block.turnId] {
                    while let next = pending.first, next.at < date {
                        result.append(.conversationEvent(next, beforeTurnId: block.turnId))
                        pending.removeFirst()
                    }
                }
            }
            result.append(block)
        }
        let tailTurn = blocks.last?.turnId ?? UUID()
        for event in pending { result.append(.conversationEvent(event, beforeTurnId: tailTurn)) }
        return result
    }

    // MARK: - Private

    private func loaded() -> [ConversationEvent] {
        if let events { return events }
        let decoded: [ConversationEvent]
        switch AttentionFileIO.read(StoredOrLegacy.self, from: fileURL, decoder: .conversationEvents) {
        case .loaded(let value): decoded = value.events
        case .missing, .corrupt: decoded = []
        }
        events = decoded
        return decoded
    }

    private func save(_ all: [ConversationEvent]) {
        AttentionFileIO.write(Stored(events: all), to: fileURL, encoder: .conversationEvents)
    }

    /// The versioned file, or the bare array written before versioning.
    private struct StoredOrLegacy: Decodable {
        let events: [ConversationEvent]

        init(from decoder: Decoder) throws {
            if let legacy = try? [ConversationEvent](from: decoder) {
                events = legacy
            } else {
                events = try Stored(from: decoder).events
            }
        }
    }

    private func refresh(_ sessionId: UUID) {
        let session =
            BackgroundTaskManager.shared.taskState(for: sessionId)?.chatSession
            ?? ChatWindowManager.shared.session(forSessionId: sessionId)
        session?.rebuildVisibleBlocks()
    }
}

extension JSONEncoder {
    fileprivate static let conversationEvents: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()
}

extension JSONDecoder {
    fileprivate static let conversationEvents: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
