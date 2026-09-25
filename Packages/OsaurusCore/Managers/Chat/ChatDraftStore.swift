//
//  ChatDraftStore.swift
//  osaurus
//
//  In-memory store for unsent composer drafts (text plus pending
//  attachments), keyed by the chat they belong to. A draft typed into a
//  saved chat is keyed by that chat's session id; a draft typed into a
//  not-yet-sent "New Chat" is keyed by the agent it was typed under, so
//  switching agents and back brings it up again, like switching tabs.
//

import Foundation
import SwiftUI

/// `ChatSession.composerGeneration` as seen by the composer. Delivered via
/// the environment (not an init argument) because `FloatingInputCard`'s
/// call site in `ChatView` is already at the type-checker's limit.
private struct ComposerGenerationKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var composerGeneration: Int {
        get { self[ComposerGenerationKey.self] }
        set { self[ComposerGenerationKey.self] = newValue }
    }
}

@MainActor
final class ChatDraftStore {
    static let shared = ChatDraftStore()

    enum Key: Hashable {
        case session(UUID)
        case newChat(agentId: UUID?)
    }

    /// Everything the composer was holding when the user navigated away.
    struct Draft: Equatable {
        var text: String
        var attachments: [Attachment]

        init(text: String, attachments: [Attachment] = []) {
            self.text = text
            self.attachments = attachments
        }

        /// True when there is nothing worth bringing back: no attachments
        /// and no text beyond whitespace.
        var isEmpty: Bool {
            attachments.isEmpty
                && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var drafts: [Key: Draft] = [:]

    init() {}

    /// Remember `draft` for `key`. An empty draft (whitespace-only text and
    /// no attachments) is not stored so a draft the user deleted does not
    /// come back later.
    func stash(_ draft: Draft, for key: Key) {
        guard !draft.isEmpty else { return }
        drafts[key] = draft
    }

    /// Text-only convenience for callers and tests that have no attachments.
    func stash(_ text: String, for key: Key) {
        stash(Draft(text: text), for: key)
    }

    /// Return and forget the draft stored for `key`, if any.
    func take(for key: Key) -> Draft? {
        drafts.removeValue(forKey: key)
    }

    func removeAll() {
        drafts.removeAll()
    }
}
