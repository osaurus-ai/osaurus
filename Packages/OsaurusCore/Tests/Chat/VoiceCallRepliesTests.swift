//
//  VoiceCallRepliesTests.swift
//  osaurusTests
//
//  The voice-call note rides on the latest user message only, and comes back
//  off exactly, so the saved chat never holds it.
//

import Foundation
import Testing

@testable import OsaurusCore

struct VoiceCallRepliesTests {

    @Test func noteGoesOnTheLatestUserMessageOnly() {
        var messages = [
            ChatMessage(role: "system", content: "You are helpful."),
            ChatMessage(role: "user", content: "First"),
            ChatMessage(role: "assistant", content: "Reply"),
            ChatMessage(role: "user", content: "What's the weather?"),
        ]
        VoiceCallReplies.addNote(to: &messages)
        #expect(messages[0].content == "You are helpful.")
        #expect(messages[1].content == "First")
        #expect(messages[3].content?.hasPrefix("What's the weather?\n\n[Voice call]") == true)
        #expect(messages[3].content?.hasSuffix("[/Voice call]") == true)
    }

    @Test func removingTheNoteRestoresTheMessage() {
        var messages = [ChatMessage(role: "user", content: "What's the weather?")]
        VoiceCallReplies.addNote(to: &messages)
        let saved = VoiceCallReplies.removingNote(from: messages + [ChatMessage(role: "assistant", content: "Sunny.")])
        #expect(saved.map(\.content) == ["What's the weather?", "Sunny."])
    }

    @Test func multipartMessagesGetTheNoteAsTheirLastPart() {
        var messages = [
            ChatMessage(
                role: "user",
                content: nil,
                contentParts: [.text("What's this?"), .imageUrl(url: "data:image/png;base64,AA==", detail: nil)]
            )
        ]
        VoiceCallReplies.addNote(to: &messages)
        #expect(messages[0].contentParts?.count == 3)
        let saved = VoiceCallReplies.removingNote(from: messages)
        #expect(saved[0].contentParts?.count == 2)
    }

    @Test func messagesWithoutTheNoteAreLeftAlone() {
        let messages = [ChatMessage(role: "user", content: "Hello")]
        #expect(VoiceCallReplies.removingNote(from: messages).map(\.content) == ["Hello"])
    }
}
