//
//  CapabilitiesLoadDefaultAgentScopeTests.swift
//  OsaurusCoreTests
//
//  Verifies the default-agent gate inside `CapabilitiesLoadTool`. This is
//  now DEFENSE-IN-DEPTH: the Default agent loads its consolidated configure
//  tools directly and no longer carries `capabilities_load` in its schema,
//  so it cannot reach this tool through the normal path. The internal gate
//  remains as a belt-and-suspenders guard against any future regression that
//  re-exposes the loader to the Default agent, and these tests lock it down:
//
//   * Loading a non-configure tool (e.g. `sandbox_exec`) from the
//     default agent returns the routing-hint error and does NOT
//     enqueue the spec into `CapabilityLoadBuffer`.
//   * Loading any `method/...` or `skill/...` id from the default
//     agent is refused — those targets are never useful inside the
//     configuration agent surface.
//
//  The "happy path" (default agent loading a configure write tool)
//  needs the full capability index seeded, which requires extra
//  bootstrap. We keep that out of this test to keep it source-only.
//  The negative paths above are sufficient to lock down the gate.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct CapabilitiesLoadDefaultAgentScopeTests {

    @Test
    func defaultAgent_cannotLoadNonConfigureTool() async throws {
        let tool = CapabilitiesLoadTool()
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await tool.execute(argumentsJSON: "{\"ids\": [\"tool/sandbox_exec\"]}")
        }
        // The router stops the load and surfaces a hint pointing the
        // model back to the read tools / capabilities_discover.
        #expect(result.contains("Default agent can only load configuration write tools"))

        // The buffer must not contain the rejected tool.
        let buffered = await CapabilityLoadBuffer.shared.drain()
        #expect(!buffered.contains { $0.function.name == "sandbox_exec" })
    }

    @Test
    func defaultAgent_cannotLoadMethods() async throws {
        let tool = CapabilitiesLoadTool()
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await tool.execute(argumentsJSON: "{\"ids\": [\"method/anything\"]}")
        }
        // Method loading is hard-disabled for the configuration agent.
        #expect(result.contains("Method loading is disabled"))
    }

    @Test
    func defaultAgent_cannotLoadSkills() async throws {
        let tool = CapabilitiesLoadTool()
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await tool.execute(argumentsJSON: "{\"ids\": [\"skill/anything\"]}")
        }
        // Skill loading is hard-disabled for the configuration agent.
        #expect(result.contains("Skill loading is disabled"))
    }
}
