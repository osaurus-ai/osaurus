//
//  ConfigApprovalQueue.swift
//  osaurus
//
//  The dedicated approval surface for `osaurus_config` applies. Every
//  attended apply parks a `ConfigApprovalRequest` here; the chat views
//  render it as an inline plan-review card and the user's tap resolves
//  the suspended tool call. When no chat
//  surface is mounted (e.g. an App Intents flow with no window),
//  `ConfigApprovalService` falls back to the generic modal panel so the
//  apply is still gated — never silently approved.
//
//  This replaces the old flow where `osaurus_config` went through the
//  generic tool-permission NSPanel (which showed raw YAML args instead of
//  the diff) plus a second high-risk text dialog.
//

import Combine
import Foundation

/// One pending config-apply approval, carrying the full structured plan so
/// the card can render an actual diff instead of a text blob.
public struct ConfigApprovalRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let plan: ConfigPlan
    /// Whether the apply runs with prune semantics (deletes entries not
    /// listed in the document) — surfaced prominently on the card.
    public let prune: Bool

    public init(id: UUID = UUID(), plan: ConfigPlan, prune: Bool) {
        self.id = id
        self.plan = plan
        self.prune = prune
    }
}

/// Terminal reason for an attended configuration review. Keeping timeout and
/// teardown distinct from an explicit button tap prevents the tool envelope
/// from falsely claiming that the user declined a card they never answered.
public enum ConfigApprovalOutcome: Sendable, Equatable {
    case approved
    case denied
    case timedOut
    case cancelled
}

/// MainActor-confined queue of pending config approvals. SwiftUI observes
/// `pending` and renders the card; `requestApproval` is the async seam the
/// tool awaits. Mirrors `ComputerUsePromptQueue`.
@MainActor
public final class ConfigApprovalQueue: ObservableObject {
    public static let shared = ConfigApprovalQueue()

    @Published public private(set) var pending: [ConfigApprovalRequest] = []

    private var continuations: [UUID: CheckedContinuation<ConfigApprovalOutcome, Never>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    /// Count of chat surfaces currently able to render the card. When zero,
    /// `ConfigApprovalService` uses the modal-panel fallback instead of
    /// parking a request nobody can see.
    private var mountedSurfaces = 0

    private init() {}

    // MARK: - Surface tracking

    public func surfaceDidMount() { mountedSurfaces += 1 }
    public func surfaceDidUnmount() { mountedSurfaces = max(0, mountedSurfaces - 1) }
    public var hasMountedSurface: Bool { mountedSurfaces > 0 }

    // MARK: - Approval

    /// Park an approval and suspend until the user (or teardown /
    /// cancellation) resolves it. Cancellation-aware: a cancelled chat turn
    /// resolves as cancelled so the tool never hangs on a card nobody answers.
    public func requestApproval(
        plan: ConfigPlan,
        prune: Bool,
        timeout: Duration = .seconds(120)
    ) async -> ConfigApprovalOutcome {
        let request = ConfigApprovalRequest(plan: plan, prune: prune)
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<ConfigApprovalOutcome, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                    return
                }
                continuations[request.id] = continuation
                pending.append(request)
                timeoutTasks[request.id] = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.resolve(id: request.id, outcome: .timedOut)
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.resolve(id: request.id, outcome: .cancelled)
            }
        }
    }

    /// Resolve a specific pending request (user tapped Apply / Cancel, the
    /// bounded review deadline expired, or the owning chat was torn down).
    public func resolve(id: UUID, outcome: ConfigApprovalOutcome) {
        pending.removeAll { $0.id == id }
        timeoutTasks.removeValue(forKey: id)?.cancel()
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.resume(returning: outcome)
    }

    /// Deny + clear every pending approval (chat teardown, Stop).
    public func cancelAll() {
        let affected = pending
        pending.removeAll()
        for request in affected {
            timeoutTasks.removeValue(forKey: request.id)?.cancel()
            continuations.removeValue(forKey: request.id)?.resume(returning: .cancelled)
        }
    }
}

/// Entry point the tool calls: prefers the in-chat card, falls back to the
/// generic modal panel when no chat surface is mounted, so an apply is
/// always human-gated on attended surfaces.
public enum ConfigApprovalService {
    public static func requestApproval(
        plan: ConfigPlan,
        prune: Bool
    ) async -> ConfigApprovalOutcome {
        let useCard = await MainActor.run { ConfigApprovalQueue.shared.hasMountedSurface }
        if useCard {
            return await ConfigApprovalQueue.shared.requestApproval(plan: plan, prune: prune)
        }
        var description = "Apply these configuration changes?\n\n" + plan.summaryText()
        if prune {
            description += "\n\nPrune is ON: entries not listed in the document will be DELETED."
        }
        let outcome = await ToolPermissionPromptService.requestPolicyApproval(
            toolName: "osaurus_config",
            description: description,
            argumentsJSON: ""
        )
        return outcome == .denied ? .denied : .approved
    }
}
