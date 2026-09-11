//
//  ChatDraftStore.swift
//  osaurus
//
//  In-memory store for unsent composer text, keyed by the chat it belongs
//  to. A draft typed into a saved chat is keyed by that chat's session id;
//  a draft typed into a not-yet-sent "New Chat" is keyed by the agent it
//  was typed under, so switching agents and back brings it up again.
//

import Foundation

@MainActor
final class ChatDraftStore {
    static let shared = ChatDraftStore()

    enum Key: Hashable {
        case session(UUID)
        case newChat(agentId: UUID?)
    }

    private var drafts: [Key: String] = [:]

    init() {}

    /// Remember `text` for `key`. Empty or whitespace-only text is not
    /// stored so a draft the user deleted does not come back later.
    func stash(_ text: String, for key: Key) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        drafts[key] = text
    }

    /// Return and forget the draft stored for `key`, if any.
    func take(for key: Key) -> String? {
        drafts.removeValue(forKey: key)
    }

    func peek(for key: Key) -> String? {
        drafts[key]
    }

    func discard(for key: Key) {
        drafts.removeValue(forKey: key)
    }

    func removeAll() {
        drafts.removeAll()
    }
}
