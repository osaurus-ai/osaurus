//
//  MLXGenerationEngine.swift
//  osaurus
//
//  Encapsulates MLX message preparation and generation stream construction.
//

import CoreImage
import Foundation
import MLX
import MLXLLM
@preconcurrency import MLXLMCommon
import MLXVLM
import os.log

private let engineLog = Logger(subsystem: "ai.osaurus", category: "Generation")
private let engineSignposter = OSSignposter(subsystem: "ai.osaurus", category: "Generation")

/// Returns the effective offset of the first KV cache layer that actually tracks position
/// (i.e., not a MambaCache / ArraysCache layer whose `offset` is always 0).
///
/// For RotatingKVCache layers that have wrapped past their sliding window, the raw `offset`
/// reflects total tokens processed — not the number of tokens actually stored. We cap at
/// `maxSize` so callers can safely use this value to index into token arrays.
func effectiveCacheOffset(_ cache: [any KVCache]) -> Int {
    for layer in cache {
        // MambaCache (and its parent ArraysCache) never updates offset — skip them.
        if layer is ArraysCache { continue }
        // Cap at maxSize for rotating caches that have wrapped past their window.
        if let maxSize = layer.maxSize {
            return min(layer.offset, maxSize)
        }
        return layer.offset
    }
    // All layers are Mamba-style; fall back to first layer (offset will be 0 but that's correct).
    return cache.first?.offset ?? 0
}

struct MLXGenerationEngine {

    private static let maxImageSize = CGSize(width: 1024, height: 1024)

    private static func downscaleIfNeeded(_ image: CIImage) -> CIImage {
        let scale = min(MediaProcessing.bestFitScale(image.extent.size, in: maxImageSize), 1.0)
        guard scale < 1.0 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    static func preprocessImages(in chat: [MLXLMCommon.Chat.Message]) -> [MLXLMCommon.Chat.Message] {
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

    /// Holds the generation stream plus the caller-owned KV cache that was
    /// passed into (or created for) `generate()`.  Because `[any KVCache]` is
    /// not `Sendable`, we wrap it in an `@unchecked Sendable` box so it can
    /// cross the `container.perform` boundary safely -- access is serialised
    /// through the `ModelRuntime` actor.
    final class CacheBox: @unchecked Sendable {
        let cache: [any KVCache]
        init(_ cache: [any KVCache]) { self.cache = cache }
    }

    static func prepareAndGenerate(
        container: ModelContainer,
        buildChat: @Sendable () -> [MLXLMCommon.Chat.Message],
        buildToolsSpec: @Sendable () -> [[String: any Sendable]]?,
        generation: GenerationParameters,
        runtime: RuntimeConfig,
        existingCache: [any KVCache]?,
        cachedTokens: [Int]?,
        wiredMemoryTicket: WiredMemoryTicket?
    ) async throws -> (
        stream: AsyncStream<MLXLMCommon.TokenGeneration>,
        tokenizer: any Tokenizer,
        cache: [any KVCache],
        promptTokens: [Int],
        genTask: Task<Void, Never>,
        toolCallFormat: ToolCallFormat,
        /// Non-nil when a two-phase prefill was performed.  The snapshot cache
        /// and its corresponding token array are at the *stable boundary* —
        /// i.e. after all history tokens have been processed but BEFORE the
        /// generation-prefix tokens (e.g. `<|im_start|>assistant\n<think>\n`).
        /// Storing the session cache keyed by these tokens instead of
        /// `promptTokens` means the next turn's common-prefix check will hit
        /// exactly at `snapshotTokens.count` == `cacheOffset`, requiring zero
        /// trim even on non-trimmable (MambaCache) models.
        snapshotCache: [any KVCache]?,
        snapshotTokens: [Int]?
    ) {
        let spState = engineSignposter.beginInterval("prepareAndGenerate", id: engineSignposter.makeSignpostID())
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { engineSignposter.endInterval("prepareAndGenerate", spState) }

        // Named result box so we can propagate optional snapshot fields across the actor boundary.
        final class ResultBox: @unchecked Sendable {
            let stream: AsyncStream<MLXLMCommon.TokenGeneration>
            let tokenizer: any Tokenizer
            let cache: CacheBox
            let promptTokens: [Int]
            let genTask: Task<Void, Never>
            let toolCallFormat: ToolCallFormat
            let snapshotCache: CacheBox?
            let snapshotTokens: [Int]?
            init(
                _ stream: AsyncStream<MLXLMCommon.TokenGeneration>,
                _ tokenizer: any Tokenizer,
                _ cache: CacheBox,
                _ promptTokens: [Int],
                _ genTask: Task<Void, Never>,
                _ toolCallFormat: ToolCallFormat,
                _ snapshotCache: CacheBox?,
                _ snapshotTokens: [Int]?
            ) {
                self.stream = stream; self.tokenizer = tokenizer; self.cache = cache
                self.promptTokens = promptTokens; self.genTask = genTask
                self.toolCallFormat = toolCallFormat
                self.snapshotCache = snapshotCache; self.snapshotTokens = snapshotTokens
            }
        }

        let result: ResultBox = try await container.perform { (context: MLXLMCommon.ModelContext) in
            let chat = preprocessImages(in: buildChat())
            let toolsSpec = buildToolsSpec()
            let parameters = ModelRuntime.makeGenerateParameters(
                temperature: generation.temperature ?? 0.7,
                maxTokens: generation.maxTokens,
                topP: generation.topPOverride ?? runtime.topP,
                repetitionPenalty: generation.repetitionPenalty,
                kvBits: runtime.kvBits,
                kvGroup: runtime.kvGroup,
                quantStart: runtime.quantStart,
                maxKV: runtime.maxKV,
                prefillStep: runtime.prefillStep
            )
            let additionalContext: [String: any Sendable]? =
                generation.modelOptions["disableThinking"]?.boolValue == true
                ? ["enable_thinking": false] : nil
            let fullInput = MLXLMCommon.UserInput(
                chat: chat,
                processing: .init(),
                tools: toolsSpec,
                additionalContext: additionalContext
            )
            let fullLMInput: LMInput
            do {
                fullLMInput = try await context.processor.prepare(input: fullInput)
            } catch {
                let detail =
                    (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                throw NSError(
                    domain: "MLXGenerationEngine",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Chat template error: \(detail)"]
                )
            }

            var contextWithEOS = context
            let existing = context.configuration.extraEOSTokens
            let extra: Set<String> = Set(["</end_of_turn>", "<end_of_turn>", "<|end|>", "<eot>"])
            contextWithEOS.configuration.extraEOSTokens = existing.union(extra)

            let newPromptTokens = fullLMInput.text.tokens.asArray(Int.self)
            engineLog.info(
                "prepareAndGenerate: promptTokens=\(newPromptTokens.count, privacy: .public) hasImage=\(fullLMInput.image != nil, privacy: .public)"
            )
            guard !newPromptTokens.isEmpty else {
                throw NSError(
                    domain: "MLXGenerationEngine",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Tokenizer produced no tokens for the given input"]
                )
            }
            var cache: [any KVCache]
            var effectiveInput = fullLMInput

            if let existingCache = existingCache, let cachedTokens = cachedTokens, fullLMInput.image == nil,
                fullLMInput.video == nil
            {
                // Find common prefix length
                var commonPrefixLength = zip(newPromptTokens, cachedTokens).prefix(while: { $0 == $1 }).count

                // We must pass at least 1 token to the model to start generation
                if commonPrefixLength == newPromptTokens.count && commonPrefixLength > 0 {
                    commonPrefixLength -= 1
                }

                // Trim cache if needed.
                // Use effectiveCacheOffset() to skip MambaCache/ArraysCache layers (offset always 0).
                let cacheOffset = effectiveCacheOffset(existingCache)
                // Log tokens around the divergence point to diagnose chat-template differences
                let divergeIdx = commonPrefixLength
                let loStart = max(0, divergeIdx - 2)
                let loEnd = min(min(newPromptTokens.count, cachedTokens.count), divergeIdx + 4)
                if loEnd > loStart {
                    let newSlice = Array(newPromptTokens[loStart ..< loEnd])
                    let cachedSlice = Array(cachedTokens[loStart ..< loEnd])
                    debugLog(
                        "[MLXGenerationEngine] diverge@\(divergeIdx): new[\(loStart)..<\(loEnd)]=\(newSlice) cached[\(loStart)..<\(loEnd)]=\(cachedSlice)"
                    )
                }
                debugLog(
                    "[MLXGenerationEngine] cache reuse: newTokens=\(newPromptTokens.count) cachedTokens=\(cachedTokens.count) commonPrefix=\(commonPrefixLength) cacheOffset=\(cacheOffset) canTrim=\(canTrimPromptCache(existingCache))"
                )
                if commonPrefixLength > cacheOffset {
                    commonPrefixLength = cacheOffset
                }

                if commonPrefixLength < cacheOffset {
                    let toTrim = cacheOffset - commonPrefixLength
                    if canTrimPromptCache(existingCache) {
                        for layerCache in existingCache {
                            _ = layerCache.trim(toTrim)
                        }
                        cache = existingCache
                        debugLog("[MLXGenerationEngine] trimmed cache by \(toTrim) tokens, reusing")
                    } else {
                        // If cache cannot be trimmed, we must discard it
                        cache = makePromptCache(model: context.model, parameters: parameters)
                        commonPrefixLength = 0
                        debugLog("[MLXGenerationEngine] cache not trimmable, full prefill")
                    }
                } else {
                    cache = existingCache
                    debugLog("[MLXGenerationEngine] cache offset matches, reusing directly")
                }

                // Slice input to only evaluate new tokens.
                // Use effectiveCacheOffset to account for hybrid models where cache[0] may be
                // a MambaCache (offset always 0) and the true offset lives in a later layer.
                if commonPrefixLength > 0 && commonPrefixLength < newPromptTokens.count && !cache.isEmpty
                    && effectiveCacheOffset(cache) > 0
                {
                    let newTokens = MLXArray(Array(newPromptTokens[commonPrefixLength...]))
                    effectiveInput = LMInput(
                        text: .init(tokens: newTokens),
                        image: fullLMInput.image,
                        video: fullLMInput.video
                    )
                    debugLog("[MLXGenerationEngine] sliced input to \(newTokens.shape) new tokens")
                }
            } else {
                // Cannot reuse cache (e.g. VLM with images, or no cached tokens)
                cache = makePromptCache(model: context.model, parameters: parameters)
                debugLog(
                    "[MLXGenerationEngine] no existing cache, full prefill. existingCache=\(existingCache != nil) cachedTokens=\(cachedTokens?.count ?? -1)"
                )
            }

            // ── Two-phase prefill ──────────────────────────────────────────────────────
            //
            // Problem: hybrid models like Qwen3.5 have MambaCache layers (isTrimmable=false).
            // The standard single-phase path stores a snapshot keyed by `newPromptTokens`,
            // which includes the generation-prefix tokens (e.g. `<|im_start|>assistant\n<think>\n`).
            // On the next turn the chat template does NOT include `<think>` in completed turns, so
            // the common prefix diverges 3 tokens before the end → toTrim=3, MambaCache can't trim
            // → full re-prefill every turn.
            //
            // Fix: when the model has non-trimmable caches and a generation prefix exists, split
            // prefill into two phases so we can snapshot at the stable boundary (before gen-prefix):
            //
            //   Phase 1: prefill `stableTokens` (all history, no gen-prefix)
            //            → deepCopy cache as snapshotCache, keyed by snapshotTokens
            //   Phase 2: feed gen-prefix tokens through model → sample first token y0
            //            → build TokenIterator seeded with y0 (cache already at full N)
            //            → prepend y0 to the generated stream
            //
            // This way the stored snapshot matches the next turn's common prefix exactly, so
            // cacheOffset == commonPrefix → toTrim == 0 → no trim needed on any cache type.

            // Only attempt two-phase when there's no image/video input (text-only path).
            let canAttemptTwoPhase = fullLMInput.image == nil && fullLMInput.video == nil

            // Whether the *model* has non-trimmable (MambaCache) layers.
            // We must check against the model's actual cache type, not `cache` — because by this
            // point the cache-reuse block above may have already replaced `cache` with a fresh
            // makePromptCache() allocation (which is all KVCacheSimple and appears trimmable),
            // while the existingCache that was passed in (or a probe) reflects the real model type.
            let modelCacheIsNonTrimmable: Bool = {
                if let ec = existingCache { return !canTrimPromptCache(ec) }
                // No prior cache — probe with a throwaway to determine model type.
                let probe = makePromptCache(model: context.model, parameters: parameters)
                return !canTrimPromptCache(probe)
            }()

            // Tokenize the stable boundary (add_generation_prompt=false) to measure gen-prefix length.
            // We pass the same additionalContext but override add_generation_prompt.
            var stableTokenCount = newPromptTokens.count  // default: no gen-prefix
            if canAttemptTwoPhase && modelCacheIsNonTrimmable {
                var stableCtx: [String: any Sendable] = additionalContext ?? [:]
                stableCtx["add_generation_prompt"] = false
                let stableInput = MLXLMCommon.UserInput(
                    chat: chat,
                    processing: .init(),
                    tools: toolsSpec,
                    additionalContext: stableCtx
                )
                if let stableLMInput = try? await context.processor.prepare(input: stableInput) {
                    stableTokenCount = stableLMInput.text.tokens.asArray(Int.self).count
                }
            }

            let genPrefixLen = newPromptTokens.count - stableTokenCount
            // existingCache != nil guard: on turn 1 there is no prior cache to reuse,
            // so deep-copying the full prefill cache would double peak RAM and OOM on large
            // system prompts (~3700+ tokens with Qwen3.5-9B-4bit).  On turn 1 the single-phase
            // path already stores a snapshot via snapshotCacheOverride after generation, so turn 2
            // will find a cache hit and use two-phase correctly.
            let useTwoPhase =
                canAttemptTwoPhase && genPrefixLen > 0 && modelCacheIsNonTrimmable
                && existingCache != nil

            debugLog(
                "[MLXGenerationEngine] twoPhase=\(useTwoPhase) genPrefixLen=\(genPrefixLen) stableTokens=\(stableTokenCount) canTrim=\(canTrimPromptCache(cache)) hasExisting=\(existingCache != nil)"
            )

            if useTwoPhase {
                // ── Phase 1: prefill stableTokens ─────────────────────────────────────
                // effectiveInput may already be sliced (cache reuse path); recompute against
                // stableTokenCount to find what still needs processing.
                let currentOffset = effectiveCacheOffset(cache)
                let stableSliceStart = currentOffset  // cache already covers this many tokens
                let stableSliceEnd = stableTokenCount

                if stableSliceStart < stableSliceEnd {
                    let stableTokens = Array(newPromptTokens[stableSliceStart ..< stableSliceEnd])
                    let stableInput = LMInput(text: .init(tokens: MLXArray(stableTokens)))
                    // model.prepare() handles chunked prefill internally with Memory.clearCache()
                    // between chunks. Also resets VLM position state (ropeDeltas /
                    // precomputedPositionIds) from the previous turn on the first call.
                    let prepResult = try contextWithEOS.model.prepare(
                        stableInput,
                        cache: cache,
                        windowSize: runtime.prefillStep
                    )
                    if case .tokens(let remainder) = prepResult, remainder.tokens.size > 0 {
                        _ = try withError {
                            contextWithEOS.model(
                                LMInput.Text(tokens: remainder.tokens[.newAxis]),
                                cache: cache.isEmpty ? nil : cache,
                                state: nil
                            )
                        }
                    }
                    try withError { eval(cache) }
                }

                // Deep-copy cache at stable boundary for snapshot storage.
                let snapCache = KVCacheStore.deepCopyCache(cache)
                let snapTokens = Array(newPromptTokens[0 ..< stableTokenCount])
                debugLog(
                    "[MLXGenerationEngine] twoPhase phase1 done: stableOffset=\(effectiveCacheOffset(cache)) snapTokens=\(snapTokens.count)"
                )

                // ── Phase 2: feed gen-prefix tokens, sample y0 ────────────────────────
                let genPrefixTokens = Array(newPromptTokens[stableTokenCount...])
                let genPrefixText = LMInput.Text(tokens: MLXArray(genPrefixTokens)[.newAxis])
                let genPrefixOutput = try withError {
                    let output = contextWithEOS.model(
                        genPrefixText,
                        cache: cache.isEmpty ? nil : cache,
                        state: nil
                    )
                    eval(cache)
                    return output
                }

                // Sample y0 from the logits of the last gen-prefix token.
                let sampler = parameters.sampler()
                var processor = parameters.processor()
                let y0 = try withError {
                    processor?.prompt(MLXArray(newPromptTokens))
                    var genLogits = genPrefixOutput.logits[0..., -1, 0...]
                    genLogits = processor?.process(logits: genLogits) ?? genLogits
                    let y0Array = sampler.sample(logits: genLogits)
                    processor?.didSample(token: y0Array)
                    return y0Array.item(Int.self)
                }
                debugLog("[MLXGenerationEngine] twoPhase phase2: y0=\(y0) cacheOffset=\(effectiveCacheOffset(cache))")

                let postPrefillOffset = effectiveCacheOffset(cache)
                debugLog(
                    "[MLXGenerationEngine] twoPhase post-prefill effectiveCacheOffset=\(postPrefillOffset)"
                )

                // Build stop-token set for EOS detection.
                var stopTokenIDs: Set<Int> = contextWithEOS.configuration.eosTokenIds
                if let tokenizerEOS = contextWithEOS.tokenizer.eosTokenId {
                    stopTokenIDs.insert(tokenizerEOS)
                }
                for token in contextWithEOS.configuration.extraEOSTokens {
                    if let id = contextWithEOS.tokenizer.convertTokenToId(token) {
                        stopTokenIDs.insert(id)
                    }
                }

                // Manual generation loop — avoids TokenIterator which calls model.prepare()
                // and resets internal VLM position state (ropeDeltas / precomputedPositionIds).
                final class LoopState: @unchecked Sendable {
                    let model: any LanguageModel
                    let cache: [any KVCache]
                    var processor: (any LogitProcessor)?
                    let sampler: any LogitSampler
                    init(_ m: any LanguageModel, _ c: [any KVCache], _ p: (any LogitProcessor)?, _ s: any LogitSampler)
                    {
                        model = m; cache = c; processor = p; sampler = s
                    }
                }
                let loop = LoopState(contextWithEOS.model, cache, processor, sampler)
                let unknownTokenId = contextWithEOS.tokenizer.unknownTokenId
                let maxTokens = parameters.maxTokens
                let promptTokenCount = newPromptTokens.count

                let (genStream, genContinuation) = AsyncStream<MLXLMCommon.TokenGeneration>.makeStream()
                let genTask = Task {
                    let performGeneration = {
                        let genStart = Date.timeIntervalSinceReferenceDate
                        var tokenCount = 0
                        var currentToken = y0
                        var stopReason: MLXLMCommon.GenerateStopReason = .stop

                        let isY0Stop = currentToken == unknownTokenId || stopTokenIDs.contains(currentToken)
                        if !isY0Stop {
                            genContinuation.yield(.token(currentToken))
                            tokenCount += 1
                        }

                        if !isY0Stop {
                            while true {
                                if Task.isCancelled { stopReason = .cancelled; break }
                                if let max = maxTokens, tokenCount >= max { stopReason = .length; break }

                                let nextToken: Int
                                do {
                                    nextToken = try withError {
                                        let logits = loop.model(
                                            MLXArray([currentToken])[.newAxis],
                                            cache: loop.cache.isEmpty ? nil : loop.cache
                                        )
                                        eval(loop.cache)
                                        var nextLogits = logits[0..., -1, 0...]
                                        nextLogits = loop.processor?.process(logits: nextLogits) ?? nextLogits
                                        let nextArr = loop.sampler.sample(logits: nextLogits)
                                        loop.processor?.didSample(token: nextArr)
                                        return nextArr.item(Int.self)
                                    }
                                } catch { stopReason = .cancelled; break }

                                if nextToken == unknownTokenId || stopTokenIDs.contains(nextToken) {
                                    stopReason = .stop; break
                                }

                                genContinuation.yield(.token(nextToken))
                                tokenCount += 1
                                currentToken = nextToken
                            }
                        }

                        let generateTime = Date.timeIntervalSinceReferenceDate - genStart
                        genContinuation.yield(
                            .info(
                                MLXLMCommon.GenerateCompletionInfo(
                                    promptTokenCount: promptTokenCount,
                                    generationTokenCount: tokenCount,
                                    promptTime: 0,
                                    generationTime: generateTime,
                                    stopReason: stopReason
                                )
                            )
                        )
                        genContinuation.finish()
                    }

                    if let ticket = wiredMemoryTicket {
                        await WiredMemoryTicket.withWiredLimit(ticket) {
                            performGeneration()
                        }
                    } else {
                        performGeneration()
                    }
                }
                genContinuation.onTermination = { @Sendable _ in genTask.cancel() }

                engineLog.info("prepareAndGenerate: twoPhase stream created, returning")

                let toolCallFormat = contextWithEOS.configuration.toolCallFormat ?? .json
                return ResultBox(
                    genStream,
                    contextWithEOS.tokenizer,
                    CacheBox(cache),
                    newPromptTokens,
                    genTask,
                    toolCallFormat,
                    CacheBox(snapCache),
                    snapTokens
                )
            }

            // ── Single-phase (standard) path ──────────────────────────────────────────
            engineLog.info(
                "prepareAndGenerate: constructing TokenIterator effectiveTokens=\(effectiveInput.text.tokens.dim(0), privacy: .public)"
            )
            let iterator = try withError {
                try TokenIterator(
                    input: effectiveInput,
                    model: contextWithEOS.model,
                    cache: cache,
                    parameters: parameters
                )
            }
            let postPrefillOffset = effectiveCacheOffset(cache)
            debugLog(
                "[MLXGenerationEngine] post-prefill effectiveCacheOffset=\(postPrefillOffset) cacheCount=\(cache.count) cacheTypes=\(cache.prefix(4).map { type(of: $0) })"
            )
            engineSignposter.emitEvent(
                "prefillComplete",
                id: engineSignposter.makeSignpostID(),
                "promptTokens: \(newPromptTokens.count, privacy: .public), effectiveTokens: \(effectiveInput.text.tokens.dim(0), privacy: .public), cacheOffset: \(postPrefillOffset, privacy: .public)"
            )
            let (stream, genTask) = MLXLMCommon.generateTokenTask(
                promptTokenCount: newPromptTokens.count,
                modelConfiguration: contextWithEOS.configuration,
                tokenizer: contextWithEOS.tokenizer,
                iterator: iterator,
                wiredMemoryTicket: wiredMemoryTicket
            )
            engineLog.info("prepareAndGenerate: generateTokenTask created, returning stream")

            let toolCallFormat = contextWithEOS.configuration.toolCallFormat ?? .json
            return ResultBox(
                stream,
                contextWithEOS.tokenizer,
                CacheBox(cache),
                newPromptTokens,
                genTask,
                toolCallFormat,
                nil,
                nil
            )
        }
        let durationMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        engineLog.info(
            "[perf] prepareAndGenerate durationMs=\(Int(durationMs), privacy: .public) promptTokens=\(result.promptTokens.count, privacy: .public)"
        )
        return (
            result.stream, result.tokenizer, result.cache.cache, result.promptTokens, result.genTask,
            result.toolCallFormat, result.snapshotCache?.cache, result.snapshotTokens
        )
    }
}
