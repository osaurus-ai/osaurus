//
//  ChatDraftStore.swift
//  osaurus
//
//  Store for unsent composer drafts (text plus pending attachments), keyed
//  by the chat they belong to. Text drafts also survive quit and relaunch. A draft typed into a
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

    // MARK: - Quit / relaunch

    /// Text drafts written at quit and read back once at launch. Attachments
    /// are not persisted: their bytes may live only in the composer.
    static func persistenceURL() -> URL {
        OsaurusPaths.config().appendingPathComponent("chat-drafts.json")
    }

    /// Stash every open composer's text (without clearing it) and write all
    /// text drafts. Called from `applicationWillTerminate`.
    func persistForQuit(openSessions: [ChatSession], to url: URL = ChatDraftStore.persistenceURL()) {
        for session in openSessions {
            let text = session.unsentComposerText
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let existing = drafts[session.draftKey]?.attachments ?? []
            drafts[session.draftKey] = Draft(text: text, attachments: existing)
        }
        var encoded: [String: String] = [:]
        for (key, draft) in drafts {
            let text = draft.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            encoded[key.persistedName] = text
        }
        if encoded.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        try? data.write(to: url, options: .atomic)
    }

    /// Read the drafts written at the last quit, then delete the file so a
    /// draft that is sent and followed by a crash does not come back.
    /// Drafts already stashed in this run win.
    func restorePersisted(from url: URL = ChatDraftStore.persistenceURL()) {
        guard let data = try? Data(contentsOf: url) else { return }
        try? FileManager.default.removeItem(at: url)
        guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        for (name, text) in decoded {
            guard let key = Key(persistedName: name), drafts[key] == nil else { continue }
            stash(Draft(text: text), for: key)
        }
    }
}

extension ChatDraftStore.Key {
    var persistedName: String {
        switch self {
        case .session(let id): return "session:\(id.uuidString)"
        case .newChat(let agentId): return "agent:\(agentId?.uuidString ?? "default")"
        }
    }

    init?(persistedName: String) {
        let parts = persistedName.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "session":
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            self = .session(id)
        case "agent":
            if parts[1] == "default" {
                self = .newChat(agentId: nil)
            } else {
                guard let id = UUID(uuidString: parts[1]) else { return nil }
                self = .newChat(agentId: id)
            }
        default:
            return nil
        }
    }
}
