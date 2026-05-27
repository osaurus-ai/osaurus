//
//  BuiltInAgentGuardTests.swift
//  OsaurusCoreTests
//
//  Pins the contract of `Agent.rejectBuiltInForExternalSurface`.
//
//  Phase A's external-surface lockdown depends on this helper returning
//  a structured `BuiltInAgentGuardError` for the two cases historical
//  code conflated:
//    * `nil` agent id — used to default to `Agent.defaultId`, now
//      always a rejection (no implicit fallback).
//    * `Agent.defaultId` — built-in agent reachable only from in-app
//      Chat UI; every other surface receives the same rejection.
//
//  Custom agents return `nil`, signalling "no guard fires — proceed".
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct BuiltInAgentGuardTests {

    @Test
    func nilAgentId_isRejectedAsBuiltIn() throws {
        let result = Agent.rejectBuiltInForExternalSurface(nil, source: "test/source")
        let err = try #require(result)
        if case .builtInAgentNotExposable(let agentId, let source) = err {
            #expect(agentId == Agent.defaultId)
            #expect(source == "test/source")
        } else {
            Issue.record("expected .builtInAgentNotExposable, got \(err)")
        }
    }

    @Test
    func defaultAgentId_isRejected() throws {
        let result = Agent.rejectBuiltInForExternalSurface(Agent.defaultId, source: "http/agents/run")
        let err = try #require(result)
        if case .builtInAgentNotExposable(let agentId, let source) = err {
            #expect(agentId == Agent.defaultId)
            #expect(source == "http/agents/run")
        } else {
            Issue.record("expected .builtInAgentNotExposable, got \(err)")
        }
    }

    @Test
    func customAgentId_isAllowed() {
        // Any non-built-in UUID is treated as a regular custom agent.
        let custom = UUID()
        let result = Agent.rejectBuiltInForExternalSurface(custom, source: "test/source")
        #expect(result == nil)
    }

    @Test
    func errorCode_isStable() {
        let err = BuiltInAgentGuardError.builtInAgentNotExposable(
            agentId: Agent.defaultId,
            source: "anywhere"
        )
        // Transports (HTTP 403, background failure payload) key off `code`.
        // Locking it down so the wire contract never silently drifts.
        #expect(err.code == "built_in_agent_not_exposable")
    }

    @Test
    func errorMessage_namesTheSource() {
        let err = BuiltInAgentGuardError.builtInAgentNotExposable(
            agentId: Agent.defaultId,
            source: "plugin/planDispatch"
        )
        #expect(err.message.contains("plugin/planDispatch"))
        #expect(err.message.contains(Agent.defaultId.uuidString))
    }
}
