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

/// Ordered, actor-isolated event log used to prove exclusion deterministically:
/// a blocked waiter cannot record its "acquired" event until the current holder
/// records its "released" event first.
private actor GateOrderRecorder {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

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

    // MARK: - Model teardown (unload) owner — exclusive against every producer

    @Test func modelTeardownProceedsWhenIdle() async {
        // Unload teardown is exclusive; it acquires and releases cleanly when
        // nothing else holds the GPU.
        await MetalGate.shared.enterModelTeardown(model: "qwen3.5-4b")
        await MetalGate.shared.exitModelTeardown(model: "qwen3.5-4b")
    }

    @Test func teardownWaitsForImageGenerationToRelease() async {
        // The chat→image handoff race: a model unload must not run its GPU
        // teardown while the image lane holds the device. Prove the teardown
        // cannot acquire until image generation releases.
        let rec = GateOrderRecorder()
        await MetalGate.shared.enterImageGeneration()
        let waiter = Task {
            await MetalGate.shared.enterModelTeardown(model: "chat-model")
            await rec.record("teardown-acquired")
            await MetalGate.shared.exitModelTeardown(model: "chat-model")
        }
        // Let the waiter run and block on the exclusive image owner.
        try? await Task.sleep(for: .milliseconds(80))
        await rec.record("image-released")
        await MetalGate.shared.exitImageGeneration()
        _ = await waiter.value
        let events = await rec.events
        #expect(events == ["image-released", "teardown-acquired"])
    }

    @Test func teardownWaitsForModelLoadToRelease() async {
        // A teardown must not overlap a model load on the shared device.
        let rec = GateOrderRecorder()
        await MetalGate.shared.enterModelLoad(model: "incoming-model")
        let waiter = Task {
            await MetalGate.shared.enterModelTeardown(model: "outgoing-model")
            await rec.record("teardown-acquired")
            await MetalGate.shared.exitModelTeardown(model: "outgoing-model")
        }
        try? await Task.sleep(for: .milliseconds(80))
        await rec.record("load-released")
        await MetalGate.shared.exitModelLoad(model: "incoming-model")
        _ = await waiter.value
        let events = await rec.events
        #expect(events == ["load-released", "teardown-acquired"])
    }

    @Test func generationWaitsForTeardownToRelease() async {
        // The restore side: a chat-model reload's generation must not start
        // while a previous model's teardown is still draining the device.
        let rec = GateOrderRecorder()
        await MetalGate.shared.enterModelTeardown(model: "old-model")
        let waiter = Task {
            await MetalGate.shared.enterGeneration(model: "new-model")
            await rec.record("gen-acquired")
            await MetalGate.shared.exitGeneration(model: "new-model")
        }
        try? await Task.sleep(for: .milliseconds(80))
        await rec.record("teardown-released")
        await MetalGate.shared.exitModelTeardown(model: "old-model")
        _ = await waiter.value
        let events = await rec.events
        #expect(events == ["teardown-released", "gen-acquired"])
    }

    // MARK: - Source contract: the unload teardown is actually gate-bracketed

    @Test func unloadTeardownIsGateBracketedInSource() throws {
        // The GPU teardown section itself can't be unit-run (no Metal in CI), so
        // pin the wiring textually: the teardown owner exists and is exclusive,
        // `ModelRuntime.unload` brackets its teardown with it, and the post-job
        // image unload is wrapped in the exclusive image lane (the symmetric
        // restore-side fix). Mirrors `ImageGenerationBridgeContractTests`.
        let coreRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Service/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // OsaurusCore/

        let gate = try String(
            contentsOf: coreRoot.appendingPathComponent("Services/ModelRuntime/MetalGate.swift"),
            encoding: .utf8
        )
        let runtime = try String(
            contentsOf: coreRoot.appendingPathComponent("Services/ModelRuntime.swift"),
            encoding: .utf8
        )
        let imageService = try String(
            contentsOf: coreRoot.appendingPathComponent(
                "Services/ModelRuntime/ImageGenerationService.swift"
            ),
            encoding: .utf8
        )

        // Exclusive teardown owner.
        #expect(gate.contains("public func enterModelTeardown(model: String) async"))
        #expect(gate.contains("public func exitModelTeardown(model: String)"))
        #expect(gate.contains(#"acquire("unload:\(model)", shared: false)"#))

        // ModelRuntime.unload brackets its GPU teardown with the gate.
        #expect(runtime.contains("await MetalGate.shared.enterModelTeardown(model: name)"))
        #expect(runtime.contains("await MetalGate.shared.exitModelTeardown(model: name)"))

        // The post-job image unload frees FLUX weights under the exclusive image
        // lane (engine.unload immediately follows entering the gate).
        #expect(
            imageService.contains(
                "await MetalGate.shared.enterImageGeneration()\n        await engine.unload()"
            )
        )
    }
}
