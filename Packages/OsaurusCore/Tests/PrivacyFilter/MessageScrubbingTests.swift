//
//  MessageScrubbingTests.swift
//  osaurusTests
//
//  [ChatMessage] extension surface: scrubbableConcat + applyingScrub,
//  with focus on the tool-call JSON path (string-leaves only, never
//  keys or numbers).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("ChatMessage Scrubbing")
struct MessageScrubbingTests {

    @Test func scrubbableConcat_skipsSystemAndJoinsRemaining() {
        // System content is app-controlled boilerplate — including it
        // poisons the token classifier's input distribution, so the
        // pipeline now skips it. See `scrubbableTexts()`.
        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: "You are an agent."),
            ChatMessage(role: "user", content: "Hi Alice."),
            ChatMessage(role: "user", content: "Send mail to bob@example.com."),
        ]
        let joined = messages.scrubbableConcat()
        #expect(!joined.contains("You are an agent."))
        #expect(joined.contains("Hi Alice."))
        #expect(joined.contains("Send mail to bob@example.com."))
        #expect(joined.contains("\u{001F}"))
    }

    @Test func scrubbableTexts_returnsPerMessageSegments() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: "Ignored boilerplate."),
            ChatMessage(role: "user", content: "First message."),
            ChatMessage(role: "user", content: "Second message."),
        ]
        let segments = messages.scrubbableTexts()
        #expect(segments == ["First message.", "Second message."])
    }

    @Test func applyingScrub_replacesContentField() async {
        let map = RedactionMap(conversationID: UUID())
        let alicePh = await map.intern("Alice", as: .person)
        let detection = DetectedEntity(
            category: .person,
            original: "Alice",
            range: "Alice".startIndex ..< "Alice".endIndex,
            placeholder: alicePh,
            approved: true
        )

        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "Hi Alice, are you there?")
        ]
        let scrubbed = messages.applyingScrub(approved: [detection])
        #expect(scrubbed.first?.content == "Hi [PERSON_1], are you there?")
    }

    @Test func applyingScrub_rewritesToolCallStringLeavesOnly() async {
        let map = RedactionMap(conversationID: UUID())
        let emailPh = await map.intern("alice@example.com", as: .email)
        let detection = DetectedEntity(
            category: .email,
            original: "alice@example.com",
            range: "alice@example.com".startIndex ..< "alice@example.com".endIndex,
            placeholder: emailPh,
            approved: true
        )

        // Tool call with a JSON-encoded "to" field containing the email.
        let toolCall = ToolCall(
            id: "call_1",
            type: "function",
            function: ToolCallFunction(
                name: "send_email",
                arguments: #"{"to":"alice@example.com","priority":3}"#
            )
        )
        let messages: [ChatMessage] = [
            ChatMessage(
                role: "assistant",
                content: nil,
                tool_calls: [toolCall],
                tool_call_id: nil
            )
        ]
        let scrubbed = messages.applyingScrub(approved: [detection])
        let args = scrubbed.first?.tool_calls?.first?.function.arguments ?? ""
        // String leaf rewritten to the placeholder.
        #expect(args.contains("[EMAIL_1]"))
        // Numeric leaf untouched.
        #expect(args.contains("\"priority\":3") || args.contains("\"priority\" : 3"))
        // Original PII gone.
        #expect(!args.contains("alice@example.com"))
    }

    @Test func applyingScrub_skipsUnapprovedDetections() async {
        let map = RedactionMap(conversationID: UUID())
        let placeholder = await map.intern("Alice", as: .person)
        let detection = DetectedEntity(
            category: .person,
            original: "Alice",
            range: "Alice".startIndex ..< "Alice".endIndex,
            placeholder: placeholder,
            approved: false
        )

        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "Hi Alice.")
        ]
        let scrubbed = messages.applyingScrub(approved: [detection])
        #expect(scrubbed.first?.content == "Hi Alice.")
    }

    /// When EVERY detection is toggled off (the Skip-All path), the
    /// outbound message should be byte-identical to what the user
    /// typed. The pipeline's empty-mapping short-circuit means this is
    /// what reaches the provider when the user taps "Send anyway" in
    /// the all-skipped banner — locking it in here so a future
    /// refactor can't silently substitute things the user explicitly
    /// rejected.
    @Test func applyingScrub_allEntitiesSkipped_returnsMessagesUnchanged() async {
        let map = RedactionMap(conversationID: UUID())
        let alicePh = await map.intern("Alice", as: .person)
        let emailPh = await map.intern("alice@example.com", as: .email)
        let detections = [
            DetectedEntity(
                category: .person,
                original: "Alice",
                range: "Alice".startIndex ..< "Alice".endIndex,
                placeholder: alicePh,
                approved: false
            ),
            DetectedEntity(
                category: .email,
                original: "alice@example.com",
                range: "alice@example.com".startIndex ..< "alice@example.com".endIndex,
                placeholder: emailPh,
                approved: false
            ),
        ]
        let original = "Hi Alice, your email is alice@example.com."
        let messages: [ChatMessage] = [ChatMessage(role: "user", content: original)]
        let scrubbed = messages.applyingScrub(approved: detections)
        #expect(scrubbed.first?.content == original)
    }
}
