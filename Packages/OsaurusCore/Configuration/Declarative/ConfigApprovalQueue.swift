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
    /// Raised by a run from the owner's paired phone: listed on
    /// `GET /config/approvals` for the phone to answer (MOBILE_PROTOCOL
    /// §16.3). Plans raised in a Mac chat never leave the Mac.
    public let fromPairedPhone: Bool
    /// Set for `osaurus_import`: the card lists the found items with
    /// per-row choices instead of a config diff. `plan` mirrors it for
    /// Attention and the phone.
    let importReview: ChatImportReview?

    public init(id: UUID = UUID(), plan: ConfigPlan, prune: Bool, fromPairedPhone: Bool = false) {
        self.id = id
        self.plan = plan
        self.prune = prune
        self.fromPairedPhone = fromPairedPhone
        self.importReview = nil
    }

    init(id: UUID = UUID(), importReview: ChatImportReview, fromPairedPhone: Bool = false) {
        self.id = id
        self.plan = importReview.plan
        self.prune = false
        self.fromPairedPhone = fromPairedPhone
        self.importReview = importReview
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
    /// The import card's per-row answers, keyed by request id then row id.
    @Published var importChoices: [UUID: [String: ChatImportItemChoice]] = [:]

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
        fromPairedPhone: Bool = false,
        timeout: Duration = .seconds(120),
        id: UUID = UUID()
    ) async -> ConfigApprovalOutcome {
        await park(
            ConfigApprovalRequest(id: id, plan: plan, prune: prune, fromPairedPhone: fromPairedPhone),
            title: L("Apply configuration changes?"), timeout: timeout)
    }

    /// Park an import review. Returns the outcome and the row choices the
    /// user left on the card (the defaults when answered elsewhere).
    func requestImportApproval(
        review: ChatImportReview,
        fromPairedPhone: Bool = false,
        timeout: Duration = .seconds(300),
        id: UUID = UUID()
    ) async -> (ConfigApprovalOutcome, [String: ChatImportItemChoice]) {
        importChoices[id] = review.defaultChoices
        let outcome = await park(
            ConfigApprovalRequest(id: id, importReview: review, fromPairedPhone: fromPairedPhone),
            title: L("Install from this source?"), timeout: timeout)
        let choices = importChoices.removeValue(forKey: id) ?? review.defaultChoices
        return (outcome, choices)
    }

    func setImportChoice(requestId: UUID, itemId: String, _ update: (inout ChatImportItemChoice) -> Void) {
        guard var choice = importChoices[requestId]?[itemId] else { return }
        update(&choice)
        importChoices[requestId]?[itemId] = choice
    }

    private func park(_ request: ConfigApprovalRequest, title: String, timeout: Duration) async
        -> ConfigApprovalOutcome
    {
        let plan = request.plan
        let prune = request.prune
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<ConfigApprovalOutcome, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                    return
                }
                continuations[request.id] = continuation
                pending.append(request)
                let id = request.id
                AttentionProducers.beginWaiting(itemId: id, step: L("Waiting for approval"))
                var item = AttentionProducers.item(
                    id: id,
                    kind: .configApproval,
                    title: title,
                    body: plan.summaryText()
                )
                item.detail = Self.detail(plan: plan, prune: prune)
                AttentionCenter.shared.raise(item) { [weak self] resolution in
                    self?.resolve(
                        id: id,
                        outcome: resolution.isGrant ? .approved : (resolution.outcome == .timedOut ? .timedOut : .denied),
                        attention: resolution
                    )
                }
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

    /// The plan as the owner's other devices show it: `ConfigPlan.payload`
    /// and whether the apply prunes.
    static func detail(plan: ConfigPlan, prune: Bool) -> Data? {
        var object = plan.payload()
        object["prune"] = prune
        return AttentionDetail.encode(object, listKey: "actions")
    }

    /// Resolve a specific pending request (user tapped Apply / Cancel, the
    /// bounded review deadline expired, or the owning chat was torn down).
    public func resolve(id: UUID, outcome: ConfigApprovalOutcome) {
        resolve(id: id, outcome: outcome, attention: nil)
    }

    /// `attention` says who answered and where; nil means the owner on the
    /// card (or the system, for timeouts and teardown).
    func resolve(id: UUID, outcome: ConfigApprovalOutcome, attention: AttentionResolution?) {
        pending.removeAll { $0.id == id }
        timeoutTasks.removeValue(forKey: id)?.cancel()
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        AttentionCenter.shared.resolve(id: id, with: attention ?? Self.attentionResolution(for: outcome))
        AttentionProducers.endWaiting(itemId: id)
        continuation.resume(returning: outcome)
    }

    private static func attentionResolution(for outcome: ConfigApprovalOutcome) -> AttentionResolution {
        switch outcome {
        case .approved: return AttentionProducers.inline(.approved)
        case .denied: return AttentionProducers.inline(.denied)
        case .timedOut: return AttentionResolution(outcome: .timedOut, surface: .system)
        case .cancelled: return AttentionProducers.abandoned
        }
    }

    /// Answers a plan from the paired phone. False when the id is not a
    /// pending phone plan: already answered, timed out, or never the phone's.
    public func resolveFromPairedPhone(id: UUID, apply: Bool) -> Bool {
        guard pending.contains(where: { $0.id == id && $0.fromPairedPhone }) else { return false }
        resolve(
            id: id,
            outcome: apply ? .approved : .denied,
            attention: AttentionResolution(
                outcome: apply ? .approved : .denied,
                surface: .phone,
                decidedBy: .ownerDevice(L("Your other device"))
            )
        )
        return true
    }

    static let phoneDiffLimitBytes = 4096
    static let phoneDiffTruncationMarker = "\n… (diff truncated; open Osaurus on the Mac for the rest)"

    /// The card's diff for the phone list, cut on a line boundary at 4 KB.
    static func phoneDiffText(_ diff: String) -> String {
        guard diff.utf8.count > phoneDiffLimitBytes else { return diff }
        let budget = phoneDiffLimitBytes - phoneDiffTruncationMarker.utf8.count
        var kept = ""
        var used = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let cost = line.utf8.count + (kept.isEmpty ? 0 : 1)
            if used + cost > budget { break }
            kept += (kept.isEmpty ? "" : "\n") + line
            used += cost
        }
        return kept + phoneDiffTruncationMarker
    }

    /// The phone's pending plans as `GET /config/approvals` JSON.
    public func pairedPhoneListJSON() -> Data {
        let rows: [[String: Any]] = pending.filter(\.fromPairedPhone).map { request in
            var row = request.plan.payload()
            row["id"] = request.id.uuidString
            row["prune"] = request.prune
            row["summary"] = request.plan.summaryText()
            if let diff = request.plan.diffText { row["diffText"] = Self.phoneDiffText(diff) }
            return row
        }
        return (try? JSONSerialization.data(withJSONObject: ["approvals": rows], options: [.sortedKeys]))
            ?? Data(#"{"approvals":[]}"#.utf8)
    }

    /// Deny + clear every pending approval (chat teardown, Stop).
    public func cancelAll() {
        let affected = pending
        pending.removeAll()
        for request in affected {
            timeoutTasks.removeValue(forKey: request.id)?.cancel()
            guard let continuation = continuations.removeValue(forKey: request.id) else { continue }
            AttentionCenter.shared.resolve(id: request.id, with: AttentionProducers.abandoned)
            AttentionProducers.endWaiting(itemId: request.id)
            continuation.resume(returning: .cancelled)
        }
    }
}

/// Entry point the tool calls: prefers the in-chat card, falls back to the
/// generic modal panel when no chat surface is mounted, so an apply is
/// always human-gated on attended surfaces.
public enum ConfigApprovalService {
    public static func requestApproval(
        plan: ConfigPlan,
        prune: Bool,
        id: UUID = UUID()
    ) async -> ConfigApprovalOutcome {
        let useCard = await MainActor.run { ConfigApprovalQueue.shared.hasMountedSurface }
        if useCard {
            return await ConfigApprovalQueue.shared.requestApproval(plan: plan, prune: prune, id: id)
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

    /// The import card, or the generic panel with the card's default
    /// choices when no chat surface can show it.
    static func requestImportApproval(
        review: ChatImportReview,
        id: UUID = UUID()
    ) async -> (ConfigApprovalOutcome, [String: ChatImportItemChoice]) {
        let useCard = await MainActor.run { ConfigApprovalQueue.shared.hasMountedSurface }
        if useCard {
            return await ConfigApprovalQueue.shared.requestImportApproval(review: review, id: id)
        }
        let outcome = await ToolPermissionPromptService.requestPolicyApproval(
            toolName: "osaurus_import",
            description: "Install these items?\n\n" + review.plan.summaryText(),
            argumentsJSON: ""
        )
        return (outcome == .denied ? .denied : .approved, review.defaultChoices)
    }
}
