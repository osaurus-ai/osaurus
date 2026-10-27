import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

/// Model-free diagnostics through the real mapper and per-model registry.
/// These injected failures do not reproduce a physical Metal command-buffer fault.
@Suite("Generation mapper MTP failure diagnostics", .timeLimit(.minutes(1)))
struct GenerationEventMapperMTPFailureTests {
    private let prior = MTPStatsSummary(
        depth: 1,
        activeDepth: 1,
        verifyCalls: 1,
        acceptedDraftTokens: 1,
        bonusTokens: 1,
        rejectedTokens: 0,
        arFallbackTokens: 0,
        adaptiveDownshifts: 0,
        adaptiveFallbackReason: nil,
        avgCommittedPerVerify: 2
    )

    private var partial: NativeMTPGenerationStats {
        NativeMTPGenerationStats(
            depth: 3,
            activeDepth: 2,
            verifyCalls: 4,
            outputTokens: 11,
            arFallbackTokens: 2,
            acceptedByDepth: [1, 2, 1],
            bonusTokens: 1,
            rejectedTokens: 3,
            avgCommittedPerVerify: 2.25,
            avgAcceptProbability: 0.7,
            adaptiveDownshifts: 1,
            adaptiveFallbackReason: "measured AR fallback",
            verifierMode: "staged",
            cacheMode: "hybrid"
        )
    }

    private var expectedPartial: MTPStatsSummary {
        MTPStatsSummary(
            depth: 3,
            activeDepth: 2,
            verifyCalls: 4,
            acceptedDraftTokens: 4,
            bonusTokens: 1,
            rejectedTokens: 3,
            arFallbackTokens: 2,
            adaptiveDownshifts: 1,
            adaptiveFallbackReason: "measured AR fallback",
            avgCommittedPerVerify: 2.25
        )
    }

    private func modelID() -> String { "mtp-diagnostic-\(UUID().uuidString)" }

    private func completion(
        stats: NativeMTPGenerationStats? = nil,
        reason: GenerateStopReason = .cancelled,
        failure: GenerationFailure? = nil
    ) -> GenerateCompletionInfo {
        GenerateCompletionInfo(
            promptTokenCount: 72,
            generationTokenCount: 11,
            promptTime: 0.2,
            generationTime: 0.1,
            stopReason: reason,
            nativeMTPStats: stats,
            generationFailure: failure
        )
    }

    private func stream(_ events: [Generation]) -> AsyncStream<Generation> {
        AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    @Test func failedStepReplacesPriorStatsBeforeTheOriginalErrorReachesItsCaller() async throws {
        let model = modelID()
        let other = modelID()
        await MLXBatchAdapter.recordLastMTPStats(modelName: model, stats: prior)
        await MLXBatchAdapter.recordLastMTPStats(modelName: other, stats: prior)
        let failure = GenerationFailure(
            stage: .decoding,
            cause: "[METAL] Impacting Interactivity: originating fixture error"
        )
        let report = Report()
        var completed = false
        var reasoning = ""
        do {
            for try await event in GenerationEventMapper.map(
                events: stream([
                    .reasoning("actual partial reasoning"),
                    .info(completion(stats: partial, failure: failure)),
                ]),
                modelName: model,
                reportFailure: { report.record($0, model: $1, prompt: $2, generated: $3) }
            ) {
                if case .reasoning(let text) = event { reasoning += text }
                if case .completionInfo = event { completed = true }
            }
            Issue.record("Expected the originating failure")
        } catch let caught as GenerationFailure {
            #expect(caught == failure)
            // The registry write must precede surface completion, not run in a
            // detached task that a Settings poll can lose to.
            let snapshot = await MLXBatchAdapter.lastMTPStatsSnapshot()
            #expect(snapshot[model] == expectedPartial)
            #expect(snapshot[other] == prior)
        }
        #expect(reasoning == "actual partial reasoning")
        #expect(!completed)
        let reports = report.snapshot()
        #expect(reports.count == 1)
        #expect(reports.first?.failure == failure)
        #expect(reports.first?.model == model)
        #expect(reports.first?.prompt == 72)
        #expect(reports.first?.generated == 11)
    }

    @Test(arguments: [GenerationFailure.Stage.preparation, .decoding])
    func failureWithoutStatsClearsOnlyItsOwnPriorReadout(_ stage: GenerationFailure.Stage) async throws {
        let model = modelID()
        let other = modelID()
        await MLXBatchAdapter.recordLastMTPStats(modelName: model, stats: prior)
        await MLXBatchAdapter.recordLastMTPStats(modelName: other, stats: prior)
        let failure = GenerationFailure(stage: stage, cause: "originating no-stats failure")
        do {
            for try await event in GenerationEventMapper.map(
                events: stream([.info(completion(failure: failure))]),
                modelName: model,
                reportFailure: { _, _, _, _ in }
            ) {
                if case .completionInfo = event { Issue.record("Failure cannot become completion") }
            }
            Issue.record("Expected the originating failure")
        } catch let caught as GenerationFailure {
            #expect(caught == failure)
            let snapshot = await MLXBatchAdapter.lastMTPStatsSnapshot()
            #expect(snapshot[model] == nil)
            #expect(snapshot[other] == prior)
        }
    }

    @Test(arguments: [false, true])
    func cancellationKeepsItsActualPartialStatsOrClearsOnlyItsModel(_ hasStats: Bool) async throws {
        let model = modelID()
        let other = modelID()
        await MLXBatchAdapter.recordLastMTPStats(modelName: model, stats: prior)
        await MLXBatchAdapter.recordLastMTPStats(modelName: other, stats: prior)
        let report = Report()
        var terminalCount = 0
        for try await event in GenerationEventMapper.map(
            events: stream([.info(completion(stats: hasStats ? partial : nil))]),
            modelName: model,
            reportFailure: { report.record($0, model: $1, prompt: $2, generated: $3) }
        ) {
            if case .completionInfo(let count, _, _, let reason, _, let stats) = event {
                terminalCount += 1
                #expect(reason == "cancelled")
                #expect(count == 11)
                #expect(stats == (hasStats ? expectedPartial : nil))
                let snapshot = await MLXBatchAdapter.lastMTPStatsSnapshot()
                #expect(snapshot[model] == (hasStats ? expectedPartial : nil))
                #expect(snapshot[other] == prior)
            }
        }
        #expect(terminalCount == 1)
        #expect(report.snapshot().isEmpty)
    }

    @Test func consumerCancellationWithoutTerminalInfoClearsOnlyItsModel() async throws {
        let model = modelID()
        let other = modelID()
        await MLXBatchAdapter.recordLastMTPStats(modelName: model, stats: prior)
        await MLXBatchAdapter.recordLastMTPStats(modelName: other, stats: prior)
        let (upstream, producer) = AsyncStream<Generation>.makeStream()
        defer { producer.finish() }
        let firstOutput = Gate()
        let cleared = Gate()
        let report = Report()
        let mapped = GenerationEventMapper.map(
            events: upstream,
            modelName: model,
            recordMTPStats: { name, stats in
                // Decorate the real registry; the witness observes completion
                // of the actual write, not a fake replacement sink/state.
                await MLXBatchAdapter.recordLastMTPStats(modelName: name, stats: stats)
                #expect(name == model)
                #expect(stats == nil)
                await cleared.signal()
            },
            reportFailure: { report.record($0, model: $1, prompt: $2, generated: $3) }
        )
        let consumer = Task { () throws -> (String, Int) in
            var reasoning = ""
            var completions = 0
            do {
                for try await event in mapped {
                    if case .reasoning(let text) = event {
                        reasoning += text
                        await firstOutput.signal()
                    }
                    if case .completionInfo = event { completions += 1 }
                }
            } catch is CancellationError {
                // Consumer close may finish or throw cancellation; neither
                // becomes natural completion or a backend failure.
            }
            return (reasoning, completions)
        }
        producer.yield(.reasoning("actual partial reasoning"))
        try await withTaskCancellationHandler {
            await firstOutput.wait()
            consumer.cancel()
            let result = try await consumer.value
            await cleared.wait()
            #expect(result.0 == "actual partial reasoning")
            #expect(result.1 == 0)
            #expect(report.snapshot().isEmpty)
            let snapshot = await MLXBatchAdapter.lastMTPStatsSnapshot()
            #expect(snapshot[model] == nil)
            #expect(snapshot[other] == prior)
        } onCancel: {
            consumer.cancel()
            producer.finish()
            Task {
                await firstOutput.signal()
                await cleared.signal()
            }
        }
    }

    @Test(arguments: [false, true])
    func ordinarySuccessPreservesItsExistingStatsContract(_ hasStats: Bool) async throws {
        let model = modelID()
        await MLXBatchAdapter.recordLastMTPStats(modelName: model, stats: prior)
        var terminalCount = 0
        for try await event in GenerationEventMapper.map(
            events: stream([.info(completion(stats: hasStats ? partial : nil, reason: .stop))]),
            modelName: model
        ) {
            if case .completionInfo(let count, _, _, let reason, _, let stats) = event {
                terminalCount += 1
                #expect(reason == "stop")
                #expect(count == 11)
                #expect(stats == (hasStats ? expectedPartial : nil))
                let snapshot = await MLXBatchAdapter.lastMTPStatsSnapshot()
                #expect(snapshot[model] == (hasStats ? expectedPartial : prior))
            }
        }
        #expect(terminalCount == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func housekeepingAndSuppressedProgressDoNotOverwriteInteractiveStats(
        _ suppressProgress: Bool,
        _ hasStats: Bool
    ) async throws {
        let model = modelID()
        await MLXBatchAdapter.recordLastMTPStats(modelName: model, stats: prior)
        let failure = GenerationFailure(stage: .decoding, cause: "background failure")
        do {
            for try await _ in GenerationEventMapper.map(
                events: stream([.info(completion(stats: hasStats ? partial : nil, failure: failure))]),
                modelName: model,
                suppressProgressUI: suppressProgress,
                recordMTPLastRun: suppressProgress,
                reportFailure: { _, _, _, _ in }
            ) {}
            Issue.record("Expected the originating failure")
        } catch let caught as GenerationFailure {
            #expect(caught == failure)
            let snapshot = await MLXBatchAdapter.lastMTPStatsSnapshot()
            #expect(snapshot[model] == prior)
        }
    }

    @Test func laterCleanupInfoCannotEraseTheFirstFailedStepsStats() async throws {
        let model = modelID()
        await MLXBatchAdapter.recordLastMTPStats(modelName: model, stats: prior)
        let first = GenerationFailure(stage: .decoding, cause: "originating failure")
        let second = GenerationFailure(stage: .decoding, cause: "secondary cleanup failure")
        let source = DrainingSource(events: [
            .info(completion(stats: partial, failure: first)),
            .info(completion(failure: second)),
        ])
        let report = Report()
        do {
            for try await _ in GenerationEventMapper.map(
                events: AsyncStream(unfolding: { await source.next() }),
                modelName: model,
                reportFailure: { report.record($0, model: $1, prompt: $2, generated: $3) }
            ) {}
            Issue.record("Expected the originating failure")
        } catch let caught as GenerationFailure {
            #expect(caught == first)
        }
        await source.drained.wait()
        let snapshot = await MLXBatchAdapter.lastMTPStatsSnapshot()
        #expect(snapshot[model] == expectedPartial)
        let reports = report.snapshot()
        #expect(reports.count == 1)
        #expect(reports.first?.failure == first)
    }

    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func signal() {
            open = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    private actor DrainingSource {
        let drained = Gate()
        private var events: [Generation]
        init(events: [Generation]) { self.events = events }
        func next() async -> Generation? {
            guard !events.isEmpty else {
                await drained.signal()
                return nil
            }
            return events.removeFirst()
        }
    }

    private final class Report: @unchecked Sendable {
        struct Entry: Sendable {
            let failure: GenerationFailure
            let model: String
            let prompt: Int
            let generated: Int
        }
        private let lock = NSLock()
        private var entries: [Entry] = []
        func record(_ failure: GenerationFailure, model: String, prompt: Int, generated: Int) {
            lock.lock(); defer { lock.unlock() }
            entries.append(.init(failure: failure, model: model, prompt: prompt, generated: generated))
        }
        func snapshot() -> [Entry] {
            lock.lock(); defer { lock.unlock() }
            return entries
        }
    }
}
