//
//  DefaultAgentIsolationContractTests.swift
//  OsaurusCoreTests
//
//  Locks the runtime half of the Default (configuration) agent's isolation
//  contract — the parts that live BELOW the tool-schema layer that
//  `ConfigureToolExposureTests` / `CapabilitiesSearchDefaultAgentScopeTests`
//  already cover:
//
//   * `AgentManager.effectiveCapabilities(for: Agent.defaultId)` hard-offs
//     every editable per-agent capability (DB, charts, speak, recall,
//     self-scheduling, computer use). These are the capabilities whose tools
//     must never reach the Default agent's schema; pinning them off here means
//     a future "let the default agent opt in" regression fails a fast unit
//     test instead of silently widening the configure surface.
//   * `Agent.rejectBuiltInForExternalSurface` keeps the Default agent (and the
//     implicit `nil` → default fallback) unreachable from every external
//     surface, while leaving custom agents reachable. This is the
//     `BuiltInAgentGuard` lockdown the plan asks us to confirm is unchanged.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct DefaultAgentIsolationContractTests {

    @Test
    func defaultAgent_editableCapabilitiesAreHardOff() {
        let caps = AgentManager.shared.effectiveCapabilities(for: Agent.defaultId)
        // The editable per-agent capabilities are locked off for the Default
        // agent regardless of any stored config — their tools (db_*,
        // render_chart, speak, search_memory, schedule_next_run, computer_use)
        // must never appear in the configure surface.
        #expect(caps.dbEnabled == false)
        #expect(caps.renderChartEnabled == false)
        #expect(caps.speakEnabled == false)
        #expect(caps.searchMemoryEnabled == false)
        #expect(caps.selfSchedulingEnabled == false)
        #expect(caps.computerUseEnabled == false)
        // Screen context is a child of Computer Use, which the Default agent
        // can never enable, so it must always resolve off here too.
        #expect(caps.screenContextEnabled == false)
    }

    @Test
    func builtInGuard_rejectsDefaultAgentFromExternalSurfaces() {
        // Explicit Default agent id → rejected.
        let explicit = Agent.rejectBuiltInForExternalSurface(
            Agent.defaultId,
            source: "test/external"
        )
        #expect(explicit != nil)
        #expect(explicit?.code == "built_in_agent_not_exposable")

        // `nil` (the historical implicit default fallback) → rejected too.
        let implicit = Agent.rejectBuiltInForExternalSurface(nil, source: "test/external")
        #expect(implicit != nil)

        // A custom agent id → reachable (no rejection).
        let custom = Agent.rejectBuiltInForExternalSurface(UUID(), source: "test/external")
        #expect(custom == nil)
    }
}
