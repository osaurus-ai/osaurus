//
//  PromptQueue.swift
//  osaurus
//
//  Single-slot FIFO queue for in-chat prompt overlays. Secrets and
//  clarify prompts share the same on-screen real estate (bottom-pinned
//  card above the input bar), so they MUST be mutually exclusive in
//  render — otherwise two cards would stack and the user wouldn't know
//  which one they're answering.
//
//  Ordering is FIFO by arrival; `enqueue` mounts the first prompt
//  immediately, subsequent prompts wait. `advance()` is called once
//  the current prompt resolves (submit/cancel via the overlay closure)
//  and immediately mounts the next one if any.
//
//  Reset paths (`session.reset()`, `cancelExecution`, etc.) drain the
//  queue: `drainAll()` cancels the current state and drops anything
//  pending so leftover prompts from a stale conversation can't pop up
//  in the new one.
//

import Foundation
import SwiftUI

/// One pending prompt. `Identifiable` so the SwiftUI overlay can key
/// off `current?.id` for in-place crossfades when one prompt resolves
/// and the next mounts.
///
/// `Identifiable` conformance is `nonisolated` because it just reads
/// the underlying `ObjectIdentifier` (no mutable state, safe across
/// actors). The whole enum can't be `@MainActor` without forcing the
/// protocol witness onto the main actor, which Swift 6 rejects as a
/// data race.
public enum PromptItem: Identifiable {
    case secret(SecretPromptState)
    case clarify(ClarifyPromptState)

    public nonisolated var id: ObjectIdentifier {
        switch self {
        case .secret(let s): return ObjectIdentifier(s)
        case .clarify(let c): return ObjectIdentifier(c)
        }
    }

    /// Cancel the underlying state so any awaiting continuation /
    /// callback resolves. Idempotent — both `SecretPromptState.cancel()`
    /// and `ClarifyPromptState.cancel()` guard on a `resolved` flag.
    @MainActor
    func cancel() {
        switch self {
        case .secret(let s): s.cancel()
        case .clarify(let c): c.cancel()
        }
    }
}

@MainActor
public final class PromptQueue: ObservableObject {
    /// The prompt currently mounted in the overlay. `nil` when no
    /// prompt is showing.
    @Published public private(set) var current: PromptItem?

    /// Pending prompts, oldest first. Hidden behind the queue's API so
    /// callers can't accidentally bypass `current`.
    private var pending: [PromptItem] = []

    public init() {}

    /// Append a prompt. Mounts immediately when the queue is empty,
    /// otherwise queues behind whatever is currently showing.
    public func enqueue(_ item: PromptItem) {
        if current == nil {
            current = item
        } else {
            pending.append(item)
        }
    }

    /// Resolve the currently mounted prompt (called from the overlay's
    /// dismiss closure) and mount the next pending one. No-op when the
    /// queue is empty so it's safe to call defensively.
    public func advance() {
        if pending.isEmpty {
            current = nil
        } else {
            current = pending.removeFirst()
        }
    }

    /// Cancel everything in the queue (current + pending) and clear.
    /// Used by reset paths so a brand-new conversation doesn't
    /// inherit dangling prompts from the previous one.
    public func drainAll() {
        if let cur = current { cur.cancel() }
        for item in pending { item.cancel() }
        pending.removeAll()
        current = nil
    }
}

// MARK: - ClarifyPromptState

/// State backing one pending `clarify` call. Mirrors
/// `SecretPromptState`'s resolve-once semantics (`submit` and `cancel`
/// both flip the `resolved` flag and become no-ops thereafter) so the
/// overlay's `onDisappear` safety net can be called any number of
/// times without re-firing the answer.
///
/// Unlike secrets, clarify is fire-and-forget from the agent loop's
/// perspective — the loop already broke out when the intercept
/// surfaced this state. The user's answer is dispatched as the next
/// user message via `onSubmit`, which restarts the loop with the
/// answer in the chat history. Cancelling does nothing on the agent
/// side; the user can simply type a different message in the main
/// chat input bar to respond manually.
@MainActor
public final class ClarifyPromptState: ObservableObject {
    public let question: String
    public let options: [String]
    public let allowMultiple: Bool

    private let onSubmit: (String) -> Void
    private let onCancel: () -> Void
    private var resolved = false

    public init(
        question: String,
        options: [String] = [],
        allowMultiple: Bool = false,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.question = question
        self.options = options
        // `allowMultiple` only makes sense alongside options; collapse
        // it defensively so callers can't end up with a single-tap chip
        // strip that pretends it accepts multi-select.
        self.allowMultiple = options.isEmpty ? false : allowMultiple
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    /// Submit the user's answer. Multi-select callers should join their
    /// selections before calling (the simplest contract is a comma+space
    /// join that reads well in the chat history).
    public func submit(_ answer: String) {
        guard !resolved else { return }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        resolved = true
        onSubmit(trimmed)
    }

    /// Dismiss without sending. Safe to call any number of times — the
    /// `resolved` flag means subsequent invocations are no-ops, so the
    /// overlay's `onDisappear` safety net can fire after an explicit
    /// cancel/submit without double-firing the callback.
    public func cancel() {
        guard !resolved else { return }
        resolved = true
        onCancel()
    }
}
