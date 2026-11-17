//
//  AgentCallTools.swift
//  osaurus
//
//  An agent calling the user back on their iPhone (`SyncAgentCalls`).
//
//  `call_user` rings the devices set to ring and returns how it went. An
//  agent may ring only when the user allowed it:
//  - once, by approving `arrange_callback` in the chat ("call me when the
//    build finishes"). The approval is the user's own tap or spoken yes, so
//    text the agent read can't arrange a call. The grant is for that chat,
//    and the next call from it uses it up;
//  - or always, with "Call You" in the agent's settings, for calls it makes
//    on its own. Those are spaced out and capped (`AgentCallPolicy`).
//
//  Both tools are in the schema only while a device can ring.
//

import Foundation
import os

/// Who may ring the user, and how often.
@MainActor
final class AgentCallPolicy {
    static let shared = AgentCallPolicy()

    /// One call the user arranged, in one chat.
    struct Grant: Codable, Equatable, Sendable {
        var id: UUID
        var sessionId: UUID
        var agentId: UUID
        var about: String
        var expiresMs: Int64
    }

    struct State: Codable, Equatable, Sendable {
        /// Agents allowed to call on their own ("Call You").
        var allowed: Set<UUID> = []
        var grants: [Grant] = []
        /// Each agent's recent calls, for the spacing and the daily cap.
        var calls: [UUID: [Int64]] = [:]
        /// Calls in a row an agent made on its own that nobody took.
        var missedInRow: [UUID: Int] = [:]
        var lastMissMs: [UUID: Int64] = [:]
        /// Each agent's limit on calls in any 24 hours, set in its settings; absent, `defaultDailyCap`.
        /// Optional so a state saved before it was kept still reads.
        var dailyCaps: [UUID: Int]?
        /// Approval calls by chat (`AgentCallPolicy.ApprovalCalls`); optional so an older state still reads.
        var approvalCalls: [UUID: ApprovalCalls]?

        func dailyCap(for agentId: UUID) -> Int {
            dailyCaps?[agentId] ?? AgentCallPolicy.defaultDailyCap
        }
    }

    /// Between two calls an agent makes on its own.
    nonisolated static let spacingMs: Int64 = 10 * 60 * 1000
    /// Calls per agent in any 24 hours, arranged ones included: a backstop, generous by default and
    /// set per agent in its settings ("Calls a Day").
    nonisolated static let defaultDailyCap = 10
    nonisolated static let dailyCapRange = 1 ... 100
    /// After this many unanswered calls in a row, an agent can't call on its own for a day.
    nonisolated static let missedInRowCap = 2
    nonisolated static let dayMs: Int64 = 24 * 3600 * 1000
    /// How long an arranged call may wait, by default and at most.
    nonisolated static let defaultGrantHours = 24
    nonisolated static let maxGrantHours = 72

    private static let defaultsKey = "AgentCallPolicy"
    private var state: State

    private init() {
        state = (UserDefaults.standard.data(forKey: Self.defaultsKey))
            .flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: "Call You"

    func isAllowed(_ agentId: UUID) -> Bool { state.allowed.contains(agentId) }

    func setAllowed(_ allowed: Bool, agentId: UUID) {
        if allowed { state.allowed.insert(agentId) } else { state.allowed.remove(agentId) }
        state.missedInRow[agentId] = nil
        save()
    }

    func dailyCap(for agentId: UUID) -> Int { state.dailyCap(for: agentId) }

    func setDailyCap(_ cap: Int, agentId: UUID) {
        let clamped = min(max(cap, Self.dailyCapRange.lowerBound), Self.dailyCapRange.upperBound)
        state.dailyCaps = (state.dailyCaps ?? [:]).merging([agentId: clamped]) { $1 }
        save()
    }

    // MARK: Arranged calls

    func arrange(sessionId: UUID, agentId: UUID, about: String, hours: Int, nowMs: Int64) -> Grant {
        let clamped = min(max(hours, 1), Self.maxGrantHours)
        let grant = Grant(
            id: UUID(),
            sessionId: sessionId,
            agentId: agentId,
            about: String(about.prefix(200)),
            expiresMs: nowMs + Int64(clamped) * 3600 * 1000
        )
        // One arranged call per chat and agent: a new one replaces the old.
        state.grants.removeAll { ($0.sessionId == sessionId && $0.agentId == agentId) || $0.expiresMs <= nowMs }
        state.grants.append(grant)
        save()
        return grant
    }

    // MARK: Deciding

    enum Decision: Equatable, Sendable {
        /// Arranged by the user: uses up this grant.
        case arranged(UUID)
        case onItsOwn
        case refused(String)
    }

    func decide(agentId: UUID, sessionId: UUID, nowMs: Int64) -> Decision {
        Self.decide(state, agentId: agentId, sessionId: sessionId, nowMs: nowMs)
    }

    nonisolated static func decide(_ state: State, agentId: UUID, sessionId: UUID, nowMs: Int64) -> Decision {
        let recent = (state.calls[agentId] ?? []).filter { $0 > nowMs - dayMs }
        let cap = state.dailyCap(for: agentId)
        if recent.count >= cap {
            return .refused(
                "This agent has called \(cap) times in the last 24 hours, its limit. Use `notify` instead, "
                    + "or ask the user to raise Calls a Day in its settings."
            )
        }
        if let grant = state.grants.first(where: {
            $0.sessionId == sessionId && $0.agentId == agentId && $0.expiresMs > nowMs
        }) {
            return .arranged(grant.id)
        }
        guard state.allowed.contains(agentId) else {
            return .refused(
                "The user hasn't asked for a call. Call only after `arrange_callback` was approved in this chat, "
                    + "or when the user allows this agent to call in its settings. Use `notify` instead."
            )
        }
        if lockedOut(state, agentId: agentId, nowMs: nowMs) {
            let misses = state.missedInRow[agentId] ?? 0
            return .refused("The user missed your last \(misses) calls. Use `notify` instead.")
        }
        if let last = recent.max(), last > nowMs - spacingMs {
            return .refused("You called less than 10 minutes ago. Use `notify` instead, or wait.")
        }
        return .onItsOwn
    }

    /// A call is about to ring: counts it and takes the grant it was arranged with, before the
    /// ring, so a second call can't pass `decide` while this one rings. `ended` gives both back
    /// when nothing rang.
    func rang(_ decision: Decision, agentId: UUID, nowMs: Int64) -> Grant? {
        let taken = Self.rang(&state, decision: decision, agentId: agentId, nowMs: nowMs)
        save()
        return taken
    }

    func ended(_ outcome: SyncAgentCalls.Outcome, decision: Decision, agentId: UUID, rangMs: Int64, taken: Grant?) {
        Self.ended(
            &state, outcome: outcome, decision: decision, agentId: agentId, rangMs: rangMs, taken: taken,
            nowMs: SyncHostedRunContract.nowMs())
        save()
    }

    nonisolated static func rang(_ state: inout State, decision: Decision, agentId: UUID, nowMs: Int64) -> Grant? {
        var recent = (state.calls[agentId] ?? []).filter { $0 > nowMs - dayMs }
        recent.append(nowMs)
        state.calls[agentId] = recent
        guard case .arranged(let id) = decision, let index = state.grants.firstIndex(where: { $0.id == id })
        else { return nil }
        return state.grants.remove(at: index)
    }

    /// Whether `outcome` means a device rang: only then does the call count and the grant stay used.
    nonisolated static func didRing(_ outcome: SyncAgentCalls.Outcome) -> Bool {
        switch outcome {
        case .answered, .missed, .declined, .cancelled: return true
        case .busy, .unavailable, .notSent: return false
        }
    }

    nonisolated static func ended(
        _ state: inout State,
        outcome: SyncAgentCalls.Outcome,
        decision: Decision,
        agentId: UUID,
        rangMs: Int64,
        taken: Grant?,
        nowMs: Int64
    ) {
        guard didRing(outcome) else {
            // Nothing rang (another call on, no device, the push service down): the call isn't
            // counted, and the user's arranged call is kept unless they arranged a new one since.
            if var calls = state.calls[agentId], let index = calls.lastIndex(of: rangMs) {
                calls.remove(at: index)
                state.calls[agentId] = calls
            }
            if let taken, taken.expiresMs > nowMs,
                !state.grants.contains(where: { $0.sessionId == taken.sessionId && $0.agentId == taken.agentId })
            {
                state.grants.append(taken)
            }
            return
        }
        switch outcome {
        case .answered:
            state.missedInRow[agentId] = nil
        case .missed, .declined:
            guard decision == .onItsOwn else { return }
            // Misses before a day-long lockout ended don't count toward the next one.
            if let last = state.lastMissMs[agentId], last <= nowMs - dayMs { state.missedInRow[agentId] = nil }
            state.missedInRow[agentId, default: 0] += 1
            state.lastMissMs[agentId] = nowMs
        default:
            break
        }
    }

    /// Whether the agent's own calls are locked out after two misses in a row.
    nonisolated static func lockedOut(_ state: State, agentId: UUID, nowMs: Int64) -> Bool {
        let misses = state.missedInRow[agentId] ?? 0
        guard misses >= missedInRowCap, let last = state.lastMissMs[agentId] else { return false }
        return last > nowMs - dayMs
    }

    // MARK: Approval calls

    /// Each chat's approval calls (`SyncApprovalPush`), kept with the rest so a relaunch doesn't
    /// reset the spacing or the stop after two in a row went unanswered.
    struct ApprovalCalls: Codable, Equatable, Sendable {
        var lastMs: Int64
        var missed: Int
    }

    /// Whether an approval call may ring in `sessionId` now, and if so marks it rung.
    func startApprovalCall(sessionId: UUID, agentId: UUID, nowMs: Int64) -> Bool {
        guard Self.mayCallAboutApproval(state, sessionId: sessionId, agentId: agentId, nowMs: nowMs) else {
            return false
        }
        var calls = (state.approvalCalls ?? [:]).filter { $0.value.lastMs > nowMs - Self.dayMs }
        calls[sessionId] = ApprovalCalls(lastMs: nowMs, missed: calls[sessionId]?.missed ?? 0)
        state.approvalCalls = calls
        save()
        return true
    }

    func endedApprovalCall(_ outcome: SyncAgentCalls.Outcome, sessionId: UUID) {
        switch outcome {
        case .answered: state.approvalCalls?[sessionId]?.missed = 0
        case .missed, .declined: state.approvalCalls?[sessionId]?.missed += 1
        case .busy, .unavailable, .cancelled, .notSent: return
        }
        save()
    }

    /// As spaced as the agent's own calls, not again after two in a row went unanswered in this
    /// chat, and never while the agent itself is locked out for missed calls.
    nonisolated static func mayCallAboutApproval(_ state: State, sessionId: UUID, agentId: UUID, nowMs: Int64) -> Bool {
        if lockedOut(state, agentId: agentId, nowMs: nowMs) { return false }
        guard let previous = state.approvalCalls?[sessionId], previous.lastMs > nowMs - dayMs else { return true }
        return previous.lastMs <= nowMs - spacingMs && previous.missed < missedInRowCap
    }
}

// MARK: - call_user

final class CallUserTool: OsaurusTool, @unchecked Sendable {
    static let toolName = "call_user"
    let name = CallUserTool.toolName
    let description =
        "Ring the user's iPhone as a phone call, and talk with them when they pick up. Call only "
        + "after the user approved `arrange_callback` in this chat, or when you're allowed to call "
        + "on your own; otherwise use `notify`. `opening` is the first thing you say when they "
        + "answer: say why you're calling and the result, in one or two sentences. Waits up to "
        + "about 45 seconds and returns `answered`, `declined`, `missed`, `busy` or `unavailable`."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "opening": .object([
                "type": .string("string"),
                "description": .string("What you say first when the user answers. One or two sentences."),
            ]),
            "reason": .object([
                "type": .string("string"),
                "description": .string(
                    "A few words for the missed-call notification if they don't answer, e.g. \"Build finished\"."
                ),
            ]),
        ]),
        "required": .array([.string("opening")]),
    ])

    /// Rings for longer than the registry's default limit allows.
    var bypassRegistryTimeout: Bool { true }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let agentReq = DatabaseToolHelpers.requireAgentId(tool: name)
        guard case .value(let agentId) = agentReq else { return agentReq.failureEnvelope ?? "" }
        let openingReq = requireString(args, "opening", expected: "what you say first", tool: name)
        guard case .value(let opening) = openingReq else { return openingReq.failureEnvelope ?? "" }
        let reasonReq = optionalString(args, "reason", expected: "a few words for a missed call")
        guard case .value(let reason) = reasonReq else { return reasonReq.failureEnvelope ?? "" }

        // Already on a call with the user (this turn is one of its turns): nothing to ring, and
        // ringing came through as a second call the phone turned down as busy (2026-11-16).
        let onCall = ToolEnvelope.success(
            tool: name,
            result: [
                "outcome": "on_call",
                "note": "You're on a live call with the user right now. Say it to them directly; "
                    + "the arranged call isn't needed.",
            ]
        )
        if ChatExecutionContext.isVoiceCall { return onCall }
        // The phone opens the call's chat when answered, so it must be a chat it can see.
        guard ChatExecutionContext.currentSessionSource == .chat,
            let sessionId = ChatExecutionContext.currentSessionId.flatMap(UUID.init(uuidString:))
        else {
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "Calls can be made only from a chat. Use `notify` instead.",
                tool: name,
                retryable: false
            )
        }
        // A call placed from this chat is still on (one the agent made to ask for an approval,
        // say): the user is listening, and the run that placed it isn't one of its turns.
        if await MainActor.run(body: { SyncAgentCalls.shared.isOnCall(sessionId: sessionId) }) { return onCall }

        let outcome: SyncAgentCalls.Outcome
        do {
            outcome = try await Self.call(agentId: agentId, sessionId: sessionId, opening: opening, reason: reason)
        } catch let refusal as Refusal {
            return ToolEnvelope.failure(kind: .rejected, message: refusal.message, tool: name, retryable: false)
        }
        return ToolEnvelope.success(tool: name, result: ["outcome": outcome.rawValue, "note": Self.note(outcome)])
    }

    struct Refusal: Error {
        let message: String
    }

    @MainActor
    private static func call(
        agentId: UUID,
        sessionId: UUID,
        opening: String,
        reason: String?
    ) async throws -> SyncAgentCalls.Outcome {
        let calls = SyncAgentCalls.shared
        guard calls.canRing else { return .unavailable }
        let policy = AgentCallPolicy.shared
        let nowMs = SyncHostedRunContract.nowMs()
        let decision = policy.decide(agentId: agentId, sessionId: sessionId, nowMs: nowMs)
        if case .refused(let why) = decision { throw Refusal(message: why) }
        let taken = policy.rang(decision, agentId: agentId, nowMs: nowMs)
        let outcome = await calls.ring(
            SyncAgentCalls.Request(
                agentId: agentId,
                agentName: resolveAgentDisplayName(agentId),
                sessionId: sessionId,
                opening: opening,
                reason: reason
            )
        )
        policy.ended(outcome, decision: decision, agentId: agentId, rangMs: nowMs, taken: taken)
        return outcome
    }

    static func note(_ outcome: SyncAgentCalls.Outcome) -> String {
        switch outcome {
        case .answered:
            return "The user picked up and is hearing your opening now. End your turn without more "
                + "text: they'll talk to you in the call."
        case .declined:
            return "The user declined the call. Don't call again about this; tell them in the chat instead."
        case .missed:
            return "Nobody answered. The user got a missed-call notification with your reason. "
                + "Put what you would have said in your reply, and don't call again right away."
        case .busy:
            return "The user is on another call. Tell them in the chat instead."
        case .unavailable:
            return "No device is set to ring for agent calls. Tell the user in the chat instead."
        case .cancelled:
            return "The call was called off before anyone answered."
        case .notSent:
            return "The call couldn't be placed: Osaurus couldn't reach its push service. Tell the user in the chat "
                + "instead, and that calls aren't getting through right now."
        }
    }
}

// MARK: - arrange_callback

final class ArrangeCallbackTool: OsaurusTool, PermissionedTool, PerCallApprovalTool, @unchecked Sendable {
    static let toolName = "arrange_callback"
    let name = ArrangeCallbackTool.toolName
    let description =
        "When the user asks you to call them back later (\"call me when the build is done\"), "
        + "call this first: they approve one call from this chat. Then start the work, in the "
        + "background if it is long, and once its result is in this chat, use `call_user`. "
        + "Never call it unless the user asked for a call."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "about": .object([
                "type": .string("string"),
                "description": .string("When you'll call, in the user's words, e.g. \"when the build finishes\"."),
            ]),
            "within_hours": .object([
                "type": .string("integer"),
                "description": .string("How long the call may wait. Default 24, at most 72."),
            ]),
        ]),
        "required": .array([.string("about")]),
    ])

    var requirements: [String] { [] }
    /// The approval is what arranges the call, so it is asked every time.
    var defaultPermissionPolicy: ToolPermissionPolicy { .ask }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let agentReq = DatabaseToolHelpers.requireAgentId(tool: name)
        guard case .value(let agentId) = agentReq else { return agentReq.failureEnvelope ?? "" }
        let aboutReq = requireString(args, "about", expected: "when you'll call", tool: name)
        guard case .value(let about) = aboutReq else { return aboutReq.failureEnvelope ?? "" }
        let hours = coerceInt(args["within_hours"]) ?? AgentCallPolicy.defaultGrantHours

        guard ChatExecutionContext.currentSessionSource == .chat,
            let sessionId = ChatExecutionContext.currentSessionId.flatMap(UUID.init(uuidString:))
        else {
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "A call can be arranged only in a chat.",
                tool: name,
                retryable: false
            )
        }
        let grant = await MainActor.run {
            AgentCallPolicy.shared.arrange(
                sessionId: sessionId,
                agentId: agentId,
                about: about,
                hours: hours,
                nowMs: SyncHostedRunContract.nowMs()
            )
        }
        let formatter = ISO8601DateFormatter()
        let until = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(grant.expiresMs) / 1000))
        return ToolEnvelope.success(
            tool: name,
            result: [
                "arranged": true,
                "until": until,
                "note": "The user agreed to one call from this chat. Start the work now; when its result "
                    + "is here, call with `call_user`.",
            ]
        )
    }
}
