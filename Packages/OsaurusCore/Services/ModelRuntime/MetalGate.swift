//
//  MetalGate.swift
//  osaurus
//
//  Process-wide mutual-exclusion gate between MLX *generation* (the LLM,
//  driven by vmlx-swift's `BatchEngine`) and MLX *embedding* (the Model2Vec
//  static-embedding pipeline behind capability/memory search). Both submit
//  work to the same Metal device on different threads. vmlx deliberately
//  does NOT lock the `eval` hot path (the C++ scheduler serializes the
//  BatchEngine's own evals and dropping the Swift lock lets asyncEval/item
//  overlap for token throughput). But an EXTERNAL caller — the embedder —
//  evaluating concurrently with the BatchEngine races on the Metal command
//  buffer and aborts with
//      -[…] addCompletedHandler:]: unrecognized selector
//  (observed live: capabilities_discover embedding during an LLM prefill).
//
//  This gate makes generation and embedding mutually exclusive so their GPU
//  work never overlaps. The embedder is the only external GPU user and its
//  work is brief, so it simply waits for any in-flight generation to finish;
//  the LLM hot path is untouched. Generation holds the gate for the FULL
//  stream consumption — vmlx does not `finish()` the stream until after its
//  end-of-turn cache-store eval, so releasing on stream end (not on the
//  `.info` event) covers the BatchEngine's async tail too.
//

import Foundation

//  Implemented as a writer-preferring readers-writer lock:
//    - Generation = SHARED (reader). Multiple LLM requests may hold it at
//      once — the BatchEngine evaluates all of its slots on one loop thread,
//      so they are mutually safe and must keep batching for throughput.
//    - Embedding  = EXCLUSIVE (writer). It runs on a different thread, so it
//      waits for every in-flight generation to drain and blocks new ones
//      from starting until it finishes. Writer preference keeps a steady
//      stream of generations from starving the embedder.
public actor MetalGate {
    public static let shared = MetalGate()

    /// Number of in-flight generations holding the shared lock.
    private var activeGenerations = 0
    /// An embedding currently holds the exclusive lock.
    private var embeddingActive = false
    /// Embedders waiting to acquire — new generations block while > 0 so the
    /// writer can't starve.
    private var embeddersWaiting = 0
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
        // Yield to any active or waiting embedder (writer preference).
        while embeddingActive || embeddersWaiting > 0 {
            await suspend()
        }
        activeGenerations += 1
    }

    public func exitGeneration() {
        activeGenerations = max(0, activeGenerations - 1)
        if activeGenerations == 0 { wakeAll() }
    }

    // MARK: - Embedding (Model2Vec / capability + memory search) — exclusive

    public func enterEmbedding() async {
        embeddersWaiting += 1
        while embeddingActive || activeGenerations > 0 {
            await suspend()
        }
        embeddersWaiting -= 1
        embeddingActive = true
    }

    public func exitEmbedding() {
        embeddingActive = false
        wakeAll()
    }
}
