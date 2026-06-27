//
//  SubagentJobEvaluatorSeedTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Model-free coverage of `SubagentJobEvaluator.withSpawnablePersona`, the
//  OsaurusEvals seam that makes the live `spawn` lane RUN across models on any
//  host: it seeds a spawnable persona into the Default agent's GLOBAL pool AND
//  forces the "Local Orchestrator Handoff" switch on (so a LOCAL run model can
//  hand off to the local text subagent), then restores the prior config. These
//  tests pin the seed-during / restore-after contract using the existing
//  `SubagentConfigurationStore` test sandbox (override dir + cross-suite lock),
//  and use a built-in agent name so the helper never creates a throwaway agent
//  — the CONFIG seed/restore is what's under test, not `AgentStore`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SubagentJobEvaluatorSeedTests {

    /// A built-in agent name so `withSpawnablePersona` takes the "already
    /// exists" branch and does not touch `AgentStore` / `AgentManager`.
    private var existingAgentName: String {
        Agent.builtInAgents.first?.name ?? "eval-seed-persona"
    }

    @Test func seedsPersonaAndHandoffDuringBodyThenRestores() async {
        let lease = await acquireSubagentStoreSandbox("spawnseed")
        defer { lease.release() }
        let persona = existingAgentName

        // Known prior: handoff OFF, empty spawn pool — the worst case where the
        // live spawn lane would otherwise skip (no persona, no local handoff).
        let prior = SubagentConfiguration(
            localTextDelegationEnabled: false,
            spawnableAgentNames: []
        )
        SubagentConfigurationStore.save(prior)
        #expect(!SubagentConfigurationStore.snapshot().isAgentSpawnable(persona))

        await SubagentJobEvaluator.withSpawnablePersona(name: persona) {
            let during = SubagentConfigurationStore.snapshot()
            #expect(during.isAgentSpawnable(persona), "persona must be spawnable during the body")
            #expect(during.localTextDelegationEnabled, "local handoff must be enabled during the body")
        }

        // Restored exactly: pool empty again, handoff back off.
        let after = SubagentConfigurationStore.snapshot()
        #expect(after.spawnableAgentNames.isEmpty, "spawn pool must be restored; got \(after.spawnableAgentNames)")
        #expect(!after.isAgentSpawnable(persona))
        #expect(!after.localTextDelegationEnabled, "local handoff must be restored to off")
    }

    @Test func noOpAndRestoreWhenAlreadyConfigured() async {
        let lease = await acquireSubagentStoreSandbox("spawnseed-noop")
        defer { lease.release() }
        let persona = existingAgentName

        // Prior already has the persona + handoff on: seeding is a no-op and the
        // restore must leave that prior state intact (not strip a user's config).
        let prior = SubagentConfiguration(
            localTextDelegationEnabled: true,
            spawnableAgentNames: [persona]
        )
        SubagentConfigurationStore.save(prior)

        await SubagentJobEvaluator.withSpawnablePersona(name: persona) {
            let during = SubagentConfigurationStore.snapshot()
            #expect(during.isAgentSpawnable(persona))
            #expect(during.localTextDelegationEnabled)
        }

        let after = SubagentConfigurationStore.snapshot()
        #expect(after.isAgentSpawnable(persona))
        #expect(after.localTextDelegationEnabled)
        #expect(after.spawnableAgentNames == [persona], "pool must be unchanged; got \(after.spawnableAgentNames)")
    }
}
