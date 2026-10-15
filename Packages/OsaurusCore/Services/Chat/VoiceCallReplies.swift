//
//  VoiceCallReplies.swift
//  osaurus
//
//  Osaurus Connect voice calls (docs/MOBILE_PROTOCOL.md §6.5). The phone
//  speaks the reply aloud, so a chat-length answer in markdown is a minute of
//  rambling with its lists read out mark by mark. A run flagged as a call
//  turn carries a note asking for a short, spoken answer.
//
//  The note goes after the conversation, on the latest user message, not in
//  the system prompt: there it would change the prompt between a call and
//  the chat around it, and a local model would read the whole conversation
//  in again on the first turn of every call and the first one after it.
//  Here only the last exchange is read again. It is never saved: the run's
//  turns are stored with it taken back off.
//

import Foundation

enum VoiceCallReplies {

    static let note = """
        [Voice call]
        The user is on a live voice call with you. Everything you write is spoken aloud by a \
        text-to-speech voice, and the user is listening, not reading. Answer the way a person \
        talks on the phone:
        - Keep it short: usually one to three sentences. Lead with the answer itself.
        - Plain spoken sentences only. No markdown, headings, bullet or numbered lists, tables, \
        code blocks, links, or emoji. Say numbers, dates and symbols the way they are said aloud.
        - Don't read out long details, lists or code. Give the gist, then offer to go into more \
        detail if the user wants it.
        - Ask at most one question at a time, and only when you need the answer.
        - If you use a tool, say briefly what you found rather than narrating each step.
        [/Voice call]
        """

    private static let separator = "\n\n"

    /// Adds the note after the latest user message.
    static func addNote(to messages: inout [ChatMessage]) {
        guard let index = messages.lastIndex(where: { $0.role == "user" }) else { return }
        let message = messages[index]
        if var parts = message.contentParts {
            parts.append(.text(note))
            messages[index] = ChatMessage(role: message.role, content: message.content, contentParts: parts)
        } else {
            let text = message.content ?? ""
            messages[index] = ChatMessage(role: message.role, content: text + separator + note)
        }
    }

    /// `messages` as they are saved: the note taken back off wherever it was
    /// added.
    static func removingNote(from messages: [ChatMessage]) -> [ChatMessage] {
        messages.map { message in
            guard message.role == "user" else { return message }
            if var parts = message.contentParts {
                guard case .text(note)? = parts.last else { return message }
                parts.removeLast()
                return ChatMessage(role: message.role, content: message.content, contentParts: parts)
            }
            guard let text = message.content, text.hasSuffix(separator + note) else { return message }
            return ChatMessage(role: message.role, content: String(text.dropLast(separator.count + note.count)))
        }
    }
}
