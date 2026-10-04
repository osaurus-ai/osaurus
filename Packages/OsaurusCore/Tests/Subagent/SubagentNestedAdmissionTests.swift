import Foundation
import Testing

@testable import OsaurusCore

// The real dispatcher deliberately clears activeKindId for a delegated chat.
// These model-free kinds preserve that exact task-local boundary and exercise
// the production host/gate, including its handoff tail, without loading MLX.
@Suite("Subagent nested admission")
struct SubagentNestedAdmissionTests {
    @Test("a delegated chat can finish its nested exclusive job", arguments: [SubagentAdmissionClass.localInPlace, .localExclusive])
    func nestedJobMakesProgress(ownerClass: SubagentAdmissionClass) async {
        let gate = SubagentAdmission(pollNanoseconds: 1_000_000)
        let probe = NestedAdmissionProbe()
        let childStop = InterruptToken()
        let owner = Task {
            let result = await Self.run(gate, id: "spawn", admission: ownerClass) { _, _, _, _ in
                let child = await Self.child(gate, stop: childStop) { _, _, _, _ in
                    await probe.record("child-ran")
                    return Self.success
                }
                await probe.setResult(child)
                return Self.success
            }
            return result
        }
        let progressed = await probe.waitFor("child-ran")
        #expect(progressed)
        if !progressed { childStop.interrupt() }
        #expect(ToolEnvelope.isSuccess(await owner.value))
        #expect(ToolEnvelope.isSuccess(await probe.result()))
        await Self.expectEmpty(gate)
    }

    @Test("nested admission yields only its own slot and still waits for a peer")
    func unrelatedPeerIsNotBorrowed() async {
        let gate = SubagentAdmission(pollNanoseconds: 1_000_000)
        let probe = NestedAdmissionProbe()
        let childStop = InterruptToken()
        let feed = Self.feed("peer-child")
        let owner = Task {
            await Self.run(gate, id: "spawn", admission: .localInPlace) { _, _, _, _ in
                #expect(await gate.admit(.localInPlace, modelKey: Self.model) == .admitted)
                await probe.record("peer-held")
                let child = await Self.child(gate, stop: childStop, feed: feed) { _, _, _, _ in
                    await probe.record("child-ran")
                    return Self.success
                }
                await probe.setResult(child)
                return Self.success
            }
        }
        #expect(await probe.waitFor("peer-held"))
        #expect(await Self.waitForQueue(feed))
        let queued = await gate.snapshot()
        #expect(queued.inPlace == 1)
        #expect(queued.exclusive == 0)
        #expect(!(await probe.contains("child-ran")))
        await gate.release(.localInPlace, modelKey: Self.model)
        let progressed = await probe.waitFor("child-ran")
        #expect(progressed)
        if !progressed { childStop.interrupt() }
        #expect(ToolEnvelope.isSuccess(await owner.value))
        #expect(ToolEnvelope.isSuccess(await probe.result()))
        await Self.expectEmpty(gate)
    }

    @Test("simultaneous nested exclusive jobs serialize through the same owner")
    func simultaneousNestedJobsSerialize() async {
        let gate = SubagentAdmission(pollNanoseconds: 1_000_000)
        let probe = NestedAdmissionProbe()
        let firstStop = InterruptToken()
        let secondStop = InterruptToken()
        let owner = Task {
            await Self.run(gate, id: "spawn", admission: .localInPlace) { _, _, _, _ in
                let first = Task {
                    await Self.child(gate, stop: firstStop) { _, _, _, _ in
                        await probe.enter("first")
                        await probe.waitForRelease()
                        await probe.leave()
                        return Self.success
                    }
                }
                let second = Task {
                    await Self.child(gate, stop: secondStop) { _, _, _, _ in
                        await probe.enter("second")
                        await probe.waitForRelease()
                        await probe.leave()
                        return Self.success
                    }
                }
                let results = await [first.value, second.value]
                #expect(results.allSatisfy(ToolEnvelope.isSuccess))
                return Self.success
            }
        }
        let progressed = await probe.waitForAnyEntry()
        #expect(progressed)
        if !progressed { firstStop.interrupt(); secondStop.interrupt() }
        await probe.release()
        #expect(ToolEnvelope.isSuccess(await owner.value))
        #expect(await probe.maximum() == 1)
        #expect(await probe.entries() == 2)
        await Self.expectEmpty(gate)
    }

    @Test("stopping a nested waiter restores owner admission before continuation")
    func stoppedWaiterRestoresOwnerExactlyOnce() async {
        let gate = SubagentAdmission(pollNanoseconds: 1_000_000)
        let probe = NestedAdmissionProbe()
        let childStop = InterruptToken()
        let feed = Self.feed("cancel-child")
        let owner = Task {
            await Self.run(gate, id: "spawn", admission: .localInPlace) { _, _, _, _ in
                #expect(await gate.admit(.localInPlace, modelKey: Self.model) == .admitted)
                await probe.record("peer-held")
                let child = await Self.child(gate, stop: childStop, feed: feed) { _, _, _, _ in
                    await probe.record("unexpected-child-run")
                    return Self.success
                }
                await probe.setResult(child)
                await probe.record("owner-continuation")
                await probe.waitForRelease()
                return Self.success
            }
        }
        #expect(await probe.waitFor("peer-held"))
        #expect(await Self.waitForQueue(feed))
        childStop.interrupt()
        await gate.release(.localInPlace, modelKey: Self.model)
        #expect(await probe.waitFor("owner-continuation"))
        let restored = await gate.snapshot()
        #expect(restored.exclusive == 1)
        #expect(restored.inPlace == 0)
        #expect(!(await probe.contains("unexpected-child-run")))
        let result = await probe.result()
        #expect(Self.kind(result) == "user_denied")
        await probe.release()
        #expect(ToolEnvelope.isSuccess(await owner.value))
        await Self.expectEmpty(gate)
    }

    @Test("outer termination cannot release a still-draining nested job")
    func ownerTerminationWaitsForNestedDrain() async {
        let gate = SubagentAdmission(pollNanoseconds: 1_000_000)
        let probe = NestedAdmissionProbe()
        let childStop = InterruptToken()
        let ownerStop = InterruptToken()
        let owner = Task {
            let result = await Self.run(gate, id: "spawn", admission: .localInPlace, stop: ownerStop) { _, _, _, interrupt in
                let child = Task {
                    await Self.child(gate, stop: childStop) { _, _, _, _ in
                        await probe.record("child-ran")
                        // Deliberate soft drain: a stopped consumer cannot abandon it.
                        await probe.waitForRelease()
                        return Self.success
                    }
                }
                await probe.setChild(child)
                await probe.waitForOwnerReturn()
                await probe.record("owner-body-returned")
                if interrupt.isInterrupted { throw CancellationError() }
                return Self.success
            }
            await probe.record("owner-finished")
            return result
        }
        let progressed = await probe.waitFor("child-ran")
        #expect(progressed)
        ownerStop.interrupt()
        await probe.allowOwnerReturn()
        #expect(await probe.waitFor("owner-body-returned"))
        if progressed {
            let peerWaiting = NestedAdmissionProbe()
            let peer = Task {
                await gate.admit(.localExclusive, onWait: { _ in Task { await peerWaiting.record("queued") } })
            }
            #expect(await peerWaiting.waitFor("queued"))
            #expect(!(await probe.contains("owner-finished")))
            await probe.release()
            #expect(await peer.value == .admitted)
            await gate.release(.localExclusive)
        } else {
            childStop.interrupt()
            await probe.release()
        }
        #expect(Self.kind(await owner.value) == "user_denied")
        _ = await probe.childResult()
        await Self.expectEmpty(gate)
    }

    @Test("queued delegation rebinds its own admission before the child tool")
    func queuedDelegationPreservesAdmission() async {
        let gate = SubagentAdmission(pollNanoseconds: 1_000_000)
        let probe = NestedAdmissionProbe()
        let childStop = InterruptToken()
        let owner = Task {
            await Self.run(gate, id: "spawn", admission: .localInPlace) { _, _, _, _ in
                let context = DelegationResidencyContext.capture(source: .delegation)
                let result = await Task.detached {
                    let resultBox = NestedAdmissionProbe()
                    // This is the existing deferred startWork wrapper, entered
                    // from an unrelated pump task with no inherited lease.
                    await context.run {
                        let child = await Self.child(gate, stop: childStop) { _, _, _, _ in
                            await probe.record("queued-child-ran")
                            return Self.success
                        }
                        await resultBox.setResult(child)
                    }
                    return await resultBox.result()
                }.value
                await probe.setResult(result)
                return Self.success
            }
        }
        let progressed = await probe.waitFor("queued-child-ran")
        #expect(progressed)
        if !progressed { childStop.interrupt() }
        #expect(ToolEnvelope.isSuccess(await owner.value))
        #expect(ToolEnvelope.isSuccess(await probe.result()))
        await Self.expectEmpty(gate)
    }

    @Test("a second nested Stop does not refund the first job's live ownership")
    func queuedBorrowerStopLeavesFirstJobOwned() async {
        let gate = SubagentAdmission(pollNanoseconds: 1_000_000)
        let probe = NestedAdmissionProbe()
        let firstStop = InterruptToken()
        let secondStop = InterruptToken()
        let secondFeed = Self.feed("second-stopped-child")
        let owner = Task {
            await Self.run(gate, id: "spawn", admission: .localInPlace) { _, _, _, _ in
                let first = Task {
                    await Self.child(gate, stop: firstStop) { _, _, _, _ in
                        await probe.record("first-ran")
                        await probe.waitForRelease()
                        return Self.success
                    }
                }
                let firstProgressed = await probe.waitFor("first-ran")
                if !firstProgressed { firstStop.interrupt() }
                let second = await Self.child(gate, stop: secondStop, feed: secondFeed) { _, _, _, _ in
                    await probe.record("unexpected-second-run")
                    return Self.success
                }
                await probe.setResult(second)
                await probe.record("second-finished")
                _ = await first.value
                return Self.success
            }
        }
        #expect(await probe.waitFor("first-ran"))
        #expect(await Self.waitForQueue(secondFeed))
        secondStop.interrupt()
        #expect(await probe.waitFor("second-finished"))
        #expect(Self.kind(await probe.result()) == "user_denied")
        #expect(!(await probe.contains("unexpected-second-run")))
        let held = await gate.snapshot()
        #expect(held.exclusive == 1)
        #expect(held.inPlace == 0)
        await probe.release()
        #expect(ToolEnvelope.isSuccess(await owner.value))
        await Self.expectEmpty(gate)
    }

    @Test("a terminal owner drains its stopped nested waiter without reacquiring a peer's GPU")
    func terminalOwnerDoesNotReclaimBehindPeer() async {
        let gate = SubagentAdmission(pollNanoseconds: 1_000_000)
        let probe = NestedAdmissionProbe()
        let childStop = InterruptToken()
        let ownerStop = InterruptToken()
        let feed = Self.feed("terminal-waiter")
        let owner = Task {
            let result = await Self.run(gate, id: "spawn", admission: .localInPlace, stop: ownerStop) { _, _, _, _ in
                #expect(await gate.admit(.localInPlace, modelKey: Self.model) == .admitted)
                await probe.record("peer-held")
                let child = Task {
                    await Self.child(gate, stop: childStop, feed: feed) { _, _, _, _ in
                        await probe.record("unexpected-child-run")
                        return Self.success
                    }
                }
                await probe.setChild(child)
                await probe.waitForOwnerReturn()
                await probe.record("owner-body-returned")
                throw CancellationError()
            }
            await probe.record("owner-finished")
            return result
        }
        #expect(await probe.waitFor("peer-held"))
        #expect(await Self.waitForQueue(feed))
        ownerStop.interrupt()
        await probe.allowOwnerReturn()
        #expect(await probe.waitFor("owner-body-returned"))
        childStop.interrupt()
        #expect(await probe.waitFor("owner-finished"))
        let held = await gate.snapshot()
        #expect(held.exclusive == 0)
        #expect(held.inPlace == 1)
        #expect(!(await probe.contains("unexpected-child-run")))
        await gate.release(.localInPlace, modelKey: Self.model)
        #expect(Self.kind(await owner.value) == "user_denied")
        #expect(Self.kind(await probe.childResult() ?? "") == "user_denied")
        await Self.expectEmpty(gate)
    }

    @Test("cancelled inline owner drains without waiting to reclaim", arguments: [false, true])
    func inlineCancellationDoesNotWaitForCleanup(cancelAfterLeafStop: Bool) async {
        let gate = SubagentAdmission(pollNanoseconds: 1_000_000)
        let probe = NestedAdmissionProbe()
        let childStop = InterruptToken()
        let feed = Self.feed("inline-cancel-child")
        let owner = Task {
            let result = await Self.run(gate, id: "spawn", admission: .localInPlace) { _, _, _, _ in
                #expect(await gate.admit(.localInPlace, modelKey: Self.model) == .admitted)
                await probe.record("peer-held")
                let child = await Self.child(gate, stop: childStop, feed: feed) { _, _, _, _ in
                    await probe.record("unexpected-child-run")
                    return Self.success
                }
                await probe.setResult(child)
                try Task.checkCancellation()
                await probe.record("owner-continued")
                return Self.success
            }
            await probe.record("owner-finished")
            return result
        }
        #expect(await probe.waitFor("peer-held"))
        #expect(await Self.waitForQueue(feed))
        if cancelAfterLeafStop {
            childStop.interrupt()
            let deadline = Date().addingTimeInterval(1)
            while case .running = feed.currentStatus(), Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            if case .running = feed.currentStatus() { Issue.record("Leaf stop did not drain") }
            // Stopping only the image must NOT resume a live owner without a
            // slot. The peer is still held at this positive terminal boundary.
            #expect(!(await probe.contains("owner-continued")))
        }
        owner.cancel()
        #expect(await probe.waitFor("owner-finished"))
        #expect(!(await probe.contains("unexpected-child-run")))
        #expect(!(await probe.contains("owner-continued")))
        let held = await gate.snapshot()
        #expect(held.inPlace == 1)
        #expect(held.exclusive == 0)
        await gate.release(.localInPlace, modelKey: Self.model)
        #expect(Self.kind(await owner.value) == "execution_error")
        await Self.expectEmpty(gate)
    }

    @Test("handoff restoration follows nested drain and retains writer through cleanup", arguments: [false, true])
    func handoffCleanupOwnsAdmission(bodyThrows: Bool) async {
        let gate = SubagentAdmission(pollNanoseconds: 1_000_000)
        let probe = NestedAdmissionProbe()
        let childStop = InterruptToken()
        let ownerFeed = Self.feed("handoff-owner")
        let handoff = NestedCleanupHandoff(gate: gate, probe: probe)
        let owner = Task {
            let result = await Self.run(gate, id: "spawn", admission: .localExclusive, feed: ownerFeed, handoff: handoff) { _, _, _, _ in
                let child = Task {
                    await Self.child(gate, stop: childStop) { _, _, _, _ in
                        await probe.record("child-ran")
                        await probe.waitForRelease()
                        await probe.record("child-drained")
                        return Self.success
                    }
                }
                await probe.setChild(child)
                await probe.waitForOwnerReturn()
                if bodyThrows { throw SubagentError.userDenied("Test stopped owner") }
                return Self.success
            }
            await probe.record("owner-finished")
            return result
        }
        let progressed = await probe.waitFor("child-ran")
        #expect(progressed)
        if !progressed { childStop.interrupt() }
        await probe.allowOwnerReturn()
        // Either the corrected host positively reports its drain wait, or the
        // old host enters restore early. Do not release the child tail first.
        let deadline = Date().addingTimeInterval(1)
        while !ownerFeed.currentEvents().contains(where: { $0.title == "waiting for local GPU" }),
            !(await probe.contains("restore-began")), Date() < deadline
        {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(ownerFeed.currentEvents().contains(where: { $0.title == "waiting for local GPU" }))
        #expect(!(await probe.contains("restore-began")))
        await probe.release()
        #expect(await probe.waitFor("restore-began"))
        let counts = await gate.snapshot()
        #expect(counts.exclusive == 1)
        #expect(counts.inPlace == 0)
        let peerProbe = NestedAdmissionProbe()
        let peer = Task {
            await gate.admit(.localExclusive, onWait: { _ in Task { await peerProbe.record("queued") } })
        }
        #expect(await peerProbe.waitFor("queued"))
        #expect(!(await probe.contains("owner-finished")))
        await probe.releaseRestore()
        let result = await owner.value
        #expect(ToolEnvelope.isError(result) == bodyThrows)
        #expect(await peer.value == .admitted)
        await gate.release(.localExclusive)
        _ = await probe.childResult()
        let order = await probe.order()
        let drained = order.firstIndex(of: "child-drained")
        let restored = order.firstIndex(of: "restore-began")
        let finished = order.firstIndex(of: "restore-finished")
        let released = order.firstIndex(of: "owner-finished")
        #expect(drained != nil && restored != nil && finished != nil && released != nil)
        if let drained, let restored, let finished, let released {
            #expect(drained < restored && restored < finished && finished < released)
        }
        await Self.expectEmpty(gate)
    }

    @Test("in-place cleanup upgrades only the owner's slot while a peer drains")
    func heldInPlaceCleanupPromotesToWriter() async {
        let gate = SubagentAdmission(pollNanoseconds: 1_000_000)
        let probe = NestedAdmissionProbe()
        let feed = Self.feed("in-place-cleanup")
        let handoff = NestedCleanupHandoff(gate: gate, probe: probe, expectsChildDrain: false)
        let owner = Task {
            await Self.run(gate, id: "spawn", admission: .localInPlace, feed: feed, handoff: handoff) { _, _, _, _ in
                #expect(await gate.admit(.localInPlace, modelKey: Self.model) == .admitted)
                await probe.record("peer-held")
                return Self.success
            }
        }
        #expect(await probe.waitFor("peer-held"))
        #expect(await Self.waitForQueue(feed))
        let queued = await gate.snapshot()
        #expect(queued.inPlace == 1)
        #expect(queued.exclusive == 0)
        #expect(!(await probe.contains("restore-began")))
        await gate.release(.localInPlace, modelKey: Self.model)
        #expect(await probe.waitFor("restore-began"))
        let restoring = await gate.snapshot()
        #expect(restoring.exclusive == 1)
        #expect(restoring.inPlace == 0)
        let peerProbe = NestedAdmissionProbe()
        let peer = Task {
            await gate.admit(.localExclusive, onWait: { _ in Task { await peerProbe.record("queued") } })
        }
        #expect(await peerProbe.waitFor("queued"))
        await probe.releaseRestore()
        #expect(ToolEnvelope.isSuccess(await owner.value))
        #expect(await peer.value == .admitted)
        await gate.release(.localExclusive)
        await Self.expectEmpty(gate)
    }

    private static let model = "osaurusai/raptor-test"
    private static var success: SubagentResult { SubagentResult(payload: ["summary": "done"]) }
    private typealias Body = @Sendable (SubagentScope, ResolvedModel, SubagentFeed, InterruptToken) async throws -> SubagentResult

    private static func run(_ gate: SubagentAdmission, id: String, admission: SubagentAdmissionClass, stop: InterruptToken = InterruptToken(), feed: SubagentFeed? = nil, handoff: any SubagentHandoff = PassthroughHandoff(), body: @escaping Body) async -> String {
        let scope = SubagentScope(sessionId: "nested-test", toolCallId: UUID().uuidString, agentId: Agent.defaultId)
        let kind = NestedAdmissionKind(id: id, admission: admission, body: body)
        let prepared = PreparedSubagentRun(kind: kind, tool: id, scope: scope, resolved: ResolvedModel(name: model, id: model, isLocal: true), handoff: handoff)
        return await SubagentSession.runPrepared(prepared, presentation: SubagentRunPresentation(feed: feed ?? Self.feed(scope.toolCallId), interrupt: stop, registerWithUI: false), captureProcessCacheSnapshot: false, admissionController: gate)
    }

    private static func child(_ gate: SubagentAdmission, stop: InterruptToken, feed: SubagentFeed? = nil, body: @escaping Body) async -> String {
        // AgentDelegationDispatcher uses this boundary before dispatchChat.
        await SubagentSession.$activeKindId.withValue(nil) {
            await run(gate, id: "image", admission: .localExclusive, stop: stop, feed: feed, body: body)
        }
    }

    private static func feed(_ id: String) -> SubagentFeed { SubagentFeed(toolCallId: id, kindId: "image", title: "nested image") }
    private static func waitForQueue(_ feed: SubagentFeed) async -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if feed.currentEvents().contains(where: { $0.title == "waiting for local GPU" }) { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }
    private static func kind(_ envelope: String) -> String? { (try? JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any])?["kind"] as? String }
    private static func expectEmpty(_ gate: SubagentAdmission) async {
        let value = await gate.snapshot()
        #expect(value.inPlace == 0)
        #expect(value.exclusive == 0)
        #expect(value.remote == 0)
    }
}

private struct NestedAdmissionKind: SubagentKind {
    let capability: SubagentCapability
    let admission: SubagentAdmissionClass
    let body: @Sendable (SubagentScope, ResolvedModel, SubagentFeed, InterruptToken) async throws -> SubagentResult
    init(id: String, admission: SubagentAdmissionClass, body: @escaping @Sendable (SubagentScope, ResolvedModel, SubagentFeed, InterruptToken) async throws -> SubagentResult) {
        capability = SubagentCapability(id: id, toolNames: [id], gate: .sandboxExec)
        self.admission = admission
        self.body = body
    }
    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel { ResolvedModel(name: "unused", isLocal: true) }
    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision { .allow }
    func admissionClass(_ resolved: ResolvedModel) -> SubagentAdmissionClass { admission }
    func run(_ scope: SubagentScope, _ resolved: ResolvedModel, feed: SubagentFeed, interrupt: InterruptToken) async throws -> SubagentResult { try await body(scope, resolved, feed, interrupt) }
}

private actor NestedAdmissionProbe {
    private var recorded = Set<String>()
    private var ordered: [String] = []
    private var restoreReleased = false
    private var restoreWaiters: [CheckedContinuation<Void, Never>] = []
    private var envelope = ""
    private var active = 0
    private var maximumActive = 0
    private var totalEntries = 0
    private var released = false
    private var ownerReturn = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var ownerWaiters: [CheckedContinuation<Void, Never>] = []
    private var child: Task<String, Never>?
    func record(_ event: String) { recorded.insert(event); ordered.append(event) }
    func order() -> [String] { ordered }
    func waitForRestoreRelease() async { if !restoreReleased { await withCheckedContinuation { restoreWaiters.append($0) } } }
    func releaseRestore() { restoreReleased = true; let waiters = restoreWaiters; restoreWaiters.removeAll(); waiters.forEach { $0.resume() } }
    func contains(_ event: String) -> Bool { recorded.contains(event) }
    func setResult(_ value: String) { envelope = value }
    func result() -> String { envelope }
    func enter(_ event: String) { record(event); active += 1; totalEntries += 1; maximumActive = max(maximumActive, active) }
    func leave() { active -= 1 }
    func maximum() -> Int { maximumActive }
    func entries() -> Int { totalEntries }
    func setChild(_ value: Task<String, Never>) { child = value }
    func childResult() async -> String? { await child?.value }
    func waitFor(_ event: String) async -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while !recorded.contains(event), Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
        return recorded.contains(event)
    }
    func waitForAnyEntry() async -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while totalEntries == 0, Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
        return totalEntries > 0
    }
    func waitForRelease() async { if !released { await withCheckedContinuation { releaseWaiters.append($0) } } }
    func release() { released = true; let waiters = releaseWaiters; releaseWaiters.removeAll(); waiters.forEach { $0.resume() } }
    func waitForOwnerReturn() async { if !ownerReturn { await withCheckedContinuation { ownerWaiters.append($0) } } }
    func allowOwnerReturn() { ownerReturn = true; let waiters = ownerWaiters; ownerWaiters.removeAll(); waiters.forEach { $0.resume() } }
}

private struct NestedCleanupHandoff: SubagentHandoff {
    let gate: SubagentAdmission
    let probe: NestedAdmissionProbe
    var expectsChildDrain = true
    // Additional member also compiles on the pre-contract baseline.
    var requiresAdmissionForCleanup: Bool { true }
    func around(scope: SubagentScope, resolved: ResolvedModel, feed: SubagentFeed, run body: () async throws -> SubagentResult) async throws -> SubagentResult {
        do {
            let result = try await body()
            await restore()
            return result
        } catch {
            await restore()
            throw error
        }
    }
    private func restore() async {
        await probe.record("restore-began")
        if expectsChildDrain { #expect(await probe.contains("child-drained")) }
        let counts = await gate.snapshot()
        #expect(counts.exclusive == 1)
        #expect(counts.inPlace == 0)
        await probe.waitForRestoreRelease()
        await probe.record("restore-finished")
    }
}
