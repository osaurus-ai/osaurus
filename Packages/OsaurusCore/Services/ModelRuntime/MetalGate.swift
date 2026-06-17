//
//  MetalGate.swift
//  osaurus
//
//  Process-wide mutual-exclusion gate between MLX *generation* (the LLM,
//  driven by vmlx-swift's `BatchEngine`) and the EXCLUSIVE external GPU users:
//  MLX *embedding* (the Model2Vec static-embedding pipeline behind
//  capability/memory search) and MLX *image generation* (the vMLXFlux engine).
//  All submit work to the same Metal device on different threads. vmlx
//  deliberately does NOT lock the `eval` hot path (the C++ scheduler serializes
//  the BatchEngine's own evals and dropping the Swift lock lets asyncEval/item
//  overlap for token throughput). But an EXTERNAL caller — the embedder, and
//  likewise the image engine, each a second MLX graph — evaluating concurrently
//  with the BatchEngine races on the Metal command buffer and aborts with
//      -[…] addCompletedHandler:]: unrecognized selector
//  (observed live: capabilities_discover embedding during an LLM prefill).
//
//  This gate makes generation, embedding, and image generation mutually
//  exclusive so their GPU work never overlaps. Generation holds the gate for
//  the FULL stream consumption — vmlx does not `finish()` the stream until
//  after its end-of-turn cache-store eval, so releasing on stream end (not on
//  the `.info` event) covers the BatchEngine's async tail too. Image
//  generation likewise holds the gate across the entire vMLXFlux event-stream
//  drain, including the terminal VAE decode eval (see ImageGenerationService).
//

import Foundation

//  Implemented as a writer-preferring readers-writer lock:
//    - Generation = SHARED (reader). Multiple LLM requests may hold it at
//      once — the BatchEngine evaluates all of its slots on one loop thread,
//      so they are mutually safe and must keep batching for throughput.
//    - Embedding / image generation = EXCLUSIVE (writer). Each runs on a
//      different thread, so it waits for every in-flight generation to drain
//      and blocks new ones from starting until it finishes. The two writers
//      also exclude each other (one exclusive holder at a time). Writer
//      preference keeps a steady stream of generations from starving a writer.
public actor MetalGate {
    public static let shared = MetalGate()

    /// Number of in-flight generations holding the shared lock.
    private var activeGenerations = 0
    /// An exclusive user (embedding or image generation) holds the lock.
    private var exclusiveActive = false
    /// Exclusive users waiting to acquire — new generations block while > 0 so
    /// a writer can't starve.
    private var exclusiveWaiting = 0
    /// Condition-variable waiters; woken on every state change, each re-checks
    /// its own predicate (standard actor condition pattern).
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    private func suspend() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    private func wakeAll() {
        guard !waiters.isEmpty else { return }
        let woken = waiters
        waiters.removeAll()
        for c in woken { c.resume() }
    }

    // MARK: - Generation (LLM via BatchEngine) — shared

    public func enterGeneration() async {
        // Yield to any active or waiting exclusive user (writer preference).
        while exclusiveActive || exclusiveWaiting > 0 {
            await suspend()
        }
        activeGenerations += 1
    }

    public func exitGeneration() {
        activeGenerations = max(0, activeGenerations - 1)
        if activeGenerations == 0 { wakeAll() }
    }

    // MARK: - Exclusive users (embedding, image generation)

    /// Acquire the exclusive lock: drain every in-flight generation, exclude
    /// the other writer, and block new generations until released.
    private func enterExclusive() async {
        exclusiveWaiting += 1
        while exclusiveActive || activeGenerations > 0 {
            await suspend()
        }
        exclusiveWaiting -= 1
        exclusiveActive = true
    }

    private func exitExclusive() {
        exclusiveActive = false
        wakeAll()
    }

    // MARK: - Embedding (Model2Vec / capability + memory search) — exclusive

    public func enterEmbedding() async { await enterExclusive() }
    public func exitEmbedding() { exitExclusive() }

    // MARK: - Image generation (vMLXFlux) — exclusive

    public func enterImageGeneration() async { await enterExclusive() }
    public func exitImageGeneration() { exitExclusive() }
}
