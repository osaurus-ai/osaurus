//
//  SubagentResidencyTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Model-free coverage of the shared residency DECISION (`SubagentResidency`)
//  that every chat-driven kind (spawn / computer_use / sandbox_reduce) uses to
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
            ramSafetyEnabled: false,
            requiredBytes: 0,
            idleWaitSeconds: 60,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == false)
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

    @Test("a different local model with the handoff disabled is rejected BEFORE evict")
    func differentLocalHandoffDisabledThrows() {
        do {
            _ = try SubagentResidency.decidePlan(
                isLocal: true,
                modelName: "local-b",
                residentChatModels: ["local-a"],
                handoffEnabled: false,
                ramSafetyEnabled: true,
                requiredBytes: 4096,
                idleWaitSeconds: 90,
                deniedMessage: denied
            )
            Issue.record("expected a denied error")
        } catch let error as SubagentError {
            guard case .denied(let message) = error else {
                Issue.record("expected .denied, got \(error)")
                return
            }
            #expect(message == denied)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("handoff(for:) maps an unload plan to a residency handoff, else passthrough")
    func handoffMapping() {
        #expect(SubagentResidency.handoff(for: ResidencyPlan(shouldUnload: true)) is ResidencyHandoff)
        #expect(SubagentResidency.handoff(for: .none) is PassthroughHandoff)
    }
}
