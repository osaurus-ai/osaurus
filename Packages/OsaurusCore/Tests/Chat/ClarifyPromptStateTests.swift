//
//  ClarifyPromptStateTests.swift
//  osaurusTests
//
//  Pins down the resolve-once semantics of `ClarifyPromptState`. The
//  state is the contract between the agent-loop intercept and the
//  inline overlay: `submit(answer:)` dispatches the user's reply,
//  `cancel()` walks away. Both must be idempotent so the overlay's
//  `onDisappear` safety net can fire after an explicit resolution
//  without re-firing the answer or double-counting cancels.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct ClarifyPromptStateTests {

    @Test
    func submit_callsOnceAndStripsWhitespace() {
        var received: [String] = []
        let state = ClarifyPromptState(
            question: "Pick",
            options: [],
            allowMultiple: false,
            onSubmit: { received.append($0) }
        )

        // Trailing newline + spaces should be trimmed; the answer is
        // what the model sees in the next turn so leftover whitespace
        // would muddy the intent.
        state.submit("  yes\n")
        #expect(received == ["yes"])

        // Subsequent submits no-op (resolved guard) so accidental
        // double-clicks don't dispatch twice.
        state.submit("again")
        #expect(received == ["yes"])
    }

    @Test
    func submit_ignoresEmptyAnswers() {
        var received: [String] = []
        let state = ClarifyPromptState(
            question: "Pick",
            onSubmit: { received.append($0) }
        )

        // Whitespace-only input is rejected silently — the UI's submit
        // button should be disabled in this state, but the gate here
        // makes the contract robust against any caller that forgets.
        state.submit("   ")
        #expect(received.isEmpty)

        // Crucially: the empty submit must NOT mark the state as
        // resolved, otherwise a real answer afterwards would be
        // swallowed.
        state.submit("real answer")
        #expect(received == ["real answer"])
    }

    @Test
    func cancel_isIdempotentAndDoesNotCallSubmit() {
        var submitCalls = 0
        var cancelCalls = 0
        let state = ClarifyPromptState(
            question: "Pick",
            onSubmit: { _ in submitCalls += 1 },
            onCancel: { cancelCalls += 1 }
        )

        // Simulates the overlay's `onDisappear` safety net firing
        // multiple times (e.g. parent view tear-down + explicit ESC).
        state.cancel()
        state.cancel()
        state.cancel()

        #expect(cancelCalls == 1)
        #expect(submitCalls == 0)
    }

    @Test
    func cancelAfterSubmit_isNoOp() {
        var submitCalls = 0
        var cancelCalls = 0
        let state = ClarifyPromptState(
            question: "Pick",
            onSubmit: { _ in submitCalls += 1 },
            onCancel: { cancelCalls += 1 }
        )

        // Real flow: user submits, then SwiftUI later tears the
        // overlay down and calls cancel() as a safety net. The cancel
        // should be a no-op since submission already resolved the state.
        state.submit("yes")
        state.cancel()

        #expect(submitCalls == 1)
        #expect(cancelCalls == 0)
    }

    @Test
    func allowMultiple_collapsesWhenNoOptions() {
        // A free-form question can't be "multi-select" — the toggle
        // only makes sense alongside options. Construct one anyway and
        // verify the state collapses it so callers don't have to guard.
        let state = ClarifyPromptState(
            question: "Why?",
            options: [],
            allowMultiple: true,
            onSubmit: { _ in }
        )
        #expect(state.allowMultiple == false)
    }
}
