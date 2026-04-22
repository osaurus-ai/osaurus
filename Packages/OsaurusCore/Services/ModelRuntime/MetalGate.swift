//
//  MetalGate.swift
//  osaurus
//
//  Reentrant counter that funnels CoreML embedding submissions through a
//  single conceptual gate. Exists so we have one place to add MLX-vs-CoreML
//  serialization back if a future MLX caller needs exclusive Metal access.
//
//  Today MLX inference is fully delegated to vmlx-swift-lm's `BatchEngine`,
//  which serializes Metal access from inside the library — the gate's
//  generation surface was retired together with the osaurus-side scheduler.
//  Only `MetalSafeEmbedder` calls into this gate; the counter is therefore
//  embeddings-only.
//

import Foundation

public actor MetalGate {
    public static let shared = MetalGate()

    private var activeEmbeddings = 0
    private var embeddingIdleWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    // MARK: - Embedding (CoreML)

    public func enterEmbedding() async {
        activeEmbeddings += 1
    }

    public func exitEmbedding() {
        activeEmbeddings = max(0, activeEmbeddings - 1)
        if activeEmbeddings == 0 {
            let waiters = embeddingIdleWaiters
            embeddingIdleWaiters.removeAll()
            for w in waiters { w.resume() }
        }
    }
}
