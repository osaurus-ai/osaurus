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
                videos: message.videos
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

        let mlxParams = ModelRuntime.makeGenerateParameters(
            temperature: generation.temperature ?? 0.7,
            maxTokens: generation.maxTokens,
            topP: generation.topPOverride ?? runtime.topP,
            repetitionPenalty: generation.repetitionPenalty,
            stopSequences: stopSequences
        )

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

            // Honor an explicit `disableThinking` toggle when present;
            // otherwise omit the kwarg so the chat template's own default
            // takes effect. (Forcing `enable_thinking: false` whenever
            // tools are present has historically surprised users with
            // thinking-capable models and can hurt tool-calling.)
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
