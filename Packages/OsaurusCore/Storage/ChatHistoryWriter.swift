//
//  ChatHistoryWriter.swift
//  osaurus
//
//  Shared helpers for chat rows written outside the in-app `ChatSession.save`
//  path (workspace-served runs, paired-phone chats): the canonical
//  `ChatMessage` → persisted-turn mapping, the workspace grouping key, and the
//  notification that tells `ChatSessionsManager` such a row landed.
//
//  Raw inference (HTTP `/v1/chat/completions`, plugin `complete` /
//  `complete_stream`) is never written to chat history; Insights records it.
//

import Foundation

enum ChatHistoryWriter {
    /// Plugin-shaped key reserved for workspace-served sessions (host side)
    /// so `(source_plugin_id, external_session_key)` grouping works per
    /// teammate conversation without colliding with real plugin ids.
    static let workspacePseudoPluginId = "__workspace__"

    /// Posted on the main queue after a row written outside the in-app
    /// `ChatSession.save` path lands (workspace-served / paired phone), so
    /// `ChatSessionsManager` can pick it up without polling.
    static let didPersistExternallyNotification = Notification.Name(
        "ChatHistoryWriter.didPersistExternally")

    /// Canonical `ChatMessage` → persisted-turn mapping shared by every
    /// surface that records a raw transcript (the live transcript
    /// `InboundSharedRunBridge` keeps for a remote caller's run of a shared
    /// agent, paired-phone chats). System messages are dropped; tool results
    /// stay as their own `.tool` turns, keyed by `tool_call_id`, and are also
    /// recorded on the assistant turn that made the call, as a Mac chat
    /// records them.
    static func turns(from messages: [ChatMessage]) -> [ChatTurnData] {
        foldingToolResults(mappedTurns(from: messages))
    }

    /// Records each `.tool` turn's result on the assistant turn that made the
    /// call (`toolResults[call id]`), where a Mac chat keeps it and where its
    /// window reads it: without it the call draws as still running forever.
    /// A Mac chat does both as the run goes; turns written from raw messages
    /// have only the `.tool` turns. Results already there are left alone.
    static func foldingToolResults(_ turns: [ChatTurnData]) -> [ChatTurnData] {
        var folded = turns
        for (index, turn) in turns.enumerated() where turn.role == .tool {
            guard let callId = turn.toolCallId,
                let owner = folded[..<index].lastIndex(where: { candidate in
                    candidate.role == .assistant && (candidate.toolCalls?.contains { $0.id == callId } ?? false)
                }),
                folded[owner].toolResults[callId] == nil
            else { continue }
            folded[owner].toolResults[callId] = turn.content
        }
        return folded
    }

    private static func mappedTurns(from messages: [ChatMessage]) -> [ChatTurnData] {
        messages
            .filter { $0.role != "system" }
            .map { msg in
                // A user message that went to the model carries the memory
                // and time blocks ahead of the user's words. They are kept
                // beside the turn, as a Mac chat keeps them, so the bubble
                // shows only what was typed.
                let injected =
                    msg.role == "user" ? InjectedContextSpans.splittingLeadingBlocks(msg.content ?? "") : nil
                var turn = ChatTurnData(
                    id: UUID(),
                    role: MessageRole(rawValue: msg.role) ?? .assistant,
                    content: injected?.rest ?? msg.content ?? "",
                    // Images the client sent inline (data URLs) are kept, as a
                    // Mac chat keeps its own; otherwise the saved chat loses
                    // the photo the model was shown. Large ones spill to the
                    // blob store when the turn is written.
                    attachments: msg.imageDataFromParts.map(Attachment.image),
                    toolCalls: msg.tool_calls,
                    toolCallId: msg.tool_call_id,
                    toolResults: [:],
                    thinking: msg.reasoning_content ?? "",
                    reasoningItemId: msg.reasoning_item_id,
                    reasoningEncrypted: msg.reasoning_encrypted,
                    responsesOutputItems: msg.responses_output_items ?? [],
                    injectedContextPrefix: injected?.prefix
                )
                turn.anthropicThinkingBlocks = msg.anthropic_thinking_blocks ?? []
                return turn
            }
    }
}
