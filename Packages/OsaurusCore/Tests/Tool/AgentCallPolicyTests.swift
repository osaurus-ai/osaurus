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
}
