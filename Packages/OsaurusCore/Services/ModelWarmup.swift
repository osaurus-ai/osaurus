//
//  ModelWarmup.swift
//  osaurus
//
//  Proactive model warm-up.
//
//  Large MLX bundles (e.g. JANG / MXFP8) pay a one-time, multi-second Metal
//  kernel-compilation (JIT) cost on their FIRST decode. On a freshly loaded
//  process that cost lands on the first real request as a cold-start
//  time-to-first-token outlier (measured ~3.0–3.2 s for Gemma-4-12B-MXFP8 vs
//  ~60–80 ms once warm). Every subsequent request is fast because MLX caches
//  the compiled kernels in-process.
//
//  `warmUp` runs ONE tiny throwaway generation through the real `ChatEngine`
//  path right after a bundle becomes resident, so the JIT compilation happens
//  off the request path and the first chat/API turn the user actually waits on
//  is already warm. This is a latency-only optimization: the warm-up output is
//  discarded and warm-up never alters sampling, parsing, or any model output —
//  it only changes *when* kernels are compiled, never *what* the model emits.
//

import Foundation
import MLXLMCommon

/// Process-local proactive warm-up for locally served models.
public enum ModelWarmup {
    private static let lock = NSLock()
    /// Models already warmed (or with a warm-up in flight) in this process.
    /// Marked before the await so concurrent callers coalesce onto one warm-up.
    /// `nonisolated(unsafe)`: every access is guarded by `lock`.
    nonisolated(unsafe) private static var warmedOrInFlight: Set<String> = []

    /// True once `warmUp(modelId:)` has started (or completed) for `modelId`
    /// in this process. Diagnostics / test hook.
    public static func isWarm(_ modelId: String) -> Bool {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        return warmedOrInFlight.contains(trimmed)
    }

    /// Synchronously claim the warm-up slot for `modelId`. Returns `true` when
    /// this caller is the first to claim it (and should drive the warm-up),
    /// `false` when a warm-up already ran or is in flight. Kept synchronous so
    /// `NSLock` is legal — `lock()/unlock()` are unavailable from async code.
    private static func claimSlot(_ modelId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if warmedOrInFlight.contains(modelId) { return false }
        warmedOrInFlight.insert(modelId)
        return true
    }

    /// Compile `modelId`'s JIT'd kernels via one tiny throwaway LOCAL
    /// generation so the first real request doesn't pay the cold-start cost.
    ///
    /// - Idempotent per (process, model): a second call returns immediately.
    /// - Best-effort: any routing/generation failure is swallowed. A model
    ///   that can't warm simply pays its cold cost on the first real request,
    ///   exactly as it did before warm-up existed.
    /// - Local-only: the engine is built with no remote provider services, so
    ///   a remote/unknown model id throws `modelNotFound`, is caught, and is a
    ///   no-op (remote models have nothing local to compile).
    ///
    /// Returns `true` when this call drove a warm-up generation to completion,
    /// `false` when it was a coalesced no-op or the warm-up failed.
    @discardableResult
    public static func warmUp(modelId: String) async -> Bool {
        // Local services only — warm-up never reaches out to remote providers.
        await warmUp(
            modelId: modelId,
            engine: ChatEngine(
                services: [FoundationModelService(), MLXService()],
                installedModelsProvider: { MLXService.getAvailableModels() },
                remoteServicesProvider: { [] }
            )
        )
    }

    /// Shared production path with an injected engine for lifecycle regression
    /// tests. The public entry point always constructs a local-only engine.
    static func warmUp(modelId: String, engine: any ResponsesEngineProtocol) async -> Bool {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard claimSlot(trimmed) else { return false }

        // Minimal prompt, a handful of greedy tokens, no tools. Tool schemas
        // only change the prompt text and the (CPU-side) tool parser — never
        // which GPU matmul/attention/sampling kernels compile — so a no-tool
        // warm-up compiles the same kernels the scored, tool-carrying requests
        // hit. Output is discarded.
        let request = ResponsesInferenceRequest(
            model: trimmed,
            input: [ChatMessage(role: "user", content: "Hi")],
            generation: ResponsesGenerationOptions(temperature: 0.0, maxOutputTokens: 8)
        )

        let startedAt = Date()
        log("warm-up start model=\(trimmed) (compiling kernels off the request path)")
        do {
            let result = try await engine.completeResponse(request: request, endAt: .streamEnd)
            switch result.completion.status {
            case .cancelled:
                throw CancellationError()
            case .incomplete:
                // The explicit eight-token JIT diagnostic may reach its cap;
                // that compiles kernels but is never a coherent-chat pass.
                guard result.completion.stopReason == "length" else {
                    throw ResponsesGenerationResult.CollectionError.incomplete(result.completion.stopReason)
                }
            case .completed:
                break
            }
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            log("warm-up done  model=\(trimmed) elapsedMs=\(ms) (one-time JIT now off the request path)")
            return true
        } catch {
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            // Swallow: the model will still serve real requests; it just pays
            // its cold kernel-compilation cost on the first one.
            log("warm-up skip  model=\(trimmed) elapsedMs=\(ms) reason=\(error)")
            return false
        }
    }

    private static func log(_ message: String) {
        RuntimeDiagnostics.write(Data("[osaurus] \(message)\n".utf8))
    }
}
