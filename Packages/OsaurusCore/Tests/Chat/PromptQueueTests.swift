//
//  PromptQueueTests.swift
//  osaurusTests
//
//  Verifies the FIFO + single-slot semantics of `PromptQueue`. The
//  queue is the contract that keeps secret prompts and clarify prompts
//  from stacking on top of each other in the chat overlay; a regression
//  here would let two cards co-exist on screen and confuse the user.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct PromptQueueTests {

    // MARK: - Helpers

    private func makeClarify(_ question: String) -> ClarifyPromptState {
        ClarifyPromptState(question: question, onSubmit: { _ in })
    }

    /// Build a SecretPromptState with a no-op continuation. Uses a
    /// random UUID for the agentId so `submit` doesn't actually write
    /// to the keychain (the value is rejected before save when no
    /// matching agent exists in tests, but cancel() is what we care
    /// about and that path doesn't touch the keychain at all).
    private func makeSecret(_ key: String) -> SecretPromptState {
        SecretPromptState(
            key: key,
            description: "desc",
            instructions: "inst",
            agentId: UUID().uuidString,
            completion: { _ in }
        )
    }

    // MARK: - FIFO ordering

    @Test
    func enqueueOnEmptyMountsImmediately() {
        let queue = PromptQueue()
        let s = makeClarify("first")
        queue.enqueue(.clarify(s))

        guard case .clarify(let mounted) = queue.current else {
            Issue.record("expected the clarify state to mount as current")
            return
        }
        #expect(mounted === s)
    }

    @Test
    func enqueueWhileMountedQueuesBehind() {
        let queue = PromptQueue()
        let first = makeClarify("first")
        let second = makeClarify("second")

        queue.enqueue(.clarify(first))
        queue.enqueue(.clarify(second))

        // First is still mounted; second is waiting.
        guard case .clarify(let mounted) = queue.current else {
            Issue.record("expected first prompt to remain current")
            return
        }
        #expect(mounted === first)
    }

    @Test
    func advanceMountsNextPending_FIFOOrder() {
        let queue = PromptQueue()
        let first = makeClarify("first")
        let second = makeSecret("second")
        let third = makeClarify("third")

        queue.enqueue(.clarify(first))
        queue.enqueue(.secret(second))
        queue.enqueue(.clarify(third))

        queue.advance()
        guard case .secret(let nowMounted) = queue.current else {
            Issue.record("expected second (secret) prompt to mount after advance")
            return
        }
        #expect(nowMounted === second)

        queue.advance()
        guard case .clarify(let lastMounted) = queue.current else {
            Issue.record("expected third (clarify) prompt to mount after second advance")
            return
        }
        #expect(lastMounted === third)

        queue.advance()
        #expect(queue.current == nil)
    }

    @Test
    func advanceOnEmptyIsNoOp() {
        // Defensive: the .overlay closure may call advance() after
        // SwiftUI has already drained the queue (e.g. session reset
        // racing with a user dismissing the card). It must not crash
        // or magically resurrect a prompt.
        let queue = PromptQueue()
        queue.advance()
        queue.advance()
        #expect(queue.current == nil)
    }

    // MARK: - Drain

    @Test
    func drainAllCancelsAndClears() {
        let queue = PromptQueue()
        let first = makeClarify("first")
        let second = makeClarify("second")

        // Track cancels by checking idempotency post-drain — a second
        // cancel() on a resolved state is a no-op, so if drain resolved
        // them we can't observe a second resolution. Use the
        // `submit("x")` path: after drain, submit should be ignored
        // (the state is already resolved).
        var firstSubmitFired = false
        let firstWithCallback = ClarifyPromptState(
            question: "first",
            onSubmit: { _ in firstSubmitFired = true }
        )
        var secondSubmitFired = false
        let secondWithCallback = ClarifyPromptState(
            question: "second",
            onSubmit: { _ in secondSubmitFired = true }
        )

        queue.enqueue(.clarify(firstWithCallback))
        queue.enqueue(.clarify(secondWithCallback))
        // Sanity: the helpers above are still valid via reference.
        _ = first
        _ = second

        queue.drainAll()
        #expect(queue.current == nil)

        // Both states are now resolved (cancel marked them) so any
        // post-drain submit is silently dropped — no answers leak into
        // a brand new conversation.
        firstWithCallback.submit("late answer")
        secondWithCallback.submit("late answer")
        #expect(firstSubmitFired == false)
        #expect(secondSubmitFired == false)
    }

    @Test
    func drainAllOnEmptyIsNoOp() {
        let queue = PromptQueue()
        queue.drainAll()
        #expect(queue.current == nil)
    }

    // MARK: - Mixed types

    @Test
    func secretsAndClarifyShareTheQueue() {
        let queue = PromptQueue()
        let secret = makeSecret("API_KEY")
        let clarify = makeClarify("Use Postgres or SQLite?")

        queue.enqueue(.secret(secret))
        queue.enqueue(.clarify(clarify))

        // Secret arrived first → it stays mounted; clarify waits behind.
        if case .secret = queue.current {
        } else {
            Issue.record("expected secret to be current after first enqueue")
        }

        queue.advance()
        if case .clarify = queue.current {
        } else {
            Issue.record("expected clarify to be current after advance")
        }
    }
}
