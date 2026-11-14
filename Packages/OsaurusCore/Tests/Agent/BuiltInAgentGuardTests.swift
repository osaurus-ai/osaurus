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

    /// Every `source:` literal passed to the guard in production code.
    private static func productionSources() throws -> Set<String> {
        let coreRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Agent
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // OsaurusCore
        let call = try NSRegularExpression(
            pattern: #"rejectBuiltInForExternalSurface\([^;]*?source:\s*"([^"]+)""#,
            options: [.dotMatchesLineSeparators])
        var found: Set<String> = []
        let files = FileManager.default.enumerator(at: coreRoot, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            let path = url.path
            guard url.pathExtension == "swift", !path.contains("/Tests/"), !path.contains("/.build/") else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in call.matches(in: text, range: range) {
                guard let r = Range(match.range(at: 1), in: text) else { continue }
                found.insert(String(text[r]).replacingOccurrences(of: #"\(eventName)"#, with: "*"))
            }
        }
        return found
    }

    @Test
    func everyBuiltInIdIsRejectedOnEveryExternalSurface() throws {
        let sources = try Self.productionSources()
        for expected in [
            "http/agents/run", "http/agents/dispatch", "http/mcp/call", "plugin/planDispatch",
            "background/dispatchChat", "event/*",
        ] {
            #expect(sources.contains(expected), "no guard call with source \(expected)")
        }
        let builtIns =
            [Agent.defaultId, Agent.architectId, Agent.configuratorId] + BuiltInWorker.allCases.map(\.agentId)
        for source in sources.union(["plugin/host"]) {
            for id in builtIns {
                let err = Agent.rejectBuiltInForExternalSurface(id, source: source)
                #expect(err == .builtInAgentNotExposable(agentId: id, source: source), "\(id) via \(source)")
            }
            #expect(Agent.rejectBuiltInForExternalSurface(UUID(), source: source) == nil)
        }
    }

    @Test
    func theArchitectStaysListedButUnreachableFromOutside() {
        #expect(!Agent.isHiddenBuiltIn(Agent.architectId))
        #expect(Agent.builtInAgents.contains { $0.id == Agent.architectId })
        #expect(Agent.rejectBuiltInForExternalSurface(Agent.architectId, source: "http/agents/run") != nil)
    }
}
