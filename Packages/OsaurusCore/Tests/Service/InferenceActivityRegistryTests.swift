import Foundation
import Testing
@testable import OsaurusCore

@Suite("Inference activity registry")
struct InferenceActivityRegistryTests {
    private final class CancellationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func record(_ id: String) {
            lock.withLock { storage.append(id) }
        }

        var ids: [String] {
            lock.withLock { storage }
        }
    }

    @Test("tracks source and lifecycle phase until terminal cleanup")
    func lifecycle() async {
        let registry = InferenceActivityRegistry()
        let id = UUID()

        await registry.begin(
            id: id,
            modelName: "example/model",
            source: .channel,
            sessionID: "channel-7",
            phase: .loading
        )
        await registry.update(id: id, phase: .prefilling)

        let active = await registry.snapshot()
        #expect(active.count == 1)
        #expect(active.first?.id == id)
        #expect(active.first?.source == .channel)
        #expect(active.first?.sessionID == "channel-7")
        #expect(active.first?.phase == .prefilling)
        #expect(active.first?.canCancel == false)

        await registry.update(id: id, phase: .unloading)
        #expect(await registry.snapshot().first?.phase == .unloading)

        await registry.finish(id: id)
        #expect(await registry.snapshot().isEmpty)
    }

    @Test("cancels only the selected request when two requests share a model")
    func exactRequestCancellation() async {
        let registry = InferenceActivityRegistry()
        let probe = CancellationProbe()
        let first = UUID()
        let second = UUID()

        for id in [first, second] {
            await registry.begin(
                id: id,
                modelName: "same/model",
                source: .httpAPI,
                sessionID: nil,
                phase: .queued
            )
        }
        await registry.installCancellation(id: first) {
            probe.record("first")
        }
        await registry.installCancellation(id: second) {
            probe.record("second")
        }

        #expect(await registry.cancel(id: first))
        #expect(probe.ids == ["first"])
        let active = await registry.snapshot()
        #expect(active.count == 2)
        #expect(active.first(where: { $0.id == first })?.cancellationRequested == true)
        #expect(active.first(where: { $0.id == second })?.cancellationRequested == false)
    }

    @Test("preserves distinct producer attribution")
    func producerAttribution() {
        #expect(SessionSource.delegation.inferenceSource == .chatUI)
        #expect(SessionSource.channel.inferenceSource == .channel)
        #expect(SessionSource.schedule.inferenceSource == .schedule)
        #expect(SessionSource.watcher.inferenceSource == .watcher)
        #expect(SessionSource.selfSchedule.inferenceSource == .selfSchedule)
        #expect(SessionSource.http.inferenceSource == .httpAPI)

        let channel = GenerationParameters(
            temperature: nil,
            maxTokens: 32,
            requestSource: .channel
        )
        #expect(channel.activitySource == .channel)

        let delegated = GenerationParameters(
            temperature: nil,
            maxTokens: 32,
            activitySource: .agent,
            requestSource: .chatUI
        )
        #expect(delegated.requestSource == .chatUI)
        #expect(delegated.activitySource == .agent)
    }
}
