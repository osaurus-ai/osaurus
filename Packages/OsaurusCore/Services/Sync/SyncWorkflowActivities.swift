//
//  SyncWorkflowActivities.swift
//  osaurus
//
//  Live Activities on iPhones for workflow runs: an iPhone starts one for a run it started, and
//  this Mac starts one by push (push-to-start) for a run begun here. Each change to the run's card
//  then goes to the activity's own push token, through the push service.
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
        /// The grant for the iPhone's push-to-start token: starts an activity for a run begun on
        /// this Mac. Nil before iOS 17.2, or with Live Activities off.
        var start: Start?

        struct Entry: Codable, Equatable, Sendable {
            var runId: String
            /// The sealed grant from `pushGrant` for the activity's push token, base64.
            var grant: String
            var grantId: String
            var expiresMs: Int64
        }

        struct Start: Codable, Equatable, Sendable {
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
    /// Each iPhone's push-to-start grant, by its device key (`runId` empty).
    private(set) var starters: [String: Target] = [:]
    /// Runs an activity was started for by push; until the iPhone shares that activity's token
    /// (it wakes in the background to), the run's notifications carry on as before.
    private var pushStarted: Set<String> = []
    private var latestRuns: [SyncDeviceFeedContract.WorkflowRunEntry] = []
    private var refreshTask: Task<Void, Never>?
    /// Runs begun before this Mac's app started are history: no activity starts for them.
    private let sinceMs = SyncHostedRunContract.nowMs()

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
            let added = Set(found.targets.keys).subtracting(targets.keys)
            targets = found.targets
            starters = found.starters
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
    ) -> (targets: [String: Target], starters: [String: Target]) {
        let filter = ConversationFilter(
            tags: [
                Tag(key: SyncConversationMapper.TagKey.kind, value: SyncDeviceFeedContract.manageKind),
                Tag(key: SyncConversationMapper.TagKey.device, value: core.deviceKey()),
            ],
            limit: 10
        )
        var found: [String: Target] = [:]
        var starters: [String: Target] = [:]
        for conversation in (try? core.conversationsFiltered(filter: filter)) ?? [] {
            let byDevice = SyncDeviceFeedContract.perDevice(
                SyncDeviceFeedContract.PushActivities.self,
                prefix: SyncDeviceFeedContract.pushActivityNamespacePrefix,
                in: conversation
            )
            for (device, record) in byDevice {
                guard let key = keys[device] else { continue }
                if let start = record.start, start.expiresMs > nowMs, !dropped.contains(start.grantId),
                    let grant = Data(base64Encoded: start.grant)
                {
                    starters[device] = Target(
                        device: device, runId: "", grant: grant, grantId: start.grantId, contentKey: key)
                }
                for entry in record.activities where entry.expiresMs > nowMs && !dropped.contains(entry.grantId) {
                    guard let grant = Data(base64Encoded: entry.grant) else { continue }
                    let runId = entry.runId.lowercased()
                    found[runId] = Target(
                        device: device, runId: runId, grant: grant, grantId: entry.grantId, contentKey: key)
                }
            }
        }
        return (found, starters)
    }

    /// Each runs list the runs feed computes: changed runs with an activity get an update, and new
    /// runs begun on this Mac start one on each iPhone that can.
    func update(_ runs: [SyncDeviceFeedContract.WorkflowRunEntry]) {
        latestRuns = runs
        let macName = SyncService.deviceName
        if !starters.isEmpty { start(runs, macName: macName) }
        guard !targets.isEmpty else { return }
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
                let outcome = await Self.deliver(state, event: isEnd ? .end : .update, to: target, core: core)
                await MainActor.run { SyncWorkflowActivities.shared.handle(outcome, target: target) }
            }
        }
    }

    /// Runs begun here since launch, still going, with no activity yet. Not runs an iPhone started:
    /// that iPhone starts its own (and, with one iPhone, would get two).
    private func start(_ runs: [SyncDeviceFeedContract.WorkflowRunEntry], macName: String) {
        for run in runs {
            let runId = run.card.runId.lowercased()
            guard run.startedMs >= sinceMs, targets[runId] == nil, !pushStarted.contains(runId),
                !Self.endStatuses.contains(run.card.status),
                !SyncWorkflowPush.shared.wasStartedFromPhone(runId)
            else { continue }
            pushStarted.insert(runId)
            let state = Self.state(run, macName: macName)
            sent[runId] = state.signature
            let startedMs = run.startedMs
            for starter in starters.values {
                Self.trace("activity start: \(run.card.status) \(state.done)/\(state.total)")
                Task.detached(priority: .userInitiated) {
                    guard let core = SyncService.shared.core else { return }
                    let event = Event.start(runId: runId, mac: core.deviceKey(), startedMs: startedMs)
                    let outcome = await Self.deliver(state, event: event, to: starter, core: core)
                    await MainActor.run { SyncWorkflowActivities.shared.handle(outcome, target: starter) }
                }
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
            if target.runId.isEmpty {
                if starters[target.device]?.grantId == target.grantId { starters[target.device] = nil }
            } else {
                targets[target.runId] = nil
            }
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

    /// What a push does to the activity.
    enum Event: Sendable {
        /// Push-to-start: the attributes are `WorkflowRunAttributes`'s (ids, nothing readable).
        case start(runId: String, mac: String, startedMs: Int64)
        case update
        case end
    }

    /// The APNs payload: `content-state` matching `WorkflowRunAttributes.ContentState`, the card
    /// sealed inside it.
    nonisolated static func payload(_ state: State, event: Event, key: Data, nowMs: Int64) throws -> Data {
        let sealed = try ChaChaPoly.seal(state.sealedCard, using: SymmetricKey(data: key)).combined
            .base64EncodedString()
        var content: [String: Any] = [
            "sealed": sealed, "status": state.status, "done": state.done, "total": state.total,
        ]
        if let endedMs = state.endedMs { content["endedMs"] = endedMs }
        var aps: [String: Any] = ["timestamp": nowMs / 1000, "content-state": content]
        switch event {
        case .start(let runId, let mac, let startedMs):
            aps["event"] = "start"
            aps["attributes-type"] = "WorkflowRunAttributes"
            aps["attributes"] = ["device": mac, "runId": runId, "startedMs": startedMs]
            // iOS wants an alert to start an activity. KEEP generic: Apple reads it.
            aps["alert"] = ["title": "Workflow running", "body": "Its steps are on your Lock Screen."]
        case .update:
            aps["event"] = "update"
        case .end:
            aps["event"] = "end"
        }
        return try JSONSerialization.data(withJSONObject: ["aps": aps], options: [.sortedKeys])
    }

    nonisolated static func deliver(_ state: State, event: Event, to target: Target, core: SyncCore) async
        -> SyncWorkflowPush.Outcome
    {
        do {
            let body = try payload(state, event: event, key: target.contentKey, nowMs: SyncHostedRunContract.nowMs())
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
