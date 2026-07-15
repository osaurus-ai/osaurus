//
//  PostScrubInvariantTests.swift
//  osaurus / PrivacyFilter Tests
//
//  Pins the post-scrub invariant: after substitution, any remaining
//  regex-detectable PII must trip the leak guard and produce a
//  `PrivacyFilterPipelineError.scrubLeaked` instead of going to the
//  wire. We exercise the gate at the helper layer
//  (`PrivacyFilterPipeline.scanForLeaks`) plus the error-formatting
//  layer (`formatScrubLeaked`) — the full pipeline path requires the
//  on-device model and is covered indirectly by integration tests.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Post-scrub invariant")
struct PostScrubInvariantTests {

    // MARK: - scanForLeaks

    /// Phone number that survives the scrub pass triggers the leak
    /// guard. This is the canonical regression for the bug that
    /// motivated the invariant: model misses bare-digit phone numbers,
    /// substitution silently passes through, and unredacted PII
    /// reaches the cloud.
    @Test func scan_leakedPhone_returnsCount() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "Call me at 949-238-0232 today.")
        ]
        let leaks = PrivacyFilterPipeline.scanForLeaks(
            in: messages,
            ruleset: .allBuiltins()
        )
        #expect(leaks[.phone] == 1)
    }

    /// Multiple categories aggregate by category, not by raw count.
    @Test func scan_multipleCategories_aggregatesCounts() {
        let messages: [ChatMessage] = [
            ChatMessage(
                role: "user",
                content: "Email me at a@example.com or call 415-555-1234."
            ),
            ChatMessage(
                role: "user",
                content: "Backup contact: b@example.com."
            ),
        ]
        let leaks = PrivacyFilterPipeline.scanForLeaks(
            in: messages,
            ruleset: .allBuiltins()
        )
        #expect(leaks[.email] == 2)
        #expect(leaks[.phone] == 1)
    }

    /// Clean messages (or messages whose PII has been replaced by
    /// placeholders) leave the guard quiet. Placeholders like
    /// `[PHONE_1]` are deliberately shaped to NOT match the regex
    /// catalog — the brackets and prefix-underscore-digit form aren't
    /// digit runs, so the leak check is silent.
    @Test func scan_placeholders_doNotTriggerLeaks() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "Call me at [PHONE_1] today.")
        ]
        let leaks = PrivacyFilterPipeline.scanForLeaks(
            in: messages,
            ruleset: .allBuiltins()
        )
        #expect(leaks.isEmpty)
    }

    /// Turning off a built-in category in the config should silence
    /// BOTH the detection pass and the leak check. The settings panel
    /// promises this symmetry — if the user has explicitly said "stop
    /// flagging phones", we won't surprise them by blocking a send on
    /// a phone the model missed.
    @Test func scan_disabledCategory_doesNotLeak() {
        var config = PrivacyFilterConfiguration()
        config.builtinPatternEnabled[.phone] = false
        let ruleset = RegexEntityDetector.EffectiveRuleSet.build(from: config)

        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "Call me at 949-238-0232 today.")
        ]
        let leaks = PrivacyFilterPipeline.scanForLeaks(
            in: messages,
            ruleset: ruleset
        )
        #expect(leaks[.phone] == nil)
    }

    /// System messages are skipped by `scrubbableTexts()` (they're
    /// app-set boilerplate, not user input). Confirm the leak scanner
    /// inherits that behavior.
    @Test func scan_systemMessages_skipped() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: "Your phone is 949-238-0232."),
            ChatMessage(role: "user", content: "ok"),
        ]
        let leaks = PrivacyFilterPipeline.scanForLeaks(
            in: messages,
            ruleset: .allBuiltins()
        )
        #expect(leaks.isEmpty)
    }

    // MARK: - Code-block masking symmetry

    /// With `skipCodeBlocks: true` the scan must ignore PII inside
    /// inline code spans — detection masked them out, so the user was
    /// never shown (and could never review) those matches. Counting
    /// them here false-positive-blocked sends whose only "leak" was a
    /// URL in a backticked snippet (the reported "N URLs were not
    /// scrubbed" bug, typically triggered by markdown-formatted MCP
    /// tool results).
    @Test func scan_urlInInlineCode_maskedScan_doesNotLeak() {
        let messages: [ChatMessage] = [
            ChatMessage(
                role: "user",
                content: "Run `curl https://internal.example.com/health` to check."
            )
        ]
        let masked = PrivacyFilterPipeline.scanForLeaks(
            in: messages,
            ruleset: .allBuiltins(),
            skipCodeBlocks: true
        )
        #expect(masked[.url] == nil)

        // Unmasked scan still sees it — locks the pre-fix behavior so
        // callers that intentionally scan raw text keep doing so.
        let raw = PrivacyFilterPipeline.scanForLeaks(
            in: messages,
            ruleset: .allBuiltins(),
            skipCodeBlocks: false
        )
        #expect(raw[.url] == 1)
    }

    /// Same symmetry for fenced and indented blocks — the shapes
    /// `CodeBlockMasker` masks during detection.
    @Test func scan_urlsInFencedAndIndentedCode_maskedScan_doNotLeak() {
        let fenced = "Docs:\n```\nfetch(\"https://a.example.com/x\")\n```\ndone."
        let indented = "Steps:\n\n    open https://b.example.com/y\n    then submit"
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: fenced),
            ChatMessage(role: "user", content: indented),
        ]
        let masked = PrivacyFilterPipeline.scanForLeaks(
            in: messages,
            ruleset: .allBuiltins(),
            skipCodeBlocks: true
        )
        #expect(masked[.url] == nil)
    }

    /// Masking must not weaken the invariant for PII in plain prose:
    /// a URL outside any code span still counts as a leak with the
    /// masked scan enabled.
    @Test func scan_urlInProse_maskedScan_stillLeaks() {
        let messages: [ChatMessage] = [
            ChatMessage(
                role: "user",
                content: "See https://leak.example.com/profile and `safe_ident` here."
            )
        ]
        let leaks = PrivacyFilterPipeline.scanForLeaks(
            in: messages,
            ruleset: .allBuiltins(),
            skipCodeBlocks: true
        )
        #expect(leaks[.url] == 1)
    }

    // MARK: - formatScrubLeaked

    /// One category. The formatter is localization-driven, so we
    /// can't assert on the exact English phrasing here (xcstrings
    /// runtime lookup doesn't fire under `swift test`). We DO assert
    /// the count and category identifier survive — they're the
    /// non-translated payload the user needs to act on.
    @Test func formatScrubLeaked_singleCategory_pluralForm() {
        let msg = PrivacyFilterPipelineError.formatScrubLeaked(
            categoryCounts: [.phone: 2]
        )
        #expect(msg.contains("2"))
        #expect(msg.lowercased().contains(L("privacy.category.phone").lowercased()))
    }

    /// Two categories — the formatter joins them with a localized
    /// conjunction. The exact word ("and") is English-locale-only;
    /// the test asserts both category identifiers are present in
    /// the rendered string regardless.
    @Test func formatScrubLeaked_twoCategories_includesBoth() {
        let msg = PrivacyFilterPipelineError.formatScrubLeaked(
            categoryCounts: [.phone: 1, .email: 1]
        )
        #expect(msg.lowercased().contains(L("privacy.category.phone").lowercased()))
        #expect(msg.lowercased().contains(L("privacy.category.email").lowercased()))
    }

    /// Whatever the categories, the value of a leaked entity never
    /// appears in the rendered error. We assert this with a fabricated
    /// raw PII string — the formatter is purely a category+count
    /// shape and shouldn't have any path to leak the value back.
    @Test func formatScrubLeaked_neverEchoesRawPII() {
        // Sanity: the formatter takes counts, not values, so the only
        // way the value could end up in the message is via a future
        // refactor that adds an argument for it. Lock that out.
        let msg = PrivacyFilterPipelineError.formatScrubLeaked(
            categoryCounts: [.phone: 1, .email: 1, .accountNumber: 1]
        )
        #expect(!msg.contains("949-238-0232"))
        #expect(!msg.contains("alice@example.com"))
    }

    /// `scrubLeaked` equality is value-based on the dictionary so the
    /// chat layer can pattern-match a specific case if it ever wants
    /// to vary the bubble text.
    @Test func scrubLeakedError_isEquatable() {
        let a = PrivacyFilterPipelineError.scrubLeaked(categoryCounts: [.phone: 1])
        let b = PrivacyFilterPipelineError.scrubLeaked(categoryCounts: [.phone: 1])
        let c = PrivacyFilterPipelineError.scrubLeaked(categoryCounts: [.phone: 2])
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - applyOutbound end-to-end (regex-only)

    /// Regex-only auto-approve config so `applyOutbound` runs without
    /// the on-device model or a review presenter.
    private static func regexOnlyAutoApproveConfig() -> PrivacyFilterConfiguration {
        var config = PrivacyFilterConfiguration()
        config.enabled = true
        config.aiDetectionEnabled = false
        config.alwaysApproveByDefault = true
        return config
    }

    /// Carry-over substitution dirties an EARLIER assistant message
    /// that contains URLs the detection pass never scanned (detection
    /// only covers the latest user turn). Those URLs must not trip
    /// the leak invariant — they were never reviewable. This was the
    /// second path to the false "N URLs were not scrubbed" block.
    @Test func applyOutbound_carryOverDirtiedHistory_doesNotBlockOnUnscannedURLs() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PostScrubInvariant-carryOver")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.regexOnlyAutoApproveConfig())

        let sid = "post-scrub-carryover-\(UUID().uuidString)"
        let providerId = UUID()
        let email = "carrytest@example.com"

        // Turn 1: interns the email into the session map.
        let turn1: [ChatMessage] = [
            ChatMessage(role: "user", content: "Contact me at \(email) please.")
        ]
        let (scrubbed1, map1) = try await PrivacyFilterPipeline.applyOutbound(
            messages: turn1,
            sessionId: sid,
            providerId: providerId
        )
        #expect(map1 != nil)
        #expect(scrubbed1.first?.content.map { !$0.contains(email) } == true)

        // Turn 2: the assistant's prior reply echoes the email (raw,
        // as clients resend unscrubbed history) AND contains two URLs
        // the model emitted itself. Carry-over substitution rewrites
        // the email there, dirtying the message; the URLs were never
        // in detection scope and must not block.
        let turn2: [ChatMessage] = [
            ChatMessage(role: "user", content: "Contact me at \(email) please."),
            ChatMessage(
                role: "assistant",
                content:
                    "Sent to \(email). See https://a.example.com/docs and https://b.example.com/faq for details."
            ),
            ChatMessage(role: "user", content: "Thanks, also call 949-238-0232."),
        ]
        let (scrubbed2, _) = try await PrivacyFilterPipeline.applyOutbound(
            messages: turn2,
            sessionId: sid,
            providerId: providerId
        )
        let assistantBody = scrubbed2[1].content ?? ""
        #expect(!assistantBody.contains(email), "carry-over email should be re-scrubbed")
        #expect(assistantBody.contains("https://a.example.com/docs"), "historic URLs ship as-is")
        let userBody = scrubbed2[2].content ?? ""
        #expect(!userBody.contains("949-238-0232"), "latest-turn phone should be scrubbed")
    }

    /// A URL inside inline code sitting next to real (approved) PII in
    /// the same message. Detection masks the code span, the email
    /// substitution dirties the message, and the re-scan must not
    /// count the masked URL as a leak. This was the primary path to
    /// the false "N URLs were not scrubbed" block.
    @Test func applyOutbound_urlInCodeSpanNextToApprovedPII_doesNotBlock() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PostScrubInvariant-codeSpan")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.regexOnlyAutoApproveConfig())

        let sid = "post-scrub-codespan-\(UUID().uuidString)"
        let messages: [ChatMessage] = [
            ChatMessage(
                role: "user",
                content:
                    "Email codespan@example.com the snippet `curl https://internal.example.com/v1` today."
            )
        ]
        let (scrubbed, _) = try await PrivacyFilterPipeline.applyOutbound(
            messages: messages,
            sessionId: sid,
            providerId: UUID()
        )
        let body = scrubbed.first?.content ?? ""
        #expect(!body.contains("codespan@example.com"), "email should be scrubbed")
        #expect(body.contains("https://internal.example.com/v1"), "code-span URL ships as-is")
    }

    /// Tool-call arguments where the URL is followed by a JSON escape
    /// sequence (`\n`) in the raw serialized text. Detection must scan
    /// the DECODED string leaves (same view substitution rewrites) so
    /// the original matches at scrub time; the old raw-JSON scan
    /// captured `...path\nthen` verbatim, substitution no-op'd, and
    /// the per-original assertion blocked the send as a URL leak.
    @Test func applyOutbound_toolArgsWithJSONEscapes_scrubsCleanly() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PostScrubInvariant-toolArgs")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.regexOnlyAutoApproveConfig())

        let sid = "post-scrub-toolargs-\(UUID().uuidString)"
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "Fetch my dashboard."),
            ChatMessage(
                role: "assistant",
                content: nil,
                tool_calls: [
                    ToolCall(
                        id: "call_1",
                        type: "function",
                        function: ToolCallFunction(
                            name: "fetch",
                            arguments: "{\"note\":\"open https://dash.example.com/u/42\\nthen report back\"}"
                        ),
                        geminiThoughtSignature: nil
                    )
                ],
                tool_call_id: nil,
                reasoning_content: nil
            ),
        ]
        let (scrubbed, _) = try await PrivacyFilterPipeline.applyOutbound(
            messages: messages,
            sessionId: sid,
            providerId: UUID()
        )
        let args = scrubbed[1].tool_calls?.first?.function.arguments ?? ""
        #expect(!args.contains("https://dash.example.com"), "tool-arg URL should be scrubbed")
        #expect(args.contains("[URL_"), "tool-arg URL should be replaced by a placeholder")
        #expect(args.contains("then report back"), "non-PII leaf text preserved")
    }
}
