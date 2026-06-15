//
//  MetalGateTests.swift
//  osaurus
//
//  MetalGate is a writer-preferring readers-writer lock: LLM generations share
//  the lock (so batching is preserved); embedding is exclusive and waits for
//  generations to drain. These tests exercise the basic acquire/release balance
//  for both roles.
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

    @Test func embeddingsSerializeWithoutDeadlock() async {
        // Embedding is now EXCLUSIVE (not a reentrant counter), so a single task
        // cannot hold two embedding acquisitions at once — acquire and release
        // each in turn. (Acquiring twice without releasing would self-deadlock,
        // which is the correct exclusion behavior.)
        await MetalGate.shared.enterEmbedding()
        await MetalGate.shared.exitEmbedding()
        await MetalGate.shared.enterEmbedding()
        await MetalGate.shared.exitEmbedding()
    }

    @Test func generationsShareTheLock() async {
        // Generations are shared readers — two acquisitions coexist (batching),
        // and both release cleanly.
        await MetalGate.shared.enterGeneration()
        await MetalGate.shared.enterGeneration()
        await MetalGate.shared.exitGeneration()
        await MetalGate.shared.exitGeneration()
    }
}
