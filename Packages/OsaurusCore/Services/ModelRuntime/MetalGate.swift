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
//  exclusive access against embeddings — it waits for all active embeddings
//  to drain, and embeddings wait for any active generation to finish.
//
//  MLX-vs-MLX serialization is *configurable* via
//  `InferenceFeatureFlags.mlxAllowConcurrentStreams`. When OFF (default),
//  this gate also serializes MLX-vs-MLX so behaviour matches pre-Phase-3
//  exactly. When ON, the per-model `ModelWorker` is the only thing
//  preventing two streams of the same model from racing; different models
//  can interleave.
//

import Foundation

public actor MetalGate {
    public static let shared = MetalGate()

    private var activeEmbeddings = 0
    /// Count of active MLX generations. With `mlxAllowConcurrentStreams` OFF
    /// this is effectively 0 or 1; with the flag ON it can climb to the
    /// number of distinct loaded models in flight.
    private var activeGenerations = 0
    private var embeddingIdleWaiters: [CheckedContinuation<Void, Never>] = []
    private var generationIdleWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    // MARK: - Embedding (CoreML)

    public func enterEmbedding() async {
        while activeGenerations > 0 {
            await withCheckedContinuation { cont in
                if activeGenerations > 0 {
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
        let allowConcurrent = InferenceFeatureFlags.mlxAllowConcurrentStreams

        if !allowConcurrent {
            // Strict MLX-vs-MLX serialization: behave exactly as before by
            // waiting until no other generation is active.
            while activeGenerations > 0 {
                await withCheckedContinuation { cont in
                    if activeGenerations > 0 {
                        generationIdleWaiters.append(cont)
                    } else {
                        cont.resume()
                    }
                }
            }
        }

        activeGenerations += 1
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
        activeGenerations = max(0, activeGenerations - 1)
        if activeGenerations == 0 {
            let waiters = generationIdleWaiters
            generationIdleWaiters.removeAll()
            for w in waiters { w.resume() }
        }
    }
}
