//
//  SyncAgentCalls.swift
//  osaurus
//
//  An agent calling the user back (`agent_calls`, docs/SYNC_MOBILE_CONTRACT.md
//  §5.7). Each iPhone or iPad set to ring for agent calls adds a PushKit
//  grant to its push registration on this Mac's manage conversation. A call
//  rings every one of them through the push service, sealed with that
//  device's content key, and the first to answer takes it: the others are
//  called off. A call nobody takes leaves a missed-call notification.
//
//  Each device answers in `ai.osaurus.call-answer/1/<its device key>`. The
//  call's state is in the manage state too (`call`), so a device whose
//  call-off push was lost still stops ringing.
//
//  One call at a time on this Mac. The talking itself is an ordinary voice
//  call on the chat, which the phone starts once answered.
//

import CryptoKit
import Foundation
import OsaurusSync
import os

extension SyncDeviceFeedContract {
    /// iPhone: its answer to the latest call, one namespace per device.
    static let callAnswerNamespacePrefix = "ai.osaurus.call-answer/1/"

    struct CallAnswer: Codable, Equatable, Sendable {
        var v: Int = 1
        var callId: String
        /// `answered`, `declined`, `missed` (rang out on the device) or `busy` (another call on).
        var outcome: String
        var atMs: Int64
    }

    /// The call this Mac is placing, in the manage state.
    struct CallState: Codable, Equatable, Sendable {
        var callId: String
        /// `ringing`, `answered` or `ended`.
        var state: String
        /// The device that took it.
        var answeredBy: String?
    }
}

@MainActor
final class SyncAgentCalls {
    static let shared = SyncAgentCalls()

    nonisolated private static let log = Logger(subsystem: "ai.osaurus", category: "sync.calls")

    /// How long a call rings before it counts as missed. The phone gives up at the same time.
    nonisolated static let ringSeconds: Double = 40
    /// Extra wait for the last answers to sync after the ring time.
    nonisolated static let answerSlackSeconds: Double = 5
    /// How long the ended state stays in the manage state.
    nonisolated static let endedStateSeconds: Double = 60

    enum Outcome: String, Sendable {
        case answered, declined, missed, busy, unavailable
        /// The run that placed the call stopped while it rang.
        case cancelled
        /// The push service couldn't be reached, or failed, for every device.
        case notSent
    }

    struct Request: Sendable {
        var agentId: UUID
        var agentName: String
        /// The chat the call is on; the phone opens it when answered.
        var sessionId: UUID
        /// What the agent says first when the user picks up.
        var opening: String
        /// For the missed-call notification.
        var reason: String?
    }

    /// A device that rings for agent calls.
    struct CallTarget: Equatable, Sendable {
        var device: String
        var voipGrant: Data
        var voipGrantId: String
        var push: SyncWorkflowPush.Target
    }

    private struct Active {
        let id: String
        let request: Request
        let rang: [CallTarget]
        var answers: [String: String] = [:]
        var failedSends = 0
        var droppedSends = 0
        var continuation: CheckedContinuation<Outcome, Never>?
        var timeout: Task<Void, Never>?
    }

    /// The call in progress, for the manage state.
    private(set) var state: SyncDeviceFeedContract.CallState?
    private var current: Active?
    private var clearStateTask: Task<Void, Never>?

    private init() {}

    // MARK: Who rings

    /// The registered devices set to ring, with a PushKit grant that still works.
    var targets: [CallTarget] {
        Self.callTargets(
            SyncWorkflowPush.shared.targets,
            dropped: DroppedGrants.load(nowMs: SyncHostedRunContract.nowMs()),
            nowMs: SyncHostedRunContract.nowMs()
        )
    }

    /// True when a call would ring at least one device.
    var canRing: Bool { !targets.isEmpty }

    /// The agent call tools' names, in the schema only while `ringAvailable`.
    nonisolated static let toolNames: Set<String> = [CallUserTool.toolName, ArrangeCallbackTool.toolName]

    /// When the last of the ringing devices' calling grants runs out, as of the last registrations
    /// read; 0 with none. A time rather than a flag, so the tools go when the grants do.
    private nonisolated static let availableUntilMs = OSAllocatedUnfairLock<Int64>(initialState: 0)
    private var expiryTask: Task<Void, Never>?
    /// `ringAvailable` as the tools list was last told: read again when the grants run out, the
    /// time has already passed, so the old value can't come from it.
    private var listedAvailable = false

    /// `canRing` as of the last registrations read, for the prompt composer off the main actor.
    nonisolated static var ringAvailable: Bool {
        availableUntilMs.withLock { $0 } > SyncHostedRunContract.nowMs()
    }

    /// The registrations were read again (`SyncWorkflowPush.refresh`).
    func registrationsChanged() {
        let until = targets.map { $0.push.registration.voipExpiresMs ?? 0 }.max() ?? 0
        Self.availableUntilMs.withLock { $0 = until }
        let now = Self.ringAvailable
        if listedAvailable != now {
            listedAvailable = now
            Self.trace(now ? "a device rings for agent calls" : "no device rings for agent calls")
            NotificationCenter.default.post(name: .toolsListChanged, object: nil)
        }
        // The last grant running out with nothing else changing: read again then, so the tools go.
        expiryTask?.cancel()
        guard now else { return }
        let waitMs = until - SyncHostedRunContract.nowMs() + 1000
        expiryTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(waitMs))
            guard !Task.isCancelled else { return }
            SyncAgentCalls.shared.registrationsChanged()
        }
    }

    nonisolated static func callTargets(
        _ targets: [SyncWorkflowPush.Target],
        dropped: Set<String>,
        nowMs: Int64
    ) -> [CallTarget] {
        targets.compactMap { target in
            let registration = target.registration
            guard registration.calls == true,
                let grantId = registration.voipGrantId, !dropped.contains(grantId),
                (registration.voipExpiresMs ?? 0) > nowMs,
                let grant = registration.voipGrant.flatMap({ Data(base64Encoded: $0) })
            else { return nil }
            return CallTarget(device: target.device, voipGrant: grant, voipGrantId: grantId, push: target)
        }
    }

    // MARK: Ringing

    /// Rings every device set to ring and waits for the outcome: the first answer, every device
    /// turning it down, or the ring time running out.
    func ring(_ request: Request) async -> Outcome {
        guard current == nil else { return .busy }
        let rang = targets
        guard !rang.isEmpty else { return .unavailable }
        let id = UUID().uuidString.lowercased()
        Self.trace("ringing \(rang.count) devices for \(request.agentName), call \(id.prefix(8))")
        setState(.init(callId: id, state: "ringing"))
        // The run that placed it stopped (a new message, Stop): the call is called off everywhere.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                current = Active(id: id, request: request, rang: rang, continuation: continuation)
                current?.timeout = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Self.ringSeconds + Self.answerSlackSeconds))
                    guard !Task.isCancelled else { return }
                    SyncAgentCalls.shared.finish(id, outcome: .missed)
                }
                for target in rang {
                    send(.ring, call: id, request: request, to: target)
                }
            }
        } onCancel: {
            Task { @MainActor in SyncAgentCalls.shared.finish(id, outcome: .cancelled) }
        }
    }

    enum CallPush: String, Sendable {
        case ring, cancel
    }

    private func send(_ kind: CallPush, call id: String, request: Request, to target: CallTarget) {
        Task.detached(priority: .userInitiated) {
            guard let core = SyncService.shared.core else { return }
            let outcome = await Self.deliver(kind, call: id, request: request, to: target, core: core)
            await MainActor.run { SyncAgentCalls.shared.sent(outcome, kind: kind, call: id, target: target) }
        }
    }

    private func sent(_ outcome: SyncWorkflowPush.Outcome, kind: CallPush, call id: String, target: CallTarget) {
        switch outcome {
        case .sent:
            Self.trace("\(kind.rawValue) sent to \(target.device.prefix(8))")
            return
        case .dropGrant(let why):
            Self.log.info("call grant dropped: \(why, privacy: .public)")
            DroppedGrants.add(target.voipGrantId, expiresMs: target.push.registration.voipExpiresMs ?? 0)
            SyncWorkflowPush.shared.refresh()
        case .wait, .retry, .failed:
            // A call can't wait: a ring that didn't go out now is a device that won't ring.
            Self.log.error("call push not sent: \(String(describing: outcome), privacy: .public)")
        }
        Self.trace("\(kind.rawValue) to \(target.device.prefix(8)) not sent: \(outcome)")
        guard kind == .ring, current?.id == id else { return }
        current?.failedSends += 1
        if case .dropGrant = outcome { current?.droppedSends += 1 }
        if let active = current, active.failedSends >= active.rang.count {
            // Every device's grant refused: none can ring. Otherwise the push service couldn't be
            // reached or failed, which says nothing about the devices (2026-11-16: a stopped local
            // service read as "no device is set to ring").
            finish(id, outcome: active.droppedSends == active.rang.count ? .unavailable : .notSent)
        }
    }

    /// The sealed payload: nothing in the clear, so the push service and Apple learn only that a
    /// call push was sent. The app opens it in-process (PushKit wakes the app, not an extension).
    nonisolated static func payload(
        _ kind: CallPush,
        call id: String,
        request: Request,
        key: Data,
        macDevice: String,
        nowMs: Int64
    ) throws -> Data {
        var content: [String: Any] = [
            "v": 1,
            "kind": kind.rawValue,
            "callId": id,
            "device": macDevice,
            "sentMs": nowMs,
        ]
        if kind == .ring {
            content["agentId"] = request.agentId.uuidString.lowercased()
            content["agentName"] = String(request.agentName.prefix(100))
            content["sessionId"] = request.sessionId.uuidString.lowercased()
            content["opening"] = String(request.opening.prefix(600))
            if let reason = request.reason { content["reason"] = String(reason.prefix(200)) }
        }
        let plain = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
        let sealed = try ChaChaPoly.seal(plain, using: SymmetricKey(data: key)).combined.base64EncodedString()
        return try JSONSerialization.data(withJSONObject: ["o": sealed], options: [.sortedKeys])
    }

    nonisolated static func deliver(
        _ kind: CallPush,
        call id: String,
        request: Request,
        to target: CallTarget,
        core: SyncCore
    ) async -> SyncWorkflowPush.Outcome {
        do {
            let payload = try payload(
                kind,
                call: id,
                request: request,
                key: target.push.contentKey,
                macDevice: core.deviceKey(),
                nowMs: SyncHostedRunContract.nowMs()
            )
            guard payload.count <= 4096 else { return .failed("payload over 4 KB") }
            let body = try core.pushSendRequest(grant: target.voipGrant, kind: .voip, collapseId: nil, payload: payload)
            return await SyncWorkflowPush.post(body)
        } catch {
            return .failed(error.syncLogDetail)
        }
    }

    // MARK: Answers

    /// The manage conversation changed: reads the devices' answers to the call ringing now.
    func manageChanged() {
        guard let core = SyncService.shared.core else { return }
        if let id = current?.id {
            Task { @MainActor in
                let answers = await Task.detached(priority: .userInitiated) { Self.answers(core: core, call: id) }.value
                SyncAgentCalls.shared.apply(answers, call: id)
            }
        }
        // Answered calls still on: the device that took the call writes `ended` when it hangs up.
        // Only its answer counts: another device can't say the user left a call it never had.
        let live = liveCalls
        guard !live.isEmpty else { return }
        Task { @MainActor in
            let ended = await Task.detached(priority: .utility) { () -> [UUID] in
                live.compactMap { sessionId, call in
                    Self.answers(core: core, call: call.id)[call.device] == "ended" ? sessionId : nil
                }
            }.value
            for sessionId in ended {
                SyncAgentCalls.shared.liveCalls[sessionId] = nil
                Self.trace("call on \(sessionId.uuidString.prefix(8)) ended")
            }
        }
    }

    // MARK: Calls on

    /// Answered calls, by chat, until the device says the call ended.
    private var liveCalls: [UUID: (id: String, device: String, sinceMs: Int64)] = [:]
    /// A call no device has said ended counts as over after this.
    nonisolated static let liveCallLimitMs: Int64 = 2 * 3600 * 1000

    /// Whether the user is on a call placed from `sessionId` now: the agent tells them in the call,
    /// and a ring would come through it as a second call the phone turns down as busy.
    func isOnCall(sessionId: UUID) -> Bool {
        guard let call = liveCalls[sessionId] else { return false }
        if SyncHostedRunContract.nowMs() - call.sinceMs > Self.liveCallLimitMs {
            liveCalls[sessionId] = nil
            return false
        }
        return true
    }

    /// Each device's answer to `call`, from every manage conversation of this Mac.
    nonisolated static func answers(core: SyncCore, call id: String) -> [String: String] {
        let filter = ConversationFilter(
            tags: [
                Tag(key: SyncConversationMapper.TagKey.kind, value: SyncDeviceFeedContract.manageKind),
                Tag(key: SyncConversationMapper.TagKey.device, value: core.deviceKey()),
            ],
            replication: .synced,
            limit: 10
        )
        var found: [String: String] = [:]
        for conversation in (try? core.conversationsFiltered(filter: filter)) ?? [] {
            let byDevice = SyncDeviceFeedContract.perDevice(
                SyncDeviceFeedContract.CallAnswer.self,
                prefix: SyncDeviceFeedContract.callAnswerNamespacePrefix,
                in: conversation,
                writtenByThatDevice: true,
                signedOnly: true
            )
            for (device, answer) in byDevice where answer.callId == id {
                found[device] = answer.outcome
            }
        }
        return found
    }

    private func apply(_ answers: [String: String], call id: String) {
        guard current?.id == id else { return }
        let rang = Set(current?.rang.map(\.device) ?? [])
        for (device, outcome) in answers where rang.contains(device) {
            current?.answers[device] = outcome
        }
        guard let active = current else { return }
        if let device = active.answers.first(where: { $0.value == "answered" })?.key {
            finish(id, outcome: .answered, answeredBy: device)
            return
        }
        guard let outcome = Self.outcome(answers: active.answers, rang: rang) else { return }
        finish(id, outcome: outcome)
    }

    /// The outcome once every device that rang has answered without taking the call; nil while
    /// one is still ringing.
    nonisolated static func outcome(answers: [String: String], rang: Set<String>) -> Outcome? {
        guard !rang.isEmpty, rang.allSatisfy({ answers[$0] != nil }) else { return nil }
        let given = rang.compactMap { answers[$0] }
        if given.contains("answered") { return .answered }
        if given.allSatisfy({ $0 == "busy" }) { return .busy }
        if given.contains("declined") { return .declined }
        return .missed
    }

    // MARK: Ending

    private func finish(_ id: String, outcome: Outcome, answeredBy: String? = nil) {
        guard var active = current, active.id == id else { return }
        current = nil
        active.timeout?.cancel()
        Self.log.info("call \(id.prefix(8), privacy: .public): \(outcome.rawValue, privacy: .public)")
        Self.trace("call \(id.prefix(8)) \(outcome.rawValue)\(answeredBy.map { " by \($0.prefix(8))" } ?? "")")
        // Devices still ringing stop: those that took or turned down the call already have.
        if outcome == .answered || outcome == .missed || outcome == .cancelled {
            for target in active.rang where active.answers[target.device] == nil {
                send(.cancel, call: id, request: active.request, to: target)
            }
        }
        setState(.init(callId: id, state: outcome == .answered ? "answered" : "ended", answeredBy: answeredBy))
        if outcome == .answered, let answeredBy {
            liveCalls[active.request.sessionId] = (id, answeredBy, SyncHostedRunContract.nowMs())
        }
        // Rang out with nobody taking it. A decline was the user's own choice, and the contract
        // (§5.7) sends the notice only for a call nobody took.
        if outcome == .missed {
            for target in active.rang {
                sendMissedCall(active.request, to: target.push)
            }
        }
        active.continuation?.resume(returning: outcome)
    }

    private func setState(_ next: SyncDeviceFeedContract.CallState?) {
        state = next
        SyncManageFeed.shared.schedulePublish()
        clearStateTask?.cancel()
        guard let next, next.state != "ringing" else { return }
        clearStateTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.endedStateSeconds))
            guard !Task.isCancelled, SyncAgentCalls.shared.state?.callId == next.callId else { return }
            SyncAgentCalls.shared.state = nil
            SyncManageFeed.shared.schedulePublish()
        }
    }

    // MARK: Missed calls

    /// A notification for a call nobody took, on the device's alert grant: the agent's name and
    /// the reason sealed, a generic line in the clear. A tap opens the chat.
    private func sendMissedCall(_ request: Request, to target: SyncWorkflowPush.Target) {
        Task.detached(priority: .utility) {
            guard let core = SyncService.shared.core else { return }
            do {
                let payload = try Self.missedCallPayload(request, key: target.contentKey, macDevice: core.deviceKey())
                let body = try core.pushSendRequest(
                    grant: target.grant,
                    kind: .alert,
                    collapseId: "call-" + request.sessionId.uuidString.lowercased(),
                    payload: payload
                )
                let outcome = await SyncWorkflowPush.post(body)
                if outcome != .sent { Self.trace("missed-call notice to \(target.device.prefix(8)): \(outcome)") }
            } catch {
                Self.log.error("missed-call notice not sent: \(error.syncLogDetail, privacy: .public)")
            }
        }
    }

    nonisolated static func missedCallPayload(_ request: Request, key: Data, macDevice: String) throws -> Data {
        let reason = request.reason.map { String($0.prefix(200)) }
        let content: [String: Any] = [
            "v": 1,
            "event": "missed_call",
            "device": macDevice,
            "agentId": request.agentId.uuidString.lowercased(),
            "sessionId": request.sessionId.uuidString.lowercased(),
            "title": String(request.agentName.prefix(100)),
            "body": reason.map { L("Missed call") + ": " + $0 } ?? L("Missed call"),
        ]
        let plain = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
        let sealed = try ChaChaPoly.seal(plain, using: SymmetricKey(data: key)).combined.base64EncodedString()
        let aps: [String: Any] = [
            "alert": ["title": L("Missed call"), "body": L("Open Osaurus to see it.")],
            "mutable-content": 1,
            "sound": "default",
        ]
        return try JSONSerialization.data(withJSONObject: ["aps": aps, "o": sealed], options: [.sortedKeys])
    }

    /// Debug builds: to the console, so `tmp/osaurus.log` has it. Never tokens, grants or keys.
    nonisolated private static func trace(_ line: @autoclosure () -> String) {
        #if DEBUG
            print("[SyncCall] \(line())")
        #endif
    }
}
