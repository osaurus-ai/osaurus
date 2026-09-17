//
//  PrivacyReviewModeTests.swift
//  osaurus / PrivacyFilter Tests
//
//  Delegated loops (Computer Use, AppleScript) send with `.autoScrub`:
//  fresh detections are redacted without opening the review sheet, which
//  would otherwise sit unanswered in the chat window until the loop's
//  per-step timeout failed the run. Also pins the multimodal diff: text
//  inside `contentParts` (screenshot messages) counts as a change, so a
//  redaction found only there doesn't fail the send as `scrubNoOp`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Privacy review mode")
struct PrivacyReviewModeTests {

    private static func reviewRequiredConfig() -> PrivacyFilterConfiguration {
        var config = PrivacyFilterConfiguration()
        config.enabled = true
        config.aiDetectionEnabled = false
        config.alwaysApproveByDefault = false
        return config
    }

    @MainActor
    @Test func autoScrub_redactsWithoutPresentingReview() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyReviewMode-autoScrub")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.reviewRequiredConfig())

        var presentations = 0
        let token = PrivacyReviewService.shared.registerPresenter { _ in presentations += 1 }
        defer { PrivacyReviewService.shared.unregisterPresenter(token) }

        let phone = "949-238-0232"
        let messages = [ChatMessage(role: "user", content: "Downloads has a file from \(phone).")]
        let (scrubbed, map) = try await PrivacyFilterPipeline.applyOutbound(
            messages: messages,
            sessionId: "review-mode-\(UUID().uuidString)",
            providerId: UUID(),
            requestSource: .chatUI,
            reviewMode: .autoScrub
        )
        #expect(presentations == 0, "auto-scrub must never open the review sheet")
        #expect(map != nil)
        #expect(scrubbed.first?.content?.contains(phone) == false)
        #expect(scrubbed.first?.content?.contains("[PHONE_1]") == true)
    }

    @MainActor
    @Test func autoScrub_keepsSessionSkipsSkipped() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyReviewMode-skips")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.reviewRequiredConfig())

        let sid = "review-mode-skip-\(UUID().uuidString)"
        let phone = "949-238-0232"
        let map = await SessionRedactionStore.shared.getOrCreate(sid, conversationID: UUID())
        await map.markSkipped([phone])

        let messages = [ChatMessage(role: "user", content: "Call \(phone).")]
        let (scrubbed, _) = try await PrivacyFilterPipeline.applyOutbound(
            messages: messages,
            sessionId: sid,
            providerId: UUID(),
            requestSource: .chatUI,
            reviewMode: .autoScrub
        )
        #expect(scrubbed.first?.content?.contains(phone) == true)
    }

    @MainActor
    @Test func autoScrub_redactionOnlyInContentParts_doesNotFailAsNoOp() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyReviewMode-parts")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.reviewRequiredConfig())

        let phone = "949-238-0232"
        let messages = [
            ChatMessage(
                role: "user",
                content: nil,
                contentParts: [.text("Screenshot of Finder. Visible file: invoice-\(phone).pdf")]
            )
        ]
        let (scrubbed, _) = try await PrivacyFilterPipeline.applyOutbound(
            messages: messages,
            sessionId: "review-mode-parts-\(UUID().uuidString)",
            providerId: UUID(),
            requestSource: .chatUI,
            reviewMode: .autoScrub
        )
        let text = scrubbed.first?.contentParts?.compactMap { part -> String? in
            if case .text(let t) = part { return t }
            return nil
        }.joined() ?? ""
        #expect(!text.contains(phone))
        #expect(text.contains("[PHONE_1]"))
    }
}
