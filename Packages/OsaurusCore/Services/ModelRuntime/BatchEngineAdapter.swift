//
//  BatchEngineAdapter.swift
//  osaurus
//
//  Routes a single inference request through `MLXLMCommon.BatchEngine` while
//  preserving the same return shape `MLXGenerationEngine.prepareAndGenerate`
//  produces — `(stream, tokenizer, promptTokens, genTask, toolCallFormat)` —
//  so callers (chiefly `ModelRuntime.generateEventStream`) can branch on the
//  feature flag without touching downstream consumers like `StreamAccumulator`.
//
//  Why an adapter at all: `BatchEngine` returns `AsyncStream<BatchGeneration>`
//  (raw token IDs) while our pipeline already expects
//  `AsyncStream<MLXLMCommon.TokenGeneration>` from `generateTokenTask`. The two
//  enums are isomorphic but distinct types, so we need a small mapping task.
//  The same task also gives us a `Task<Void, Never>` handle to attach
//  cancellation to — `BatchEngine.cancel(BatchRequestID)` is the upstream
//  primitive, and we surface it via standard Swift task cancellation.
//
//  Cache coordinator: captured automatically by `container.makeBatchEngine`.
//  Multi-turn KV reuse, mediaSalt for VLMs, sliding-window cache support —
//  all handled inside `BatchEngine.stepPrefill`/`finishSlot`. We do not need
//  to plumb anything cache-related through this layer.
//

import Foundation
import MLX
@preconcurrency import MLXLMCommon
import os.log

private let batchAdapterLog = Logger(subsystem: "ai.osaurus", category: "BatchAdapter")

struct BatchEngineAdapter {

    /// Per-process cache of `BatchEngine` instances keyed by model name.
    ///
    /// Engines are heavyweight: they hold a captured `ModelContext` and run a
    /// background scheduling task. Creating one per request would defeat the
    /// continuous-batching point — the whole reason `BatchEngine` exists is
    /// to share a single forward pass across overlapping requests, which can
    /// only happen if those requests submit into the *same* engine instance.
    ///
    /// `ModelRuntime` owns lifetime: it calls `engine(for:container:maxBatchSize:)`
    /// on first use and `shutdownEngine(for:)` from `unload(name:)` /
    /// `clearAll()`.
    actor Registry {
        static let shared = Registry()

        private var engines: [String: BatchEngine] = [:]

        /// Returns the cached engine for `modelName`, creating it on first use
        /// from the supplied `ModelContainer`. The container's existing cache
        /// coordinator is captured automatically by `makeBatchEngine`.
        func engine(
            for modelName: String,
            container: ModelContainer,
            maxBatchSize: Int
        ) async -> BatchEngine {
            if let existing = engines[modelName] { return existing }
            let engine = await container.makeBatchEngine(maxBatchSize: maxBatchSize)
            engines[modelName] = engine
            batchAdapterLog.info(
                "registry: created BatchEngine for \(modelName, privacy: .public) maxBatchSize=\(maxBatchSize, privacy: .public)"
            )
            return engine
        }

        /// Shut down and remove the engine for `modelName`. Safe to call when
        /// no engine exists. Pending requests on the engine receive a
        /// `.cancelled` info event before the actor exits its scheduling loop.
        func shutdownEngine(for modelName: String) async {
            guard let engine = engines.removeValue(forKey: modelName) else { return }
            await engine.shutdown()
            batchAdapterLog.info(
                "registry: shutdown BatchEngine for \(modelName, privacy: .public)"
            )
        }

        /// Shut down every cached engine. Used by `ModelRuntime.clearAll()`.
        func shutdownAll() async {
            let snapshot = engines
            engines.removeAll()
            for (name, engine) in snapshot {
                await engine.shutdown()
                batchAdapterLog.info(
                    "registry: shutdown BatchEngine for \(name, privacy: .public)"
                )
            }
        }
    }

    /// Result tuple matching `MLXGenerationEngine.prepareAndGenerate` so the
    /// caller can branch on the feature flag without touching consumers.
    typealias PreparedStream = MLXGenerationEngineResult

    /// What `prepareInput` produces inside `container.perform`. Pulled into a
    /// named struct so the prep step can return it directly via a `Sendable`
    /// box — cleaner than mutating fields on a heap-allocated holder.
    private struct PreparedInput: @unchecked Sendable {
        let input: LMInput
        let promptTokens: [Int]
        let tokenizer: any Tokenizer
        let toolCallFormat: ToolCallFormat
    }

    /// Mirror of `MLXGenerationEngine.prepareAndGenerate` that submits to a
    /// shared `BatchEngine` instead of constructing a per-request `TokenIterator`.
    ///
    /// Tool-call detection is left to `StreamAccumulator` exactly as in the
    /// non-batch path — `BatchEngine` does not understand tool grammars.
    static func prepareAndSubmit(
        modelName: String,
        container: ModelContainer,
        buildChat: @Sendable () -> [MLXLMCommon.Chat.Message],
        buildToolsSpec: @Sendable () -> [[String: any Sendable]]?,
        generation: GenerationParameters,
        runtime: RuntimeConfig,
        maxBatchSize: Int
    ) async throws -> PreparedStream {
        let trace = generation.ttftTrace
        trace?.mark("batch_prepare_start")

        let prepared = try await prepareInput(
            container: container,
            buildChat: buildChat,
            buildToolsSpec: buildToolsSpec,
            generation: generation,
            trace: trace
        )

        // Get-or-create the per-model `BatchEngine`. The engine captures the
        // container's cache coordinator at construction so multi-turn KV
        // reuse just works for every request from this point on.
        let engine = await Registry.shared.engine(
            for: modelName,
            container: container,
            maxBatchSize: maxBatchSize
        )

        let mlxParams = ModelRuntime.makeGenerateParameters(
            temperature: generation.temperature ?? 0.7,
            maxTokens: generation.maxTokens,
            topP: generation.topPOverride ?? runtime.topP,
            repetitionPenalty: generation.repetitionPenalty,
            maxKV: runtime.maxKV
        )

        // Submit. `BatchEngine.submit` takes its `LMInput` by `consuming` so
        // ownership moves into the engine's slot.
        trace?.mark("batch_submit")
        let (requestId, batchStream) = await engine.submit(
            input: prepared.input,
            parameters: mlxParams
        )

        // Bridge `BatchGeneration` (raw token IDs) into `TokenGeneration`
        // (what `StreamAccumulator` already consumes) and route Swift
        // cancellation into `BatchEngine.cancel(requestId)`.
        let (outStream, continuation) = AsyncStream<MLXLMCommon.TokenGeneration>.makeStream()
        let producerTask = Task<Void, Never> {
            await withTaskCancellationHandler {
                for await event in batchStream {
                    if Task.isCancelled { break }
                    switch event {
                    case .token(let tokenId):
                        continuation.yield(.token(tokenId))
                    case .info(let info):
                        continuation.yield(.info(info))
                    }
                }
                continuation.finish()
            } onCancel: {
                // Engine yields a final `.info(.cancelled)` and closes the
                // stream; the for-await above then drains naturally.
                Task { await engine.cancel(requestId) }
            }
        }

        batchAdapterLog.info(
            "submit: model=\(modelName, privacy: .public) requestId=\(String(describing: requestId), privacy: .public) promptTokens=\(prepared.promptTokens.count, privacy: .public)"
        )

        return (
            stream: outStream,
            tokenizer: prepared.tokenizer,
            promptTokens: prepared.promptTokens,
            genTask: producerTask,
            toolCallFormat: prepared.toolCallFormat
        )
    }

    /// Tokenize + apply the chat template inside `container.perform` so the
    /// processor call is serialized against any other container access. This
    /// mirrors the tokenization path in `MLXGenerationEngine.prepareAndGenerate`.
    private static func prepareInput(
        container: ModelContainer,
        buildChat: @Sendable () -> [MLXLMCommon.Chat.Message],
        buildToolsSpec: @Sendable () -> [[String: any Sendable]]?,
        generation: GenerationParameters,
        trace: TTFTTrace?
    ) async throws -> PreparedInput {
        // Heap-allocated outbox so the throwing closure can hand a value back
        // across the actor boundary. `try await container.perform` either
        // assigns `result` or throws — there is no third state.
        final class OutBox: @unchecked Sendable { var result: PreparedInput? }
        let box = OutBox()

        try await container.perform { (context: MLXLMCommon.ModelContext) in
            trace?.mark("batch_container_perform_entered")
            let chat = MLXGenerationEngine.preprocessImages(in: buildChat())
            let toolsSpec = buildToolsSpec()

            let additionalContext: [String: any Sendable]?
            if let disableThinking = generation.modelOptions["disableThinking"]?.boolValue {
                additionalContext = ["enable_thinking": !disableThinking]
            } else {
                additionalContext = nil
            }
            let userInput = MLXLMCommon.UserInput(
                chat: chat,
                processing: .init(),
                tools: toolsSpec,
                additionalContext: additionalContext
            )

            trace?.mark("batch_tokenization_start")
            let lmInput: LMInput
            do {
                lmInput = try await context.processor.prepare(input: userInput)
            } catch {
                let detail =
                    (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                throw NSError(
                    domain: "BatchEngineAdapter",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Chat template error: \(detail)"]
                )
            }
            trace?.mark("batch_tokenization_done")

            let tokens = lmInput.text.tokens.asArray(Int.self)
            guard !tokens.isEmpty else {
                throw NSError(
                    domain: "BatchEngineAdapter",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Tokenizer produced no tokens for the given input"]
                )
            }

            box.result = PreparedInput(
                input: lmInput,
                promptTokens: tokens,
                tokenizer: context.tokenizer,
                toolCallFormat: context.configuration.toolCallFormat ?? .json
            )
        }

        guard let prepared = box.result else {
            // Defensive — `container.perform` must either assign or throw.
            throw NSError(
                domain: "BatchEngineAdapter",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Prepared input missing after container.perform"]
            )
        }
        return prepared
    }
}
