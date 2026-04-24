//
//  MLXBatchAdapter.swift
//  osaurus
//
//  Single MLX entry point: routes each request through `BatchEngine.generate`,
//  which emits authoritative `.chunk(String)` / `.reasoning(String)` /
//  `.toolCall(ToolCall)` / `.info(GenerateCompletionInfo)` events. Reasoning,
//  tool-call extraction, and text-level stop matching are all owned by the
//  library — osaurus passes `stopSequences` as `GenerateParameters.extraStopStrings`
//  and forwards every event through `GenerationEventMapper`.
//
//  Osaurus no longer parses tool calls, reasoning, or stop sequences at the
//  app layer — see `GenerationEventMapper` for the trivial `Generation` →
//  `ModelRuntimeEvent` bridge that replaced the old token-level
//  `StreamAccumulator` and app-side `StopSequenceBuffer`.
//
//  Cache coordinator: captured automatically by `container.makeBatchEngine`.
//  Multi-turn KV reuse, mediaSalt for VLMs, sliding-window cache support —
//  all handled inside the engine. We do not need to plumb anything cache-
//  related through this layer.
//

import CoreImage
import Foundation
import MLX
@preconcurrency import MLXLMCommon
import MLXRandom
import MLXVLM  // MediaProcessing for image downscaling
import os.log

private let batchAdapterLog = Logger(subsystem: "ai.osaurus", category: "BatchAdapter")

struct MLXBatchAdapter {

    /// Result handed back to `ModelRuntime`. The `Generation` stream is
    /// consumed by `GenerationEventMapper`, which translates the upstream
    /// events into `ModelRuntimeEvent`. The producer task exists so callers
    /// can cancel the underlying `BatchEngine` request via Swift's standard
    /// task-cancellation mechanism.
    struct PreparedStream {
        let stream: AsyncStream<Generation>
        let promptTokens: [Int]
        let genTask: Task<Void, Never>
    }

    // MARK: - Per-model engine cache

    /// Per-process cache of `BatchEngine` instances keyed by model name.
    ///
    /// Engines are heavyweight: they hold a captured `ModelContext` and run a
    /// background scheduling task. Creating one per request would defeat the
    /// continuous-batching point — the whole reason `BatchEngine` exists is
    /// to share a single forward pass across overlapping requests, which can
    /// only happen if those requests submit into the *same* engine instance.
    actor Registry {
        static let shared = Registry()

        private var engines: [String: BatchEngine] = [:]

        /// Returns the cached engine for `modelName`, creating it on first
        /// use from the supplied `ModelContainer`. The container's existing
        /// cache coordinator is captured automatically by `makeBatchEngine`.
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

        /// Shut down and remove the engine for `modelName`. Safe to call
        /// when no engine exists. Pending requests on the engine receive a
        /// `.cancelled` info event before the actor exits.
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

    // MARK: - Image preprocessing

    private static let maxImageSize = CGSize(width: 1024, height: 1024)

    private static func downscaleIfNeeded(_ image: CIImage) -> CIImage {
        let scale = min(MediaProcessing.bestFitScale(image.extent.size, in: maxImageSize), 1.0)
        guard scale < 1.0 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    /// Downscale CIImage attachments to a sane upper bound before tokenization.
    /// Pre-existing `URL` / `array` cases pass through untouched.
    ///
    /// Preserves `toolCalls` and `toolCallId` through the rebuild — dropping
    /// them here would silently unwind the structured tool-call handoff set
    /// up by `ModelRuntime.mapOpenAIChatToMLX`, and MiniMax (plus every other
    /// template that reads `message.tool_calls[i]`) would fall back to the
    /// old "no previous assistant message with a tool call" hard fail.
    private static func preprocessImages(in chat: [MLXLMCommon.Chat.Message]) -> [MLXLMCommon.Chat.Message] {
        chat.map { message in
            let processedImages = message.images.map { userInputImage -> UserInput.Image in
                switch userInputImage {
                case .ciImage(let ciImage):
                    return .ciImage(downscaleIfNeeded(ciImage))
                default:
                    return userInputImage
                }
            }
            return MLXLMCommon.Chat.Message(
                role: message.role,
                content: message.content,
                images: processedImages,
                videos: message.videos,
                toolCalls: message.toolCalls,
                toolCallId: message.toolCallId
            )
        }
    }

    // MARK: - Submission

    /// Tokenize the chat + tools, fetch (or create) the per-model
    /// `BatchEngine`, and submit one request via `engine.generate`. Returns
    /// the resulting `Generation` stream wrapped with cancellation plumbing.
    static func generate(
        modelName: String,
        container: ModelContainer,
        buildChat: @Sendable () -> [MLXLMCommon.Chat.Message],
        buildToolsSpec: @Sendable () -> [[String: any Sendable]]?,
        generation: GenerationParameters,
        stopSequences: [String],
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

        let engine = await Registry.shared.engine(
            for: modelName,
            container: container,
            maxBatchSize: maxBatchSize
        )

        // Honor the model's shipped sampling defaults (Hugging Face
        // `generation_config.json`) when the OpenAI-wire request omits a
        // field. Without this overlay osaurus served, e.g., Qwen 3.5 397B
        // at 0.7 temperature when its recipe specifies 0.6, and Gemma-4
        // 26B-A4B with top_k disabled when the recipe specifies top_k=64.
        // Explicit client values still win — the `?? modelDefaults`
        // ordering only applies when `generation.*` is nil.
        let modelDefaults = LocalGenerationDefaults.defaults(forModelId: modelName)
        let mlxParams = ModelRuntime.makeGenerateParameters(
            temperature: generation.temperature ?? modelDefaults.temperature ?? 0.7,
            maxTokens: generation.maxTokens,
            topP: generation.topPOverride ?? modelDefaults.topP ?? runtime.topP,
            topK: modelDefaults.topK ?? 0,
            repetitionPenalty: generation.repetitionPenalty ?? modelDefaults.repetitionPenalty,
            stopSequences: stopSequences
        )

        // Best-effort per-request determinism: seed the MLX global random
        // state immediately before submission. Note: vmlx's `Sampler`
        // constructs its own `RandomState()` from time-of-day inside the
        // engine, so concurrent seeded requests against the same model
        // are NOT guaranteed reproducible. Single-request seeding still
        // benefits any MLX code path that consults `MLXRandom.globalState`.
        if let seed = generation.seed {
            MLXRandom.seed(seed)
        }

        // `engine.generate` returns `AsyncStream<Generation>` directly with
        // reasoning + tool-call extraction handled inside vmlx. We re-wrap
        // it so we can attach a producer `Task` for cancellation.
        trace?.mark("batch_submit")
        let upstream = await engine.generate(
            input: prepared.input,
            parameters: mlxParams
        )

        let (outStream, continuation) = AsyncStream<Generation>.makeStream()
        let producerTask = Task<Void, Never> {
            await withTaskCancellationHandler {
                for await event in upstream {
                    if Task.isCancelled { break }
                    continuation.yield(event)
                }
                continuation.finish()
            } onCancel: {
                // The upstream stream is bound to a single request inside
                // the engine; cancelling the consumer task closes it
                // cooperatively (engine emits a final `.info(.cancelled)`
                // and finishes the stream).
                continuation.finish()
            }
        }

        batchAdapterLog.info(
            "submit: model=\(modelName, privacy: .public) promptTokens=\(prepared.promptTokens.count, privacy: .public)"
        )

        return PreparedStream(
            stream: outStream,
            promptTokens: prepared.promptTokens,
            genTask: producerTask
        )
    }

    // MARK: - Tokenization

    private struct PreparedInput: @unchecked Sendable {
        let input: LMInput
        let promptTokens: [Int]
    }

    private static func prepareInput(
        container: ModelContainer,
        buildChat: @Sendable () -> [MLXLMCommon.Chat.Message],
        buildToolsSpec: @Sendable () -> [[String: any Sendable]]?,
        generation: GenerationParameters,
        trace: TTFTTrace?
    ) async throws -> PreparedInput {
        // Heap-allocated outbox so the throwing closure can hand a value back
        // across the actor boundary.
        final class OutBox: @unchecked Sendable { var result: PreparedInput? }
        let box = OutBox()

        try await container.perform { (context: MLXLMCommon.ModelContext) in
            trace?.mark("batch_container_perform_entered")
            let chat = preprocessImages(in: buildChat())
            let toolsSpec = buildToolsSpec()

            // `enable_thinking` handling. If the user set `disableThinking`
            // explicitly, honor it. Otherwise default to `true` — templates
            // that don't reference `enable_thinking` silently ignore the
            // kwarg, but templates that do reference it (Gemma-4 / Qwen-3
            // thinking / AutoThinkingProfile targets) rely on the flag to
            // activate reasoning. The previous behavior (send `nil` here
            // and let the template default win) meant Gemma-4's
            // `{%- if not enable_thinking | default(false) -%}` branch
            // fired and suppressed CoT even when the profile said the
            // model supports thinking — which was invisible to us when
            // profile detection itself failed (e.g. model stored outside
            // `~/MLXModels` so `LocalReasoningCapability.analyze` never
            // got to read the template).
            let additionalContext: [String: any Sendable]
            if let disableThinking = generation.modelOptions["disableThinking"]?.boolValue {
                additionalContext = ["enable_thinking": !disableThinking]
            } else {
                additionalContext = ["enable_thinking": true]
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
                    domain: "MLXBatchAdapter",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Chat template error: \(detail)"]
                )
            }
            trace?.mark("batch_tokenization_done")

            let tokens = lmInput.text.tokens.asArray(Int.self)
            guard !tokens.isEmpty else {
                throw NSError(
                    domain: "MLXBatchAdapter",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Tokenizer produced no tokens for the given input"]
                )
            }

            box.result = PreparedInput(input: lmInput, promptTokens: tokens)
        }

        guard let prepared = box.result else {
            throw NSError(
                domain: "MLXBatchAdapter",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Prepared input missing after container.perform"]
            )
        }
        return prepared
    }
}
