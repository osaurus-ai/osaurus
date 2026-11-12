//
//  SyncWorkflowActivities.swift
//  osaurus
//
//  Updates the Live Activity an iPhone shows for a workflow run it started (`workflow_push`):
//  each change to the run's card goes to the activity's own push token, through the push service.
//  End to end encrypted like workflow notifications: the run's name, this Mac's name and the steps
//  are sealed with the iPhone's content key; only a status, step counts and the end time travel in
//  the clear, and the iPhone's widget opens the rest as it draws. KEEP: never put readable content
//  in `content-state`.
//
//  iPhone side: `WorkflowRunActivity` and `WorkflowRunAttributes` in iOSaurus. The sealed card and
//  the state's keys must match `WorkflowRunAttributes.Card` and `.ContentState` there.
//

import CryptoKit
import Foundation
import OsaurusSync
import os

extension SyncDeviceFeedContract {
    /// iPhone: the Live Activities it shows for this Mac's runs, one namespace per iPhone.
    static let pushActivityNamespacePrefix = "ai.osaurus.push-activity/1/"

    struct PushActivities: Codable, Equatable, Sendable {
        var v: Int = 1
        var activities: [Entry]

        struct Entry: Codable, Equatable, Sendable {
            var runId: String
            /// The sealed grant from `pushGrant` for the activity's push token, base64.
            var grant: String
            var grantId: String
            var expiresMs: Int64
        }
    }
}

@MainActor
final class SyncWorkflowActivities {
    static let shared = SyncWorkflowActivities()

    nonisolated private static let log = Logger(subsystem: "ai.osaurus", category: "sync.push")

    struct Target: Equatable, Sendable {
        var device: String
        var runId: String
        var grant: Data
        var grantId: String
        var contentKey: Data
    }

    /// By run id (lowercased).
    private(set) var targets: [String: Target] = [:]
    /// What each activity last got, so only changes are sent.
    private var sent: [String: String] = [:]
    /// Runs whose activity got its final state.
    private var ended: Set<String> = []
    private var latestRuns: [SyncDeviceFeedContract.WorkflowRunEntry] = []
    private var refreshTask: Task<Void, Never>?

    private init() {}

    /// Reads the iPhones' activities again; content keys come from their push registrations.
    func refresh(registrations: [SyncWorkflowPush.Target]) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            guard let core = SyncService.shared.core else { return }
            let keys = Dictionary(registrations.map { ($0.device, $0.contentKey) }, uniquingKeysWith: { a, _ in a })
            let dropped = DroppedGrants.load(nowMs: SyncHostedRunContract.nowMs())
            let found = await Task.detached(priority: .utility) {
                Self.read(core: core, keys: keys, dropped: dropped, nowMs: SyncHostedRunContract.nowMs())
            }.value
            guard !Task.isCancelled else { return }
            let added = Set(found.keys).subtracting(targets.keys)
            targets = found
            if !added.isEmpty {
                Self.trace("\(added.count) new Live Activities")
                // A new activity gets the run's current state at once.
                for runId in added { sent[runId] = nil }
                update(latestRuns)
            }
        }
    }

    nonisolated static func read(
        core: SyncCore, keys: [String: Data], dropped: Set<String>, nowMs: Int64
    ) -> [String: Target] {
        let filter = ConversationFilter(
            tags: [
                Tag(key: SyncConversationMapper.TagKey.kind, value: SyncDeviceFeedContract.manageKind),
                Tag(key: SyncConversationMapper.TagKey.device, value: core.deviceKey()),
            ],
            limit: 10
        )
        var found: [String: Target] = [:]
        for conversation in (try? core.conversationsFiltered(filter: filter)) ?? [] {
            let byDevice = SyncDeviceFeedContract.perDevice(
                SyncDeviceFeedContract.PushActivities.self,
                prefix: SyncDeviceFeedContract.pushActivityNamespacePrefix,
                in: conversation
            )
            for (device, record) in byDevice {
                guard let key = keys[device] else { continue }
                for entry in record.activities where entry.expiresMs > nowMs && !dropped.contains(entry.grantId) {
                    guard let grant = Data(base64Encoded: entry.grant) else { continue }
                    let runId = entry.runId.lowercased()
                    found[runId] = Target(
                        device: device, runId: runId, grant: grant, grantId: entry.grantId, contentKey: key)
                }
            }
        }
        return found
    }

    /// Each runs list the runs feed computes: changed runs with an activity get an update.
    func update(_ runs: [SyncDeviceFeedContract.WorkflowRunEntry]) {
        latestRuns = runs
        guard !targets.isEmpty else { return }
        let macName = SyncService.deviceName
        for run in runs {
            let runId = run.card.runId.lowercased()
            guard let target = targets[runId], !ended.contains(runId) else { continue }
            let state = Self.state(run, macName: macName)
            guard sent[runId] != state.signature else { continue }
            sent[runId] = state.signature
            let isEnd = Self.endStatuses.contains(run.card.status)
            if isEnd { ended.insert(runId) }
            Self.trace("activity \(isEnd ? "end" : "update"): \(run.card.status) \(state.done)/\(state.total)")
            Task.detached(priority: .userInitiated) {
                guard let core = SyncService.shared.core else { return }
                let outcome = await Self.deliver(state, end: isEnd, to: target, core: core)
                await MainActor.run { SyncWorkflowActivities.shared.handle(outcome, target: target) }
            }
        }
    }

    private func handle(_ outcome: SyncWorkflowPush.Outcome, target: Target) {
        switch outcome {
        case .sent:
            break
        case .dropGrant(let why):
            Self.trace("activity grant dropped: \(why)")
            DroppedGrants.add(target.grantId, expiresMs: SyncHostedRunContract.nowMs() + 24 * 60 * 60 * 1000)
            targets[target.runId] = nil
        default:
            Self.trace("activity update not sent: \(outcome)")
        }
    }

    // MARK: State

    nonisolated static let endStatuses: Set<String> = ["completed", "failed", "cancelled", "needs_setup"]

    struct State: Sendable {
        var sealedCard: Data
        var status: String
        var done: Int
        var total: Int
        var endedMs: Int64?
        /// Status and every step's status: what makes an update worth sending.
        var signature: String
    }

    nonisolated static func state(_ run: SyncDeviceFeedContract.WorkflowRunEntry, macName: String) -> State {
        let shown = run.card.steps.filter { $0.status != "skipped" }
        let steps = shown.map { ["name": $0.name, "status": stepStatus($0.status)] }
        let done = shown.filter { $0.status == "done" || $0.status == "pinned" }.count
        // `WorkflowRunAttributes.Card` on the iPhone.
        let card: [String: Any] = ["name": run.card.name, "mac": macName, "steps": steps]
        let plain = (try? JSONSerialization.data(withJSONObject: card, options: [.sortedKeys])) ?? Data()
        let signature = ([run.card.status] + shown.map(\.status)).joined(separator: ",")
        return State(
            sealedCard: plain, status: run.card.status, done: done, total: shown.count,
            endedMs: endStatuses.contains(run.card.status) ? (run.finishedMs ?? SyncHostedRunContract.nowMs()) : nil,
            signature: signature)
    }

    /// The card's step statuses as the widget draws them.
    nonisolated static func stepStatus(_ status: String) -> String {
        switch status {
        case "done", "pinned": return "completed"
        case "running", "failed", "awaiting_user": return status
        case "waiting": return "awaiting_user"
        default: return "pending"
        }
    }

    /// The APNs payload: `content-state` matching `WorkflowRunAttributes.ContentState`, the card
    /// sealed inside it.
    nonisolated static func payload(_ state: State, end: Bool, key: Data, nowMs: Int64) throws -> Data {
        let sealed = try ChaChaPoly.seal(state.sealedCard, using: SymmetricKey(data: key)).combined
            .base64EncodedString()
        var content: [String: Any] = [
            "sealed": sealed, "status": state.status, "done": state.done, "total": state.total,
        ]
        if let endedMs = state.endedMs { content["endedMs"] = endedMs }
        let aps: [String: Any] = [
            "timestamp": nowMs / 1000,
            "event": end ? "end" : "update",
            "content-state": content,
        ]
        return try JSONSerialization.data(withJSONObject: ["aps": aps], options: [.sortedKeys])
    }

    nonisolated static func deliver(_ state: State, end: Bool, to target: Target, core: SyncCore) async
        -> SyncWorkflowPush.Outcome
    {
        do {
            let body = try payload(state, end: end, key: target.contentKey, nowMs: SyncHostedRunContract.nowMs())
            guard body.count <= 4096 else { return .failed("payload over 4 KB") }
            let request = try core.pushSendRequest(
                grant: target.grant, kind: .liveActivity, collapseId: nil, payload: body)
            return await SyncWorkflowPush.post(request)
        } catch {
            return .failed(error.syncLogDetail)
        }
    }

    nonisolated private static func trace(_ line: @autoclosure () -> String) {
        #if DEBUG
            print("[SyncPush] \(line())")
        #endif
    }
}
