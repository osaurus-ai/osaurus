//
//  PrivacyReviewNonInteractiveTests.swift
//  osaurus / PrivacyFilter Tests
//
//  Pins the request-origin gate on interactive privacy review: HTTP
//  API / plugin / P2P requests must NEVER suspend on the review sheet,
//  even when a chat window has registered a presenter. Before this
//  gate, a server-origin `/v1/chat/completions` request that tripped
//  PII detection would pop the sheet over an unrelated chat window and
//  hang the HTTP client until the user noticed. Non-UI origins now
//  either fail closed with the typed
//  `PrivacyFilterPipelineError.reviewRequiresInteractive` (default) or
//  auto-approve when `requireReviewForNonInteractive` is off.
//

import Foundation
import Testing

@testable import OsaurusCore

// `.serialized` for the same reason as PrivacyReviewServiceTests:
// every test mutates the shared presenter registry and the
// PrivacyFilterStore snapshot cache.
@Suite("Privacy review non-interactive gate", .serialized)
@MainActor
struct PrivacyReviewNonInteractiveTests {

    private static func makeDetection(_ name: String = "Alice") async -> DetectedEntity {
        let map = RedactionMap(conversationID: UUID())
        let placeholder = await map.intern(name, as: .person)
        return DetectedEntity(
            category: .person,
            original: name,
            range: name.startIndex ..< name.endIndex,
            placeholder: placeholder,
            approved: true
        )
    }

    /// Regex-only filter config so `applyOutbound` runs without the
    /// on-device model. `alwaysApproveByDefault` stays OFF so fresh
    /// detections actually reach the review gate.
    private static func regexOnlyConfig(
        requireReviewForNonInteractive: Bool
    ) -> PrivacyFilterConfiguration {
        var config = PrivacyFilterConfiguration()
        config.enabled = true
        config.aiDetectionEnabled = false
        config.alwaysApproveByDefault = false
        config.requireReviewForNonInteractive = requireReviewForNonInteractive
        return config
    }

    // MARK: - PrivacyReviewService.review origin gate

    /// The core hang fix: a registered presenter must NOT be used for
    /// a non-interactive caller. With the fail-closed default on, the
    /// outcome is the typed block — not a suspended continuation.
    @Test func nonInteractive_withPresenterRegistered_blocksWithoutPresenting() async {
        let guard_ = await acquirePrivacyStoreSandbox("NonInteractive-block")
        defer { guard_.release() }

        let service = PrivacyReviewService.shared
        PrivacyFilterStore.save(PrivacyFilterConfiguration())  // requireReview default: true

        var presenterFired = false
        let token = service.registerPresenter { _ in presenterFired = true }
        defer { service.unregisterPresenter(token) }

        let detection = await Self.makeDetection()
        let outcome = await service.review(
            detections: [detection],
            sessionId: "session-non-interactive-block",
            allowInteractive: false
        )
        if case .blockedNonInteractive = outcome {
            // Expected: fail closed, no sheet.
        } else {
            Issue.record("Expected .blockedNonInteractive, got \(outcome)")
        }
        #expect(presenterFired == false, "review sheet must never present for non-UI origins")
    }

    /// Power-user opt-out: with `requireReviewForNonInteractive` off,
    /// the non-interactive caller auto-approves — still without ever
    /// touching the presenter.
    @Test func nonInteractive_withOptOut_autoApprovesWithoutPresenting() async {
        let guard_ = await acquirePrivacyStoreSandbox("NonInteractive-optout")
        defer { guard_.release() }

        let service = PrivacyReviewService.shared
        var config = PrivacyFilterConfiguration()
        config.requireReviewForNonInteractive = false
        PrivacyFilterStore.save(config)
        defer { PrivacyFilterStore.save(PrivacyFilterConfiguration()) }

        var presenterFired = false
        let token = service.registerPresenter { _ in presenterFired = true }
        defer { service.unregisterPresenter(token) }

        let detection = await Self.makeDetection("Bob")
        let outcome = await service.review(
            detections: [detection],
            sessionId: "session-non-interactive-optout",
            allowInteractive: false
        )
        if case .approved(let entities) = outcome {
            #expect(entities.count == 1)
        } else {
            Issue.record("Expected .approved, got \(outcome)")
        }
        #expect(presenterFired == false)
    }

    // MARK: - Pipeline typed error

    /// End-to-end (regex-only): an HTTP-origin request with fresh PII
    /// throws the typed `reviewRequiresInteractive` error instead of
    /// suspending on the registered presenter. The error carries the
    /// detection count and maps to a 422 with a stable code so API
    /// clients can react programmatically.
    @Test func applyOutbound_httpOrigin_failsClosedWithTypedError() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("NonInteractive-pipeline")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.regexOnlyConfig(requireReviewForNonInteractive: true))
        defer { PrivacyFilterStore.save(PrivacyFilterConfiguration()) }

        var presenterFired = false
        let token = PrivacyReviewService.shared.registerPresenter { _ in presenterFired = true }
        defer { PrivacyReviewService.shared.unregisterPresenter(token) }

        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "Contact me at pipeline-block@example.com.")
        ]
        do {
            _ = try await PrivacyFilterPipeline.applyOutbound(
                messages: messages,
                sessionId: "pf-non-interactive-\(UUID().uuidString)",
                providerId: UUID(),
                requestSource: .httpAPI
            )
            Issue.record("Expected reviewRequiresInteractive to be thrown")
        } catch let error as PrivacyFilterPipelineError {
            guard case .reviewRequiresInteractive(let count) = error else {
                Issue.record("Expected .reviewRequiresInteractive, got \(error)")
                return
            }
            #expect(count == 1)
            #expect(error.httpErrorCode == "privacy_filter_review_required")
            #expect(error.httpStatus == 422)
            #expect(!error.localizedDescription.isEmpty)
        }
        #expect(presenterFired == false, "HTTP-origin request must not pop the review sheet")
    }

    /// With the opt-out flipped, the same HTTP-origin request
    /// auto-approves and ships scrubbed — no sheet, no error.
    @Test func applyOutbound_httpOrigin_withOptOut_scrubsAndSends() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("NonInteractive-pipeline-optout")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.regexOnlyConfig(requireReviewForNonInteractive: false))
        defer { PrivacyFilterStore.save(PrivacyFilterConfiguration()) }

        var presenterFired = false
        let token = PrivacyReviewService.shared.registerPresenter { _ in presenterFired = true }
        defer { PrivacyReviewService.shared.unregisterPresenter(token) }

        let email = "pipeline-optout@example.com"
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "Contact me at \(email).")
        ]
        let (scrubbed, map) = try await PrivacyFilterPipeline.applyOutbound(
            messages: messages,
            sessionId: "pf-non-interactive-optout-\(UUID().uuidString)",
            providerId: UUID(),
            requestSource: .httpAPI
        )
        #expect(map != nil)
        #expect(scrubbed.first?.content.map { !$0.contains(email) } == true)
        #expect(presenterFired == false)
    }
}
