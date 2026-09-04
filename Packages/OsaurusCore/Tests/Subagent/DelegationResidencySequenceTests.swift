//
//  DelegationResidencySequenceTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  The delegation RAM-safety sequence, asserted as an ORDER (not as three
//  independent booleans): whenever the chat model delegates to a DIFFERENT
//  local model with the "Local Orchestrator Handoff" toggle on, the runtime
//  must
//
//    unload main → load delegate → run → unload delegate → reload main
//
//  and never hold both models resident. Model-free: the decision comes from
//  the pure `SubagentResidency.decidePlan` and the execution order from
//  `ResidencyHandoff` with injected operations (no `ModelRuntime`). Covers:
//    (a) main chat model loaded,
//    (b) main chat model NOT loaded (parity: reload leg still runs),
//    (c) a nested agent caller (its own model is the one swapped/restored),
//    (d) toggle OFF → no sequencing (and never a refusal),
//    (e) same model → no churn,
//  plus the failure path (delegate throws → delegate still unloaded → main
//  still reloaded) and the readout the user sees.
//

import Foundation
import Testing

@testable import OsaurusCore

private struct DelegateBlewUp: Error, LocalizedError {
    var errorDescription: String? { "delegate failed" }
}

/// Thread-safe ordered log of the realized sequence steps.
private final class SequenceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []
    func add(_ step: String) {
        lock.lock()
        steps.append(step)
        lock.unlock()
    }
    var value: [String] {
        lock.lock()
        defer { lock.unlock() }
        return steps
    }
}

/// A production-shaped handoff whose four residency legs record into `log`
/// using the same tokens `DelegationResidencySequence.Step` renders, so the
/// realized order can be compared 1:1 with the planned order.
///
/// `mainResident` mirrors what the real unload leg finds: `true` unloads the
/// parent and returns a normal lease; `false` returns the restore-only lease
/// (`unloadedModelNames == []`, `restoreModelNames == [parent]`).
private func sequencedHandoff(
    log: SequenceLog,
    plan: ResidencyPlan,
    mainResident: Bool,
    delegate: String
) -> ResidencyHandoff {
    ResidencyHandoff(
        plan: { _ in plan },
        preflight: { _, _, _ in },
        unload: { parent, _, _ in
            let parentName = parent ?? "chat"
            if mainResident {
                log.add("unload_main:\(parentName)")
                return ChatResidencyLease(unloadedModelNames: [parentName])
            }
            return ChatResidencyLease(
                unloadedModelNames: [],
                restoreModelNames: [parentName]
            )
        },
        restore: { lease, _ in
            for name in lease.restoreModelNames {
                log.add("reload_main:\(name)")
            }
            return lease.restoreModelNames
        },
        releaseDelegate: { _, _ in
            log.add("unload_delegate:\(delegate)")
            return [delegate]
        }
    )
}

private func scope(parent: String) -> SubagentScope {
    SubagentScope(
        sessionId: "seq",
        toolCallId: "call-1",
        agentId: Agent.defaultId,
        parentModelName: parent
    )
}

private func feed() -> SubagentFeed {
    SubagentFeed(toolCallId: "call-1", kindId: "spawn", title: "delegation")
}

private let denied = "unused: the toggle never refuses"

@Suite("Delegation RAM-safety sequence")
struct DelegationResidencySequenceTests {

    // MARK: (a) main chat model loaded

    @Test("(a) main loaded, different local delegate: unload main → load delegate → run → unload delegate → reload main")
    func mainLoadedFullSequence() async throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: ["local-a"],
            handoffEnabled: true,
            ramSafetyEnabled: false,
            requiredBytes: 0,
            idleWaitSeconds: 60,
            deniedMessage: denied,
            invokingParentModelName: "local-a"
        )
        #expect(plan.shouldUnload)

        let log = SequenceLog()
        let handoff = sequencedHandoff(
            log: log,
            plan: plan,
            mainResident: true,
            delegate: "local-b"
        )
        let resolved = ResolvedModel(name: "local-b", id: "local-b", isLocal: true)
        let liveFeed = feed()
        let result = try await handoff.around(
            scope: scope(parent: "local-a"),
            resolved: resolved,
            feed: liveFeed
        ) {
            // The delegate model cold-loads INSIDE the body under the lease's
            // ownership token (so step 5 can release exactly it).
            #expect(ModelResidencyOwnershipContext.childOwnershipToken != nil)
            log.add("load_delegate:local-b")
            log.add("run")
            return SubagentResult(payload: ["summary": "done"], summary: "done")
        }

        let expected = [
            "unload_main:local-a",
            "load_delegate:local-b",
            "run",
            "unload_delegate:local-b",
            "reload_main:local-a",
        ]
        #expect(log.value == expected)
        // The planned order equals the realized order.
        let planned = DelegationResidencySequence.steps(
            plan: plan,
            mainModelName: "local-a",
            mainResident: true,
            delegateModelName: "local-b"
        )
        #expect(planned.map(\.description) == expected)
        // The user-visible readout carries the same sequence.
        #expect(result.payload["handoff_sequence"] as? [String] == expected)
        let summary = result.payload["handoff_summary"] as? String ?? ""
        #expect(summary.contains("swapped chat model 'local-a' out for delegate 'local-b'"))
        #expect(summary.contains("loaded 'local-a' back"))
        #expect(
            liveFeed.currentEvents().contains {
                $0.kind == .narrate && $0.title == "model swap"
            }
        )
        #expect(
            liveFeed.currentEvents().contains {
                $0.kind == .phase && $0.title == "handing_off_to_delegate"
            }
        )
    }

    // MARK: (b) main chat model NOT loaded

    @Test("(b) main NOT loaded: no unload leg, but the delegate is still unloaded and main is loaded back")
    func mainNotLoadedStillRestores() async throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: [],
            handoffEnabled: true,
            ramSafetyEnabled: false,
            requiredBytes: 0,
            idleWaitSeconds: 60,
            deniedMessage: denied,
            invokingParentModelName: "local-a"
        )
        #expect(plan.shouldUnload, "the parity leg needs the swap plan even when main is not loaded")

        let log = SequenceLog()
        let handoff = sequencedHandoff(
            log: log,
            plan: plan,
            mainResident: false,
            delegate: "local-b"
        )
        let result = try await handoff.around(
            scope: scope(parent: "local-a"),
            resolved: ResolvedModel(name: "local-b", id: "local-b", isLocal: true),
            feed: feed()
        ) {
            log.add("load_delegate:local-b")
            log.add("run")
            return SubagentResult(payload: ["summary": "done"], summary: "done")
        }

        let expected = [
            "load_delegate:local-b",
            "run",
            "unload_delegate:local-b",
            "reload_main:local-a",
        ]
        #expect(log.value == expected)
        #expect(
            DelegationResidencySequence.steps(
                plan: plan,
                mainModelName: "local-a",
                mainResident: false,
                delegateModelName: "local-b"
            ).map(\.description) == expected
        )
        #expect(result.payload["handoff_sequence"] as? [String] == expected)
        let summary = result.payload["handoff_summary"] as? String ?? ""
        #expect(summary.contains("was not loaded"))
        #expect(summary.contains("loaded 'local-a' for the chat turn"))
    }

    @Test("(b) restore-only lease shape: nothing unloaded, parent queued for reload")
    func restoreOnlyLeaseShape() {
        let lease = ChatResidencyLease(
            unloadedModelNames: [],
            restoreModelNames: ["local-a"]
        )
        #expect(lease.isRestoreOnly)
        #expect(!lease.isEmpty)
        // A normal lease restores exactly what it unloaded.
        let normal = ChatResidencyLease(unloadedModelNames: ["local-a"])
        #expect(!normal.isRestoreOnly)
        #expect(normal.restoreModelNames == ["local-a"])
        #expect(ChatResidencyLease.empty.isEmpty)
    }

    // MARK: (c) nested agent caller

    @Test("(c) nested agent caller: the CALLER's model is swapped out and restored, not the default chat model")
    func nestedAgentCallerSequence() async throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: ["agent-c"],
            handoffEnabled: true,
            ramSafetyEnabled: false,
            requiredBytes: 0,
            idleWaitSeconds: 60,
            deniedMessage: denied,
            invokingParentModelName: "agent-c"
        )
        #expect(plan.shouldUnload)

        let log = SequenceLog()
        let handoff = sequencedHandoff(
            log: log,
            plan: plan,
            mainResident: true,
            delegate: "local-b"
        )
        // The scope carries the invoking AGENT's model (`ChatExecutionContext
        // .currentModelName` of the agent's own chat turn), which is what the
        // unload/reload legs act on.
        let callerScope = SubagentScope(
            sessionId: "agent-chat",
            toolCallId: "call-2",
            agentId: UUID(),
            parentModelName: "agent-c"
        )
        _ = try await handoff.around(
            scope: callerScope,
            resolved: ResolvedModel(name: "local-b", id: "local-b", isLocal: true),
            feed: feed()
        ) {
            log.add("load_delegate:local-b")
            log.add("run")
            return SubagentResult(payload: ["summary": "done"], summary: "done")
        }
        #expect(
            log.value == [
                "unload_main:agent-c",
                "load_delegate:local-b",
                "run",
                "unload_delegate:local-b",
                "reload_main:agent-c",
            ]
        )
    }

    // MARK: (d) toggle OFF

    @Test("(d) toggle OFF: no sequencing — passthrough handoff, body only, never a refusal")
    func toggleOffNoSequencing() async throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: ["local-a"],
            handoffEnabled: false,
            ramSafetyEnabled: false,
            requiredBytes: 0,
            idleWaitSeconds: 60,
            deniedMessage: denied,
            invokingParentModelName: "local-a"
        )
        #expect(!plan.shouldUnload)
        #expect(plan.sequencingDisabled)
        #expect(plan.mode == "sequencing_off")

        let handoff = SubagentResidency.handoff(for: plan)
        #expect(handoff is PassthroughHandoff)

        let log = SequenceLog()
        _ = try await handoff.around(
            scope: scope(parent: "local-a"),
            resolved: ResolvedModel(name: "local-b", id: "local-b", isLocal: true),
            feed: feed()
        ) {
            log.add("run")
            return SubagentResult(payload: ["summary": "done"], summary: "done")
        }
        #expect(log.value == ["run"])
        #expect(
            DelegationResidencySequence.steps(
                plan: plan,
                mainModelName: "local-a",
                mainResident: true,
                delegateModelName: "local-b"
            ) == [.run]
        )
        let summary = DelegationResidencySequence.summary(
            plan: plan,
            mainModelName: "local-a",
            mainResident: true,
            delegateModelName: "local-b"
        )
        #expect(summary.contains("Local Orchestrator Handoff is off"))
    }

    // MARK: (e) same model

    @Test("(e) same model as the caller: no unload/reload churn even with the toggle ON")
    func sameModelNoChurn() async throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-a",
            residentChatModels: ["local-a"],
            handoffEnabled: true,
            ramSafetyEnabled: false,
            requiredBytes: 0,
            idleWaitSeconds: 60,
            deniedMessage: denied,
            invokingParentModelName: "local-a"
        )
        #expect(!plan.shouldUnload)
        #expect(!plan.sequencingDisabled)
        #expect(plan.mode == "in_place")
        #expect(SubagentResidency.handoff(for: plan) is PassthroughHandoff)
        #expect(
            DelegationResidencySequence.steps(
                plan: plan,
                mainModelName: "local-a",
                mainResident: true,
                delegateModelName: "local-a"
            ) == [.run]
        )
    }

    @Test("cloud delegate: no local swap regardless of the toggle")
    func cloudDelegateNoSwap() throws {
        for toggle in [true, false] {
            let plan = try SubagentResidency.decidePlan(
                isLocal: false,
                modelName: "openai/gpt-5",
                residentChatModels: ["local-a"],
                handoffEnabled: toggle,
                ramSafetyEnabled: false,
                requiredBytes: 0,
                idleWaitSeconds: 60,
                deniedMessage: denied,
                invokingParentModelName: "local-a"
            )
            #expect(!plan.shouldUnload)
            #expect(SubagentResidency.handoff(for: plan) is PassthroughHandoff)
        }
    }

    // MARK: failure path keeps the order

    @Test("delegate failure: the delegate is still unloaded and main still reloaded, in order")
    func failurePathKeepsOrder() async {
        let plan = ResidencyPlan(shouldUnload: true)
        let log = SequenceLog()
        let handoff = sequencedHandoff(
            log: log,
            plan: plan,
            mainResident: true,
            delegate: "local-b"
        )
        await #expect(throws: DelegateBlewUp.self) {
            _ = try await handoff.around(
                scope: scope(parent: "local-a"),
                resolved: ResolvedModel(name: "local-b", id: "local-b", isLocal: true),
                feed: feed()
            ) {
                log.add("load_delegate:local-b")
                throw DelegateBlewUp()
            }
        }
        #expect(
            log.value == [
                "unload_main:local-a",
                "load_delegate:local-b",
                "unload_delegate:local-b",
                "reload_main:local-a",
            ]
        )
    }

    @Test("two models are never resident at once: unload_delegate always precedes reload_main")
    func delegateReleasedBeforeMainReload() async throws {
        for mainResident in [true, false] {
            let log = SequenceLog()
            let handoff = sequencedHandoff(
                log: log,
                plan: ResidencyPlan(shouldUnload: true),
                mainResident: mainResident,
                delegate: "local-b"
            )
            _ = try await handoff.around(
                scope: scope(parent: "local-a"),
                resolved: ResolvedModel(name: "local-b", id: "local-b", isLocal: true),
                feed: feed()
            ) {
                log.add("run")
                return SubagentResult(payload: [:], summary: "")
            }
            let steps = log.value
            let release = steps.firstIndex(of: "unload_delegate:local-b")
            let reload = steps.firstIndex(of: "reload_main:local-a")
            #expect(release != nil && reload != nil)
            if let release, let reload {
                #expect(
                    release < reload,
                    Comment(rawValue: "mainResident=\(mainResident): \(steps)")
                )
            }
            if mainResident {
                #expect(steps.first == "unload_main:local-a")
            } else {
                #expect(!steps.contains("unload_main:local-a"))
            }
        }
    }
}
