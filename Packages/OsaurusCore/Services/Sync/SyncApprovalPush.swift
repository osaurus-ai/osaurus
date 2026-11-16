//
//  SyncApprovalPush.swift
//  osaurus
//
//  Approvals a chat run for an iPhone waits on (`SyncHostRunner`, `approval/1`
//  in the chat). The card is in the chat, which only that iPhone shows, so once
//  the app is closed nothing said a run was waiting and it waited unseen.
//
//  - A notification to each iPhone that asked for these in its push
//    registration (`approval` in its events), sealed with its content key. When
//    the approvals are answered or go, a background push clears it.
//  - When the user arranged a call from this chat (`arrange_callback`), the
//    agent calls instead: the call reads the card out and takes a yes or no.
//    That call doesn't use the arranged call up, so the agent can still call
//    with the result.
//

import CryptoKit
import Foundation
import OsaurusSync
import os

@MainActor
final class SyncApprovalPush {
    static let shared = SyncApprovalPush()

    nonisolated private static let log = Logger(subsystem: "ai.osaurus", category: "sync.approval-push")

    /// The registration event an iPhone asks for these with.
    nonisolated static let event = "approval"
    /// The registration event for being called about it too, when a call was arranged.
    nonisolated static let callEvent = "approval_call"

    /// Approval calls in progress, by session: one at a time per chat.
    private var calling: Set<UUID> = []
    /// Each chat's approval calls: when the last rang, and how many in a row went unanswered. An arranged
    /// call isn't used up by them, so without these an agent could ring once per approval, back to back.
    private var approvalCalls: [UUID: (lastMs: Int64, missed: Int)] = [:]

    private init() {}

    /// The approvals `sessionId`'s run waits on changed from `before` to `after`. `requester` is
    /// the device that asked for the run; nil when the Mac continued the chat itself (a helper's
    /// report), and then every iPhone that asked for these hears.
    func changed(
        sessionId: UUID,
        agentId: UUID?,
        requester: String?,
        onCall: Bool = false,
        before: [SyncHostedRunContract.PendingApproval],
        after: [SyncHostedRunContract.PendingApproval]
    ) {
        // A turn of a live call: the call reads the card out and hears the answer. A notice, or a
        // second call, rang through the one the user was on (2026-11-16).
        let quiet = onCall || SyncAgentCalls.shared.isOnCall(sessionId: sessionId)
        let known = Set(before.map(\.id))
        let added = after.filter { !known.contains($0.id) }
        let targets = SyncWorkflowPush.shared.targets.filter {
            $0.registration.events.contains(Self.event) && (requester == nil || $0.device == requester)
        }
        if let first = added.first, !quiet {
            let agentName = agentId.map(resolveAgentDisplayName) ?? L("Your agent")
            let what = Self.summary(first)
            Self.trace(
                "\(added.count) approvals waiting in \(sessionId.uuidString.prefix(8)); \(targets.count) iPhones")
            for target in targets {
                send(.waiting(agentName: agentName, what: what), sessionId: sessionId, agentId: agentId, to: target)
            }
            // Called, rather than only notified, when a device asked for that ("Call Me for Approvals").
            let wantsCall = targets.contains { $0.registration.events.contains(Self.callEvent) }
            if let agentId, wantsCall {
                callIfArranged(sessionId: sessionId, agentId: agentId, agentName: agentName, what: what)
            }
        } else if after.isEmpty, !before.isEmpty {
            for target in targets {
                send(.cleared, sessionId: sessionId, agentId: agentId, to: target)
            }
        }
    }

    /// What the approval is for, short: the first sentence of the tool's own description (written
    /// for the model, a paragraph long), else its name. Never the arguments: a command read out
    /// in the call means nothing by ear, and the card shows it.
    nonisolated static func summary(_ approval: SyncHostedRunContract.PendingApproval) -> String {
        let description = approval.description.trimmingCharacters(in: .whitespacesAndNewlines)
        var line = description.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if let end = line.range(of: ". ") { line = String(line[..<end.lowerBound]) }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return String((line.isEmpty ? approval.tool : line).prefix(160))
    }

    // MARK: Calling

    /// The user asked to be called from this chat: the call is how they hear about it.
    private func callIfArranged(sessionId: UUID, agentId: UUID, agentName: String, what: String) {
        let policy = AgentCallPolicy.shared
        let nowMs = SyncHostedRunContract.nowMs()
        let previous = approvalCalls[sessionId]
        // As spaced as the agent's own calls, and not again after two in a row went unanswered.
        if let previous,
            previous.lastMs > nowMs - AgentCallPolicy.spacingMs
                || previous.missed >= AgentCallPolicy.missedInRowCap
        {
            Self.trace("not calling about the approval in \(sessionId.uuidString.prefix(8)): too soon or missed")
            return
        }
        guard !calling.contains(sessionId), SyncAgentCalls.shared.canRing,
            case .arranged = policy.decide(agentId: agentId, sessionId: sessionId, nowMs: nowMs)
        else { return }
        approvalCalls[sessionId] = (nowMs, previous?.missed ?? 0)
        calling.insert(sessionId)
        // Counted toward the agent's calls a day, but the arranged call is kept for the result.
        policy.rang(.onItsOwn, agentId: agentId, nowMs: nowMs)
        Self.trace("calling about the approval in \(sessionId.uuidString.prefix(8))")
        Task { @MainActor in
            let outcome = await SyncAgentCalls.shared.ring(
                SyncAgentCalls.Request(
                    agentId: agentId,
                    agentName: agentName,
                    sessionId: sessionId,
                    opening: L("I need your OK before I go on: \(what)"),
                    reason: L("Needs your approval")
                )
            )
            Self.trace("approval call in \(sessionId.uuidString.prefix(8)): \(outcome.rawValue)")
            SyncApprovalPush.shared.calling.remove(sessionId)
            SyncApprovalPush.shared.noteApprovalCall(outcome, sessionId: sessionId, agentId: agentId)
        }
    }

    /// Counts an unanswered approval call against the chat and the agent, as its own calls are.
    private func noteApprovalCall(_ outcome: SyncAgentCalls.Outcome, sessionId: UUID, agentId: UUID) {
        let nowMs = SyncHostedRunContract.nowMs()
        switch outcome {
        case .answered:
            approvalCalls[sessionId]?.missed = 0
        case .missed, .declined:
            approvalCalls[sessionId]?.missed += 1
        case .busy, .unavailable, .cancelled, .notSent:
            break
        }
        AgentCallPolicy.shared.ended(outcome, decision: .onItsOwn, agentId: agentId, nowMs: nowMs)
    }

    // MARK: Notifications

    enum Notice: Sendable {
        case waiting(agentName: String, what: String)
        case cleared
    }

    private func send(_ notice: Notice, sessionId: UUID, agentId: UUID?, to target: SyncWorkflowPush.Target) {
        Task.detached(priority: .utility) {
            guard let core = SyncService.shared.core else { return }
            do {
                let payload = try Self.payload(
                    notice, sessionId: sessionId, agentId: agentId, key: target.contentKey, macDevice: core.deviceKey())
                let body: Data
                switch notice {
                case .waiting:
                    body = try core.pushSendRequest(
                        grant: target.grant,
                        kind: .alert,
                        collapseId: "approval-" + sessionId.uuidString.lowercased(),
                        payload: payload
                    )
                case .cleared:
                    body = try core.pushSendRequest(
                        grant: target.grant, kind: .background, collapseId: nil, payload: payload)
                }
                let outcome = await SyncWorkflowPush.post(body)
                if outcome != .sent { Self.trace("approval notice to \(target.device.prefix(8)): \(outcome)") }
            } catch {
                Self.log.error("approval notice not sent: \(error.syncLogDetail, privacy: .public)")
            }
        }
    }

    /// The agent's name and what it waits on are sealed; the alert in the clear is generic.
    nonisolated static func payload(
        _ notice: Notice,
        sessionId: UUID,
        agentId: UUID?,
        key: Data,
        macDevice: String
    ) throws -> Data {
        var content: [String: Any] = [
            "v": 1,
            "device": macDevice,
            "sessionId": sessionId.uuidString.lowercased(),
        ]
        if let agentId { content["agentId"] = agentId.uuidString.lowercased() }
        let aps: [String: Any]
        switch notice {
        case .waiting(let agentName, let what):
            content["event"] = event
            content["title"] = String(agentName.prefix(100))
            content["body"] = L("Needs your approval") + ": " + what
            aps = [
                "alert": ["title": L("Approval needed"), "body": L("Open Osaurus to see it.")],
                "mutable-content": 1,
                "sound": "default",
                "thread-id": "approval-" + sessionId.uuidString.lowercased(),
            ]
        case .cleared:
            content["event"] = "approval_cleared"
            aps = ["content-available": 1]
        }
        let plain = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
        let sealed = try ChaChaPoly.seal(plain, using: SymmetricKey(data: key)).combined.base64EncodedString()
        return try JSONSerialization.data(withJSONObject: ["aps": aps, "o": sealed], options: [.sortedKeys])
    }

    /// Debug builds: to the console, so `tmp/osaurus.log` has it. Never tokens, grants or keys.
    nonisolated private static func trace(_ line: @autoclosure () -> String) {
        #if DEBUG
            print("[SyncApproval] \(line())")
        #endif
    }
}
