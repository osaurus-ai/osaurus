//
//  AgentCallPolicyTests.swift
//  osaurusTests
//
//  When an agent may ring the user: a call arranged in the chat, or one it
//  makes on its own with "Call You" on, spaced out and capped.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentCallPolicyTests {

    private static let now: Int64 = 1_700_000_000_000
    private static let agent = UUID()
    private static let chat = UUID()

    private static func grant(session: UUID = chat, agent: UUID = agent, expiresMs: Int64 = now + 1000)
        -> AgentCallPolicy.Grant
    {
        AgentCallPolicy.Grant(id: UUID(), sessionId: session, agentId: agent, about: "build", expiresMs: expiresMs)
    }

    private static func decide(_ state: AgentCallPolicy.State) -> AgentCallPolicy.Decision {
        AgentCallPolicy.decide(state, agentId: agent, sessionId: chat, nowMs: now)
    }

    private static func isRefused(_ decision: AgentCallPolicy.Decision) -> Bool {
        if case .refused = decision { return true }
        return false
    }

    @Test("without an arranged call or Call You, an agent can't ring")
    func refusedByDefault() {
        #expect(Self.isRefused(Self.decide(AgentCallPolicy.State())))
    }

    @Test("a call arranged in this chat is allowed, and names its grant")
    func arranged() {
        let grant = Self.grant()
        var state = AgentCallPolicy.State()
        state.grants = [grant]
        #expect(Self.decide(state) == .arranged(grant.id))
    }

    @Test("a grant for another chat, another agent, or past its time doesn't count")
    func grantElsewhere() {
        var state = AgentCallPolicy.State()
        state.grants = [
            Self.grant(session: UUID()),
            Self.grant(agent: UUID()),
            Self.grant(expiresMs: Self.now),
        ]
        #expect(Self.isRefused(Self.decide(state)))
    }

    @Test("with Call You on, an agent rings on its own, at most once every 10 minutes")
    func onItsOwnSpacing() {
        var state = AgentCallPolicy.State()
        state.allowed = [Self.agent]
        #expect(Self.decide(state) == .onItsOwn)
        state.calls[Self.agent] = [Self.now - AgentCallPolicy.spacingMs + 1]
        #expect(Self.isRefused(Self.decide(state)))
        state.calls[Self.agent] = [Self.now - AgentCallPolicy.spacingMs - 1]
        #expect(Self.decide(state) == .onItsOwn)
    }

    @Test("an arranged call isn't held to the spacing")
    func arrangedSkipsSpacing() {
        let grant = Self.grant()
        var state = AgentCallPolicy.State()
        state.grants = [grant]
        state.calls[Self.agent] = [Self.now - 1]
        #expect(Self.decide(state) == .arranged(grant.id))
    }

    @Test("the daily cap holds for arranged calls too")
    func dailyCap() {
        var state = AgentCallPolicy.State()
        state.grants = [Self.grant()]
        state.allowed = [Self.agent]
        let cap = AgentCallPolicy.defaultDailyCap
        state.calls[Self.agent] = (1...cap).map { Self.now - Int64($0) * 60 * 60 * 1000 }
        #expect(Self.isRefused(Self.decide(state)))
        // Calls older than a day don't count.
        state.calls[Self.agent] = (1...cap).map { Self.now - AgentCallPolicy.dayMs - Int64($0) }
        #expect(!Self.isRefused(Self.decide(state)))
    }

    @Test("an agent's own Calls a Day replaces the default, up or down")
    func ownDailyCap() {
        var state = AgentCallPolicy.State()
        state.grants = [Self.grant()]
        state.calls[Self.agent] = (1...3).map { Self.now - Int64($0) * 1000 }
        state.dailyCaps = [Self.agent: 3]
        #expect(Self.isRefused(Self.decide(state)))
        state.dailyCaps = [Self.agent: AgentCallPolicy.defaultDailyCap + 5]
        state.calls[Self.agent] = (1...AgentCallPolicy.defaultDailyCap).map { Self.now - Int64($0) * 1000 }
        #expect(!Self.isRefused(Self.decide(state)))
        // Another agent's limit doesn't apply.
        state.dailyCaps = [UUID(): 1]
        #expect(Self.isRefused(Self.decide(state)))
    }

    @Test("after two unanswered calls in a row, an agent can't ring on its own for a day")
    func missedInRow() {
        var state = AgentCallPolicy.State()
        state.allowed = [Self.agent]
        state.missedInRow[Self.agent] = AgentCallPolicy.missedInRowCap
        state.lastMissMs[Self.agent] = Self.now - 1000
        #expect(Self.isRefused(Self.decide(state)))
        state.lastMissMs[Self.agent] = Self.now - AgentCallPolicy.dayMs - 1
        #expect(Self.decide(state) == .onItsOwn)
    }

    @Test("once a lockout ends, one more miss doesn't lock the agent out again")
    func lockoutDoesNotReArm() {
        var state = AgentCallPolicy.State()
        state.allowed = [Self.agent]
        state.missedInRow[Self.agent] = AgentCallPolicy.missedInRowCap
        state.lastMissMs[Self.agent] = Self.now - AgentCallPolicy.dayMs - 1
        AgentCallPolicy.ended(
            &state, outcome: .missed, decision: .onItsOwn, agentId: Self.agent, rangMs: Self.now, taken: nil,
            nowMs: Self.now)
        #expect(state.missedInRow[Self.agent] == 1)
        #expect(!AgentCallPolicy.lockedOut(state, agentId: Self.agent, nowMs: Self.now))
        #expect(Self.decide(state) == .onItsOwn)
    }

    // MARK: Using up the arranged call

    private static func ring(_ state: inout AgentCallPolicy.State, outcome: SyncAgentCalls.Outcome) {
        let decision = decide(state)
        let taken = AgentCallPolicy.rang(&state, decision: decision, agentId: agent, nowMs: now)
        AgentCallPolicy.ended(
            &state, outcome: outcome, decision: decision, agentId: agent, rangMs: now, taken: taken, nowMs: now + 1)
    }

    @Test("an arranged call that rang is used up and counted", arguments: [
        SyncAgentCalls.Outcome.answered, .declined, .missed, .cancelled,
    ])
    func arrangedCallRang(outcome: SyncAgentCalls.Outcome) {
        var state = AgentCallPolicy.State()
        state.grants = [Self.grant(expiresMs: Self.now + 60_000)]
        Self.ring(&state, outcome: outcome)
        #expect(state.grants.isEmpty)
        #expect(state.calls[Self.agent] == [Self.now])
        #expect(Self.isRefused(Self.decide(state)))
    }

    @Test("an arranged call that didn't ring is given back and not counted", arguments: [
        SyncAgentCalls.Outcome.busy, .unavailable, .notSent,
    ])
    func arrangedCallGivenBack(outcome: SyncAgentCalls.Outcome) {
        let grant = Self.grant(expiresMs: Self.now + 60_000)
        var state = AgentCallPolicy.State()
        state.grants = [grant]
        Self.ring(&state, outcome: outcome)
        #expect(state.grants.map(\.id) == [grant.id])
        #expect(state.grants.first?.attempts == [.init(atMs: Self.now, outcome: outcome.rawValue)])
        #expect(state.ringing == nil)
        #expect((state.calls[Self.agent] ?? []).isEmpty)
        #expect(Self.decide(state) == .arranged(grant.id))
    }

    @Test("while a call rings, its arranged call is taken, so a second call can't use it")
    func arrangedCallTakenWhileRinging() {
        var state = AgentCallPolicy.State()
        state.grants = [Self.grant(expiresMs: Self.now + 60_000)]
        _ = AgentCallPolicy.rang(&state, decision: Self.decide(state), agentId: Self.agent, nowMs: Self.now)
        #expect(Self.isRefused(Self.decide(state)))
    }

    @Test("a given-back call doesn't replace one the user arranged since")
    func givenBackKeepsNewerGrant() {
        var state = AgentCallPolicy.State()
        state.grants = [Self.grant(expiresMs: Self.now + 60_000)]
        let decision = Self.decide(state)
        let taken = AgentCallPolicy.rang(&state, decision: decision, agentId: Self.agent, nowMs: Self.now)
        let newer = Self.grant(expiresMs: Self.now + 120_000)
        state.grants = [newer]
        AgentCallPolicy.ended(
            &state, outcome: .busy, decision: decision, agentId: Self.agent, rangMs: Self.now, taken: taken,
            nowMs: Self.now + 1)
        #expect(state.grants == [newer])
        #expect(state.history?.first?.end == .replaced)
    }

    // MARK: The Inbox

    @Test("an arranged call that rang ends with how it went", arguments: [
        (SyncAgentCalls.Outcome.answered, AgentCallPolicy.End.answered), (.declined, .declined), (.missed, .missed),
        (.cancelled, .calledOff),
    ])
    func endsWithOutcome(outcome: SyncAgentCalls.Outcome, end: AgentCallPolicy.End) {
        let grant = Self.grant(expiresMs: Self.now + 60_000)
        var state = AgentCallPolicy.State()
        state.grants = [grant]
        Self.ring(&state, outcome: outcome)
        #expect(state.history?.map(\.id) == [grant.id])
        #expect(state.history?.first?.end == end)
        #expect(state.history?.first?.endedMs == Self.now + 1)
        #expect(state.ringing == nil)
    }

    @Test("while its call rings, an arranged call is listed as ringing")
    func listedWhileRinging() {
        let grant = Self.grant(expiresMs: Self.now + 60_000)
        var state = AgentCallPolicy.State()
        state.grants = [grant]
        _ = AgentCallPolicy.rang(&state, decision: Self.decide(state), agentId: Self.agent, nowMs: Self.now)
        #expect(state.ringing == [grant])
        #expect(state.grants.isEmpty)
    }

    @Test("a call ringing when Osaurus quit is given back on the next launch")
    func ringingGivenBackOnRelaunch() {
        let grant = Self.grant(expiresMs: Self.now + 60_000)
        var state = AgentCallPolicy.State()
        state.ringing = [grant]
        AgentCallPolicy.relaunched(&state, nowMs: Self.now)
        #expect(state.grants == [grant])
        #expect(state.ringing == nil)
    }

    @Test("an arranged call the agent didn't make in time ends expired, at its expiry")
    func expires() {
        let grant = Self.grant(expiresMs: Self.now - 10)
        var state = AgentCallPolicy.State()
        state.grants = [grant]
        #expect(AgentCallPolicy.sweep(&state, nowMs: Self.now))
        #expect(state.grants.isEmpty)
        #expect(state.history?.first?.end == .expired)
        #expect(state.history?.first?.endedMs == Self.now - 10)
        #expect(!AgentCallPolicy.sweep(&state, nowMs: Self.now))
    }

    @Test("arranging again in the same chat replaces the waiting call")
    func arrangingReplaces() {
        let first = Self.grant(expiresMs: Self.now + 60_000)
        let second = Self.grant(expiresMs: Self.now + 120_000)
        var state = AgentCallPolicy.State()
        AgentCallPolicy.arrange(&state, first, nowMs: Self.now)
        AgentCallPolicy.arrange(&state, second, nowMs: Self.now + 5)
        #expect(state.grants == [second])
        #expect(state.history?.first?.id == first.id)
        #expect(state.history?.first?.end == .replaced)
    }

    @Test("a waiting call the user called off ends cancelled, and the agent is told not to call")
    func cancelWaiting() {
        let grant = Self.grant(expiresMs: Self.now + 60_000)
        var state = AgentCallPolicy.State()
        state.grants = [grant]
        state.allowed = [Self.agent]
        #expect(AgentCallPolicy.cancel(&state, id: grant.id, nowMs: Self.now) == .cancelled)
        #expect(state.grants.isEmpty)
        #expect(state.history?.first?.end == .cancelled)
        // Refused even with Call You on, while the call would still have waited.
        #expect(Self.isRefused(Self.decide(state)))
        #expect(AgentCallPolicy.cancel(&state, id: grant.id, nowMs: Self.now) == .alreadyEnded)
        #expect(AgentCallPolicy.cancel(&state, id: UUID(), nowMs: Self.now) == .notFound)
        #expect(
            AgentCallPolicy.decide(state, agentId: Self.agent, sessionId: Self.chat, nowMs: Self.now + 60_000)
                == .onItsOwn)
    }

    @Test("a ringing call the user called off ends cancelled once the ring stops")
    func cancelRinging() {
        let grant = Self.grant(expiresMs: Self.now + 60_000)
        var state = AgentCallPolicy.State()
        state.grants = [grant]
        let decision = Self.decide(state)
        let taken = AgentCallPolicy.rang(&state, decision: decision, agentId: Self.agent, nowMs: Self.now)
        #expect(AgentCallPolicy.cancel(&state, id: grant.id, nowMs: Self.now) == .ringing(grant))
        AgentCallPolicy.ended(
            &state, outcome: .cancelled, decision: decision, agentId: Self.agent, rangMs: Self.now, taken: taken,
            nowMs: Self.now + 1, cancelledByUser: true)
        #expect(state.history?.first?.end == .cancelled)
        #expect(Self.isRefused(Self.decide(state)))
    }

    @Test("ended calls are kept a week, newest first, at most 50")
    func historyBounds() {
        var state = AgentCallPolicy.State()
        let old = Self.grant()
        AgentCallPolicy.close(&state, old, end: .missed, atMs: Self.now - AgentCallPolicy.historyMs - 1)
        for index in 0..<60 {
            AgentCallPolicy.close(&state, Self.grant(), end: .answered, atMs: Self.now + Int64(index))
        }
        let history = state.history ?? []
        #expect(history.count == AgentCallPolicy.historyLimit)
        #expect(!history.contains { $0.id == old.id })
        #expect(history.first?.endedMs == Self.now + 59)
    }

    @Test("a state saved before arranged calls were kept still reads")
    func oldStateReads() throws {
        let json = #"{"allowed":[],"grants":[{"id":"#(UUID())","sessionId":"#(UUID())","agentId":"#(UUID())","#
            + #""about":"build","expiresMs":1}],"calls":[],"missedInRow":[],"lastMissMs":[]}"#
        let state = try JSONDecoder().decode(AgentCallPolicy.State.self, from: Data(json.utf8))
        #expect(state.grants.count == 1 && state.grants[0].createdMs == nil && state.history == nil)
    }

    // MARK: Approval calls

    private static func mayCall(_ state: AgentCallPolicy.State, session: UUID = chat) -> Bool {
        AgentCallPolicy.mayCallAboutApproval(state, sessionId: session, agentId: agent, nowMs: now)
    }

    @Test("approval calls in a chat are spaced like the agent's own calls")
    func approvalCallSpacing() {
        var state = AgentCallPolicy.State()
        #expect(Self.mayCall(state))
        state.approvalCalls = [Self.chat: .init(lastMs: Self.now - AgentCallPolicy.spacingMs + 1, missed: 0)]
        #expect(!Self.mayCall(state))
        // Another chat isn't held to it.
        #expect(Self.mayCall(state, session: UUID()))
        state.approvalCalls = [Self.chat: .init(lastMs: Self.now - AgentCallPolicy.spacingMs - 1, missed: 0)]
        #expect(Self.mayCall(state))
    }

    @Test("approval calls stop after two in a row go unanswered in the chat")
    func approvalCallMisses() {
        var state = AgentCallPolicy.State()
        state.approvalCalls = [
            Self.chat: .init(lastMs: Self.now - AgentCallPolicy.spacingMs - 1, missed: AgentCallPolicy.missedInRowCap)
        ]
        #expect(!Self.mayCall(state))
    }

    @Test("no approval call while the agent is locked out for missed calls")
    func approvalCallLockout() {
        var state = AgentCallPolicy.State()
        state.missedInRow[Self.agent] = AgentCallPolicy.missedInRowCap
        state.lastMissMs[Self.agent] = Self.now - 1000
        #expect(!Self.mayCall(state))
    }

    @Test("approval-call spacing and misses are kept in the saved state")
    func approvalCallsPersist() throws {
        var state = AgentCallPolicy.State()
        state.approvalCalls = [Self.chat: .init(lastMs: Self.now, missed: 1)]
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(AgentCallPolicy.State.self, from: data) == state)
        // A state saved before approval calls were kept still reads.
        var old = AgentCallPolicy.State()
        old.allowed = [Self.agent]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any] ?? [:]
        json["approvalCalls"] = nil
        let decoded = try JSONDecoder().decode(
            AgentCallPolicy.State.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.approvalCalls == nil && decoded.allowed == [Self.agent])
    }
}
