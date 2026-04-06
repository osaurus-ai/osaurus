//
//  MetalGateTests.swift
//  osaurus
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct MetalGateTests {

    @Test func embeddingProceedsWhenIdle() async {
        await MetalGate.shared.enterEmbedding()
        await MetalGate.shared.exitEmbedding()
    }

    @Test func generationProceedsWhenIdle() async {
        await MetalGate.shared.enterGeneration()
        await MetalGate.shared.exitGeneration()
    }

    @Test func embeddingWaitsForGeneration() async {
        await MetalGate.shared.enterGeneration()

        let embeddingStarted = AtomicFlag()
        let embeddingTask = Task {
            await MetalGate.shared.enterEmbedding()
            embeddingStarted.set()
            await MetalGate.shared.exitEmbedding()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!embeddingStarted.value)

        await MetalGate.shared.exitGeneration()
        await embeddingTask.value
        #expect(embeddingStarted.value)
    }

    @Test func generationWaitsForEmbedding() async {
        await MetalGate.shared.enterEmbedding()

        let generationStarted = AtomicFlag()
        let generationTask = Task {
            await MetalGate.shared.enterGeneration()
            generationStarted.set()
            await MetalGate.shared.exitGeneration()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!generationStarted.value)

        await MetalGate.shared.exitEmbedding()
        await generationTask.value
        #expect(generationStarted.value)
    }

    @Test func multipleEmbeddingsConcurrently() async {
        await MetalGate.shared.enterEmbedding()
        await MetalGate.shared.enterEmbedding()
        await MetalGate.shared.exitEmbedding()
        await MetalGate.shared.exitEmbedding()
    }

    @Test func generationExcludesSecondGeneration() async {
        await MetalGate.shared.enterGeneration()

        let secondStarted = AtomicFlag()
        let secondTask = Task {
            await MetalGate.shared.enterGeneration()
            secondStarted.set()
            await MetalGate.shared.exitGeneration()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!secondStarted.value)

        await MetalGate.shared.exitGeneration()
        await secondTask.value
        #expect(secondStarted.value)
    }
}

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false

    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}
