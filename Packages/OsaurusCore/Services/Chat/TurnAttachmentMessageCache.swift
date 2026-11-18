//
//  TurnAttachmentMessageCache.swift
//  osaurus
//
//  Model-visible messages for turns that carry attachments, built once per
//  run. Building one reads every image, audio, video and document from the
//  blob store, and the agent loop rebuilds history on the main actor before
//  each model call.
//

import Foundation

@MainActor
final class TurnAttachmentMessageCache {
    private struct Entry {
        let content: String
        let attachmentIds: [UUID]
        let toolCallId: String?
        let message: ChatMessage
    }

    private var entries: [UUID: Entry] = [:]

    /// `build()` for `turn`, reused while the turn's content, attachments
    /// and tool call id are unchanged. Turns without attachments are cheap
    /// to build and always rebuilt.
    func message(for turn: ChatTurn, build: () -> ChatMessage) -> ChatMessage {
        guard !turn.attachments.isEmpty else { return build() }
        let ids = turn.attachments.map(\.id)
        let content = turn.content
        if let entry = entries[turn.id], entry.attachmentIds == ids, entry.toolCallId == turn.toolCallId,
            entry.content == content
        {
            return entry.message
        }
        let message = build()
        entries[turn.id] = Entry(content: content, attachmentIds: ids, toolCallId: turn.toolCallId, message: message)
        return message
    }
}
