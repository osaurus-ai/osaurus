//
//  SkippedRedactionPersistenceTests.swift
//  osaurus / PrivacyFilter Tests
//
//  A skip in the review sheet is final for the session. Before this, a
//  skipped original stayed interned in the RedactionMap, so the next
//  outbound call (every agent-loop iteration is one) treated it as an
//  already-approved carry-over: no prompt, substituted on the wire, and
//  highlighted in the reply. Also pins the two word-fragment guards that
//  turned a Rampart "y" out of "Ternary" into redactions inside every
//  word containing a "y".
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite("Skipped redactions stay skipped")
struct SkippedRedactionPersistenceTests {

    private static func regexOnlyReviewConfig() -> PrivacyFilterConfiguration {
        var config = PrivacyFilterConfiguration()
        config.enabled = true
        config.aiDetectionEnabled = false
        config.alwaysApproveByDefault = false
        return config
    }

    // MARK: - Pipeline

    @MainActor
    @Test func skipAll_thenNextAgentLoopCall_neverPromptsOrRedactsSkipped() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("SkippedRedactionPersistence")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.regexOnlyReviewConfig())

        let sid = "skip-persist-\(UUID().uuidString)"
        let providerId = UUID()
        let phone = "949-238-0232"

        var presentations = 0
        let token = PrivacyReviewService.shared.registerPresenter { state in
            presentations += 1
            Task { @MainActor in
                state.skipAll()
                state.confirm()
            }
        }
        defer { PrivacyReviewService.shared.unregisterPresenter(token) }

        // Call 1: user turn with a phone number, user skips it.
        let call1: [ChatMessage] = [
            ChatMessage(role: "user", content: "Call me at \(phone) about the build.")
        ]
        let (scrubbed1, _) = try await PrivacyFilterPipeline.applyOutbound(
            messages: call1,
            sessionId: sid,
            providerId: providerId,
            requestSource: .chatUI
        )
        #expect(presentations == 1)
        #expect(scrubbed1.first?.content?.contains(phone) == true, "skipped phone ships as-is")

        // Call 2: same turn, next agent-loop iteration with a tool result
        // appended. The skipped phone must not be re-prompted, must not be
        // substituted as a carry-over, and must not trip the leak scan.
        let call2 = call1 + [
            ChatMessage(role: "tool", content: "{\"ok\":true,\"contact\":\"\(phone)\"}")
        ]
        let (scrubbed2, _) = try await PrivacyFilterPipeline.applyOutbound(
            messages: call2,
            sessionId: sid,
            providerId: providerId,
            requestSource: .chatUI
        )
        #expect(presentations == 1, "a skipped original must not prompt again")
        #expect(scrubbed2[0].content?.contains(phone) == true)
        #expect(scrubbed2[1].content?.contains(phone) == true)
        #expect(scrubbed2.allSatisfy { !($0.content ?? "").contains("[PHONE_") })
    }

    @Test func markSkipped_removesPlaceholderAndRemembersOriginal() async {
        let map = RedactionMap(conversationID: UUID())
        let placeholder = await map.intern("y", as: .person)
        await map.markSkipped(["y"])
        #expect(await map.resolve(token: placeholder.token) == nil)
        #expect(await map.snapshot().isEmpty)
        #expect(await map.skippedOriginals == ["y"])
    }

    // MARK: - Rampart word fragments

    private static func span(
        _ text: String,
        _ offset: Int,
        _ length: Int
    ) -> (category: EntityCategory, range: Range<String.Index>) {
        let lo = text.index(text.startIndex, offsetBy: offset)
        return (.person, lo ..< text.index(lo, offsetBy: length))
    }

    @Test func dropWordFragments_dropsSlicesOfLongerWords() {
        let text = "OsaurusAI/Bonsai-27b-Ternary-JANG"
        let ternary = text.range(of: "Ternary")!
        let terOffset = text.distance(from: text.startIndex, to: ternary.lowerBound)
        let spans = [
            Self.span(text, terOffset, 3),  // "Ter"
            Self.span(text, terOffset + 6, 1),  // "y"
        ]
        #expect(RampartPrivacyDetector.dropWordFragments(spans, in: text).isEmpty)
    }

    @Test func dropWordFragments_keepsWholeWords() {
        let text = "My name is Margaret Okonkwo."
        let spans = [Self.span(text, 11, 16)]  // "Margaret Okonkwo"
        #expect(RampartPrivacyDetector.dropWordFragments(spans, in: text).count == 1)
        // Possessive and edges of the string are still boundaries.
        let possessive = "Margaret's file"
        #expect(RampartPrivacyDetector.dropWordFragments([Self.span(possessive, 0, 8)], in: possessive).count == 1)
    }

    @Test func dropWordFragments_keepsNamesInScriptsWithoutSpaces() {
        let text = "我叫李明是工程师"
        let spans = [Self.span(text, 2, 2)]  // "李明"
        #expect(RampartPrivacyDetector.dropWordFragments(spans, in: text).count == 1)
    }

    // MARK: - Highlighter

    @Test func highlighter_isInsideWord() {
        let text = "ready to survey your system" as NSString
        #expect(RedactionHighlighter.isInsideWord(text.range(of: "y"), in: text))
        let standalone = "call y now" as NSString
        #expect(!RedactionHighlighter.isInsideWord(standalone.range(of: "y"), in: standalone))
        let name = "Hi Margaret, welcome" as NSString
        #expect(!RedactionHighlighter.isInsideWord(name.range(of: "Margaret"), in: name))
    }
}
