//
//  SubagentAdmissionTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Unit coverage of the process-wide admission gate that serializes local
//  subagent runs (the parallel-batch handoff race fix) while letting remote
//  runs fan out. Uses a private instance with a fast poll so the tests are
//  deterministic and quick; one session-level test proves two exclusive runs
//  never overlap end to end through `SubagentSession.run`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("SubagentAdmission")
struct SubagentAdmissionTests {

    private func makeGate() -> SubagentAdmission {
        SubagentAdmission(pollNanoseconds: 2_000_000)  // 2 ms poll for tests
    }

    @Test("admission identity preserves full ids and groups aliases by stable id")
    func canonicalModelIdentity() {
        let full = ResolvedModel(
            name: "OsaurusAI/Ornith-1.0-9B-JANG_4M",
            id: "OsaurusAI/Ornith-1.0-9B-JANG_4M",
            isLocal: true
        )
        let short = ResolvedModel(
            name: "ornith-1.0-9b-jang_4m",
            id: "OsaurusAI/Ornith-1.0-9B-JANG_4M",
            isLocal: true
        )
        let sameBasenameOtherOrganization = ResolvedModel(
            name: "ornith-1.0-9b-jang_4m",
            id: "OtherOrg/Ornith-1.0-9B-JANG_4M",
            isLocal: true
        )
        let idlessFallback = ResolvedModel(
            name: "ThirdOrg/Ornith-1.0-9B-JANG_4M",
            isLocal: true
        )
        let remote = ResolvedModel(name: "remote/model", isLocal: false)

        let canonical = "osaurusai/ornith-1.0-9b-jang_4m"
        #expect(SubagentSession.canonicalAdmissionModelKey(full) == canonical)
        #expect(SubagentSession.canonicalAdmissionModelKey(short) == canonical)
        #expect(
            SubagentSession.canonicalAdmissionModelKey(sameBasenameOtherOrganization)
                == "otherorg/ornith-1.0-9b-jang_4m"
        )
        #expect(
            SubagentSession.canonicalAdmissionModelKey(idlessFallback)
                == "thirdorg/ornith-1.0-9b-jang_4m"
        )
        #expect(SubagentSession.canonicalAdmissionModelKey(remote) == nil)
    }

    @Test("remote admits concurrently, even while an exclusive run is active")
    func remoteAlwaysAdmits() async {
        let gate = makeGate()
        #expect(await gate.admit(.localExclusive) == .admitted)
        #expect(await gate.admit(.remote) == .admitted)
        #expect(await gate.admit(.remote) == .admitted)
        let counts = await gate.snapshot()
        #expect(counts.exclusive == 1)
        #expect(counts.remote == 2)
        await gate.release(.remote)
        await gate.release(.remote)
        await gate.release(.localExclusive)
    }

    @Test("in-place runs coexist with each other")
    func inPlaceCoexists() async {
        let gate = makeGate()
        #expect(await gate.admit(.localInPlace) == .admitted)
        #expect(await gate.admit(.localInPlace) == .admitted)
        let counts = await gate.snapshot()
        #expect(counts.inPlace == 2)
        await gate.release(.localInPlace)
        await gate.release(.localInPlace)
    }

    @Test("same-model in-place runs overlap but a different local model waits")
    func inPlaceAdmissionIsModelKeyed() async {
        let gate = makeGate()
        #expect(
            await gate.admit(.localInPlace, modelKey: "model-a")
                == .admitted
        )
        #expect(
            await gate.admit(.localInPlace, modelKey: "MODEL-A")
                == .admitted
        )

        let different = Task {
            await gate.admit(
                .localInPlace,
                modelKey: "model-b",
                timeoutSeconds: 5
            )
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let held = await gate.snapshot()
        #expect(held.inPlace == 2)

        await gate.release(.localInPlace, modelKey: "model-a")
        await gate.release(.localInPlace, modelKey: "model-a")
        #expect(await different.value == .admitted)
        await gate.release(.localInPlace, modelKey: "model-b")
    }

    @Test("a second exclusive run queues until the first releases")
    func exclusiveSerializes() async {
        let gate = makeGate()
        #expect(await gate.admit(.localExclusive) == .admitted)

        let waited = WaitFlag()
        let second = Task {
            await gate.admit(
                .localExclusive,
                timeoutSeconds: 5,
                onWait: { _ in waited.set() }
            )
        }
        // Give the second admit time to hit the wait loop, then release.
        try? await Task.sleep(nanoseconds: 20_000_000)
        await gate.release(.localExclusive)

        let outcome = await second.value
        #expect(outcome == .admitted)
        #expect(waited.isSet)
        await gate.release(.localExclusive)
        let counts = await gate.snapshot()
        #expect(counts.exclusive == 0)
    }

    @Test("an exclusive run waits for in-place runs to drain")
    func exclusiveWaitsForInPlace() async {
        let gate = makeGate()
        #expect(await gate.admit(.localInPlace) == .admitted)
        let second = Task {
            await gate.admit(.localExclusive, timeoutSeconds: 5)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await gate.release(.localInPlace)
        #expect(await second.value == .admitted)
        await gate.release(.localExclusive)
    }

    @Test("an in-place run is blocked only by an exclusive run")
    func inPlaceBlockedByExclusive() async {
        let gate = makeGate()
        #expect(await gate.admit(.localExclusive) == .admitted)
        let second = Task {
            await gate.admit(.localInPlace, timeoutSeconds: 5)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await gate.release(.localExclusive)
        #expect(await second.value == .admitted)
        await gate.release(.localInPlace)
    }

    @Test("a blocked run times out with the active-run description")
    func timeout() async {
        let gate = makeGate()
        #expect(await gate.admit(.localExclusive) == .admitted)
        let outcome = await gate.admit(.localExclusive, timeoutSeconds: 0.05)
        guard case .timedOut(let active) = outcome else {
            Issue.record("expected .timedOut, got \(outcome)")
            return
        }
        #expect(active.contains("local handoff"))
        await gate.release(.localExclusive)
    }

    @Test("cancelling a waiting task returns .cancelled without taking a slot")
    func cancelledWaiter() async {
        let gate = makeGate()
        #expect(await gate.admit(.localExclusive) == .admitted)
        let waiter = Task {
            await gate.admit(.localExclusive, timeoutSeconds: 30)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        waiter.cancel()
        #expect(await waiter.value == .cancelled)
        let counts = await gate.snapshot()
        #expect(counts.exclusive == 1)
        await gate.release(.localExclusive)
    }

    @Test("release clamps at zero (defensive against double-release)")
    func releaseClamps() async {
        let gate = makeGate()
        await gate.release(.localExclusive)
        let counts = await gate.snapshot()
        #expect(counts.exclusive == 0)
        #expect(await gate.admit(.localExclusive) == .admitted)
        await gate.release(.localExclusive)
    }

    @Test("slot reservations compose atomically for one-plus-one and two-plus-two")
    func slotReservationsComposeAtomically() async {
        let onePlusOne = makeGate()
        #expect(
            await onePlusOne.reserveLocalInPlace(
                modelKey: "model-a",
                requestedSlots: 1,
                slotCapacity: 2
            ) == .admitted(slots: 1)
        )
        #expect(
            await onePlusOne.reserveLocalInPlace(
                modelKey: "MODEL-A",
                requestedSlots: 1,
                slotCapacity: 2
            ) == .admitted(slots: 1)
        )
        #expect(await onePlusOne.snapshot().inPlace == 2)
        await onePlusOne.releaseLocalInPlace(modelKey: "model-a", slots: 1)
        await onePlusOne.releaseLocalInPlace(modelKey: "model-a", slots: 1)

        let twoPlusTwo = makeGate()
        #expect(
            await twoPlusTwo.reserveLocalInPlace(
                modelKey: "model-a",
                requestedSlots: 2,
                slotCapacity: 4
            ) == .admitted(slots: 2)
        )
        #expect(
            await twoPlusTwo.reserveLocalInPlace(
                modelKey: "model-a",
                requestedSlots: 2,
                slotCapacity: 4
            ) == .admitted(slots: 2)
        )
        #expect(await twoPlusTwo.snapshot().inPlace == 4)
        await twoPlusTwo.releaseLocalInPlace(modelKey: "model-a", slots: 4)
        #expect(await twoPlusTwo.snapshot().inPlace == 0)
    }

    @Test("post-admission capacity shrink resizes aggregate reservations atomically")
    func slotReservationResizeHonorsFreshCapacity() async {
        let gate = makeGate()
        #expect(
            await gate.reserveLocalInPlace(
                modelKey: "model-a",
                requestedSlots: 2,
                slotCapacity: 4
            ) == .admitted(slots: 2)
        )
        #expect(
            await gate.reserveLocalInPlace(
                modelKey: "model-a",
                requestedSlots: 2,
                slotCapacity: 4
            ) == .admitted(slots: 2)
        )
        #expect(await gate.snapshot().inPlace == 4)

        let first = await gate.resizeLocalInPlace(
            modelKey: "model-a",
            heldSlots: 2,
            requestedSlots: 2,
            slotCapacity: 3
        )
        #expect(first == 1)
        #expect(await gate.snapshot().inPlace == 3)

        let second = await gate.resizeLocalInPlace(
            modelKey: "model-a",
            heldSlots: 2,
            requestedSlots: 2,
            slotCapacity: 2
        )
        #expect(second == 1)
        #expect(await gate.snapshot().inPlace == 2)

        await gate.releaseLocalInPlace(modelKey: "model-a", slots: first)
        await gate.releaseLocalInPlace(modelKey: "model-a", slots: second)
        #expect(await gate.snapshot().inPlace == 0)
    }

    @Test("zero-width resize removes only the caller reservation")
    func slotReservationResizeCanReleaseCaller() async {
        let gate = makeGate()
        #expect(
            await gate.reserveLocalInPlace(
                modelKey: "model-a",
                requestedSlots: 2,
                slotCapacity: 4
            ) == .admitted(slots: 2)
        )
        #expect(
            await gate.reserveLocalInPlace(
                modelKey: "model-a",
                requestedSlots: 2,
                slotCapacity: 4
            ) == .admitted(slots: 2)
        )

        let first = await gate.resizeLocalInPlace(
            modelKey: "model-a",
            heldSlots: 2,
            requestedSlots: 2,
            slotCapacity: 2
        )
        #expect(first == 0)
        #expect(await gate.snapshot().inPlace == 2)

        await gate.releaseLocalInPlace(modelKey: "model-a", slots: 2)
        #expect(await gate.snapshot().inPlace == 0)
    }

    @Test("one direct-style slot leaves only the process-wide batch remainder")
    func directStyleReservationLeavesBatchRemainder() async {
        let gate = makeGate()
        #expect(
            await gate.reserveLocalInPlace(
                modelKey: "model-a",
                requestedSlots: 1,
                slotCapacity: 3
            ) == .admitted(slots: 1)
        )
        #expect(
            await gate.reserveLocalInPlace(
                modelKey: "model-a",
                requestedSlots: 3,
                slotCapacity: 3
            ) == .admitted(slots: 2)
        )
        #expect(await gate.snapshot().inPlace == 3)
        await gate.releaseLocalInPlace(modelKey: "model-a", slots: 1)
        await gate.releaseLocalInPlace(modelKey: "model-a", slots: 2)
        #expect(await gate.snapshot().inPlace == 0)
    }

    @Test("partial grants never oversubscribe and a full capacity waiter stays queued")
    func slotCapacityNeverOversubscribes() async {
        let gate = makeGate()
        #expect(
            await gate.reserveLocalInPlace(
                modelKey: "model-a",
                requestedSlots: 2,
                slotCapacity: 3
            ) == .admitted(slots: 2)
        )
        #expect(
            await gate.reserveLocalInPlace(
                modelKey: "model-a",
                requestedSlots: 2,
                slotCapacity: 3
            ) == .admitted(slots: 1)
        )

        let waited = WaitFlag()
        let blocked = Task {
            await gate.reserveLocalInPlace(
                modelKey: "model-a",
                requestedSlots: 1,
                slotCapacity: 3,
                timeoutSeconds: 30,
                onWait: { _ in waited.set() }
            )
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(waited.isSet)
        #expect(await gate.snapshot().inPlace == 3)

        blocked.cancel()
        #expect(await blocked.value == .cancelled)
        #expect(await gate.snapshot().inPlace == 3)
        await gate.releaseLocalInPlace(modelKey: "model-a", slots: 3)
        #expect(await gate.snapshot().inPlace == 0)
    }

    @Test("a different-model slot reservation waits until the resident model drains")
    func differentModelSlotReservationWaits() async {
        let gate = makeGate()
        #expect(
            await gate.reserveLocalInPlace(
                modelKey: "model-a",
                requestedSlots: 1,
                slotCapacity: 2
            ) == .admitted(slots: 1)
        )
        let waited = WaitFlag()
        let other = Task {
            await gate.reserveLocalInPlace(
                modelKey: "model-b",
                requestedSlots: 1,
                slotCapacity: 2,
                timeoutSeconds: 5,
                onWait: { _ in waited.set() }
            )
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(waited.isSet)
        #expect(await gate.snapshot().inPlace == 1)

        await gate.releaseLocalInPlace(modelKey: "model-a", slots: 1)
        #expect(await other.value == .admitted(slots: 1))
        await gate.releaseLocalInPlace(modelKey: "model-b", slots: 1)
        #expect(await gate.snapshot().inPlace == 0)
    }

    @Test("queued exclusive work wins before a newer same-model slot reservation")
    func exclusiveWriterPreferenceAppliesToSlots() async {
        let gate = makeGate()
        #expect(
            await gate.reserveLocalInPlace(
                modelKey: "model-a",
                requestedSlots: 1,
                slotCapacity: 2
            ) == .admitted(slots: 1)
        )

        let exclusiveWaited = WaitFlag()
        let exclusive = Task {
            await gate.admit(
                .localExclusive,
                timeoutSeconds: 5,
                onWait: { _ in exclusiveWaited.set() }
            )
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(exclusiveWaited.isSet)
        #expect(
            await gate.resizeLocalInPlace(
                modelKey: "model-a",
                heldSlots: 1,
                requestedSlots: 2,
                slotCapacity: 2
            ) == 1
        )
        #expect(await gate.snapshot().inPlace == 1)

        let newerWaited = WaitFlag()
        let newer = Task {
            await gate.reserveLocalInPlace(
                modelKey: "model-a",
                requestedSlots: 1,
                slotCapacity: 2,
                timeoutSeconds: 5,
                onWait: { _ in newerWaited.set() }
            )
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(newerWaited.isSet)

        await gate.releaseLocalInPlace(modelKey: "model-a", slots: 1)
        #expect(await exclusive.value == .admitted)
        let whileExclusive = await gate.snapshot()
        #expect(whileExclusive.exclusive == 1)
        #expect(whileExclusive.inPlace == 0)

        await gate.release(.localExclusive)
        #expect(await newer.value == .admitted(slots: 1))
        await gate.releaseLocalInPlace(modelKey: "model-a", slots: 1)
        let final = await gate.snapshot()
        #expect(final.exclusive == 0)
        #expect(final.inPlace == 0)
    }

    @Test("cancelling a slot waiter leaves no hidden reservation")
    func cancelledSlotWaiterDoesNotLeak() async {
        let gate = makeGate()
        #expect(
            await gate.reserveLocalInPlace(
                modelKey: "model-a",
                requestedSlots: 1,
                slotCapacity: 1
            ) == .admitted(slots: 1)
        )
        let waited = WaitFlag()
        let waiter = Task {
            await gate.reserveLocalInPlace(
                modelKey: "model-a",
                requestedSlots: 1,
                slotCapacity: 1,
                timeoutSeconds: 30,
                onWait: { _ in waited.set() }
            )
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(waited.isSet)
        waiter.cancel()
        #expect(await waiter.value == .cancelled)
        #expect(await gate.snapshot().inPlace == 1)

        await gate.releaseLocalInPlace(modelKey: "model-a", slots: 1)
        #expect(await gate.snapshot().inPlace == 0)
    }

    // MARK: - Plan → class mapping

    @Test("residency plan maps onto the admission class")
    func planMapping() {
        let unloadPlan = ResidencyPlan(shouldUnload: true)
        #expect(
            SubagentResidency.admissionClass(isLocal: true, plan: unloadPlan) == .localExclusive
        )
        #expect(SubagentResidency.admissionClass(isLocal: true, plan: .none) == .localInPlace)
        #expect(SubagentResidency.admissionClass(isLocal: false, plan: .none) == .remote)
    }
}

// MARK: - Session-level serialization

private actor AdmissionAuthorityProbe {
    private var validations = 0
    private var revoked = false
    private var runs = 0

    func validate() throws {
        validations += 1
        if revoked {
            throw SubagentError.denied(
                "authority revoked while waiting for admission"
            )
        }
    }

    func revoke() {
        revoked = true
    }

    func recordRun() {
        runs += 1
    }

    func snapshot() -> (validations: Int, runs: Int) {
        (validations, runs)
    }
}

private final class AdmissionAuthorityKind: SubagentKind, @unchecked Sendable {
    let capability = SubagentCapability(
        id: "admission-authority-test",
        toolNames: ["admission-authority-test"],
        gate: .delegation
    )
    let probe: AdmissionAuthorityProbe

    init(probe: AdmissionAuthorityProbe) {
        self.probe = probe
    }

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        ResolvedModel(
            name: "admission-authority-local",
            id: "admission-authority-local",
            isLocal: true
        )
    }

    func permission(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel
    ) async -> SubagentDecision {
        .allow
    }

    func validateExecutionAuthority(
        _ scope: SubagentScope,
        resolved: ResolvedModel
    ) async throws {
        try await probe.validate()
    }

    func admissionClass(
        _ resolved: ResolvedModel
    ) -> SubagentAdmissionClass {
        .localExclusive
    }

    func run(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel,
        feed: SubagentFeed,
        interrupt: InterruptToken
    ) async throws -> SubagentResult {
        await probe.recordRun()
        return SubagentResult(payload: ["summary": "unexpected run"])
    }
}

private final class DirectResidencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var plan: ResidencyPlan = .none
    private var refreshes = 0
    private var refreshStarted = false
    private var runs = 0
    private var handoffPlans: [ResidencyPlan] = []

    func setPlan(_ value: ResidencyPlan) {
        lock.lock()
        plan = value
        lock.unlock()
    }

    func currentPlan() -> ResidencyPlan {
        lock.lock()
        defer { lock.unlock() }
        return plan
    }

    func refresh() -> ResidencyPlan {
        lock.lock()
        defer { lock.unlock() }
        refreshes += 1
        return plan
    }

    func markRefreshStarted() {
        lock.lock()
        refreshStarted = true
        lock.unlock()
    }

    func recordHandoff(_ value: ResidencyPlan) {
        lock.lock()
        handoffPlans.append(value)
        lock.unlock()
    }

    func recordRun() {
        lock.lock()
        runs += 1
        lock.unlock()
    }

    func snapshot() -> (
        refreshes: Int,
        refreshStarted: Bool,
        runs: Int,
        handoffPlans: [ResidencyPlan]
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (refreshes, refreshStarted, runs, handoffPlans)
    }
}

private struct DirectResidencyProbeHandoff: SubagentHandoff {
    let probe: DirectResidencyProbe
    let plan: ResidencyPlan

    func around(
        scope: SubagentScope,
        resolved: ResolvedModel,
        feed: SubagentFeed,
        run body: () async throws -> SubagentResult
    ) async throws -> SubagentResult {
        probe.recordHandoff(plan)
        return try await body()
    }
}

private final class DirectResidencyKind:
    SubagentKind, SubagentPostAdmissionResidencyPlanning, @unchecked Sendable
{
    let capability = SubagentCapability(
        id: "direct-residency-test",
        toolNames: ["direct-residency-test"],
        gate: .delegation
    )
    let probe: DirectResidencyProbe
    let refreshDelayNanoseconds: UInt64

    init(
        probe: DirectResidencyProbe,
        refreshDelayNanoseconds: UInt64 = 0
    ) {
        self.probe = probe
        self.refreshDelayNanoseconds = refreshDelayNanoseconds
    }

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        ResolvedModel(
            name: "direct-residency-local",
            id: "direct-residency-local",
            isLocal: true
        )
    }

    func permission(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel
    ) async -> SubagentDecision {
        .allow
    }

    func admissionClass(
        _ resolved: ResolvedModel
    ) -> SubagentAdmissionClass {
        SubagentResidency.admissionClass(
            isLocal: resolved.isLocal,
            plan: probe.currentPlan()
        )
    }

    func refreshedResidencyPlanAfterAdmission(
        for resolved: ResolvedModel
    ) async throws -> ResidencyPlan {
        probe.markRefreshStarted()
        if refreshDelayNanoseconds > 0 {
            try? await Task.sleep(
                nanoseconds: refreshDelayNanoseconds
            )
        }
        return probe.refresh()
    }

    func makeHandoff() -> SubagentHandoff {
        DirectResidencyProbeHandoff(
            probe: probe,
            plan: probe.currentPlan()
        )
    }

    func run(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel,
        feed: SubagentFeed,
        interrupt: InterruptToken
    ) async throws -> SubagentResult {
        probe.recordRun()
        return SubagentResult(
            payload: ["summary": "ran with refreshed residency"]
        )
    }
}

@Suite("SubagentSession admission")
struct SubagentSessionAdmissionTests {
    @Test("queued direct run drops stale handoff after exclusive plan downgrades")
    func directRunRefreshDropsStaleExclusiveHandoff() async {
        let admission = SubagentAdmission(pollNanoseconds: 1_000_000)
        #expect(
            await admission.admit(
                .localExclusive,
                modelKey: "exclusive-blocker"
            ) == .admitted
        )

        let probe = DirectResidencyProbe()
        probe.setPlan(
            ResidencyPlan(
                shouldUnload: true,
                requiredBytes: 4_096,
                ramSafetyEnabled: true,
                maxElapsedSeconds: 30
            )
        )
        let scope = SubagentScope(
            sessionId: "direct-residency-downgrade",
            toolCallId:
                "direct-residency-downgrade-\(UUID().uuidString)",
            agentId: Agent.defaultId
        )
        let preparation = await SubagentSession.prepare(
            DirectResidencyKind(probe: probe),
            tool: "direct-residency-test",
            scope: scope
        )
        guard case .ready(let prepared) = preparation else {
            Issue.record("Expected direct residency test kind to prepare")
            await admission.release(
                .localExclusive,
                modelKey: "exclusive-blocker"
            )
            return
        }

        let task = Task {
            await SubagentSession.runPrepared(
                prepared,
                admissionController: admission,
                postAdmissionLocalCapacityOverride: { _, _ in 1 }
            )
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(probe.snapshot().refreshes == 0)

        probe.setPlan(.none)
        await admission.release(
            .localExclusive,
            modelKey: "exclusive-blocker"
        )

        let envelope = await task.value
        let snapshot = probe.snapshot()
        #expect(ToolEnvelope.isSuccess(envelope))
        #expect(snapshot.refreshes == 1)
        #expect(snapshot.runs == 1)
        #expect(snapshot.handoffPlans.count == 1)
        #expect(snapshot.handoffPlans.first?.shouldUnload == false)
        let counters = await admission.snapshot()
        #expect(counters.exclusive == 0)
        #expect(counters.inPlace == 0)
    }

    @Test("downgraded direct run still rejects unsafe single-child RAM plan")
    func directRunDowngradeRechecksSingleChildRAM() async {
        let admission = SubagentAdmission(pollNanoseconds: 1_000_000)
        #expect(
            await admission.admit(
                .localExclusive,
                modelKey: "exclusive-ram-blocker"
            ) == .admitted
        )

        let probe = DirectResidencyProbe()
        probe.setPlan(ResidencyPlan(shouldUnload: true))
        let scope = SubagentScope(
            sessionId: "direct-residency-ram-recheck",
            toolCallId:
                "direct-residency-ram-recheck-\(UUID().uuidString)",
            agentId: Agent.defaultId
        )
        let preparation = await SubagentSession.prepare(
            DirectResidencyKind(probe: probe),
            tool: "direct-residency-test",
            scope: scope
        )
        guard case .ready(let prepared) = preparation else {
            Issue.record("Expected direct residency test kind to prepare")
            await admission.release(
                .localExclusive,
                modelKey: "exclusive-ram-blocker"
            )
            return
        }

        let task = Task {
            await SubagentSession.runPrepared(
                prepared,
                admissionController: admission,
                postAdmissionLocalCapacityOverride: { _, _ in 0 }
            )
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(probe.snapshot().refreshes == 0)
        probe.setPlan(.none)
        await admission.release(
            .localExclusive,
            modelKey: "exclusive-ram-blocker"
        )

        let envelope = await task.value
        let snapshot = probe.snapshot()
        #expect(ToolEnvelope.isError(envelope))
        #expect(
            ToolEnvelope.failureMessage(envelope)
                .localizedCaseInsensitiveContains("RAM-safety")
        )
        #expect(snapshot.refreshes == 1)
        #expect(snapshot.runs == 0)
        #expect(snapshot.handoffPlans.isEmpty)
        let counters = await admission.snapshot()
        #expect(counters.exclusive == 0)
        #expect(counters.inPlace == 0)
    }

    @Test("interrupt during direct residency refresh stops before handoff and run")
    func interruptDuringDirectResidencyRefreshStopsExecution() async {
        let admission = SubagentAdmission(pollNanoseconds: 1_000_000)
        let probe = DirectResidencyProbe()
        let scope = SubagentScope(
            sessionId: "direct-residency-refresh-stop",
            toolCallId:
                "direct-residency-refresh-stop-\(UUID().uuidString)",
            agentId: Agent.defaultId
        )
        let preparation = await SubagentSession.prepare(
            DirectResidencyKind(
                probe: probe,
                refreshDelayNanoseconds: 100_000_000
            ),
            tool: "direct-residency-test",
            scope: scope
        )
        guard case .ready(let prepared) = preparation else {
            Issue.record("Expected direct residency test kind to prepare")
            return
        }

        let interrupt = InterruptToken()
        let task = Task {
            await SubagentSession.runPrepared(
                prepared,
                presentation: SubagentRunPresentation(
                    feed: SubagentFeed(
                        toolCallId: scope.toolCallId,
                        kindId: "direct-residency-test",
                        title: "direct residency"
                    ),
                    interrupt: interrupt,
                    registerWithUI: false
                ),
                admissionController: admission
            )
        }
        let deadline = Date().addingTimeInterval(2)
        while !probe.snapshot().refreshStarted, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(probe.snapshot().refreshStarted)
        interrupt.interrupt()

        let envelope = await task.value
        let snapshot = probe.snapshot()
        #expect(ToolEnvelope.isError(envelope))
        #expect(
            ToolEnvelope.failureMessage(envelope)
                .localizedCaseInsensitiveContains("stopped")
        )
        #expect(snapshot.runs == 0)
        #expect(snapshot.handoffPlans.isEmpty)
        let counters = await admission.snapshot()
        #expect(counters.exclusive == 0)
        #expect(counters.inPlace == 0)
    }

    @Test("queued direct run refreshes residency and upgrades to exclusive")
    func directRunRefreshesResidencyAfterAdmissionWait() async {
        let admission = SubagentAdmission(pollNanoseconds: 1_000_000)
        #expect(
            await admission.admit(
                .localInPlace,
                modelKey: "different-resident-model"
            ) == .admitted
        )

        let probe = DirectResidencyProbe()
        let scope = SubagentScope(
            sessionId: "direct-residency-replan",
            toolCallId: "direct-residency-replan-\(UUID().uuidString)",
            agentId: Agent.defaultId
        )
        let preparation = await SubagentSession.prepare(
            DirectResidencyKind(probe: probe),
            tool: "direct-residency-test",
            scope: scope
        )
        guard case .ready(let prepared) = preparation else {
            Issue.record("Expected direct residency test kind to prepare")
            await admission.release(
                .localInPlace,
                modelKey: "different-resident-model"
            )
            return
        }

        let task = Task {
            await SubagentSession.runPrepared(
                prepared,
                admissionController: admission
            )
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(probe.snapshot().refreshes == 0)

        probe.setPlan(
            ResidencyPlan(
                shouldUnload: true,
                requiredBytes: 9_876,
                ramSafetyEnabled: true,
                maxElapsedSeconds: 47
            )
        )
        await admission.release(
            .localInPlace,
            modelKey: "different-resident-model"
        )

        let envelope = await task.value
        let snapshot = probe.snapshot()
        #expect(ToolEnvelope.isSuccess(envelope))
        #expect(snapshot.refreshes == 2)
        #expect(snapshot.runs == 1)
        #expect(snapshot.handoffPlans.count == 1)
        #expect(snapshot.handoffPlans.first?.shouldUnload == true)
        #expect(snapshot.handoffPlans.first?.requiredBytes == 9_876)
        #expect(snapshot.handoffPlans.first?.ramSafetyEnabled == true)
        let counters = await admission.snapshot()
        #expect(counters.exclusive == 0)
        #expect(counters.inPlace == 0)
    }

    @Test("authority revoked while queued is rejected after admission without running")
    func postAdmissionAuthorityRevalidation() async {
        let admission = SubagentAdmission(pollNanoseconds: 1_000_000)
        #expect(
            await admission.admit(
                .localExclusive,
                modelKey: "authority-blocker"
            ) == .admitted
        )

        let probe = AdmissionAuthorityProbe()
        let scope = SubagentScope(
            sessionId: "post-admission-authority",
            toolCallId: "post-admission-authority-\(UUID().uuidString)",
            agentId: Agent.defaultId
        )
        let preparation = await SubagentSession.prepare(
            AdmissionAuthorityKind(probe: probe),
            tool: "admission-authority-test",
            scope: scope
        )
        guard case .ready(let prepared) = preparation else {
            Issue.record("Expected authority test kind to prepare")
            await admission.release(
                .localExclusive,
                modelKey: "authority-blocker"
            )
            return
        }

        let task = Task {
            await SubagentSession.runPrepared(
                prepared,
                admissionController: admission
            )
        }
        let deadline = Date().addingTimeInterval(2)
        while (await probe.snapshot()).validations < 1,
            Date() < deadline
        {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        await probe.revoke()
        await admission.release(
            .localExclusive,
            modelKey: "authority-blocker"
        )

        let result = await task.value
        let snapshot = await probe.snapshot()
        #expect(ToolEnvelope.isError(result))
        #expect(
            ToolEnvelope.failureMessage(result).contains(
                "revoked while waiting for admission"
            )
        )
        #expect(snapshot.validations == 2)
        #expect(snapshot.runs == 0)
    }

    @Test("interrupt while queued maps to honest user stop and does not take a slot")
    func interruptWhileQueuedMapsToUserDenied() async {
        let admission = SubagentAdmission.shared
        #expect(
            await admission.admit(.localExclusive, modelKey: "queue-blocker")
                == .admitted
        )

        let transcript = await SubagentJobEvaluator.runScripted(
            ScriptedSubagentSpec(
                kindId: "queued-scripted",
                needsHandoff: true,
                runDelayMs: 5_000
            ),
            interruptAfterMs: 100
        )

        await admission.release(.localExclusive, modelKey: "queue-blocker")

        #expect(!transcript.succeeded)
        #expect(transcript.envelopeKind == "user_denied")
        #expect(transcript.summary.localizedCaseInsensitiveContains("stopped"))
        #expect(transcript.feedPhases.contains("waiting for local GPU"))
    }

    /// A kind that reports `.localExclusive` and records run overlap.
    private final class ExclusiveKind: SubagentKind, @unchecked Sendable {
        let capability = SubagentCapability(
            id: "exclusive-scripted",
            toolNames: ["exclusive-scripted"],
            gate: .sandboxExec
        )
        let tracker: OverlapTracker

        init(tracker: OverlapTracker) { self.tracker = tracker }

        func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
            ResolvedModel(name: "scripted-local", id: "scripted-local", isLocal: true)
        }
        func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
            .allow
        }
        func admissionClass(_ resolved: ResolvedModel) -> SubagentAdmissionClass {
            .localExclusive
        }
        func run(
            _ scope: SubagentScope,
            _ resolved: ResolvedModel,
            feed: SubagentFeed,
            interrupt: InterruptToken
        ) async throws -> SubagentResult {
            tracker.enter()
            try? await Task.sleep(nanoseconds: 50_000_000)
            tracker.exit()
            return SubagentResult(payload: ["kind": "scripted", "summary": "done"])
        }
    }

    @Test("two concurrent exclusive runs never overlap through the host")
    func exclusiveRunsSerializeThroughSession() async {
        let tracker = OverlapTracker()
        let a = ExclusiveKind(tracker: tracker)
        let b = ExclusiveKind(tracker: tracker)
        async let first = SubagentSession.run(a, tool: "exclusive-scripted")
        async let second = SubagentSession.run(b, tool: "exclusive-scripted")
        let envelopes = await [first, second]
        #expect(envelopes.allSatisfy { ToolEnvelope.isSuccess($0) })
        #expect(tracker.maxConcurrent == 1)
        #expect(tracker.totalRuns == 2)
    }

    /// A kind that reports `.remote` and holds inside `run` until BOTH runs
    /// are in flight (rendezvous), proving remote spawns fan out in parallel.
    /// If remote runs were wrongly serialized, the first would hold its slot
    /// while waiting for a second that can never start — the rendezvous times
    /// out and `maxConcurrent` stays 1.
    private final class RemoteKind: SubagentKind, @unchecked Sendable {
        let capability = SubagentCapability(
            id: "remote-scripted",
            toolNames: ["remote-scripted"],
            gate: .sandboxExec
        )
        let tracker: OverlapTracker

        init(tracker: OverlapTracker) { self.tracker = tracker }

        func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
            ResolvedModel(name: "scripted-remote", isLocal: false)
        }
        func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
            .allow
        }
        func admissionClass(_ resolved: ResolvedModel) -> SubagentAdmissionClass {
            .remote
        }
        func run(
            _ scope: SubagentScope,
            _ resolved: ResolvedModel,
            feed: SubagentFeed,
            interrupt: InterruptToken
        ) async throws -> SubagentResult {
            tracker.enter()
            defer { tracker.exit() }
            // Rendezvous on ARRIVALS (monotonic), not the live count — the
            // sibling may already have exited by the time this run polls.
            let deadline = Date().addingTimeInterval(2)
            while tracker.totalRuns < 2, Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            return SubagentResult(payload: ["kind": "scripted", "summary": "done"])
        }
    }

    @Test("two concurrent remote runs overlap through the host (parallel fan-out)")
    func remoteRunsFanOutThroughSession() async {
        let tracker = OverlapTracker()
        let a = RemoteKind(tracker: tracker)
        let b = RemoteKind(tracker: tracker)
        async let first = SubagentSession.run(a, tool: "remote-scripted")
        async let second = SubagentSession.run(b, tool: "remote-scripted")
        let envelopes = await [first, second]
        #expect(envelopes.allSatisfy { ToolEnvelope.isSuccess($0) })
        #expect(tracker.maxConcurrent == 2)
        #expect(tracker.totalRuns == 2)
    }
}

// MARK: - Test helpers

private final class WaitFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

private final class OverlapTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var _maxConcurrent = 0
    private var _totalRuns = 0

    var currentActive: Int {
        lock.lock()
        defer { lock.unlock() }
        return active
    }
    var maxConcurrent: Int {
        lock.lock()
        defer { lock.unlock() }
        return _maxConcurrent
    }
    var totalRuns: Int {
        lock.lock()
        defer { lock.unlock() }
        return _totalRuns
    }

    func enter() {
        lock.lock()
        active += 1
        _maxConcurrent = max(_maxConcurrent, active)
        _totalRuns += 1
        lock.unlock()
    }
    func exit() {
        lock.lock()
        active -= 1
        lock.unlock()
    }
}
