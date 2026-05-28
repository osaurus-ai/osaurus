//
//  ConfigurationToolBaseTests.swift
//  OsaurusCoreTests
//
//  Validates the runtime default-agent gate that every `osaurus_*`
//  configure tool calls first. The composer's allowlist filter is the
//  primary defence; this runtime gate is the secondary defence against
//  any registration path that leaks a configure tool into a non-default
//  agent's schema (or invokes one outside a chat session at all).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ConfigurationToolBaseGateTests {

    @Test
    func gate_returnsFailureWhenNoSessionAgent() async throws {
        // No ChatExecutionContext.currentAgentId binding — the gate
        // refuses the call because configure tools are session-only.
        let result = ConfigurationToolBase.defaultAgentGateFailure(tool: "osaurus_probe")
        let envelope = try #require(result)
        #expect(ToolEnvelope.isError(envelope))
        #expect(envelope.contains("chat session context"))
    }

    @Test
    func gate_returnsFailureForNonDefaultAgent() async throws {
        let result = await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            ConfigurationToolBase.defaultAgentGateFailure(tool: "osaurus_probe")
        }
        let envelope = try #require(result)
        #expect(ToolEnvelope.isError(envelope))
        #expect(envelope.contains("Default agent"))
    }

    @Test
    func gate_passesForDefaultAgent() async {
        let result = await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            ConfigurationToolBase.defaultAgentGateFailure(tool: "osaurus_probe")
        }
        // nil means "no gate, proceed".
        #expect(result == nil)
    }

    @Test
    func defaultPolicy_isAsk() {
        // Configure writes mutate persistent state; defaulting to .ask
        // is a product invariant — never default to .auto here.
        #expect(ConfigurationToolBase.defaultPolicy == .ask)
    }

    @Test
    func requirement_isStable() {
        // Tool permission UI buckets every configure write under this
        // single capability id. Renaming it would silently re-prompt
        // every user, so the wire string is locked down by test.
        #expect(ConfigurationToolBase.requirement == "configure_osaurus")
    }
}
