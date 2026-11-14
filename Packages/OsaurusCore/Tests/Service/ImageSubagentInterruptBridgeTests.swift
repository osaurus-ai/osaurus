import Foundation
import Testing
import vMLXFlux
@testable import OsaurusCore

// Actual service, gate, FluxEngine wrapper and feed InterruptToken. The concrete
// image producer is tensor-free. Baseline exposes an inert defaulted token seam;
// these assertions require the subsequent bridge, not a cancelled consumer Task.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ImageSubagentInterruptBridgeTests {
    @Test func activeStopDrainsAndPreventsSecondImage() async throws {
        let f = ImageProducerFixture(held: [0])
        let interrupt = InterruptToken()
        defer { Task { await f.probe.releaseAll(); await f.checkpoints.releaseAll() } }
        let stream = await f.service.generate(.init(model: f.first, prompt: "stop", seed: 31, numImages: 2),
            jobID: "active", interrupt: interrupt)
        let consumer = Task { try await collectImageEvents(stream) }
        try await waitUntil { await f.probe.startCount == 1 }
        interrupt.interrupt()
        await f.probe.release(0)
        let events = try await consumer.value
        await f.service.waitForJobDrain(jobID: "active")
        f.log.record("joined")
        let snapshot = await f.probe.snapshot()
        #expect(snapshot.starts.map(\.seed) == [31])
        #expect(snapshot.active == 0 && snapshot.maximumActive == 1)
        expectCancelled(events)
        let order = f.log.events
        let ended = try #require(order.firstIndex(of: "end:0"))
        let joined = try #require(order.firstIndex(of: "joined"))
        #expect(ended < joined)
        await f.service.unload()
    }

    @Test func editStopAtDrainedBoundarySuppressesSuccess() async throws {
        let f = ImageProducerFixture(held: [], kind: .imageEdit, heldCheckpoints: [.drained(0)])
        let interrupt = InterruptToken()
        defer { Task { await f.probe.releaseAll(); await f.checkpoints.releaseAll() } }
        let stream = await f.service.edit(.init(model: f.first, prompt: "edit", sourceImages: [Data([9])]),
            jobID: "edit", interrupt: interrupt)
        let consumer = Task { try await collectImageEvents(stream) }
        await f.checkpoints.waitUntilReached(.drained(0))
        interrupt.interrupt()
        await f.checkpoints.release(.drained(0))
        expectCancelled(try await consumer.value)
        await f.service.waitForJobDrain(jobID: "edit")
        #expect(await f.probe.snapshot().edits.count == 1)
        await f.service.unload()
    }

    @Test func preInterruptedJobDoesNotLoadOrGenerate() async throws {
        let f = ImageProducerFixture(held: [])
        let interrupt = InterruptToken()
        interrupt.interrupt()
        let events = try await collectImageEvents(await f.service.generate(
            .init(model: f.first, prompt: "already stopped"), jobID: "pre", interrupt: interrupt))
        await f.service.waitForJobDrain(jobID: "pre")
        let snapshot = await f.probe.snapshot()
        #expect(snapshot.loads.isEmpty && snapshot.starts.isEmpty)
        expectCancelled(events)
        await f.service.unload()
    }

    @Test func queuedStopDoesNotLoadAfterOtherOwnerReleasesGate() async throws {
        let gate = MetalGate.makeForTesting()
        let f = ImageProducerFixture(held: [], gate: gate)
        try await gate.enterImageGeneration()
        let interrupt = InterruptToken()
        let stream = await f.service.generate(.init(model: f.first, prompt: "queued"),
            jobID: "queued-token", interrupt: interrupt)
        let consumer = Task { try await collectImageEvents(stream) }
        interrupt.interrupt()
        await gate.exitImageGeneration()
        expectCancelled(try await consumer.value)
        await f.service.waitForJobDrain(jobID: "queued-token")
        let snapshot = await f.probe.snapshot()
        #expect(snapshot.loads.isEmpty && snapshot.starts.isEmpty)
        await f.service.unload()
    }

    @Test func lateStopCannotPoisonAnotherJob() async throws {
        let f = ImageProducerFixture(held: [])
        let old = InterruptToken()
        let first = try await collectImageEvents(await f.service.generate(
            .init(model: f.first, prompt: "complete", seed: 71), jobID: "finished", interrupt: old))
        await f.service.waitForJobDrain(jobID: "finished")
        old.interrupt()
        let next = try await collectImageEvents(await f.service.generate(
            .init(model: f.first, prompt: "independent", seed: 72), jobID: "next", interrupt: InterruptToken()))
        await f.service.waitForJobDrain(jobID: "next")
        for events in [first, next] {
            #expect(events.contains { if case .completed = $0 { return true }; return false })
            #expect(!events.contains { if case .cancelled = $0 { return true }; return false })
        }
        #expect(await f.probe.snapshot().starts.map(\.seed) == [71, 72])
        await f.service.unload()
    }

    private func expectCancelled(_ events: [ImageGenerationEvent]) {
        #expect(events.contains { if case .cancelled = $0 { return true }; return false })
        #expect(!events.contains { if case .completed = $0 { return true }; return false })
    }

    private enum Deadline: Error { case expired }
    private func waitUntil(_ predicate: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw Deadline.expired
    }
}
