//
//  SubagentResidencyTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Model-free coverage of the shared residency DECISION (`SubagentResidency`)
//  that every chat-driven kind (spawn / computer_use) uses to
//  decide whether running its resolved model must unload the resident chat
//  model. The middleware itself is covered by `ResidencyHandoffTests`; here we
//  pin the pure `decidePlan` control flow and the `handoff(for:)` mapping.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Subagent residency decision")
struct SubagentResidencyTests {
    private let denied = "handoff disabled"

    @Test("a remote model never touches local residency")
    func remoteModelNeedsNoSwap() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: false,
            modelName: "remote/model",
            residentChatModels: ["local-a"],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 123,
            idleWaitSeconds: 60,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == false)
    }

    @Test("the same local model already resident runs in place")
    func sameLocalRunsInPlace() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-a",
            residentChatModels: ["local-a"],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 60,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == false)
        #expect(plan.ramSafetyEnabled)
        #expect(plan.requiredBytes == 4096)
        #expect(plan.maxElapsedSeconds == 60)
    }

    @Test("the same model in a different case is treated as resident (no swap)")
    func sameLocalCaseInsensitive() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "Local-A",
            residentChatModels: ["local-a"],
            handoffEnabled: true,
            ramSafetyEnabled: false,
            requiredBytes: 0,
            idleWaitSeconds: 60,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == false)
        #expect(plan.ramSafetyEnabled == false)
        #expect(plan.requiredBytes == 0)
        #expect(plan.maxElapsedSeconds == 60)
    }

    @Test("same invoking parent reuses target despite unrelated protected residency")
    func sameParentTargetIgnoresUnrelatedProtectedResidency() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-a",
            residentChatModels: ["LOCAL-A"],
            protectedResidentModels: ["api-b"],
            handoffEnabled: false,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(!plan.shouldUnload)
        #expect(!plan.coexists)
        #expect(plan.requiredBytes == 4096)
        #expect(plan.ramSafetyEnabled)
        #expect(plan.maxElapsedSeconds == 90)
    }

    @Test("nothing else resident means nothing to evict")
    func nothingResidentNeedsNoSwap() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: [],
            handoffEnabled: false,  // irrelevant — nothing to evict
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == false)
        #expect(plan.ramSafetyEnabled)
        #expect(plan.requiredBytes == 4096)
        #expect(plan.maxElapsedSeconds == 90)
    }

    @Test("a different local model with the handoff enabled unloads, carrying the plan")
    func differentLocalUnloads() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: ["local-a"],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == true)
        #expect(plan.requiredBytes == 4096)
        #expect(plan.ramSafetyEnabled == true)
        #expect(plan.maxElapsedSeconds == 90)
    }

    @Test("handoff refuses before unloading when unrelated non-chat work is resident")
    func unrelatedProtectedResidentRefusesHandoff() {
        do {
            _ = try SubagentResidency.decidePlan(
                isLocal: true,
                modelName: "local-c",
                residentChatModels: ["local-a"],
                protectedResidentModels: ["api-b"],
                handoffEnabled: true,
                ramSafetyEnabled: true,
                requiredBytes: 4096,
                idleWaitSeconds: 90,
                deniedMessage: denied
            )
            Issue.record("unrelated protected residency should refuse before handoff")
        } catch let error as SubagentError {
            guard case .unavailable(let message) = error else {
                Issue.record("expected unavailable, got \(error)")
                return
            }
            #expect(message.contains("api-b"))
            #expect(message.contains("non-chat"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("protected target refuses before a non-coexisting parent handoff")
    func protectedTargetRefusesBeforeParentUnload() {
        do {
            _ = try SubagentResidency.decidePlan(
                isLocal: true,
                modelName: "api-b",
                residentChatModels: ["local-a"],
                protectedResidentModels: ["api-b"],
                handoffEnabled: true,
                ramSafetyEnabled: true,
                requiredBytes: 4096,
                idleWaitSeconds: 90,
                deniedMessage: denied
            )
            Issue.record("protected target should refuse before the parent is unloaded")
        } catch let error as SubagentError {
            guard case .unavailable(let message) = error else {
                Issue.record("expected unavailable, got \(error)")
                return
            }
            #expect(message.contains("api-b"))
            #expect(message.contains("restored"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("RAM-safe coexistence (toggle OFF) may reuse a protected target without unloading the parent")
    func protectedTargetCanBeReusedByCoexistence() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "api-b",
            residentChatModels: ["local-a"],
            protectedResidentModels: ["api-b"],
            handoffEnabled: false,
            ramSafetyEnabled: true,
            requiredBytes: 2_000,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(plan.coexists)
        #expect(!plan.shouldUnload)
    }

    @Test("protected target keep-parent planning preserves RAM admission inputs")
    func protectedTargetReusePreservesMemoryInputs() throws {
        let gb: Int64 = 1 << 30
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "api-b",
            residentChatModels: ["local-a"],
            protectedResidentModels: ["api-b"],
            handoffEnabled: false,
            ramSafetyEnabled: true,
            requiredBytes: 4 * gb,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(plan.coexists)
        #expect(!plan.shouldUnload)
        #expect(plan.ramSafetyEnabled)
        #expect(plan.requiredBytes == 4 * gb)
    }

    @Test("RAM-safe coexistence (toggle OFF) may add a child without reclaiming protected residents")
    func coexistenceCanPreserveProtectedResident() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-c",
            residentChatModels: ["local-a"],
            protectedResidentModels: ["api-b"],
            handoffEnabled: false,
            ramSafetyEnabled: true,
            requiredBytes: 2_000,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(plan.coexists)
        #expect(!plan.shouldUnload)
    }

    @Test("OFF uses a scoped keep-parent handoff, never a passthrough eviction")
    func differentLocalHandoffDisabledRunsWithoutSequencing() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: ["local-a"],
            handoffEnabled: false,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == false)
        #expect(plan.coexists)
        #expect(plan.mode == "coexist")
        #expect(SubagentResidency.handoff(for: plan) is CoexistenceHandoff)
    }

    @Test("handoff toggle ON + main chat model NOT loaded: the reload leg still runs (parity)")
    func differentLocalMainNotLoadedStillRestores() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: [],  // main model evicted / never warmed
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            invokingParentModelName: "local-a"
        )
        #expect(plan.shouldUnload == true)
        #expect(plan.mode == "swap_unload_reload")
        #expect(SubagentResidency.handoff(for: plan) is ResidencyHandoff)
    }

    @Test("handoff toggle OFF + main chat model NOT loaded: run in place, no reload leg")
    func differentLocalMainNotLoadedToggleOffRunsInPlace() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: [],
            handoffEnabled: false,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            invokingParentModelName: "local-a"
        )
        #expect(plan.shouldUnload == false)
        #expect(plan.coexists)
    }

    @Test("main NOT loaded + delegate IS the parent model: no churn even with the toggle ON")
    func sameModelMainNotLoadedNoChurn() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "Local-A",
            residentChatModels: [],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            invokingParentModelName: "local-a"
        )
        #expect(plan.shouldUnload == false)
        #expect(!plan.coexists)
        #expect(plan.mode == "in_place")
    }

    @Test("nested agent caller: the invoking agent's own model is the one swapped out and restored")
    func nestedAgentCallerSwapsItsOwnModel() throws {
        // A custom agent (model `agent-c`) chatting and delegating to an agent
        // whose model is `local-b`: the residency decision is made for the
        // CALLER's resident model, not the default chat model.
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: ["agent-c"],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            invokingParentModelName: "agent-c"
        )
        #expect(plan.shouldUnload == true)
        // The nested caller delegating to its OWN model still runs in place.
        let same = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "agent-c",
            residentChatModels: ["agent-c"],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            invokingParentModelName: "agent-c"
        )
        #expect(same.shouldUnload == false)
    }

    @Test("handoff(for:) maps an unload plan to a residency handoff, else passthrough")
    func handoffMapping() {
        #expect(SubagentResidency.handoff(for: ResidencyPlan(shouldUnload: true)) is ResidencyHandoff)
        #expect(SubagentResidency.handoff(for: .none) is PassthroughHandoff)
        #expect(
            SubagentResidency.handoff(
                for: ResidencyPlan(shouldUnload: false, coexists: true)
            ) is CoexistenceHandoff
        )
    }

    @Test(
        "OFF retains the parent irrespective of RAM toggle or known bundle size",
        arguments: [false, true],
        [Int64(0), Int64(10 * 1_073_741_824)]
    )
    func keepParentIsIndependentOfMemoryAdmission(ramSafety: Bool, size: Int64) throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: ["local-a"],
            handoffEnabled: false,
            ramSafetyEnabled: ramSafety,
            requiredBytes: size,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(plan.coexists)
        #expect(!plan.shouldUnload)
        #expect(plan.requiredBytes == size)
        #expect(plan.ramSafetyEnabled == ramSafety)
        #expect(plan.mode == "coexist")
        #expect(SubagentResidency.handoff(for: plan) is CoexistenceHandoff)
    }

    @Test("admission class: coexist and unload plans are exclusive; in-place shares; remote never contends")
    func admissionClassMapping() {
        #expect(
            SubagentResidency.admissionClass(
                isLocal: true,
                plan: ResidencyPlan(shouldUnload: true)
            ) == .localExclusive
        )
        #expect(
            SubagentResidency.admissionClass(
                isLocal: true,
                plan: ResidencyPlan(shouldUnload: false, coexists: true)
            ) == .localExclusive
        )
        #expect(
            SubagentResidency.admissionClass(isLocal: true, plan: .none) == .localInPlace
        )
        #expect(
            SubagentResidency.admissionClass(isLocal: false, plan: .none) == .remote
        )
    }

    @Test("coexistence handoff: waits for idle then runs; a busy GPU refuses the run")
    func coexistenceHandoffIdleGate() async throws {
        let scope = SubagentScope(
            sessionId: "coexist-test",
            toolCallId: "call-1",
            agentId: UUID()
        )
        let resolved = ResolvedModel(name: "local-b", isLocal: true)
        let feed = SubagentFeed(toolCallId: "call-1", kindId: "spawn", title: "test")

        let ranBody = CoexistenceProbe()
        let idle = CoexistenceHandoff(maxElapsedSeconds: 30, waitForIdle: { _ in true })
        let result = try await idle.around(scope: scope, resolved: resolved, feed: feed) {
            ranBody.mark()
            return SubagentResult(payload: ["ok": true], summary: "done")
        }
        #expect(result.summary == "done")
        #expect(ranBody.wasMarked)

        let busy = CoexistenceHandoff(maxElapsedSeconds: 30, waitForIdle: { _ in false })
        do {
            _ = try await busy.around(scope: scope, resolved: resolved, feed: feed) {
                Issue.record("body must not run when the idle wait fails")
                return SubagentResult(payload: [:], summary: "")
            }
            Issue.record("expected an unavailable error")
        } catch let error as SubagentError {
            guard case .unavailable = error else {
                Issue.record("expected .unavailable, got \(error)")
                return
            }
        }
    }

    // MARK: - Named four-direction proof
    //
    // The same `decidePlan` outcomes above, restated as the FOUR
    // orchestrator→target residency directions the live `spawn_model_residency`
    // lane exercises end-to-end, so "all four directions" is legible and
    // asserted by name. `isLocal` is the TARGET's residency; `residentChatModels`
    // models the ORCHESTRATOR (a remote orchestrator has no resident local chat
    // model, so it is `[]`). Only local→local with a different model does real
    // work — every other direction runs in place.

    @Test("direction local→local (same model): run in place, no swap")
    func directionLocalToLocalSame() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-a",
            residentChatModels: ["local-a"],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == false)
    }

    @Test("direction local→local (different, handoff ON): unload then reload")
    func directionLocalToLocalDifferentOn() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: ["local-a"],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == true)
    }

    @Test("direction local→local (different, handoff OFF): retains invoking parent")
    func directionLocalToLocalDifferentOff() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: ["local-a"],
            handoffEnabled: false,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == false)
        #expect(plan.coexists)
    }

    @Test("direction local→remote: remote target never touches local GPU")
    func directionLocalToRemote() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: false,
            modelName: "xai/grok-4.3",
            residentChatModels: ["local-a"],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == false)
    }

    @Test("direction remote→local: remote orchestrator has no resident local to evict")
    func directionRemoteToLocal() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: [],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == false)
    }

    @Test("direction remote→remote: nothing local in play")
    func directionRemoteToRemote() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: false,
            modelName: "xai/grok-4.3",
            residentChatModels: [],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == false)
    }
}

/// Tiny thread-safe flag for the handoff body probe.
private final class CoexistenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    func mark() {
        lock.lock()
        defer { lock.unlock() }
        marked = true
    }
    var wasMarked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return marked
    }
}
