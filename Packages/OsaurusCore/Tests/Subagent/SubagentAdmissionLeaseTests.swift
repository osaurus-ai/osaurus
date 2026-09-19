import Foundation
import Testing

@testable import OsaurusCore

private actor LeaseEvents {
    private var events: [String] = []
    func add(_ event: String) { events.append(event) }
    func contains(_ event: String) -> Bool { events.contains(event) }
    func snapshot() -> [String] { events }
}

private func waitForLeaseEvent(_ event: String, in events: LeaseEvents) async -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while !(await events.contains(event)) {
        if Date() > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

@Suite("Owned nested local admission")
struct SubagentAdmissionLeaseTests {
    private func reserve(
        _ controller: SubagentAdmission,
        model: String = "parent",
        slots: Int = 1
    ) async -> SubagentAdmissionLease {
        let outcome = await controller.reserveLocalInPlace(
            modelKey: model, requestedSlots: slots, slotCapacity: slots
        )
        #expect(outcome == .admitted(slots: slots))
        return SubagentAdmissionLease(
            controller: controller, admissionClass: .localInPlace,
            modelKey: model, slots: slots, parentInterrupt: InterruptToken()
        )
    }

    @Test("a nested child borrows owned capacity and releases exactly once", arguments: [1, 2])
    func nestedCapacityOne(slots: Int) async throws {
        let controller = SubagentAdmission(pollNanoseconds: 1_000_000)
        let lease = await reserve(controller, slots: slots)
        let result = try await lease.withNestedRun(interrupt: InterruptToken(), onWait: { _ in }) { child in
            #expect(await controller.snapshot().inPlace == 0)
            #expect(await controller.snapshot().exclusive == 1)
            let outcome = await child.reserveLocalInPlace(
                modelKey: "parent", requestedSlots: 1, slotCapacity: 1, timeoutSeconds: 0.1
            )
            #expect(outcome == .admitted(slots: 1))
            await child.releaseLocalInPlace(modelKey: "parent", slots: 1)
            return "completed"
        }
        #expect(result == "completed")
        // Parent continuation is still covered until its handoff finishes.
        #expect(await controller.snapshot().exclusive == 1)
        await lease.close()
        await lease.close()
        #expect(await controller.snapshot().exclusive == 0)
        #expect(await controller.snapshot().inPlace == 0)
    }

    @Test("an exclusive parent can run another local model without a second global writer")
    func differentModelHandoff() async throws {
        let controller = SubagentAdmission(pollNanoseconds: 1_000_000)
        #expect(await controller.admit(.localExclusive, modelKey: "parent") == .admitted)
        let lease = SubagentAdmissionLease(
            controller: controller, admissionClass: .localExclusive,
            modelKey: "parent", slots: 0, parentInterrupt: InterruptToken()
        )
        _ = try await lease.withNestedRun(interrupt: InterruptToken(), onWait: { _ in }) { child in
            #expect(await child.admit(.localExclusive, modelKey: "different", timeoutSeconds: 0.1) == .admitted)
            #expect(await controller.snapshot().exclusive == 1)
            #expect(await controller.admit(.remote) == .admitted)
            await controller.release(.remote)
            await child.release(.localExclusive, modelKey: "different")
            return "handoff restored"
        }
        await lease.close()
        #expect(await controller.snapshot().exclusive == 0)
    }

    @Test("two parents release only their own slots before upgrading")
    func simultaneousUpgrades() async throws {
        let controller = SubagentAdmission(pollNanoseconds: 1_000_000)
        #expect(await controller.reserveLocalInPlace(
            modelKey: "parent", requestedSlots: 2, slotCapacity: 2
        ) == .admitted(slots: 2))
        let leases = (0..<2).map { _ in
            SubagentAdmissionLease(
                controller: controller, admissionClass: .localInPlace,
                modelKey: "parent", slots: 1, parentInterrupt: InterruptToken()
            )
        }
        let events = LeaseEvents()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, lease) in leases.enumerated() {
                group.addTask {
                    _ = try await lease.withNestedRun(interrupt: InterruptToken(), onWait: { _ in }) { _ in
                        #expect(await controller.snapshot().exclusive == 1)
                        await events.add("child-\(index)")
                        return "done"
                    }
                    await lease.close()
                }
            }
            try await group.waitForAll()
        }
        #expect(await events.snapshot().count == 2)
        #expect(await controller.snapshot().exclusive == 0)
        #expect(await controller.snapshot().inPlace == 0)
    }

    @Test("Stop while upgrading drains ownership but never starts the cancelled child")
    func cancelledUpgrade() async {
        let controller = SubagentAdmission(pollNanoseconds: 1_000_000)
        #expect(await controller.reserveLocalInPlace(
            modelKey: "parent", requestedSlots: 2, slotCapacity: 2
        ) == .admitted(slots: 2))
        let interrupt = InterruptToken()
        let lease = SubagentAdmissionLease(
            controller: controller, admissionClass: .localInPlace,
            modelKey: "parent", slots: 1, parentInterrupt: interrupt
        )
        let events = LeaseEvents()
        let run = Task {
            try await lease.withNestedRun(interrupt: InterruptToken(), onWait: { _ in
                interrupt.interrupt()
            }) { _ in
                await events.add("unexpected child")
                return "unexpected"
            }
        }
        // The other owner's slot must not be stolen by the upgrade/Stop.
        let deadline = Date().addingTimeInterval(5)
        while !interrupt.isInterrupted, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(interrupt.isInterrupted)
        #expect(await controller.snapshot().inPlace == 1)
        run.cancel()
        await controller.releaseLocalInPlace(modelKey: "parent", slots: 1)
        do {
            _ = try await run.value
            Issue.record("cancelled nested child must not execute")
        } catch is CancellationError {} catch { Issue.record("unexpected error: \(error)") }
        #expect(await events.snapshot().isEmpty)
        await lease.close()
        #expect(await controller.snapshot().exclusive == 0)
        #expect(await controller.snapshot().inPlace == 0)
    }

    @Test("closing interrupts and drains the child before releasing global ownership")
    func closeDrainsActiveChild() async throws {
        let controller = SubagentAdmission(pollNanoseconds: 1_000_000)
        let lease = await reserve(controller)
        let childInterrupt = InterruptToken()
        let events = LeaseEvents()
        let run = Task {
            try await lease.withNestedRun(interrupt: childInterrupt, onWait: { _ in }) { _ in
                await events.add("started")
                while !childInterrupt.isInterrupted {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                #expect(await controller.snapshot().exclusive == 1)
                await events.add("drained")
                return "stopped"
            }
        }
        #expect(await waitForLeaseEvent("started", in: events))
        let close = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await lease.close()
            await events.add("released")
        }
        await close.value
        #expect(try await run.value == "stopped")
        #expect(await events.snapshot() == ["started", "drained", "released"])
        #expect(await controller.snapshot().exclusive == 0)
        do {
            _ = try await lease.withNestedRun(interrupt: InterruptToken(), onWait: { _ in }) { _ in "late" }
            Issue.record("closed parent must reject late children")
        } catch is CancellationError {}
    }

    @Test("a stopped queued sibling does not interrupt the active child")
    func queuedSiblingStop() async throws {
        let controller = SubagentAdmission(pollNanoseconds: 1_000_000)
        let lease = await reserve(controller)
        let firstInterrupt = InterruptToken()
        let secondInterrupt = InterruptToken()
        let events = LeaseEvents()
        let first = Task {
            try await lease.withNestedRun(interrupt: firstInterrupt, onWait: { _ in }) { _ in
                await events.add("first started")
                while !firstInterrupt.isInterrupted { try? await Task.sleep(for: .milliseconds(5)) }
                return "first done"
            }
        }
        #expect(await waitForLeaseEvent("first started", in: events))
        do {
            _ = try await lease.withNestedRun(interrupt: secondInterrupt, onWait: { _ in
                secondInterrupt.interrupt()
            }) { _ in
                await events.add("unexpected second")
                return "unexpected"
            }
            Issue.record("stopped sibling must not run")
        } catch is CancellationError {}
        #expect(!firstInterrupt.isInterrupted)
        #expect(await controller.snapshot().exclusive == 1)
        await lease.close()
        _ = try await first.value
        #expect(await events.snapshot() == ["first started"])
        #expect(await controller.snapshot().exclusive == 0)
    }
}

private struct NestedAdmissionKind: SubagentKind, SubagentPostAdmissionResidencyPlanning {
    let id: String
    var isLocal = true
    var validate: @Sendable () async throws -> Void = {}
    var execute: @Sendable (InterruptToken) async throws -> SubagentResult

    var capability: SubagentCapability { .init(id: id, toolNames: [id], gate: .delegation) }
    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        .init(name: "nested-test", id: "nested-test", isLocal: isLocal)
    }
    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision { .allow }
    func validateExecutionAuthority(_ scope: SubagentScope, resolved: ResolvedModel) async throws {
        try await validate()
    }
    func refreshedResidencyPlanAfterAdmission(for resolved: ResolvedModel) async throws -> ResidencyPlan {
        .init(shouldUnload: false, ramSafetyEnabled: true)
    }
    func run(
        _ scope: SubagentScope, _ resolved: ResolvedModel, feed: SubagentFeed, interrupt: InterruptToken
    ) async throws -> SubagentResult { try await execute(interrupt) }
}

@Suite("Nested real delegated chat host", .serialized)
struct SubagentNestedHostTests {
    @Test("Stop during a nested upgrade keeps the user-denied cancellation envelope")
    func stoppedNestedUpgradeEnvelope() async throws {
        let controller = SubagentAdmission(pollNanoseconds: 1_000_000)
        #expect(await controller.reserveLocalInPlace(
            modelKey: "nested-test", requestedSlots: 2, slotCapacity: 2
        ) == .admitted(slots: 2))
        let lease = SubagentAdmissionLease(
            controller: controller, admissionClass: .localInPlace,
            modelKey: "nested-test", slots: 1, parentInterrupt: InterruptToken()
        )
        let events = LeaseEvents()
        let child = try await prepared(NestedAdmissionKind(id: "stopped-child") { _ in
            await events.add("unexpected child")
            return SubagentResult(payload: ["summary": "unexpected"])
        })
        let interrupt = InterruptToken()
        let run = Task {
            await SubagentSession.$inheritedAdmissionLease.withValue(lease) {
                await SubagentSession.runPrepared(
                    child,
                    presentation: .init(
                        feed: SubagentFeed(toolCallId: child.scope.toolCallId, kindId: child.tool, title: child.tool),
                        interrupt: interrupt, registerWithUI: false
                    ),
                    captureProcessCacheSnapshot: false,
                    admissionController: controller,
                    postAdmissionLocalCapacityOverride: { _, _ in 1 }
                )
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while await controller.snapshot().inPlace != 1, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await controller.snapshot().inPlace == 1)
        interrupt.interrupt()
        // Only the unrelated peer releases its own slot.
        await controller.releaseLocalInPlace(modelKey: "nested-test", slots: 1)
        let result = await run.value
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("user_denied"))
        #expect(result.contains("\"cancelled\":true"))
        #expect(!(await events.contains("unexpected child")))
        await lease.close()
        #expect(await controller.snapshot().exclusive == 0)
        #expect(await controller.snapshot().inPlace == 0)
    }

    @Test("an inherited chat task executes a browser child and keeps RAM validation", arguments: [0, 1])
    func inheritedChatTask(capacity: Int) async throws {
        let controller = SubagentAdmission(pollNanoseconds: 1_000_000)
        let events = LeaseEvents()
        let child = NestedAdmissionKind(id: "browser-child") { _ in
            await events.add("child ran")
            return SubagentResult(payload: ["summary": "browser finished"])
        }
        let childPrepared = try await prepared(child)
        let parent = NestedAdmissionKind(id: "delegated-chat") { _ in
            // Matches AgentDelegationDispatcher -> ChatSession.send: reset
            // recursion only, then create a task which inherits the lease.
            let nested = await SubagentSession.$activeKindId.withValue(nil) {
                let task = Task {
                    await run(childPrepared, controller: controller) { _, _ in
                        await events.add("RAM checked")
                        return capacity
                    }
                }
                return await task.value
            }
            #expect(ToolEnvelope.isSuccess(nested) == (capacity > 0))
            if capacity == 0 { #expect(nested.contains("stable_memory_refusal")) }
            await events.add("parent continued")
            return SubagentResult(payload: ["summary": "parent done"])
        }
        let result = await run(try await prepared(parent), controller: controller) { _, _ in 1 }
        #expect(ToolEnvelope.isSuccess(result))
        #expect(await events.contains("RAM checked"))
        #expect(await events.contains("child ran") == (capacity > 0))
        #expect(await events.contains("parent continued"))
        #expect(await controller.snapshot().inPlace == 0)
        #expect(await controller.snapshot().exclusive == 0)
    }

    @Test("nested execution authority is rechecked after ownership transfer")
    func nestedAuthorityRevocation() async throws {
        let controller = SubagentAdmission(pollNanoseconds: 1_000_000)
        let events = LeaseEvents()
        let child = NestedAdmissionKind(id: "revoked-child", validate: {
            await events.add("validated")
            if await events.snapshot().count > 1 { throw SubagentError.unavailable("grant revoked") }
        }) { _ in
            await events.add("unexpected child")
            return SubagentResult(payload: ["summary": "unexpected"])
        }
        let childPrepared = try await prepared(child)
        let parent = NestedAdmissionKind(id: "delegated-chat") { _ in
            let nested = await SubagentSession.$activeKindId.withValue(nil) {
                await run(childPrepared, controller: controller) { _, _ in 1 }
            }
            #expect(ToolEnvelope.isError(nested))
            #expect(nested.contains("grant revoked"))
            return SubagentResult(payload: ["summary": "parent handled refusal"])
        }
        let result = await run(try await prepared(parent), controller: controller) { _, _ in 1 }
        #expect(ToolEnvelope.isSuccess(result))
        #expect(!(await events.contains("unexpected child")))
        #expect(await controller.snapshot().exclusive == 0)
    }

    private func prepared(_ kind: NestedAdmissionKind) async throws -> PreparedSubagentRun {
        let result = await SubagentSession.prepare(
            kind, tool: kind.id,
            scope: .init(sessionId: UUID().uuidString, toolCallId: UUID().uuidString, agentId: Agent.defaultId)
        )
        guard case .ready(let prepared) = result else { throw CancellationError() }
        return prepared
    }

    private func run(
        _ prepared: PreparedSubagentRun,
        controller: SubagentAdmission,
        capacity: @escaping @Sendable (PreparedSubagentRun, ResidencyPlan) async -> Int
    ) async -> String {
        let interrupt = InterruptToken()
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            interrupt.interrupt()
        }
        let result = await SubagentSession.runPrepared(
            prepared,
            presentation: .init(
                feed: SubagentFeed(toolCallId: prepared.scope.toolCallId, kindId: prepared.tool, title: prepared.tool),
                interrupt: interrupt, registerWithUI: false
            ),
            captureProcessCacheSnapshot: false,
            admissionController: controller,
            postAdmissionLocalCapacityOverride: capacity
        )
        deadline.cancel()
        await deadline.value
        return result
    }
}
