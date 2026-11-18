//
//  PrivacyReviewServiceTests.swift
//  osaurus / PrivacyFilter Tests
//
//  Locks in the cancel + presenter-token contracts on
//  `PrivacyReviewService.review`:
//
//    • `Task.cancel()` while suspended on the review continuation
//      resolves the outcome as `.canceled` via
//      `withTaskCancellationHandler` and the registered state's
//      `cancel()` (no leaked suspensions).
//    • `unregisterPresenter(_:)` takes a token and only drops *that*
//      registration — a second window's presenter stays intact.
//    • A review goes to the window that owns its conversation, and
//      falls back to the newest window for unowned scopes.
//

import Foundation
import Testing

@testable import OsaurusCore

// `.serialized` because every test in this suite mutates the global
// `PrivacyReviewService.shared` (presenter registry + open states)
// and `PrivacyFilterStore.snapshot()` cache. Running them in parallel
// would interleave registrations/saves and (more importantly) the
// `withTaskCancellationHandler` paths can starve each other on the
// main actor when two tests both park on their continuations
// concurrently. Serialized: one test at a time on the main actor.
@Suite("PrivacyReviewService", .serialized)
@MainActor
struct PrivacyReviewServiceTests {

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

    // MARK: - Cancellation

    /// Stop button equivalent: cancelling the surrounding Task should
    /// resolve the review as `.canceled`, not hang the continuation
    /// (the original `withCheckedContinuation` implementation did).
    @Test func taskCancellation_resolvesAsCanceled() async {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyReviewServiceTests")
        defer { guard_.release() }

        // Use a fresh service to avoid cross-test bleed via the shared
        // singleton's open-state map.
        let service = PrivacyReviewService.shared
        // Defensive: ensure no stale config short-circuits the test.
        PrivacyFilterStore.save(PrivacyFilterConfiguration())

        // Capture the state so we know the sheet would have appeared.
        // We don't actually present anything — the test just needs a
        // presenter closure to be registered.
        var presentedState: RedactionReviewState?
        let token = service.registerPresenter { state in
            presentedState = state
        }
        defer { service.unregisterPresenter(token) }

        let detection = await Self.makeDetection()

        let outcomeTask = Task<PrivacyReviewOutcome, Never> {
            await service.review(detections: [detection], sessionId: "session-cancel-test")
        }

        // Give the review Task a runloop turn to register on the
        // continuation. Without this, `cancel()` races with the
        // suspension and may resolve before the cancellation handler
        // is installed.
        await Task.yield()
        await Task.yield()

        outcomeTask.cancel()
        let outcome = await outcomeTask.value
        if case .canceled = outcome {
            // Expected.
        } else {
            Issue.record("Expected .canceled outcome, got \(outcome)")
        }
        // The presenter still saw the state (the sheet would have
        // appeared); cancellation just resolved before the user did.
        #expect(presentedState != nil)
    }

    // MARK: - Presenter tokens

    /// Two registered presenters; unregistering the older one must
    /// leave the newer one routable. This is the regression we hit
    /// when chat windows clobbered each other's registration on
    /// close.
    @Test func presenterToken_unregisterOnlyMatching() async {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyReviewServiceTests")
        defer { guard_.release() }

        let service = PrivacyReviewService.shared
        PrivacyFilterStore.save(PrivacyFilterConfiguration())

        var firstSaw: RedactionReviewState?
        var secondSaw: RedactionReviewState?

        let first = service.registerPresenter { state in firstSaw = state }
        let second = service.registerPresenter { state in secondSaw = state }
        defer {
            service.unregisterPresenter(first)
            service.unregisterPresenter(second)
        }

        // Drop the *first* registration — second should remain the
        // active presenter.
        service.unregisterPresenter(first)

        let detection = await Self.makeDetection("Bob")
        let reviewTask = Task<PrivacyReviewOutcome, Never> {
            await service.review(
                detections: [detection],
                sessionId: "session-token-test"
            )
        }
        // Yield so the presenter closure fires before we resolve.
        await Task.yield()
        await Task.yield()

        // Cancel to clean up the awaiting Task.
        reviewTask.cancel()
        _ = await reviewTask.value

        // Only the second presenter should have been called.
        #expect(firstSaw == nil)
        #expect(secondSaw != nil)
    }

    // MARK: - Owner routing

    /// The window that owns the conversation presents its review even
    /// when another window registered later, and the sheet starts on
    /// the conversation's policy.
    @Test func review_routesToOwningWindow() async {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyReviewServiceTests")
        defer { guard_.release() }

        let service = PrivacyReviewService.shared
        PrivacyFilterStore.save(PrivacyFilterConfiguration())
        let scope = "owner-scope-\(UUID().uuidString)"
        await SessionRedactionStore.shared.setPolicy(scope, .autoRedact)
        defer { Task { await SessionRedactionStore.shared.invalidate(scope) } }

        var ownerSaw: RedactionReviewState?
        var otherSaw: RedactionReviewState?
        let owner = service.registerPresenter(owns: { $0 == scope }) { ownerSaw = $0 }
        let other = service.registerPresenter { otherSaw = $0 }
        defer {
            service.unregisterPresenter(owner)
            service.unregisterPresenter(other)
        }

        let detection = await Self.makeDetection("Dana")
        let reviewTask = Task<PrivacyReviewOutcome, Never> {
            await service.review(detections: [detection], sessionId: scope)
        }
        for _ in 0 ..< 10 where ownerSaw == nil { await Task.yield() }
        reviewTask.cancel()
        _ = await reviewTask.value

        #expect(ownerSaw != nil)
        #expect(otherSaw == nil)
        #expect(ownerSaw?.policy == .autoRedact)
    }

    /// No window claims the scope (HTTP-style session id): the newest
    /// registration presents, as before owner routing existed.
    @Test func review_unownedScope_fallsBackToNewestWindow() async {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyReviewServiceTests")
        defer { guard_.release() }

        let service = PrivacyReviewService.shared
        PrivacyFilterStore.save(PrivacyFilterConfiguration())

        var firstSaw: RedactionReviewState?
        var secondSaw: RedactionReviewState?
        let first = service.registerPresenter(owns: { $0 == "someone-else" }) { firstSaw = $0 }
        let second = service.registerPresenter { secondSaw = $0 }
        defer {
            service.unregisterPresenter(first)
            service.unregisterPresenter(second)
        }

        let detection = await Self.makeDetection("Eve")
        let reviewTask = Task<PrivacyReviewOutcome, Never> {
            await service.review(detections: [detection], sessionId: "unowned-\(UUID().uuidString)")
        }
        for _ in 0 ..< 10 where secondSaw == nil { await Task.yield() }
        reviewTask.cancel()
        _ = await reviewTask.value

        #expect(firstSaw == nil)
        #expect(secondSaw != nil)
    }

    /// While a review waits on the user, the chat it belongs to is waiting
    /// on a person, not stuck; answering it ends that.
    @Test func openReview_marksScopeAwaitingUntilAnswered() async {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyReviewServiceTests")
        defer { guard_.release() }

        let service = PrivacyReviewService.shared
        PrivacyFilterStore.save(PrivacyFilterConfiguration())
        let scope = UUID().uuidString

        var presented: RedactionReviewState?
        let token = service.registerPresenter { presented = $0 }
        defer { service.unregisterPresenter(token) }

        let detection = await Self.makeDetection("Frank")
        let reviewTask = Task<PrivacyReviewOutcome, Never> {
            await service.review(detections: [detection], sessionId: scope)
        }
        for _ in 0 ..< 10 where presented == nil { await Task.yield() }

        #expect(service.isAwaitingReview(scopeId: scope))
        #expect(!service.isAwaitingReview(scopeId: "another-chat"))
        #expect(RunProgressLoadingPhase.current(agentId: nil, sessionId: scope) == .privacyReview)

        presented?.confirm()
        _ = await reviewTask.value
        for _ in 0 ..< 10 where service.isAwaitingReview(scopeId: scope) { await Task.yield() }
        #expect(!service.isAwaitingReview(scopeId: scope))
    }
}
