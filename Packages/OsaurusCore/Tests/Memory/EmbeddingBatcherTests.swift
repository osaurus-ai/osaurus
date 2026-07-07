//
//  EmbeddingBatcherTests.swift
//  osaurusTests
//
//  Batcher-logic tests run against a mock backend (never the real model):
//  coalescing, result distribution, error propagation, cancellation
//  isolation, and the window latency bound. Timing-sensitive tests inject
//  the window duration and only assert bounds that cannot flake (lower
//  bounds from `clock.sleep`, and upper bounds far below an injected huge
//  window).
//

import Foundation
import MLX
import Testing
import VecturaKit

@testable import OsaurusCore

// MARK: - Mocks

/// Backend that records every batch it receives and returns a deterministic
/// vector per text (no time, no randomness).
private actor CountingBackend {
    private(set) var calls: [[String]] = []
    private let failure: (any Error)?

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    func embed(_ texts: [String]) throws -> [[Float]] {
        calls.append(texts)
        if let failure {
            throw failure
        }
        return texts.map(Self.vector(for:))
    }

    nonisolated static func vector(for text: String) -> [Float] {
        [
            Float(text.utf8.count),
            Float(text.unicodeScalars.first?.value ?? 0),
            Float(text.unicodeScalars.last?.value ?? 0),
        ]
    }
}

private struct BackendFailure: Error, Equatable {}

private actor RecordingVecturaEmbedder: VecturaEmbedder {
    private(set) var singleCalls: [String] = []
    private(set) var batchCalls: [[String]] = []

    var dimension: Int {
        get async throws { 3 }
    }

    func embed(texts: [String]) async throws -> [[Float]] {
        batchCalls.append(texts)
        return texts.map(CountingBackend.vector(for:))
    }

    func embed(text: String) async throws -> [Float] {
        singleCalls.append(text)
        return CountingBackend.vector(for: text)
    }
}

// MARK: - Batcher tests

struct EmbeddingBatcherTests {
    private func makeBatcher(
        window: Duration,
        maxBatchSize: Int = EmbeddingBatcher.defaultMaxBatchSize,
        backend: CountingBackend
    ) -> EmbeddingBatcher {
        EmbeddingBatcher(window: window, maxBatchSize: maxBatchSize) { texts in
            try await backend.embed(texts)
        }
    }

    @Test func batchedOutputMatchesSequentialOutput() async throws {
        let backend = CountingBackend()
        let batcher = makeBatcher(window: .milliseconds(100), backend: backend)
        let texts = ["alpha", "bravo", "charlie", "delta", "echo"]

        let batched = try await withThrowingTaskGroup(of: (String, [Float]).self) { group in
            for text in texts {
                group.addTask { (text, try await batcher.embed(text)) }
            }
            var results: [String: [Float]] = [:]
            for try await (text, vector) in group {
                results[text] = vector
            }
            return results
        }

        // Sequential reference: what one direct call per text would return.
        for text in texts {
            #expect(batched[text] == CountingBackend.vector(for: text))
        }
    }

    @Test func concurrentCallersCoalesceIntoOneBackendCall() async throws {
        let backend = CountingBackend()
        // Generous window so all concurrently spawned callers land inside it
        // even on a heavily loaded machine.
        let batcher = makeBatcher(window: .milliseconds(500), backend: backend)
        let texts = ["one", "two", "three", "four"]

        try await withThrowingTaskGroup(of: Void.self) { group in
            for text in texts {
                group.addTask { _ = try await batcher.embed(text) }
            }
            try await group.waitForAll()
        }

        let calls = await backend.calls
        #expect(calls.count == 1)
        #expect(calls.first?.sorted() == texts.sorted())
    }

    @Test func loneCallerLatencyIsBoundedByWindow() async throws {
        let backend = CountingBackend()
        let window: Duration = .milliseconds(50)
        let batcher = makeBatcher(window: window, backend: backend)

        let clock = ContinuousClock()
        let start = clock.now
        let vector = try await batcher.embed("solo")
        let elapsed = clock.now - start

        #expect(vector == CountingBackend.vector(for: "solo"))
        // A lone request waits out exactly one window before its (instant,
        // mocked) forward: at least `window`, and nowhere near 100x it. The
        // generous upper bound only catches "window never closed" bugs
        // without flaking on scheduler noise.
        #expect(elapsed >= window)
        #expect(elapsed < .seconds(5))
        let calls = await backend.calls
        #expect(calls == [["solo"]])
    }

    @Test func errorPropagatesToEveryWaiter() async throws {
        let backend = CountingBackend(failure: BackendFailure())
        let batcher = makeBatcher(window: .milliseconds(100), backend: backend)

        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for text in ["a", "b", "c"] {
                group.addTask {
                    do {
                        _ = try await batcher.embed(text)
                        return false
                    } catch is BackendFailure {
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var failures: [Bool] = []
            for await sawExpectedError in group {
                failures.append(sawExpectedError)
            }
            return failures
        }

        #expect(outcomes == [true, true, true])
        let calls = await backend.calls
        #expect(calls.count == 1)
    }

    @Test func cancellingOneWaiterDoesNotKillTheBatch() async throws {
        let backend = CountingBackend()
        let batcher = makeBatcher(window: .milliseconds(500), backend: backend)

        let survivorA = Task { try await batcher.embed("alpha") }
        let cancelled = Task { try await batcher.embed("bravo") }
        let survivorB = Task { try await batcher.embed("charlie") }

        // Give all three time to enqueue inside the 500 ms window, then
        // cancel the middle waiter while the window is still open.
        try await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()

        #expect(try await survivorA.value == CountingBackend.vector(for: "alpha"))
        #expect(try await survivorB.value == CountingBackend.vector(for: "charlie"))
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.value
        }

        let calls = await backend.calls
        #expect(calls.count == 1)
        #expect(calls.first?.contains("alpha") == true)
        #expect(calls.first?.contains("charlie") == true)
    }

    @Test func fullBatchFlushesWithoutWaitingForTheWindow() async throws {
        let backend = CountingBackend()
        // Window intentionally enormous: completion well before it proves the
        // max-batch-size flush fired, with no dependence on tight timing.
        let batcher = makeBatcher(
            window: .seconds(30), maxBatchSize: 3, backend: backend
        )
        let texts = ["x", "y", "z"]

        let clock = ContinuousClock()
        let start = clock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for text in texts {
                group.addTask { _ = try await batcher.embed(text) }
            }
            try await group.waitForAll()
        }
        let elapsed = clock.now - start

        #expect(elapsed < .seconds(10))
        let calls = await backend.calls
        #expect(calls.count == 1)
        #expect(calls.first?.count == 3)
    }

    @Test func sequentialLoneCallersGetOneBatchEach() async throws {
        let backend = CountingBackend()
        let batcher = makeBatcher(window: .milliseconds(20), backend: backend)

        let first = try await batcher.embed("first")
        let second = try await batcher.embed("second")

        #expect(first == CountingBackend.vector(for: "first"))
        #expect(second == CountingBackend.vector(for: "second"))
        let calls = await backend.calls
        #expect(calls == [["first"], ["second"]])
    }
}

// MARK: - CoalescingEmbedder routing

struct CoalescingEmbedderTests {
    @Test func singleTextRoutesThroughBatcherAndBatchesPassThrough() async throws {
        let direct = RecordingVecturaEmbedder()
        let backend = CountingBackend()
        let embedder = CoalescingEmbedder(
            direct: direct,
            batcher: EmbeddingBatcher(window: .milliseconds(20)) { texts in
                try await backend.embed(texts)
            }
        )

        // Caller-assembled batches bypass the window entirely.
        let batchResult = try await embedder.embed(texts: ["p", "q"])
        #expect(batchResult == [["p", "q"].map(CountingBackend.vector(for:))].flatMap { $0 })
        #expect(await direct.batchCalls == [["p", "q"]])
        #expect(await backend.calls.isEmpty)

        // Single-text embeds coalesce through the batcher's backend.
        let single = try await embedder.embed(text: "r")
        #expect(single == CountingBackend.vector(for: "r"))
        #expect(await backend.calls == [["r"]])
        #expect(await direct.singleCalls.isEmpty)
    }
}

// MARK: - Real-model batch parity (skipped when the model is not local)

/// Verifies the batched `[N, L]` padded forward in `VMLXModel2VecEmbedder`
/// produces the same vectors as one-at-a-time forwards — i.e. padding and
/// masking do not change any text's embedding.
///
/// Opt-in: MLX hard-aborts the whole test process when its metallib is not
/// locatable, and plain `swift test` has no Cmlx resource bundle. Run with
/// the model directory override set and a `default.metallib` (from an app
/// build's Cmlx bundle) copied next to the package manifest:
///
///     OSAURUS_EMBEDDING_MODEL_DIR=/path/to/potion-base-4M \
///       swift test --package-path Packages/OsaurusCore \
///       --filter VMLXModel2VecEmbedderBatchParityTests
struct VMLXModel2VecEmbedderBatchParityTests {
    private static var explicitModelDirectoryUsable: Bool {
        // Require the deliberate env override — merely having the model in
        // the Hugging Face cache must not opt a plain `swift test` run into
        // MLX initialization (see the metallib abort note above).
        guard
            let override = ProcessInfo.processInfo.environment["OSAURUS_EMBEDDING_MODEL_DIR"],
            !override.isEmpty
        else { return false }
        return VMLXModel2VecEmbedder.locateModelDirectory(modelName: EmbeddingService.modelName)
            != nil
    }

    @Test(.enabled(if: explicitModelDirectoryUsable))
    func batchedForwardMatchesPerTextForward() async throws {
        // The parity property (padding/masking must not change any text's
        // vector) is device-independent; pin to the CPU device so results
        // do not depend on the host GPU.
        Device.setDefault(device: .cpu)

        let embedder = VMLXModel2VecEmbedder(
            modelName: EmbeddingService.modelName,
            dimension: EmbeddingService.embeddingDimension,
            tokenizerLoader: SwiftTransformersTokenizerLoader()
        )
        // Mixed lengths force real padding; the empty string exercises the
        // zero-token row inside a batch.
        let texts = [
            "dog",
            "a much longer sentence about memory search and distillation workloads",
            "",
            "batching",
        ]

        let batched = try await embedder.embed(texts: texts)
        #expect(batched.count == texts.count)

        for (index, text) in texts.enumerated() {
            let single = try await embedder.embed(text: text)
            #expect(single.count == batched[index].count)
            let maxDelta = zip(single, batched[index])
                .map { abs($0 - $1) }
                .max() ?? 0
            // Reduction order differs between the padded batched mean and the
            // single-text mean, so allow float32 noise but nothing more.
            #expect(maxDelta < 1e-4, "vector mismatch for texts[\(index)] = \(text)")
        }

        // potion-base-4M normalizes: every non-empty text embeds to a unit
        // vector, and the empty text stays exactly zero.
        for (index, text) in texts.enumerated() {
            let norm = batched[index].map { $0 * $0 }.reduce(0, +).squareRoot()
            if text.isEmpty {
                #expect(norm == 0)
            } else {
                #expect(abs(norm - 1) < 1e-3)
            }
        }
    }
}
