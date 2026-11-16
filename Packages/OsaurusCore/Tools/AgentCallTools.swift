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
    }

    /// Between two calls an agent makes on its own.
    nonisolated static let spacingMs: Int64 = 10 * 60 * 1000
    /// Calls per agent in any 24 hours, arranged ones included.
    nonisolated static let dailyCap = 5
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
        if recent.count >= dailyCap {
            return .refused("This agent has called \(dailyCap) times in the last 24 hours. Use `notify` instead.")
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
        let misses = state.missedInRow[agentId] ?? 0
        if misses >= missedInRowCap, let last = state.lastMissMs[agentId], last > nowMs - dayMs {
            return .refused("The user missed your last \(misses) calls. Use `notify` instead.")
        }
        if let last = recent.max(), last > nowMs - spacingMs {
            return .refused("You called less than 10 minutes ago. Use `notify` instead, or wait.")
        }
        return .onItsOwn
    }

    /// A call rang: counts it, and uses up the grant it was arranged with.
    func rang(_ decision: Decision, agentId: UUID, nowMs: Int64) {
        var recent = (state.calls[agentId] ?? []).filter { $0 > nowMs - Self.dayMs }
        recent.append(nowMs)
        state.calls[agentId] = recent
        if case .arranged(let id) = decision {
            state.grants.removeAll { $0.id == id }
        }
        save()
    }

    func ended(_ outcome: SyncAgentCalls.Outcome, decision: Decision, agentId: UUID, nowMs: Int64) {
        switch outcome {
        case .answered:
            state.missedInRow[agentId] = nil
        case .missed, .declined:
            guard decision == .onItsOwn else { return }
            state.missedInRow[agentId, default: 0] += 1
            state.lastMissMs[agentId] = nowMs
        case .busy, .unavailable:
            return
        }
        save()
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
        policy.rang(decision, agentId: agentId, nowMs: nowMs)
        let outcome = await calls.ring(
            SyncAgentCalls.Request(
                agentId: agentId,
                agentName: resolveAgentDisplayName(agentId),
                sessionId: sessionId,
                opening: opening,
                reason: reason
            )
        )
        policy.ended(outcome, decision: decision, agentId: agentId, nowMs: SyncHostedRunContract.nowMs())
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
