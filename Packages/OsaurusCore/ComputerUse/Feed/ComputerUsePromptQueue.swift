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

    public init(id: UUID = UUID(), toolCallId: String, preview: ActionPreview) {
        self.id = id
        self.toolCallId = toolCallId
        self.preview = preview
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

    public init(id: UUID = UUID(), toolCallId: String) {
        self.id = id
        self.toolCallId = toolCallId
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

    private init() {}

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
            return true
        }
        let request = ConfirmRequest(toolCallId: toolCallId, preview: preview)
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
        pending.removeAll { $0.id == id }
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.resume(returning: approved)
    }

    /// Approve a request AND auto-approve subsequent same-or-lower-effect actions
    /// in the same app for the rest of this run. A no-op for a request whose
    /// preview has no app (nothing safe to scope the blanket approval to).
    public func resolveApprovingRest(id: UUID) {
        guard let request = pending.first(where: { $0.id == id }) else { return }
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
        let request = CloudVisionConsentRequest(toolCallId: toolCallId)
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
