//
//  ForegroundReservationTests.swift
//  osaurusTests
//
//  A live chat turn on a local model holds background work that would swap
//  in a different local model; same-model, remote and unknown claims go
//  through, and the hold expires so a long chat cannot starve the queue.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ForegroundReservationTests {
    static let local = ResourceClaim(model: "other-local", isLocal: true)

    @Test func arbiterWaitsOnlyForAConflictingLocalModel() {
        let center = ForegroundReservationCenter()
        let arbiter = ResourceArbiter(reservations: center)
        center.reserveForTesting(owner: "chat", model: "chat-local", isLocal: true)
        let now = Date()

        #expect(arbiter.decide(claim: Self.local, waitingSince: now) == .wait(reason: "foreground_active"))
        #expect(
            arbiter.decide(claim: ResourceClaim(model: "CHAT-LOCAL", isLocal: true), waitingSince: now)
                == .admit(note: nil))
        #expect(
            arbiter.decide(claim: ResourceClaim(model: "gpt-x", isLocal: false), waitingSince: now)
                == .admit(note: nil))
        #expect(arbiter.decide(claim: .unknown, waitingSince: now) == .admit(note: nil))
        #expect(arbiter.decide(claim: nil, waitingSince: now) == .admit(note: nil))
    }

    @Test func aClaimOnSeveralLocalModelsWaitsForAnyOtherReservation() {
        let center = ForegroundReservationCenter()
        let arbiter = ResourceArbiter(reservations: center)
        center.reserveForTesting(owner: "chat", model: "chat-local", isLocal: true)
        let workflow = ResourceClaim(model: "chat-local", isLocal: true, additionalModels: ["other-local"])
        #expect(workflow.localModels == ["chat-local", "other-local"])
        #expect(arbiter.decide(claim: workflow, waitingSince: Date()) == .wait(reason: "foreground_active"))
        let sameOnly = ResourceClaim(model: "chat-local", isLocal: true)
        #expect(arbiter.decide(claim: sameOnly, waitingSince: Date()) == .admit(note: nil))
    }

    @Test func claimsWrittenBeforeAdditionalModelsStillDecode() throws {
        let old = #"{"model":"m","isLocal":true}"#
        let claim = try JSONDecoder().decode(ResourceClaim.self, from: Data(old.utf8))
        #expect(claim.additionalModels == nil)
        #expect(claim.localModels == ["m"])
    }

    @Test func reservationHistoryIsCapped() throws {
        let database = TaskDatabase()
        try database.openInMemory()
        let base = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        for i in 0..<(TaskDatabase.reservationRows + 25) {
            try database.upsertReservation(
                ForegroundReservation(
                    owner: "chat", kind: .chat, model: nil, isLocal: false,
                    startedAt: base.addingTimeInterval(Double(i))))
        }
        try database.prune(now: base)
        let kept = try database.reservations(limit: TaskDatabase.reservationRows * 2)
        #expect(kept.count == TaskDatabase.reservationRows)
        #expect(kept.last?.startedAt == base.addingTimeInterval(25))
    }

    @Test func remoteReservationsHoldNothing() {
        let center = ForegroundReservationCenter()
        let arbiter = ResourceArbiter(reservations: center)
        center.reserveForTesting(owner: "chat", model: "gpt-x", isLocal: false)
        #expect(arbiter.decide(claim: Self.local, waitingSince: Date()) == .admit(note: nil))
    }

    /// An agent that names no model runs on the session's fallback pick, so
    /// its claim must name that model rather than claim nothing.
    @Test func anAgentWithoutAModelClaimsTheSessionsFallbackPick() {
        let item = ModelPickerItem(id: "mlx-test/local-chat", displayName: "Local Chat", source: .local)
        let agentId = UUID()
        #expect(ChatSession.initialModel(for: agentId, in: [item]) == item.id)
        #expect(ResourceArbiter.claim(forAgent: agentId, pickerItems: [item]).model == item.id)
    }

    @Test func holdExpiresWithAJournaledNote() {
        let center = ForegroundReservationCenter()
        let arbiter = ResourceArbiter(reservations: center)
        center.reserveForTesting(owner: "chat", model: "chat-local", isLocal: true)
        let since = Date(timeIntervalSinceNow: -ResourceArbiter.maxForegroundHold - 1)
        #expect(arbiter.decide(claim: Self.local, waitingSince: since) == .admit(note: "foreground_hold_expired"))
    }

    @Test func releasingTheReservationAdmitsTheHeldTask() async throws {
        let center = ForegroundReservationCenter()
        let store = TaskStore(database: nil)
        let scheduler = TaskScheduler(store: store, reservations: center)
        let reservation = center.reserveForTesting(owner: "chat", model: "chat-local", isLocal: true)
        let task = OsaurusTask(
            title: "Background", origin: .automation, createdBy: .system("test"),
            work: .agentTurn(AgentTurnWork(agentId: nil, source: .automation)), state: .queued, claim: Self.local)
        store.record(task)
        var started = false
        let submission = TaskScheduler.Submission(
            id: task.id, queueId: TaskQueue.defaultID, claim: Self.local, onStart: { started = true })

        #expect(scheduler.submit(submission) == .queued(position: 1))
        #expect(store.task(id: task.id)?.waitReason == "foreground_active")

        center.release(reservation)
        for _ in 0 ..< 100 where !started {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(started)
        #expect(center.active.isEmpty)
    }

    // MARK: - Sandbox admission

    @Test func aColdSandboxIdentityWaitsWhileTheVMIsBusy() {
        let arbiter = ResourceArbiter(reservations: ForegroundReservationCenter())
        let claim = ResourceClaim(model: nil, isLocal: false, sandboxMember: "wf-cold")
        let busy = SandboxPodSnapshot(isRunning: true, members: ["agent-a", "wf-warm"], busyHolders: ["agent-a"])
        #expect(arbiter.decide(claim: claim, waitingSince: Date(), sandbox: busy) == .wait(reason: "sandbox_busy"))
        // A member never waits, and a restart of an idle or stopped VM stops nothing.
        let warm = ResourceClaim(model: nil, isLocal: false, sandboxMember: "wf-warm")
        #expect(arbiter.decide(claim: warm, waitingSince: Date(), sandbox: busy) == .admit(note: nil))
        let idle = SandboxPodSnapshot(isRunning: true, members: ["agent-a"], busyHolders: [])
        #expect(arbiter.decide(claim: claim, waitingSince: Date(), sandbox: idle) == .admit(note: nil))
        #expect(arbiter.decide(claim: claim, waitingSince: Date(), sandbox: SandboxPodSnapshot()) == .admit(note: nil))
        // No expiry: an hour later it still waits rather than stop running work.
        let longAgo = Date(timeIntervalSinceNow: -3600)
        #expect(arbiter.decide(claim: claim, waitingSince: longAgo, sandbox: busy) == .wait(reason: "sandbox_busy"))
    }

    @Test func claimsWrittenBeforeSandboxMembersStillDecode() throws {
        let old = #"{"model":"m","isLocal":true}"#
        let claim = try JSONDecoder().decode(ResourceClaim.self, from: Data(old.utf8))
        #expect(claim.sandboxMember == nil)
    }

    @Test func aSandboxBusyTaskStartsOnceTheVMFreesUp() async throws {
        let store = TaskStore(database: nil)
        var snapshot = SandboxPodSnapshot(isRunning: true, members: ["agent-a"], busyHolders: ["agent-a"])
        let scheduler = TaskScheduler(
            store: store, reservations: ForegroundReservationCenter(),
            sandboxSnapshot: { snapshot }, refreshSandbox: {})
        let claim = ResourceClaim(model: nil, isLocal: false, sandboxMember: "wf-cold")
        let task = OsaurusTask(
            title: "Workflow", origin: .automation, createdBy: .system("test"),
            work: .agentTurn(AgentTurnWork(agentId: nil, source: .automation)), state: .queued, claim: claim)
        store.record(task)
        var started = false
        let submission = TaskScheduler.Submission(
            id: task.id, queueId: TaskQueue.defaultID, claim: claim, onStart: { started = true })
        #expect(scheduler.submit(submission) == .queued(position: 1))
        #expect(store.task(id: task.id)?.waitReason == "sandbox_busy")

        snapshot.busyHolders = []
        scheduler.pump()
        #expect(started)
    }

    @Test func releaseIsIdempotent() {
        let center = ForegroundReservationCenter()
        let id = center.reserveForTesting(owner: "chat", model: "m", isLocal: true)
        center.release(id)
        center.release(id)
        center.release(nil)
        #expect(center.active.isEmpty)
    }
}
