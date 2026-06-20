//
//  GenerationEventMapper.swift
//  osaurus
//
//  Bridge from vmlx-swift `Generation` events to osaurus's typed
//  `ModelRuntimeEvent`. Reasoning stripping, tool-call extraction, AND
//  text-level stop-sequence matching all live inside `BatchEngine.generate`,
//  so this layer is purely a translation step:
//
//    .chunk(text)     -> .tokens(text)         (pure user-visible answer)
//    .reasoning(text) -> .reasoning(text)      (chain-of-thought delta)
//    .prefillProgress -> .prefillProgress(...) (prompt-processing progress)
//    .toolCall(call)  -> .toolInvocation(...)  (parsed tool envelope)
//    .info(info)      -> .completionInfo(...)  (final stats / stopReason)
//
//  Stop sequences are enforced by the library via
//  `GenerateParameters.extraStopStrings` — when one matches, the engine
//  emits the safe prefix as `.chunk`, halts generation, and finishes the
//  stream with `.info(stopReason: .stop)`. Osaurus never inspects chunk
//  text for stop-sequence matches.
//

import Foundation
@preconcurrency import MLXLMCommon
import os.log

private let mapperSignposter = OSSignposter(subsystem: "ai.osaurus", category: "Generation")
private let mapperLog = Logger(subsystem: "ai.osaurus", category: "Generation")

enum GenerationEventMapper {

    /// Map a `Generation` stream into the typed `ModelRuntimeEvent` stream
    /// callers (HTTP handlers, ChatView, plugin runners) consume.
    ///
    /// - Parameter modelName: The resolved model id; used for telemetry only.
    ///   Family-specific reasoning repair belongs in the vmlx parser/template
    ///   path, not in this translation layer. If a no-thinking request still
    ///   emits `.reasoning`, Osaurus keeps that signal visible for root-cause
    ///   debugging instead of merging or suppressing it.
    static func map(
        events: AsyncStream<Generation>,
        modelName: String = "",
        trace: TTFTTrace? = nil
    ) -> AsyncThrowingStream<ModelRuntimeEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ModelRuntimeEvent, Error>.makeStream()
        let task = Task {
            let interval = mapperSignposter.beginInterval(
                "generation",
                id: mapperSignposter.makeSignpostID()
            )
            let startedAt = CFAbsoluteTimeGetCurrent()
            var firstChunk = true
            var finalTokenCount = 0
            var sawCompletionInfo = false
            var sawReasoning = false
            var estimatedTextTokens = 0
            var markedFirstModelOutput = false
            // Prefill diagnostics: log only on stage CHANGE so we see the
            // cacheRestore→prefill split (how many tokens were restored from
            // cache vs freshly processed) without a line per progress tick.
            var lastPrefillStage: String?
            // Decode diagnostics: first-output wall-clock + whether this step
            // ended in a tool call. Tool-call steps tear down the stream before
            // vmlx emits `.info`, so STEP-STATS never fires for them — the
            // STEP-DECODE line at stream end covers those steps instead.
            var firstOutputAt: CFAbsoluteTime?
            var sawToolCall = false

            func markFirstModelOutput() {
                guard !markedFirstModelOutput else { return }
                markedFirstModelOutput = true
                firstOutputAt = CFAbsoluteTimeGetCurrent()
                let ms = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                trace?.set("first_token_ms", ms)
                trace?.mark("first_model_output")
            }

            for await event in events {
                if case .info(let info) = event {
                    sawCompletionInfo = true
                    finalTokenCount = info.generationTokenCount
                    logCompletionInfo(info)
                    continuation.yield(
                        .completionInfo(
                            tokenCount: info.generationTokenCount,
                            tokensPerSecond: info.tokensPerSecond,
                            unclosedReasoning: info.unclosedReasoning,
                            stopReason: Self.openAIStopReason(from: info.stopReason),
                            promptTokensPerSecond: info.promptTokensPerSecond
                        )
                    )
                    continue
                }

                if Task.isCancelled { break }
                switch event {
                case .chunk(let text):
                    guard !text.isEmpty else { continue }
                    markFirstModelOutput()
                    if firstChunk {
                        firstChunk = false
                        InferenceProgressManager.shared.prefillDidFinishAsync()
                    }
                    estimatedTextTokens += max(1, text.count / 4)
                    continuation.yield(.tokens(text))

                case .reasoning(let text):
                    guard !text.isEmpty else { continue }
                    markFirstModelOutput()
                    sawReasoning = true
                    estimatedTextTokens += max(1, text.count / 4)
                    // Reasoning-capable families (DSV4-Flash thinking,
                    // Qwen 3.5 / 3.6 thinking-on, etc.) can stream
                    // `.reasoning` deltas for many seconds before the
                    // first `.chunk`. Marking prefill done on the
                    // first non-empty event of either kind keeps the
                    // "loading model" / spinner UI honest — the model
                    // IS producing output, just on a different
                    // channel.
                    if firstChunk {
                        firstChunk = false
                        InferenceProgressManager.shared.prefillDidFinishAsync()
                    }
                    continuation.yield(.reasoning(text))

                case .prefillProgress(let progress):
                    let state = PrefillProgressState(
                        stage: PrefillProgressStage(rawValue: progress.stage.rawValue) ?? .prefill,
                        completedUnitCount: progress.completedUnitCount,
                        totalUnitCount: progress.totalUnitCount,
                        detail: progress.detail
                    )
                    InferenceProgressManager.shared.prefillDidUpdateAsync(state)
                    if state.stage.rawValue != lastPrefillStage {
                        lastPrefillStage = state.stage.rawValue
                        PrefillDebugLog.shared.log(
                            "     STEP-PREFILL stage=\(state.stage.rawValue) "
                                + "completed=\(state.completedUnitCount)/\(state.totalUnitCount)"
                                + (state.detail.map { " detail=\($0)" } ?? "")
                        )
                    }
                    continuation.yield(.prefillProgress(state))

                case .toolCall(let call):
                    sawToolCall = true
                    markFirstModelOutput()
                    let argsJSON = serializeArguments(
                        call.function.arguments,
                        toolName: call.function.name
                    )
                    continuation.yield(
                        .toolInvocation(name: call.function.name, argsJSON: argsJSON)
                    )

                case .info:
                    continue

                @unknown default:
                    // Forward-compat: unknown future cases are skipped
                    // so a library bump cannot leak raw markers to the UI.
                    continue
                }
            }

            if !sawCompletionInfo {
                finalTokenCount = estimatedTextTokens
                mapperLog.notice(
                    "generation stream ended without vmlx completion info; synthesizing stats model=\(modelName, privacy: .public) estimatedTokens=\(estimatedTextTokens, privacy: .public) unclosedReasoning=\(sawReasoning, privacy: .public)"
                )
                continuation.yield(
                    .completionInfo(
                        tokenCount: estimatedTextTokens,
                        tokensPerSecond: 0,
                        unclosedReasoning: sawReasoning,
                        stopReason: nil,
                        promptTokensPerSecond: 0
                    )
                )
            }

            let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            mapperSignposter.endInterval(
                "generation",
                interval,
                "\(finalTokenCount, privacy: .public) tokens"
            )
            mapperLog.info(
                "[perf] generation durationMs=\(durationMs, privacy: .public) tokenCount=\(finalTokenCount, privacy: .public)"
            )

            // Decode diagnostics: per-step decode timing for EVERY step,
            // including tool-call steps that never reach `.info`. ttftMs is
            // prefill+queue time to first output; decodeMs/decodeTps cover the
            // generation itself. genTokens is exact when vmlx info arrived,
            // otherwise an estimate (text/reasoning only — tool-call arg tokens
            // are not counted).
            let nowEnd = CFAbsoluteTimeGetCurrent()
            let ttftMs = firstOutputAt.map { Int(($0 - startedAt) * 1000) }
            let decodeMs = firstOutputAt.map { Int((nowEnd - $0) * 1000) }
            let decodeTps =
                (firstOutputAt != nil && decodeMs! > 0)
                ? Double(finalTokenCount) / (Double(decodeMs!) / 1000.0)
                : 0
            PrefillDebugLog.shared.log(
                "     STEP-DECODE endedInToolCall=\(sawToolCall) "
                    + "ttftMs=\(ttftMs.map(String.init) ?? "?") decodeMs=\(decodeMs.map(String.init) ?? "?") "
                    + "genTokens=\(finalTokenCount)\(sawCompletionInfo ? "" : "(est)") "
                    + "decodeTps=\(String(format: "%.1f", decodeTps)) totalMs=\(durationMs)"
            )

            InferenceProgressManager.shared.prefillDidFinishAsync()
            continuation.finish()
        }
        continuation.onTermination = { @Sendable _ in
            task.cancel()
        }
        return stream
    }

    // MARK: - Helpers

    /// One log line + one signpost event per completion. Pulled out of
    /// `map` so the per-event switch reads as the wire-format translation
    /// it actually is.
    private static func logCompletionInfo(_ info: GenerateCompletionInfo) {
        mapperLog.info(
            "[perf] mlxStats promptTokens=\(info.promptTokenCount, privacy: .public) promptTps=\(info.promptTokensPerSecond, privacy: .public) promptMs=\(Int(info.promptTime * 1000), privacy: .public) genTokens=\(info.generationTokenCount, privacy: .public) genTps=\(info.tokensPerSecond, privacy: .public) genMs=\(Int(info.generateTime * 1000), privacy: .public) stop=\(String(describing: info.stopReason), privacy: .public) unclosedReasoning=\(info.unclosedReasoning, privacy: .public)"
        )

        // Prefill diagnostics: vmlx's actual processed-prompt count + prefill
        // timing for this step, then the cumulative cache counters AFTER it.
        // Compare promptTokens here against the STEP-BEGIN tokenizedPrompt: a
        // smaller value means the KV prefix was reused rather than re-prefilled.
        let promptTokens = info.promptTokenCount
        let promptTps = info.promptTokensPerSecond
        let promptMs = Int(info.promptTime * 1000)
        let genTokens = info.generationTokenCount
        let genTps = info.tokensPerSecond
        PrefillDebugLog.shared.log(
            "     STEP-STATS promptTokens=\(promptTokens) promptMs=\(promptMs) "
                + "promptTps=\(String(format: "%.1f", promptTps)) genTokens=\(genTokens) "
                + "genTps=\(String(format: "%.1f", genTps)) stop=\(String(describing: info.stopReason))"
        )
        if PrefillDebugLog.shared.isEnabled {
            Task.detached {
                guard let after = await MLXBatchAdapter.snapshotDiagnostics() else { return }
                PrefillDebugLog.shared.log(
                    "     STEP-END   cacheAfter{prefixHits=\(after.prefixHits) "
                        + "prefixMisses=\(after.prefixMisses) diskL2Hits=\(after.diskL2Hits) "
                        + "diskL2Misses=\(after.diskL2Misses) diskL2Stores=\(after.diskL2Stores)}"
                )
            }
        }
        mapperSignposter.emitEvent(
            "mlxStats",
            id: .exclusive,
            "prompt: \(info.promptTokenCount, privacy: .public) tok \(info.promptTokensPerSecond, privacy: .public) tok/s | gen: \(info.generationTokenCount, privacy: .public) tok \(info.tokensPerSecond, privacy: .public) tok/s"
        )
    }

    private static func openAIStopReason(from stopReason: GenerateStopReason) -> String {
        switch stopReason {
        case .stop:
            return "stop"
        case .length:
            return "length"
        case .cancelled:
            return "cancelled"
        }
    }

    /// Convert vmlx's `[String: JSONValue]` argument map to a compact JSON
    /// string suitable for `ModelRuntimeEvent.toolInvocation(argsJSON:)`.
    /// On serialization failure, returns a structured error envelope so the
    /// model and the executor both see something they can react to instead
    /// of silently swallowing the argument set.
    private static func serializeArguments(
        _ arguments: [String: MLXLMCommon.JSONValue],
        toolName: String
    ) -> String {
        let anyDict = arguments.mapValues { $0.anyValue }
        // Pre-validate the dictionary: `JSONSerialization.data(...)` raises
        // an Objective-C `NSException` (not a Swift `Error`) when given
        // non-finite Doubles, NaN, or other invalid values — Swift `catch`
        // cannot intercept it and the process aborts. Checking
        // `isValidJSONObject` first ensures we always exit through the
        // structured envelope path instead of crashing the runtime.
        guard JSONSerialization.isValidJSONObject(anyDict) else {
            mapperLog.error(
                "[tools] arguments for \(toolName, privacy: .public) failed JSON validation (non-finite number, unsupported type, or non-string key)"
            )
            return errorEnvelope(toolName: toolName)
        }
        do {
            // Sorted keys: replayed verbatim into the next turn's
            // `tool_calls[].function.arguments`; unstable ordering would
            // invalidate the local KV prefix cache. See
            // `JSONDeterminism.swift`.
            let data = try JSONSerialization.data(withJSONObject: anyDict, options: .osaurusCanonical)
            if let json = String(data: data, encoding: .utf8) {
                return json
            }
            mapperLog.error(
                "[tools] arguments for \(toolName, privacy: .public) serialised to non-UTF8 data"
            )
        } catch {
            mapperLog.error(
                "[tools] failed to serialise arguments for \(toolName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
        return errorEnvelope(toolName: toolName)
    }

    /// Structured error envelope returned by `serializeArguments` on every
    /// failure path. Wire shape is intentionally a valid JSON object so MCP
    /// (and any other downstream tool runner) can detect the failure by
    /// looking for the `_error` field — `MCPProviderTool` already does so.
    private static func errorEnvelope(toolName: String) -> String {
        "{\"_error\":\"argument_serialization_failed\",\"_tool\":\"\(toolName)\"}"
    }
}
