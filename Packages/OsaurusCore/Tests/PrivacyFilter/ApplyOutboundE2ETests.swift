//
//  ApplyOutboundE2ETests.swift
//  osaurus / PrivacyFilter Tests
//
//  Covers the full pipeline detect → approve → scrub → send →
//  unscrub without depending on the on-device classifier
//  (`PrivacyFilterEngine.detect` requires the loaded MLX kit). We
//  simulate the detect step with `RegexEntityDetector.detect`,
//  which is exactly what the engine layer would feed into the
//  review service on the regex side anyway. The remaining steps —
//  approval → `applyingScrub` → `wrapInboundStream` —
//  are exercised against the real implementations.
//
//  Why this is worth keeping separate from `RoundTripTests`: that
//  suite only covers single-string round-trip on a `RedactionMap`.
//  This one walks through a multi-message `ChatMessage` array
//  (user + assistant tool-call), runs the full substitution pass,
//  and asserts the wire payload AND the inbound stream both come
//  out correct. The most common regression we catch here is the
//  tool-call JSON arg path silently dropping its scrub
//  (`MessageScrubbing.substituteJSONArguments` mis-handling a
//  fragment).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("PrivacyFilter applyOutbound E2E")
struct ApplyOutboundE2ETests {

    /// Multi-message conversation with a phone in the user turn and
    /// the same phone re-used in a tool-call argument JSON. Both
    /// sites must be rewritten to the same placeholder, the wire
    /// payload must contain no raw PII, and the assistant's reply
    /// (which echoes `[PHONE_1]`) must come back through the
    /// streaming unscrubber as the original number.
    @Test func userTurnPlusToolCall_endToEnd() async throws {
        let phone = "949-238-0232"
        let email = "alice@example.com"

        let map = RedactionMap(conversationID: UUID())

        // Step 1 (synth detect): regex detector finds phone + email
        // in the user message. This is exactly what the engine's
        // regex rail emits on the same string.
        let scrubbableText = "Hi, my phone is \(phone) and email \(email)"
        let regexMatches = RegexEntityDetector.detect(
            in: scrubbableText,
            ruleset: .allBuiltins()
        )
        #expect(regexMatches.count >= 2, "regex should find phone + email")

        // Step 2 (intern + approve): user "approves all" — drive
        // through `internBatch` the same way the engine's loop
        // does. `DetectedEntity.approved == true` is the contract
        // `applyingScrub` looks for.
        let internItems = regexMatches.map {
            (original: $0.original, category: $0.category, label: $0.label)
        }
        let placeholders = await map.internBatch(internItems)
        var approved: [DetectedEntity] = []
        for (i, match) in regexMatches.enumerated() {
            approved.append(
                DetectedEntity(
                    category: match.category,
                    original: match.original,
                    range: match.range,
                    placeholder: placeholders[i],
                    approved: true,
                    containingText: scrubbableText
                )
            )
        }

        // Step 3 (scrub): build a small multi-message conversation
        // with the phone duplicated inside a tool-call argument JSON
        // so the substitution has to walk both `content` and
        // `tool_calls[*].function.arguments`.
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: scrubbableText),
            ChatMessage(
                role: "assistant",
                content: nil,
                tool_calls: [
                    ToolCall(
                        id: "call_1",
                        type: "function",
                        function: ToolCallFunction(
                            name: "send_sms",
                            arguments: "{\"to\":\"\(phone)\",\"body\":\"hi\"}"
                        ),
                        geminiThoughtSignature: nil
                    )
                ],
                tool_call_id: nil,
                reasoning_content: nil
            ),
        ]
        let scrubbed = messages.applyingScrub(approved: approved)
        #expect(scrubbed.count == messages.count)

        // Find the user's content + the tool args after substitution.
        let scrubbedUserContent = scrubbed[0].content ?? ""
        let scrubbedToolArgs = scrubbed[1].tool_calls?.first?.function.arguments ?? ""

        // Step 4 (send): every PII string must be gone from the wire
        // payload — user content AND tool args.
        #expect(!scrubbedUserContent.contains(phone), "user content still leaks phone")
        #expect(!scrubbedUserContent.contains(email), "user content still leaks email")
        #expect(!scrubbedToolArgs.contains(phone), "tool args still leak phone")

        // Both sites must use the SAME placeholder for the same
        // original (placeholder stability is the whole reason the
        // `RedactionMap` exists).
        let phonePlaceholder = await map.snapshot().first { $0.1 == phone }?.0.token
        #expect(phonePlaceholder != nil, "RedactionMap missing phone placeholder")
        if let token = phonePlaceholder {
            #expect(scrubbedUserContent.contains(token))
            #expect(scrubbedToolArgs.contains(token))
        }

        // Step 5 (unscrub): assistant SSE stream echoes the
        // placeholder. `wrapInboundStream` must restore the
        // original before the consumer sees it.
        guard let token = phonePlaceholder else { return }
        let upstream = AsyncThrowingStream<String, Error> { cont in
            cont.yield("calling now: \(token).")
            cont.finish()
        }
        let wrapped = PrivacyFilterPipeline.wrapInboundStream(upstream, map: map)
        var collected = ""
        for try await chunk in wrapped {
            collected.append(chunk)
        }
        #expect(collected.contains(phone), "inbound stream did not restore phone")
        #expect(!collected.contains(token), "inbound stream left the placeholder literal")
    }

    /// Same conversation but the user explicitly UN-approves the
    /// email entity (e.g. ticked it off in the review sheet). The
    /// scrub must:
    ///   * still substitute the phone (approved),
    ///   * leave the email literal (skipped),
    ///   * and the wire payload must still satisfy that no
    ///     OTHER originals leaked.
    @Test func partialApproval_onlyApprovedAreScrubbed() async {
        let phone = "949-238-0232"
        let email = "alice@example.com"
        let map = RedactionMap(conversationID: UUID())

        let text = "phone \(phone) email \(email)"
        let regex = RegexEntityDetector.detect(in: text, ruleset: .allBuiltins())
        let internItems = regex.map {
            (original: $0.original, category: $0.category, label: $0.label)
        }
        let placeholders = await map.internBatch(internItems)

        // Mark email as un-approved (the user untoggled it in the
        // review sheet) — `applyingScrub` reads `entity.approved`
        // and skips when false.
        var detections: [DetectedEntity] = []
        for (i, match) in regex.enumerated() {
            detections.append(
                DetectedEntity(
                    category: match.category,
                    original: match.original,
                    range: match.range,
                    placeholder: placeholders[i],
                    approved: match.category != .email,
                    containingText: text
                )
            )
        }

        let messages: [ChatMessage] = [ChatMessage(role: "user", content: text)]
        let scrubbed = messages.applyingScrub(approved: detections)
        let body = scrubbed[0].content ?? ""

        #expect(!body.contains(phone), "approved phone should be scrubbed")
        #expect(body.contains(email), "unapproved email should remain literal")
    }
}
