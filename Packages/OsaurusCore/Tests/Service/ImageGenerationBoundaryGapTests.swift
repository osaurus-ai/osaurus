import Foundation
import Testing
@testable import OsaurusCore

// Regression cases reproduced before the stream-boundary checks.
// A stream-end checkpoint controls the exact race boundary; no sleeps or
// mutation of process-global MLX error state are used.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ImageGenerationBoundaryGapTests {
    @Test func cancellationAfterLastLeafEventMustSuppressCompletion() async throws {
        let fixture = ImageProducerFixture(held: [], heldCheckpoints: [.drained(0)])
        defer { Task { await fixture.probe.releaseAll(); await fixture.checkpoints.releaseAll() } }
        let stream = await fixture.service.generate(.init(model: fixture.first,
            prompt: "cancel at finish", seed: 41), jobID: "tail-cancel")
        let consumer = Task { try await collectImageEvents(stream) }
        await fixture.checkpoints.waitUntilReached(.drained(0))
        await fixture.service.cancel(jobID: "tail-cancel")
        await fixture.checkpoints.release(.drained(0))
        let events = try await consumer.value
        await fixture.service.waitForJobDrain(jobID: "tail-cancel")
        #expect(events.contains { if case .cancelled = $0 { return true }; return false })
        #expect(!events.contains { if case .completed = $0 { return true }; return false })
        await fixture.service.unload()
    }

    @Test func recoveredErrorAfterFirstImageMustBlockSecondFactory() async throws {
        let fixture = ImageProducerFixture(held: [], heldCheckpoints: [.drained(0)])
        defer { Task { await fixture.probe.releaseAll(); await fixture.checkpoints.releaseAll() } }
        let stream = await fixture.service.generate(.init(model: fixture.first,
            prompt: "error between images", seed: 51, numImages: 2), jobID: "error-between")
        let consumer = Task { try await collectImageEvents(stream) }
        await fixture.checkpoints.waitUntilReached(.drained(0))
        fixture.error.record("fixture recovered command-buffer error")
        await fixture.checkpoints.release(.drained(0))
        let events = try await consumer.value
        await fixture.service.waitForJobDrain(jobID: "error-between")
        let created = await fixture.checkpoints.createdIndices
        let snapshot = await fixture.probe.snapshot()
        #expect(created == [0])
        #expect(snapshot.starts.map(\.seed) == [51])
        #expect(events.contains { if case .failed = $0 { return true }; return false })
        #expect(!events.contains { if case .completed = $0 { return true }; return false })
        let resident = await fixture.service.loadedModelSummary()
        #expect(resident == nil)
    }
}
