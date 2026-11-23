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
//  Every arranged call is kept until it ends, and for a week after
//  (`history`), so the Inbox on the Mac and the iPhone can show whether it
//  was made and how it went, and the user can call off one no longer needed.
//

import Foundation
import os

/// Who may ring the user, and how often.
@MainActor
final class AgentCallPolicy: ObservableObject {
    static let shared = AgentCallPolicy()

    nonisolated private static let log = Logger(subsystem: "ai.osaurus", category: "agent.calls")

    /// One call the user arranged, in one chat.
    struct Grant: Codable, Equatable, Sendable, Identifiable {
        var id: UUID
        var sessionId: UUID
        var agentId: UUID
        var about: String
        var expiresMs: Int64
        /// Nil on a grant saved before arranged calls were kept.
        var createdMs: Int64?
        /// Tries that rang nothing (another call on, no device, the push service down), oldest first.
        var attempts: [Attempt]?
        /// How it ended; set on the grants in `history` only.
        var end: End?
        var endedMs: Int64?
    }

    struct Attempt: Codable, Equatable, Sendable {
        var atMs: Int64
        /// `busy`, `unavailable` or `notSent` (`SyncAgentCalls.Outcome`).
        var outcome: String
    }

    /// How an arranged call ended.
    enum End: String, Codable, Sendable {
        case answered, missed, declined
        /// The run that placed the call stopped while it rang.
        case calledOff
        /// The user called it off, on the Mac or an iPhone.
        case cancelled
        /// The agent didn't call in time.
        case expired
        /// A new call was arranged in the same chat.
        case replaced
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
        /// Arranged calls taken by a call ringing now: back to `grants` if nothing rang.
        var ringing: [Grant]?
        /// Ended arranged calls, newest first: at most `historyLimit`, for `historyMs`.
        var history: [Grant]?
        /// Ringing arranged calls the user called off: they end `cancelled` however the ring ends, and stay
        /// called off if Osaurus quits first. Saved for that.
        var cancelling: [UUID]?

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
    /// How long an ended arranged call stays in the Inbox, and how many are kept.
    nonisolated static let historyMs: Int64 = 7 * dayMs
    nonisolated static let historyLimit = 50

    /// Where the state was kept before it held what the user arranged; read once, then removed.
    private static let defaultsKey = "AgentCallPolicy"
    private static var url: URL { OsaurusPaths.syncLocalState().appendingPathComponent("agent-calls.json") }
    /// Saves in order, off the main thread.
    private static let saveQueue = DispatchQueue(label: "ai.osaurus.agent-calls.save", qos: .utility)

    @Published private(set) var state: State
    private var expiryTask: Task<Void, Never>?

    private init() {
        let saved = (try? EncryptedFileStore.readPolicyAware(plaintextURL: Self.url))
            .flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        let legacy = UserDefaults.standard.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        state = saved ?? legacy ?? State()
        Self.relaunched(&state, nowMs: SyncHostedRunContract.nowMs())
        // The old copy goes only once the file holds the state: a failed write keeps it for the next launch.
        save(droppingLegacy: legacy != nil)
    }

    private func save(droppingLegacy: Bool = false) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        let url = Self.url
        Self.saveQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try EncryptedFileStore.writePolicyAware(data, toPlaintextURL: url)
                if droppingLegacy { UserDefaults.standard.removeObject(forKey: Self.defaultsKey) }
            } catch {
                Self.log.error("agent calls not saved: \(String(describing: error), privacy: .public)")
            }
        }
        scheduleExpiry()
    }

    /// Wakes at the next arranged call's expiry to move it to `history`.
    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let next = state.grants.map(\.expiresMs).min() else { return }
        let waitMs = max(0, next - SyncHostedRunContract.nowMs()) + 500
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(waitMs))
            guard !Task.isCancelled, let self else { return }
            if Self.sweep(&self.state, nowMs: SyncHostedRunContract.nowMs()) { self.save() }
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
            expiresMs: nowMs + Int64(clamped) * 3600 * 1000,
            createdMs: nowMs
        )
        Self.arrange(&state, grant, nowMs: nowMs)
        save()
        return grant
    }

    /// One arranged call per chat and agent: a new one replaces the old.
    nonisolated static func arrange(_ state: inout State, _ grant: Grant, nowMs: Int64) {
        sweep(&state, nowMs: nowMs)
        let replaced = state.grants.filter { $0.sessionId == grant.sessionId && $0.agentId == grant.agentId }
        state.grants.removeAll { $0.sessionId == grant.sessionId && $0.agentId == grant.agentId }
        for old in replaced { close(&state, old, end: .replaced, atMs: nowMs) }
        state.grants.append(grant)
    }

    /// Moves `grant` to `history`, newest first, dropping what is past `historyMs` or `historyLimit`.
    /// `nowMs` (default `atMs`) is what "past `historyMs`" counts from: a call that expired long ago, closed
    /// on a later launch, mustn't keep the rest from ageing out.
    nonisolated static func close(_ state: inout State, _ grant: Grant, end: End, atMs: Int64, nowMs: Int64? = nil) {
        var ended = grant
        ended.end = end
        ended.endedMs = atMs
        let kept = (state.history ?? []).filter { $0.id != grant.id }
        let cutoff = max(atMs, nowMs ?? atMs) - historyMs
        let sorted = (kept + [ended])
            .filter { ($0.endedMs ?? 0) > cutoff }
            .sorted { ($0.endedMs ?? 0) > ($1.endedMs ?? 0) }
        state.history = Array(sorted.prefix(historyLimit))
    }

    /// Arranged calls past their time end `expired`. Whether any did.
    @discardableResult
    nonisolated static func sweep(_ state: inout State, nowMs: Int64) -> Bool {
        let expired = state.grants.filter { $0.expiresMs <= nowMs }
        guard !expired.isEmpty else { return false }
        state.grants.removeAll { $0.expiresMs <= nowMs }
        for grant in expired { close(&state, grant, end: .expired, atMs: grant.expiresMs, nowMs: nowMs) }
        return true
    }

    /// A call ringing when Osaurus quit never ended: its arranged call is given back, as for one that
    /// rang nothing.
    /// One the user called off while it rang stays called off.
    nonisolated static func relaunched(_ state: inout State, nowMs: Int64) {
        let cancelling = Set(state.cancelling ?? [])
        for grant in state.ringing ?? [] {
            if cancelling.contains(grant.id) {
                close(&state, grant, end: .cancelled, atMs: nowMs)
            } else if !state.grants.contains(where: {
                $0.sessionId == grant.sessionId && $0.agentId == grant.agentId
            }) {
                state.grants.append(grant)
            }
        }
        state.ringing = nil
        state.cancelling = nil
        sweep(&state, nowMs: nowMs)
    }

    // MARK: Calling off

    enum CancelResult: Equatable, Sendable {
        case cancelled
        /// Its call is ringing: called off, it ends `cancelled` once the ring stops.
        case ringing(Grant)
        case alreadyEnded
        case notFound
    }

    /// The user calls off an arranged call. A call ringing for it, or about an approval in its chat,
    /// stops; the agent is told not to call about it.
    @discardableResult
    func cancel(_ id: UUID, nowMs: Int64) -> CancelResult {
        let result = Self.cancel(&state, id: id, nowMs: nowMs)
        switch result {
        case .cancelled:
            if let grant = state.history?.first(where: { $0.id == id }) {
                SyncAgentCalls.shared.callOff(sessionId: grant.sessionId, agentId: grant.agentId)
            }
            save()
        case .ringing(let grant):
            save()
            SyncAgentCalls.shared.callOff(sessionId: grant.sessionId, agentId: grant.agentId)
        case .alreadyEnded, .notFound:
            break
        }
        let short = id.uuidString.prefix(8)
        Self.log.info("cancelling call \(short, privacy: .public): \(String(describing: result), privacy: .public)")
        return result
    }

    nonisolated static func cancel(_ state: inout State, id: UUID, nowMs: Int64) -> CancelResult {
        if let index = state.grants.firstIndex(where: { $0.id == id }) {
            let grant = state.grants.remove(at: index)
            close(&state, grant, end: .cancelled, atMs: nowMs)
            return .cancelled
        }
        if let grant = state.ringing?.first(where: { $0.id == id }) {
            if state.cancelling?.contains(id) != true { state.cancelling = (state.cancelling ?? []) + [id] }
            return .ringing(grant)
        }
        if state.history?.contains(where: { $0.id == id }) == true { return .alreadyEnded }
        return .notFound
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
        // The user called off the call arranged here: no call about it, "Call You" or not, while it
        // would still have been waiting.
        if let last = state.history?.first(where: { $0.sessionId == sessionId && $0.agentId == agentId }),
            last.end == .cancelled, last.expiresMs > nowMs
        {
            return .refused(
                "The user called off the call arranged in this chat. Don't call about it; tell them in the chat "
                    + "instead."
            )
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

    /// How the arranged call `taken` ended, if it did.
    @discardableResult
    func ended(
        _ outcome: SyncAgentCalls.Outcome, decision: Decision, agentId: UUID, rangMs: Int64, taken: Grant?
    ) -> End? {
        Self.ended(
            &state, outcome: outcome, decision: decision, agentId: agentId, rangMs: rangMs, taken: taken,
            nowMs: SyncHostedRunContract.nowMs())
        save()
        return taken.flatMap { grant in state.history?.first(where: { $0.id == grant.id })?.end }
    }

    /// The arranged calls still to come, ringing ones first.
    var waiting: [(grant: Grant, ringing: Bool)] {
        (state.ringing ?? []).map { ($0, true) }
            + state.grants.sorted { ($0.createdMs ?? 0) > ($1.createdMs ?? 0) }.map { ($0, false) }
    }

    var history: [Grant] { state.history ?? [] }

    nonisolated static func rang(_ state: inout State, decision: Decision, agentId: UUID, nowMs: Int64) -> Grant? {
        var recent = (state.calls[agentId] ?? []).filter { $0 > nowMs - dayMs }
        recent.append(nowMs)
        state.calls[agentId] = recent
        guard case .arranged(let id) = decision, let index = state.grants.firstIndex(where: { $0.id == id })
        else { return nil }
        let taken = state.grants.remove(at: index)
        state.ringing = (state.ringing ?? []) + [taken]
        return taken
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
        nowMs: Int64,
        cancelledByUser: Bool = false
    ) {
        if let taken { state.ringing?.removeAll { $0.id == taken.id } }
        if state.ringing?.isEmpty == true { state.ringing = nil }
        // Called off by the user while it rang, whether or not a device then rang: it ends `cancelled`.
        let calledOffByUser = taken.map { state.cancelling?.contains($0.id) == true } ?? false
        let byUser = cancelledByUser || calledOffByUser
        if let taken { state.cancelling?.removeAll { $0 == taken.id } }
        if state.cancelling?.isEmpty == true { state.cancelling = nil }
        guard didRing(outcome) else {
            // Nothing rang (another call on, no device, the push service down): the call isn't
            // counted, and the user's arranged call is kept unless they arranged a new one since.
            if var calls = state.calls[agentId], let index = calls.lastIndex(of: rangMs) {
                calls.remove(at: index)
                state.calls[agentId] = calls
            }
            guard var taken else { return }
            taken.attempts = (taken.attempts ?? []) + [Attempt(atMs: rangMs, outcome: outcome.rawValue)]
            if byUser {
                close(&state, taken, end: .cancelled, atMs: nowMs)
            } else if state.grants.contains(where: { $0.sessionId == taken.sessionId && $0.agentId == taken.agentId }) {
                close(&state, taken, end: .replaced, atMs: nowMs)
            } else if taken.expiresMs <= nowMs {
                close(&state, taken, end: .expired, atMs: nowMs)
            } else {
                state.grants.append(taken)
            }
            return
        }
        if let taken {
            let end: End
            switch outcome {
            case .answered: end = .answered
            case .declined: end = .declined
            case .cancelled: end = byUser ? .cancelled : .calledOff
            default: end = .missed
            }
            close(&state, taken, end: end, atMs: nowMs)
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
        approvalCallsBefore[sessionId] = calls[sessionId]
        calls[sessionId] = ApprovalCalls(lastMs: nowMs, missed: calls[sessionId]?.missed ?? 0)
        state.approvalCalls = calls
        save()
        return true
    }

    /// Each ringing approval call's chat as it was before: a call that never rang gives the chat back
    /// its spacing.
    private var approvalCallsBefore: [UUID: ApprovalCalls] = [:]

    func endedApprovalCall(_ outcome: SyncAgentCalls.Outcome, sessionId: UUID, rangMs: Int64) {
        let before = approvalCallsBefore.removeValue(forKey: sessionId)
        switch outcome {
        case .answered: state.approvalCalls?[sessionId]?.missed = 0
        case .missed, .declined: state.approvalCalls?[sessionId]?.missed += 1
        case .cancelled: return
        case .busy, .unavailable, .notSent:
            guard state.approvalCalls?[sessionId]?.lastMs == rangMs else { return }
            state.approvalCalls?[sessionId] = before
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
        let end = policy.ended(outcome, decision: decision, agentId: agentId, rangMs: nowMs, taken: taken)
        if end == .cancelled { throw Refusal(message: Self.calledOffByUser) }
        return outcome
    }

    static let calledOffByUser =
        "The user called off this call while it rang. Don't call about it again; tell them in the chat instead."

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
