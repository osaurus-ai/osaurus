//
//  PrivacyReviewService.swift
//  osaurus / PrivacyFilter
//
//  Main-actor singleton that bridges the pipeline's detection step to
//  the SwiftUI review sheet. The pipeline calls `review(...)`; if a
//  window has registered itself as the presenter, the call suspends
//  until the user picks Approve / Skip / Cancel / Always-Approve. If
//  nobody is registered, every detection auto-approves so background
//  callers (HTTP API, plugins, agent loops) don't deadlock waiting on
//  a UI that isn't there.
//
//  Registrations are keyed by an opaque `PresenterToken`. Each chat
//  window registers on appear and unregisters with the same token on
//  disappear. Because tokens identify the registration that's being
//  removed, a teardown can't accidentally clobber a registration that
//  another window took over in between — see the original bug where
//  closing a stale window silently swallowed reviews for the focused
//  one.
//

import Foundation

/// Outcome of one review pass.
enum PrivacyReviewOutcome: Sendable {
    /// User approved (possibly with per-row tweaks). Carries the list
    /// the pipeline should substitute. Same shape and length as the
    /// input list with `approved` flags reflecting the user's choice.
    case approved([DetectedEntity])
    /// User canceled — the send should be aborted upstream.
    case canceled
    /// Fail-closed block for a non-interactive caller: the request
    /// origin can't drive the review sheet (HTTP API, plugin, P2P — or
    /// no presenter is registered at all) and
    /// `requireReviewForNonInteractive` is on. Distinct from
    /// `.canceled` so the pipeline can surface a typed, actionable
    /// error to the API client instead of an ambiguous cancel.
    case blockedNonInteractive
}

/// Opaque handle returned by `registerPresenter`. The chat window
/// retains it and passes it back to `unregisterPresenter(_:)` so the
/// service can drop only this specific registration.
struct PresenterToken: Hashable, Sendable {
    fileprivate let id: UUID
}

@MainActor
final class PrivacyReviewService {
    static let shared = PrivacyReviewService()

    private struct Registration {
        let token: PresenterToken
        let closure: (RedactionReviewState) -> Void
    }

    /// Most recent registration wins, but older ones stay around so
    /// their tokens can still be cleared without affecting the active
    /// one. We only ever present through `current`.
    private var registrations: [Registration] = []

    /// The active presenter — last one registered.
    private var current: Registration? { registrations.last }

    /// Open review states by id, so a cancellation handler running on
    /// some other Task can route a cancel to the right state.
    private var openStates: [UUID: RedactionReviewState] = [:]

    private init() {}

    /// Register the chat window's sheet-presenting closure. The
    /// closure receives a fully-populated `RedactionReviewState`
    /// (already bound to a continuation); the window assigns it to a
    /// `@Published var` so SwiftUI's `.sheet(item:)` picks it up.
    ///
    /// Returns a token the caller MUST hold and pass to
    /// `unregisterPresenter(_:)` on teardown — discarding it leaks the
    /// registration and forces a stale closure to keep capturing the
    /// window state forever.
    func registerPresenter(_ closure: @escaping (RedactionReviewState) -> Void) -> PresenterToken {
        let token = PresenterToken(id: UUID())
        registrations.append(Registration(token: token, closure: closure))
        return token
    }

    /// Clear a previously registered presenter by token. Other
    /// registrations remain intact — fixes the original "second window
    /// closes and silently disables review for the first" bug.
    func unregisterPresenter(_ token: PresenterToken) {
        registrations.removeAll { $0.token == token }
    }

    /// Ask the registered presenter (if any) to confirm the detection
    /// list. Returns the approved subset, or `nil` when canceled.
    /// Auto-approves when no presenter is registered, when the global
    /// "always approve" config flag is on, or when the session has
    /// opted into always-approve.
    ///
    /// `allowInteractive` is the request-origin gate: HTTP API,
    /// plugin, and P2P callers pass `false` so a registered chat-window
    /// presenter is NEVER used for a request the user didn't send from
    /// that window. Without this, a server-origin request would pop
    /// the review sheet over an unrelated chat and suspend the HTTP
    /// response until the user notices — the client just hangs. Those
    /// callers take the same fail-closed / opt-out branch as the
    /// no-presenter case.
    func review(
        detections: [DetectedEntity],
        sessionId: String,
        allowInteractive: Bool = true,
        allowRemote: Bool = false
    ) async -> PrivacyReviewOutcome {
        // Short circuit: nothing to review.
        if detections.isEmpty {
            return .approved(detections)
        }

        let configSnapshot = PrivacyFilterStore.snapshot()

        // Per-session "Require review" wins over EVERYTHING — the
        // user explicitly opted this conversation OUT of auto-approve
        // (e.g. global default is on, but they're about to share
        // sensitive context they want a final look at). Checked first
        // so it overrides both the global flag and per-session
        // auto-approve.
        let sessionRequiresReview = await SessionRedactionStore.shared.isReviewRequired(sessionId)
        if !sessionRequiresReview {
            // Honor the global "always approve" toggle from settings.
            // This is the user's coarse-grained "I trust this app and
            // want frictionless sending" switch; per-session is the
            // fine-grained version that's preserved across review
            // sheets in the same conversation.
            if configSnapshot.alwaysApproveByDefault {
                print("[PrivacyReview] auto-approved \(detections.count) item(s): global always-approve is on")
                return .approved(detections)
            }

            // Honor per-session auto-approve.
            if await SessionRedactionStore.shared.isAutoApproveEnabled(sessionId) {
                print("[PrivacyReview] auto-approved \(detections.count) item(s): session \(sessionId) has always-approve on")
                return .approved(detections)
            }
        }

        // The owner's paired phone is a real pair of eyes, just not this
        // window: hand it the review instead of failing closed (§19).
        if !allowInteractive, allowRemote {
            print("[PrivacyReview] handing \(detections.count) item(s) to the paired phone for session \(sessionId)")
            return await reviewRemotely(detections: detections, sessionId: sessionId)
        }

        guard allowInteractive, let presenter = current?.closure else {
            // No usable UI — either the caller is non-interactive
            // (HTTP API, plugin, P2P: `allowInteractive == false`) or
            // no presenter is registered. Two paths:
            //
            //   * `requireReviewForNonInteractive == true` (default): a
            //     background caller (HTTP `/chat/completions`, plugin
            //     agent, headless tool) tried to ship PII through the
            //     filter. With no UI to confirm, block the send with
            //     `.blockedNonInteractive` — the pipeline lifts it into
            //     a typed error instead of silently auto-approving.
            //     This is the fail-closed posture documented in
            //     `docs/PRIVACY_FILTER.md`.
            //
            //   * otherwise (power user opt-out): auto-approve so the
            //     send proceeds — same legacy behaviour as before this
            //     flag landed.
            if configSnapshot.requireReviewForNonInteractive {
                let cause =
                    allowInteractive
                    ? "no review presenter is registered"
                    : "request origin is non-interactive"
                print(
                    "[PrivacyFilter] BLOCKING non-interactive send: \(detections.count) detection(s) but \(cause)."
                )
                return .blockedNonInteractive
            }
            print("[PrivacyReview] auto-approved \(detections.count) item(s): no reviewer and non-interactive review is not required")
            return .approved(detections)
        }

        let state = RedactionReviewState(
            detections: detections,
            sessionId: sessionId
        )
        // Pre-hydrate the always-approve toggle from session state so
        // the sheet shows the user the correct current value. Handled
        // here (not in init) because `SessionRedactionStore` is actor-
        // isolated and we already have an awaiting context.
        state.alwaysApprove = await SessionRedactionStore.shared.isAutoApproveEnabled(sessionId)
        let stateId = state.id
        openStates[stateId] = state
        print("[PrivacyReview] showing the Mac review sheet \(stateId) for \(detections.count) item(s)")

        // `withTaskCancellationHandler` lets us forward `Task.cancel()`
        // (e.g. the Stop button) into a `.canceled` resolution. Without
        // this, hitting Stop while the sheet is open would cancel the
        // awaiting Task but leave the continuation suspended forever —
        // and the sheet visible. The `onCancel` closure runs on
        // whichever executor the canceller is on, so we route through
        // a `@Sendable`-safe Task that hops to the main actor and
        // dispatches via the singleton (Swift 6 doesn't let us capture
        // a task-isolated `self` into a main-actor Task closure
        // without sendability headaches).
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<PrivacyReviewOutcome, Never>) in
                state.onResolve = { outcome in
                    Task { @MainActor in
                        PrivacyReviewService.shared.clearOpenState(id: stateId)
                    }
                    cont.resume(returning: outcome)
                }
                presenter(state)
            }
        } onCancel: {
            Task { @MainActor in
                PrivacyReviewService.shared.cancelOpenState(id: stateId)
            }
        }
    }


    // MARK: - Remote review (Osaurus Connect)

    /// One review a paired phone can answer (docs/MOBILE_PROTOCOL.md §19).
    struct RemoteReview: Sendable {
        let id: UUID
        let sessionId: String
        let items: [Item]

        struct Item: Sendable {
            let id: UUID
            /// `person | email | phone | address | url | date | accountNumber | secret`
            let category: String
            /// The detected text. It goes to the user's own phone inside the
            /// Secure Channel — the point of the review is that the user sees
            /// exactly what would otherwise reach the provider.
            let original: String
            /// What replaces it if approved, e.g. `[PERSON_1]`.
            let placeholder: String
        }
    }

    /// Reviews waiting on a remote answer, oldest first.
    private var remoteStates: [UUID: RedactionReviewState] = [:]

    var remoteReviews: [RemoteReview] {
        remoteStates.values
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { state in
                RemoteReview(
                    id: state.id,
                    sessionId: state.sessionId,
                    items: state.entities.map { entity in
                        RemoteReview.Item(
                            id: entity.id,
                            category: entity.category.rawValue,
                            original: entity.original,
                            placeholder: entity.placeholder.token
                        )
                    }
                )
            }
    }

    /// Answers a review from a paired phone. `redactedIds` are the items to
    /// replace with placeholders; anything omitted is sent as-is, exactly as
    /// unticking a row in the Mac's sheet does. Returns false when the id is
    /// unknown — already answered, or the run ended.
    @discardableResult
    func resolveRemotely(id: UUID, redactedIds: Set<UUID>) -> Bool {
        guard let state = remoteStates[id] else {
            print("[PrivacyReview] phone answered review \(id), but it is no longer pending")
            return false
        }
        print("[PrivacyReview] phone answered review \(id): redact \(redactedIds.intersection(Set(state.entities.map(\.id))).count) of \(state.entities.count)")
        remoteStates.removeValue(forKey: id)
        for entity in state.entities {
            state.setApproval(entity, to: redactedIds.contains(entity.id))
        }
        state.confirm()
        return true
    }

    /// Cancels a review from a paired phone: the send is aborted, nothing
    /// reaches the provider.
    @discardableResult
    func cancelRemotely(id: UUID) -> Bool {
        guard let state = remoteStates[id] else {
            print("[PrivacyReview] phone cancelled review \(id), but it is no longer pending")
            return false
        }
        print("[PrivacyReview] phone cancelled review \(id)")
        remoteStates.removeValue(forKey: id)
        state.cancel()
        return true
    }

    /// Suspends until the paired phone answers, the way the chat window's
    /// sheet suspends until the user presses a button. Used only when the
    /// request came from the owner's own phone (`allowRemote`), so a random
    /// HTTP caller still fails closed.
    private func reviewRemotely(
        detections: [DetectedEntity],
        sessionId: String
    ) async -> PrivacyReviewOutcome {
        let state = RedactionReviewState(detections: detections, sessionId: sessionId)
        let stateId = state.id
        remoteStates[stateId] = state
        print("[PrivacyReview] remote review \(stateId) parked for session \(sessionId): \(detections.count) item(s), waiting on the phone")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<PrivacyReviewOutcome, Never>) in
                state.onResolve = { outcome in
                    Task { @MainActor in
                        PrivacyReviewService.shared.clearRemoteState(id: stateId)
                    }
                    cont.resume(returning: outcome)
                }
            }
        } onCancel: {
            Task { @MainActor in
                PrivacyReviewService.shared.cancelRemoteState(id: stateId)
            }
        }
    }

    private func cancelRemoteState(id: UUID) {
        if remoteStates[id] != nil {
            print("[PrivacyReview] remote review \(id) cancelled: its run was cancelled (client hung up or the run was stopped)")
        }
        remoteStates[id]?.cancel()
    }

    private func clearRemoteState(id: UUID) {
        remoteStates.removeValue(forKey: id)
    }

    /// Resolve a still-open review state as `.canceled`. Invoked from
    /// the `withTaskCancellationHandler` onCancel branch when the
    /// awaiting Task is cancelled (e.g. user tapped the Stop button
    /// while the sheet was open). Idempotent — the state's own
    /// resolution flag short-circuits any redundant resolve, so
    /// multi-firing this is safe.
    private func cancelOpenState(id: UUID) {
        openStates[id]?.cancel()
    }

    /// Remove a resolved state from the open registry. Called by the
    /// state's `onResolve` so the cancellation handler routing above
    /// no-ops once the user picked a button.
    private func clearOpenState(id: UUID) {
        openStates.removeValue(forKey: id)
    }
}
