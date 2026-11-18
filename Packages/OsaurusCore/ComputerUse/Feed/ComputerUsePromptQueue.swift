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
                let id = request.id
                let title =
                    preview.appName.map { L("Allow Computer Use: \(preview.actionLabel) in \($0)?") }
                    ?? L("Allow Computer Use: \(preview.actionLabel)?")
                AttentionProducers.beginWaiting(itemId: id, step: L("Waiting for approval"))
                let scoped = !(preview.appName ?? "").isEmpty
                var item = AttentionProducers.item(
                    id: id, kind: .computerUse, title: title, body: preview.targetLabel ?? "",
                    actions: scoped ? [.approve, .approveRest, .deny, .open] : nil)
                item.detail = Self.detail(for: preview)
                AttentionCenter.shared.raise(item) { [weak self] resolution in
                    if resolution.outcome == .allowedForConversation, scoped {
                        self?.resolveApprovingRest(id: id, attention: resolution)
                    } else {
                        self?.resolve(id: id, approved: resolution.isGrant, attention: resolution)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.resolve(id: request.id, approved: false, attention: AttentionProducers.abandoned)
            }
        }
    }

    static let typedTextDetailLimit = 2_000
    static let scriptDetailLimit = 4_000

    /// The step as the owner's other devices show it before answering.
    static func detail(for preview: ActionPreview) -> Data? {
        var object: [String: Any] = ["action": preview.actionLabel, "effect": preview.effect.rawValue]
        var cut = false
        if let app = preview.appName, !app.isEmpty { object["app"] = app }
        if let target = preview.targetLabel, !target.isEmpty { object["target"] = target }
        if let note = preview.note, !note.isEmpty { object["note"] = note }
        if let typed = preview.typedText, !typed.isEmpty {
            let clipped = AttentionDetail.clip(typed, typedTextDetailLimit)
            object["typedText"] = clipped.text
            cut = cut || clipped.cut
        }
        if let script = preview.scriptBody, !script.isEmpty {
            let clipped = AttentionDetail.clip(script, scriptDetailLimit)
            object["script"] = clipped.text
            cut = cut || clipped.cut
        }
        if cut { object["truncated"] = true }
        return AttentionDetail.encode(object)
    }

    /// Resolve a specific pending request (user tapped approve/deny).
    public func resolve(id: UUID, approved: Bool) {
        resolve(id: id, approved: approved, attention: nil)
    }

    /// `attention` says who answered and where; nil means the owner on the card.
    func resolve(id: UUID, approved: Bool, attention: AttentionResolution?) {
        if continuations[id] != nil {
            AttentionCenter.shared.resolve(id: id, with: attention ?? AttentionProducers.inline(approved ? .approved : .denied))
            AttentionProducers.endWaiting(itemId: id)
        }
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
        resolveApprovingRest(id: id, attention: nil)
    }

    func resolveApprovingRest(id: UUID, attention: AttentionResolution?) {
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
        resolve(id: id, approved: true, attention: attention ?? AttentionProducers.inline(.allowedForConversation))
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
                let id = request.id
                AttentionProducers.beginWaiting(itemId: id, step: L("Waiting for approval"))
                AttentionCenter.shared.raise(
                    AttentionProducers.item(
                        id: id,
                        kind: .computerUse,
                        title: L("Allow screenshots to be sent to a cloud vision model?")
                    )
                ) { [weak self] resolution in
                    self?.resolveConsent(id: id, choice: resolution.isGrant ? .allowOnce : .deny, attention: resolution)
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.resolveConsent(id: request.id, choice: .deny, attention: AttentionProducers.abandoned)
            }
        }
    }

    /// Resolve a specific pending consent prompt (user picked allow/deny).
    public func resolveConsent(id: UUID, choice: CloudVisionConsentChoice) {
        resolveConsent(id: id, choice: choice, attention: nil)
    }

    func resolveConsent(id: UUID, choice: CloudVisionConsentChoice, attention: AttentionResolution?) {
        pendingConsent.removeAll { $0.id == id }
        guard let continuation = consentContinuations.removeValue(forKey: id) else { return }
        AttentionCenter.shared.resolve(id: id, with: attention ?? AttentionProducers.inline(choice == .deny ? .denied : .approved))
        AttentionProducers.endWaiting(itemId: id)
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
            guard let continuation = continuations.removeValue(forKey: request.id) else { continue }
            AttentionCenter.shared.resolve(id: request.id, with: AttentionProducers.abandoned)
            AttentionProducers.endWaiting(itemId: request.id)
            continuation.resume(returning: false)
        }

        let affectedConsent = pendingConsent.filter { $0.toolCallId == toolCallId }
        pendingConsent.removeAll { $0.toolCallId == toolCallId }
        for request in affectedConsent {
            guard let continuation = consentContinuations.removeValue(forKey: request.id) else { continue }
            AttentionCenter.shared.resolve(id: request.id, with: AttentionProducers.abandoned)
            AttentionProducers.endWaiting(itemId: request.id)
            continuation.resume(returning: .deny)
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

    /// How a phone's answer landed.
    public enum PairedPhoneAnswer: Sendable {
        case answered
        /// Already answered, the run ended, or never the phone's card.
        case notPending
        /// The card is still waiting: this decision does not fit its kind.
        case invalidDecision
    }

    /// Answers one of the phone's cards. Actions take `approve | deny |
    /// approve_rest`; consent takes `allow_once | allow_always | deny`. A
    /// decision that does not fit is refused, never read as an approval, and
    /// leaves the card pending.
    public func resolveFromPairedPhone(id: UUID, decision: String) -> PairedPhoneAnswer {
        func phone(_ outcome: AttentionResolution.Outcome) -> AttentionResolution {
            AttentionResolution(outcome: outcome, surface: .phone, decidedBy: .ownerDevice(L("iPhone")))
        }
        if pending.contains(where: { $0.id == id && $0.fromPairedPhone }) {
            switch decision {
            case "approve": resolve(id: id, approved: true, attention: phone(.approved))
            case "deny": resolve(id: id, approved: false, attention: phone(.denied))
            case "approve_rest": resolveApprovingRest(id: id, attention: phone(.allowedForConversation))
            default: return .invalidDecision
            }
            return .answered
        }
        if pendingConsent.contains(where: { $0.id == id && $0.fromPairedPhone }) {
            switch decision {
            case "allow_once": resolveConsent(id: id, choice: .allowOnce, attention: phone(.approved))
            case "allow_always": resolveConsent(id: id, choice: .allowAlways, attention: phone(.approved))
            case "deny": resolveConsent(id: id, choice: .deny, attention: phone(.denied))
            default: return .invalidDecision
            }
            return .answered
        }
        return .notPending
    }
}
