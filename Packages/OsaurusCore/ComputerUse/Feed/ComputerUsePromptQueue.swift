//
//  ComputerUsePromptQueue.swift
//  OsaurusCore — Computer Use
//
//  The local-first consent surface. When the gate returns `.confirm`, the
//  loop awaits `ComputerUsePromptQueue.shared.requestConfirmation(...)`,
//  which parks a `ConfirmRequest` the chat view renders as an inline
//  approve/deny overlay. The user's tap resolves the suspended call. A run
//  that is interrupted or torn down resolves any of its pending prompts as
//  denied so the loop never hangs on a card nobody will answer.
//

import Combine
import Foundation

/// One pending confirmation, surfaced to the user before a gated action runs.
public struct ConfirmRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let toolCallId: String
    public let preview: ActionPreview
    /// Raised by a run from the owner's paired phone: listed on
    /// `GET /computer-use/prompts` for the phone to answer (MOBILE_PROTOCOL
    /// §16.4). Every Mac chat window still shows it too.
    public let fromPairedPhone: Bool

    public init(id: UUID = UUID(), toolCallId: String, preview: ActionPreview, fromPairedPhone: Bool = false) {
        self.id = id
        self.toolCallId = toolCallId
        self.preview = preview
        self.fromPairedPhone = fromPairedPhone
    }
}

/// The user's answer to a just-in-time cloud-vision consent prompt.
public enum CloudVisionConsentChoice: String, Sendable, Equatable {
    /// Allow for this run only (session grant).
    case allowOnce
    /// Allow and remember (persistent grant).
    case allowAlways
    /// Don't allow; stay on-device for the rest of the run.
    case deny
}

/// One pending cloud-vision consent prompt, surfaced when a run would benefit
/// from a screenshot but the user hasn't granted cloud-vision consent yet.
public struct CloudVisionConsentRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let toolCallId: String
    /// See `ConfirmRequest.fromPairedPhone`.
    public let fromPairedPhone: Bool

    public init(id: UUID = UUID(), toolCallId: String, fromPairedPhone: Bool = false) {
        self.id = id
        self.toolCallId = toolCallId
        self.fromPairedPhone = fromPairedPhone
    }
}

/// MainActor-confined queue of pending prompts. SwiftUI observes `pending` /
/// `pendingConsent` and renders the overlay; `requestConfirmation` and
/// `requestCloudVisionConsent` are the async seams the loop awaits.
@MainActor
public final class ComputerUsePromptQueue: ObservableObject {
    public static let shared = ComputerUsePromptQueue()

    @Published public private(set) var pending: [ConfirmRequest] = []
    @Published public private(set) var pendingConsent: [CloudVisionConsentRequest] = []

    private var continuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var consentContinuations: [UUID: CheckedContinuation<CloudVisionConsentChoice, Never>] =
        [:]
    /// Per-run "approve remaining" thresholds: `toolCallId → normalized app →
    /// highest effect auto-approved`. An action confirms automatically when its
    /// effect is `<=` the recorded ceiling for its app. Cleared on teardown.
    private var autoApprove: [String: [String: EffectClass]] = [:]
    /// Number of mounted `ComputerUseConfirmOverlay`s. Zero means nobody can
    /// render a card, so a confirm would suspend until the wall clock — the
    /// loop asks `canPresent` first and fails fast instead.
    @Published public private(set) var presenterCount = 0

    private init() {}

    // MARK: - Presenters

    public func registerPresenter() { presenterCount += 1 }

    public func unregisterPresenter() { presenterCount = max(0, presenterCount - 1) }

    /// Whether a confirm / consent card can currently be shown to the user.
    /// Under tests there is no UI; treat the queue as presentable so scripted
    /// confirm seams keep working.
    public var canPresent: Bool {
        presenterCount > 0 || RuntimeEnvironment.isUnderTests
    }

    // MARK: - Confirmation

    /// Park a confirmation and suspend until the user (or a teardown) resolves
    /// it. Returns whether the action was approved. Auto-approves without a
    /// prompt when the user previously chose "approve remaining" for this app at
    /// this effect or higher. Cancellation-aware: if the run's Task is cancelled
    /// while suspended, the call resolves as denied so the loop never hangs.
    public func requestConfirmation(_ preview: ActionPreview, toolCallId: String) async -> Bool {
        if let app = preview.appName, !app.isEmpty,
            let ceiling = autoApprove[toolCallId]?[AutonomyPolicy.normalize(app)],
            preview.effect <= ceiling
        {
            ComputerUseTraceLog.recordConfirmationQueue(
                toolCallId: toolCallId,
                requestId: UUID(),
                event: "auto_approved",
                preview: preview,
                approved: true
            )
            return true
        }
        let request = ConfirmRequest(
            toolCallId: toolCallId,
            preview: preview,
            fromPairedPhone: ChatExecutionContext.hasRemoteReviewer
        )
        ComputerUseTraceLog.recordConfirmationQueue(
            toolCallId: toolCallId,
            requestId: request.id,
            event: "enqueued",
            preview: preview
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                continuations[request.id] = continuation
                pending.append(request)
            }
        } onCancel: {
            Task { @MainActor in
                self.resolve(id: request.id, approved: false)
            }
        }
    }

    /// Resolve a specific pending request (user tapped approve/deny).
    public func resolve(id: UUID, approved: Bool) {
        if let request = pending.first(where: { $0.id == id }) {
            ComputerUseTraceLog.recordConfirmationQueue(
                toolCallId: request.toolCallId,
                requestId: request.id,
                event: "resolved",
                preview: request.preview,
                approved: approved
            )
        }
        pending.removeAll { $0.id == id }
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.resume(returning: approved)
    }

    /// Approve a request AND auto-approve subsequent same-or-lower-effect actions
    /// in the same app for the rest of this run. A no-op for a request whose
    /// preview has no app (nothing safe to scope the blanket approval to).
    public func resolveApprovingRest(id: UUID) {
        guard let request = pending.first(where: { $0.id == id }) else { return }
        ComputerUseTraceLog.recordConfirmationQueue(
            toolCallId: request.toolCallId,
            requestId: request.id,
            event: "approve_remaining",
            preview: request.preview,
            approved: true
        )
        if let app = request.preview.appName, !app.isEmpty {
            let key = AutonomyPolicy.normalize(app)
            var perApp = autoApprove[request.toolCallId] ?? [:]
            perApp[key] =
                perApp[key].map { EffectClass.max($0, request.preview.effect) }
                ?? request.preview.effect
            autoApprove[request.toolCallId] = perApp
        }
        resolve(id: id, approved: true)
    }

    // MARK: - Cloud-vision consent

    /// Park a cloud-vision consent prompt and suspend until the user resolves it.
    /// Cancellation-aware (resolves as `.deny`) so the loop never hangs.
    public func requestCloudVisionConsent(toolCallId: String) async -> CloudVisionConsentChoice {
        let request = CloudVisionConsentRequest(
            toolCallId: toolCallId,
            fromPairedPhone: ChatExecutionContext.hasRemoteReviewer
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<CloudVisionConsentChoice, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .deny)
                    return
                }
                consentContinuations[request.id] = continuation
                pendingConsent.append(request)
            }
        } onCancel: {
            Task { @MainActor in
                self.resolveConsent(id: request.id, choice: .deny)
            }
        }
    }

    /// Resolve a specific pending consent prompt (user picked allow/deny).
    public func resolveConsent(id: UUID, choice: CloudVisionConsentChoice) {
        pendingConsent.removeAll { $0.id == id }
        guard let continuation = consentContinuations.removeValue(forKey: id) else { return }
        continuation.resume(returning: choice)
    }

    // MARK: - Teardown

    /// Deny + clear every pending prompt (confirm + consent) for a run and drop
    /// its "approve remaining" thresholds. Called on interrupt / teardown, and
    /// by the feed's Stop control so Stop works even while a card is up.
    public func cancelAll(forToolCallId toolCallId: String) {
        autoApprove.removeValue(forKey: toolCallId)

        let affected = pending.filter { $0.toolCallId == toolCallId }
        pending.removeAll { $0.toolCallId == toolCallId }
        for request in affected {
            continuations.removeValue(forKey: request.id)?.resume(returning: false)
        }

        let affectedConsent = pendingConsent.filter { $0.toolCallId == toolCallId }
        pendingConsent.removeAll { $0.toolCallId == toolCallId }
        for request in affectedConsent {
            consentContinuations.removeValue(forKey: request.id)?.resume(returning: .deny)
        }
    }
}

// MARK: - Paired phone (MOBILE_PROTOCOL §16.4)

extension ComputerUsePromptQueue {
    /// The phone's pending confirm and consent cards as
    /// `GET /computer-use/prompts` JSON, confirmations first.
    public func pairedPhoneListJSON() -> Data {
        var rows: [[String: Any]] = pending.filter(\.fromPairedPhone).map { request in
            let preview = request.preview
            var row: [String: Any] = [
                "id": request.id.uuidString,
                "kind": "action",
                "action": preview.actionLabel,
                "effect": preview.effect.rawValue,
                // "Approve the rest" needs an app to scope the lease to.
                "offers_approve_rest": !(preview.appName ?? "").isEmpty,
            ]
            if let app = preview.appName { row["app"] = app }
            if let target = preview.targetLabel { row["target"] = target }
            if let note = preview.note { row["note"] = note }
            if let typed = preview.typedText { row["typed_text"] = typed }
            if let script = preview.scriptBody { row["script"] = script }
            return row
        }
        rows += pendingConsent.filter(\.fromPairedPhone).map { request -> [String: Any] in
            ["id": request.id.uuidString, "kind": "cloud_vision_consent"]
        }
        return (try? JSONSerialization.data(withJSONObject: ["prompts": rows], options: [.sortedKeys]))
            ?? Data(#"{"prompts":[]}"#.utf8)
    }

    /// Answers one of the phone's cards. Actions take `approve | deny |
    /// approve_rest`; consent takes `allow_once | allow_always | deny`.
    /// False when the id is not a pending phone card, or the decision does
    /// not fit its kind (never read as an approval).
    public func resolveFromPairedPhone(id: UUID, decision: String) -> Bool {
        if pending.contains(where: { $0.id == id && $0.fromPairedPhone }) {
            switch decision {
            case "approve": resolve(id: id, approved: true)
            case "deny": resolve(id: id, approved: false)
            case "approve_rest": resolveApprovingRest(id: id)
            default: return false
            }
            return true
        }
        if pendingConsent.contains(where: { $0.id == id && $0.fromPairedPhone }) {
            switch decision {
            case "allow_once": resolveConsent(id: id, choice: .allowOnce)
            case "allow_always": resolveConsent(id: id, choice: .allowAlways)
            case "deny": resolveConsent(id: id, choice: .deny)
            default: return false
            }
            return true
        }
        return false
    }
}
