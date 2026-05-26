//
//  PrivacyFilterPipelineCancelTests.swift
//  osaurus / PrivacyFilter Tests
//
//  Covers the `PrivacyFilterPipelineError.reviewCanceled` contract:
//  when the user dismisses the redaction review sheet,
//  `applyOutbound` throws (rather than returning an empty-message
//  sentinel). Callers like `RemoteProviderService` rely on this to
//  abort the send before any HTTP traffic.
//
//  We can't drive the real model from a unit test, but we can
//  validate the cancel path is wired correctly by directly exercising
//  the state's `cancel()` action against an isolated service +
//  presenter pair, and asserting the resulting outcome maps to a
//  thrown error in scrub-equivalent helpers.
//

import Foundation
import Testing

@testable import OsaurusCore

// Serialized for the same reason as `PrivacyReviewServiceTests`:
// shared singleton + `withTaskCancellationHandler` continuations
// don't compose with parallel @MainActor tests.
@Suite("PrivacyFilterPipeline cancel", .serialized)
@MainActor
struct PrivacyFilterPipelineCancelTests {

    /// Direct test of the typed error: confirms it conforms to
    /// `Equatable` so call sites can do `catch PrivacyFilterPipelineError.reviewCanceled`
    /// in pattern matches without an extra cast.
    @Test func reviewCanceledError_isEquatable() {
        let a = PrivacyFilterPipelineError.reviewCanceled
        let b = PrivacyFilterPipelineError.reviewCanceled
        #expect(a == b)
    }

    /// Each error case carries a non-empty `localizedDescription`.
    /// The chat layer surfaces this verbatim, so blank or
    /// stack-trace-only strings would land in the bubble as visible
    /// junk for the user.
    @Test func errorCases_haveActionableLocalizedDescriptions() {
        let cases: [PrivacyFilterPipelineError] = [
            .reviewCanceled,
            .engineUnavailable("test detail"),
            .scrubNoOp(approvedCount: 2),
        ]
        for error in cases {
            let desc = error.localizedDescription
            #expect(!desc.isEmpty, "\(error) has empty localizedDescription")
            #expect(
                !desc.lowercased().contains("the operation couldn't be completed"),
                "\(error) falls back to the generic NSError description: \(desc)"
            )
        }
        // The engine-unavailable variant should mention the action the
        // user needs to take so the chat bubble is self-explanatory.
        let engineErr = PrivacyFilterPipelineError.engineUnavailable("model missing")
        #expect(
            engineErr.localizedDescription.contains("Settings"),
            "engineUnavailable should point the user at Settings"
        )
    }

    /// `engineUnavailable` and `scrubNoOp` are distinct values so the
    /// chat layer can branch on them if it ever wants to.
    @Test func errorCases_distinctValues() {
        #expect(
            PrivacyFilterPipelineError.engineUnavailable("a")
                != PrivacyFilterPipelineError.engineUnavailable("b")
        )
        #expect(
            PrivacyFilterPipelineError.scrubNoOp(approvedCount: 1)
                != PrivacyFilterPipelineError.scrubNoOp(approvedCount: 2)
        )
        #expect(
            PrivacyFilterPipelineError.reviewCanceled
                != PrivacyFilterPipelineError.engineUnavailable("x")
        )
    }

    /// End-to-end: when the registered presenter calls `state.cancel()`
    /// (as the Cancel-send button does), the review outcome propagates
    /// as `.canceled` from `PrivacyReviewService.review`. This is the
    /// resolution that `applyOutbound` translates into the thrown
    /// `reviewCanceled` error.
    @Test func presenterCancel_resolvesAsCanceled() async {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyFilterPipelineCancelTests")
        defer { guard_.release() }

        let service = PrivacyReviewService.shared
        PrivacyFilterStore.save(PrivacyFilterConfiguration())

        let token = service.registerPresenter { state in
            // Resolve immediately as cancel — same shape as the
            // Cancel-send button click.
            state.cancel()
        }
        defer { service.unregisterPresenter(token) }

        let map = RedactionMap(conversationID: UUID())
        let placeholder = await map.intern("Dan", as: .person)
        let detection = DetectedEntity(
            category: .person,
            original: "Dan",
            range: "Dan".startIndex ..< "Dan".endIndex,
            placeholder: placeholder,
            approved: true
        )

        let outcome = await service.review(
            detections: [detection],
            sessionId: "session-cancel-roundtrip"
        )
        if case .canceled = outcome {
            // Expected.
        } else {
            Issue.record("Expected .canceled, got \(outcome)")
        }
    }
}
