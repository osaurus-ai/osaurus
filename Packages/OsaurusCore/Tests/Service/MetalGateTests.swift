//
//  MetalGateTests.swift
//  osaurus
//
//  MetalGate is mutual exclusion keyed by producer identity: same-model
//  generations share the lock (so batching is preserved); a different model, an
//  embedder, and a model load are each exclusive. These tests exercise the
//  basic acquire/release balance for those roles.
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

    @Test func sameModelGenerationsShareTheLock() async {
        // Same-model generations are shared — two acquisitions coexist
        // (batching), and both release cleanly.
        await MetalGate.shared.enterGeneration(model: "qwen3.5-4b")
        await MetalGate.shared.enterGeneration(model: "qwen3.5-4b")
        await MetalGate.shared.exitGeneration(model: "qwen3.5-4b")
        await MetalGate.shared.exitGeneration(model: "qwen3.5-4b")
    }

    @Test func modelLoadProceedsWhenIdle() async {
        // A model load is an exclusive producer; it acquires and releases
        // cleanly when nothing else holds the GPU.
        await MetalGate.shared.enterModelLoad(model: "qwen3.5-4b")
        await MetalGate.shared.exitModelLoad(model: "qwen3.5-4b")
    }
}
