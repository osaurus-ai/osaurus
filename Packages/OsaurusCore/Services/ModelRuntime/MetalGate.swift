//
//  MetalGate.swift
//  osaurus
//
//  Mutual-exclusion gate preventing concurrent Metal command submissions
//  from MLX (generation) and CoreML (embedding).  Overlapping submissions
//  cause EXC_BAD_ACCESS / SIGSEGV on Apple Silicon.
//
//  Multiple embeddings may be active concurrently (CoreML handles its own
//  serialization via the SwiftEmbedder actor).  MLX generation requires
//  exclusive access — it waits for all active embeddings to drain, and
//  embeddings wait for any active generation to finish.
//

import Foundation

public actor MetalGate {
    public static let shared = MetalGate()

    private var activeEmbeddings = 0
    private var generationActive = false
    private var embeddingIdleWaiters: [CheckedContinuation<Void, Never>] = []
    private var generationIdleWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    // MARK: - Embedding (CoreML)

    public func enterEmbedding() async {
        while generationActive {
            await withCheckedContinuation { cont in
                if generationActive {
                    generationIdleWaiters.append(cont)
                } else {
                    cont.resume()
                }
            }
        }
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

    // MARK: - Generation (MLX)

    public func enterGeneration() async {
        while generationActive {
            await withCheckedContinuation { cont in
                if generationActive {
                    generationIdleWaiters.append(cont)
                } else {
                    cont.resume()
                }
            }
        }
        generationActive = true
        while activeEmbeddings > 0 {
            await withCheckedContinuation { cont in
                if activeEmbeddings == 0 {
                    cont.resume()
                } else {
                    embeddingIdleWaiters.append(cont)
                }
            }
        }
    }

    public func exitGeneration() {
        generationActive = false
        let waiters = generationIdleWaiters
        generationIdleWaiters.removeAll()
        for w in waiters { w.resume() }
    }
}
