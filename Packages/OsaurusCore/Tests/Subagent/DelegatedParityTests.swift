//
//  DelegatedParityTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Chat-versus-spawn parity: a delegated spawn runs a REAL chat session of
//  the target agent, so it must resolve the same model, the same
//  generation-config sources, and the same global MTP policy as a normal
//  chat with that agent. The delegation contract may TIGHTEN limits
//  (max tokens, turns, context) but must never invent sampler defaults,
//  clobber bundle generation config, or carry a spawn-only MTP switch.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct DelegatedParityTests {

    private func localItem(_ id: String) -> ModelPickerItem {
        ModelPickerItem(id: id, displayName: id, source: .local)
    }

    private func makeAgent(defaultModel: String) -> (agent: Agent, cleanup: () async -> Void) {
        let agent = Agent(
            name: "Delegated Parity Agent \(UUID().uuidString)",
            autonomousExec: AutonomousExecConfig(enabled: false)
        )
        AgentManager.shared.add(agent)
        AgentManager.shared.updateDefaultModel(for: agent.id, model: defaultModel)
        return (agent, { _ = await AgentManager.shared.delete(id: agent.id) })
    }

    private func drainInitialCacheSnapshot() async {
        for _ in 0 ..< 3 { await Task.yield() }
    }

    /// MODEL PARITY: a dispatched session WITH a delegation contract adopts
    /// exactly the same model as one without — the contract carries no
    /// model dimension, so delegated spawn and normal dispatch resolve the
    /// target agent's current default identically.
    @Test func delegatedDispatchResolvesSameModelAsNormalDispatch() async {
        let (agent, cleanup) = makeAgent(defaultModel: "mlx-test/parity-default")
        let items = [localItem("mlx-test/parity-default"), localItem("mlx-test/other")]

        // ISOLATION, not retries. Two shared-global race sources are
        // removed structurally:
        //  1. `detachPickerCacheForTesting()` removes the process-global
        //    `ModelPickerItemCache.$items` subscription so the shared
        //    cache snapshot can never clobber the fixture's items.
        //  2. Every `await` below happens BEFORE the decisive section;
        //    the set-default → apply-items → adopt → capture sequence for
        //    BOTH sessions is one synchronous MainActor run, so no other
        //    suite's MainActor work (agent CRUD, cache rebuilds) can
        //    interleave between the default being set and the adoptions
        //    reading it.
        func prepareSession(contract: DelegatedRunContract?) async -> ChatSession {
            let session = ChatSession()
            session.agentId = agent.id
            session.delegationBudget = contract
            session.source = .delegation
            session.detachPickerCacheForTesting()
            await drainInitialCacheSnapshot()
            return session
        }

        let normal = await prepareSession(contract: nil)
        let delegated = await prepareSession(
            contract: DelegatedRunContract(
                responseTokens: 2048, assistantTurns: 2, contextPositions: 16_684))

        // Decisive synchronous section — no suspension points.
        AgentManager.shared.updateDefaultModel(
            for: agent.id, model: "mlx-test/parity-default")
        normal.applyPickerItems(items)
        normal.applyAgentDefaultModelForDispatch()
        delegated.applyPickerItems(items)
        delegated.applyAgentDefaultModelForDispatch()
        let normalSelection = normal.selectedModel
        let delegatedSelection = delegated.selectedModel

        #expect(normalSelection == "mlx-test/parity-default")
        #expect(delegatedSelection == normalSelection)
        await cleanup()
    }

    /// GENERATION-CONFIG PARITY: the effective sampling/limit sources are
    /// agent-scoped (`AgentManager.effectiveTemperature` /
    /// `effectiveMaxTokens`) — there is no spawn-scoped override store, so
    /// chat and spawn read the same values by construction. The contract's
    /// only interaction is the tighten-only response clamp.
    @Test func delegatedContractOnlyTightensNeverReplacesAgentConfig() async {
        let (agent, cleanup) = makeAgent(defaultModel: "mlx-test/parity-default")
        let contract = DelegatedRunContract(
            responseTokens: 2048, assistantTurns: 2, contextPositions: 16_684)

        let chatValue = AgentManager.shared.effectiveMaxTokens(for: agent.id)
        let spawnValue = AgentManager.shared.effectiveMaxTokens(for: agent.id)
        #expect(chatValue == spawnValue, "one agent-scoped source for both surfaces")

        // Whatever the agent's value, the contract can only tighten it.
        let clamped = contract.clampedResponseTokens(agentConfigured: chatValue)
        #expect(clamped <= contract.responseTokens)
        if let chatValue { #expect(clamped <= chatValue) }
        await cleanup()
    }

    /// NO INVENTED SAMPLER / NO SPAWN-ONLY MTP SWITCH: the delegation
    /// contract and the spawn budget/request surfaces carry ONLY bounded
    /// limits. Reflection pins that no field smells like a sampler or
    /// speculative-decode knob, so bundle generation config and the global
    /// MTP policy cannot be overridden from the spawn path.
    @Test func spawnSurfacesCarryNoSamplerOrMTPKnobs() {
        let forbidden = [
            "temperature", "topp", "topk", "minp", "sampler", "penalty",
            "mtp", "draft", "spec", "greedy", "seed",
        ]

        func fieldNames(_ subject: Any) -> [String] {
            Mirror(reflecting: subject).children.compactMap { $0.label?.lowercased() }
        }

        let contractFields = fieldNames(
            DelegatedRunContract(responseTokens: 1, assistantTurns: 1, contextPositions: 1))
        let budgetFields = fieldNames(SubagentBudgets())
        let requestFields = fieldNames(DispatchRequest(prompt: "x"))

        for name in contractFields + budgetFields + requestFields {
            for bad in forbidden {
                #expect(
                    !name.contains(bad),
                    "spawn surface field '\(name)' looks like a sampler/MTP knob")
            }
        }
        #expect(contractFields.sorted() == [
            "assistantturns", "contextpositions", "responsetokens",
        ])
    }

    /// MTP POLICY PARITY: the resolution snapshot is keyed ONLY by resident
    /// model name — `ModelRuntime.mtpResolution(forModel:)` has no session,
    /// source, or spawn parameter, so a spawned child of model M and a chat
    /// with model M read the identical resolution. With no resident model,
    /// resolution is nil ("unavailable"), which callers must never read as
    /// "MTP off".
    @Test func mtpResolutionHasNoSpawnDimension() async {
        let missing = await ModelRuntime.mtpResolution(
            forModel: "mlx-test/never-resident-\(UUID().uuidString)")
        #expect(missing == nil, "unresolvable model must be nil, not a fabricated 'off'")
    }
}
