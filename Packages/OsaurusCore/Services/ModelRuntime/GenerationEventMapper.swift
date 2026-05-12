//
//  GenerationEventMapper.swift
//  osaurus
//
//  Bridge from vmlx-swift-lm `Generation` events to osaurus's typed
//  `ModelRuntimeEvent`. Reasoning stripping, tool-call extraction, AND
//  text-level stop-sequence matching all live inside `BatchEngine.generate`,
//  so this layer is purely a translation step:
//
//    .chunk(text)     -> .tokens(text)         (pure user-visible answer)
//    .reasoning(text) -> .reasoning(text)      (chain-of-thought delta)
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

    /// True when `.reasoning` deltas are the user-visible answer, not a hidden
    /// chain-of-thought side channel.
    ///
    /// Ling is configured as a non-reasoning family in osaurus; if it leaks
    /// `<think>`, the stripped inner text is still visible answer text.
    /// MiniMax M2/M2.7 must stay on the reasoning rail when Thinking is on.
    /// The vmlx parser starts inside the prompt-side `<think>` block and
    /// transitions to content when the model emits `</think>`; promoting that
    /// rail to content hides the Thinking panel and breaks the UI contract.
    static func treatReasoningAsContent(modelName: String) -> Bool {
        ModelFamilyNames.isLingFamily(modelName)
    }

    /// Map a `Generation` stream into the typed `ModelRuntimeEvent` stream
    /// callers (HTTP handlers, ChatView, plugin runners) consume.
    ///
    /// - Parameter modelName: The resolved model id; used solely to decide
    ///   the reasoning-merge policy (see `treatReasoningAsContent`). Empty
    ///   string is safe — the family matchers default to `false` and the
    ///   stream behaves identically to the historical pass-through.
    static func map(
        events: AsyncStream<Generation>,
        modelName: String = ""
    ) -> AsyncThrowingStream<ModelRuntimeEvent, Error> {
        let mergeReasoning = treatReasoningAsContent(modelName: modelName)
        let suppressUnclosedReasoning = ModelFamilyNames.isLingFamily(modelName)
        return AsyncThrowingStream<ModelRuntimeEvent, Error> { continuation in
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

                for await event in events {
                    if case .info(let info) = event {
                        sawCompletionInfo = true
                        finalTokenCount = info.generationTokenCount
                        logCompletionInfo(info)
                        continuation.yield(
                            .completionInfo(
                                tokenCount: info.generationTokenCount,
                                tokensPerSecond: info.tokensPerSecond,
                                unclosedReasoning: suppressUnclosedReasoning
                                    ? false
                                    : info.unclosedReasoning
                            )
                        )
                        continue
                    }

                    if Task.isCancelled { break }
                    switch event {
                    case .chunk(let text):
                        if firstChunk {
                            firstChunk = false
                            InferenceProgressManager.shared.prefillDidFinishAsync()
                        }
                        guard !text.isEmpty else { continue }
                        estimatedTextTokens += max(1, text.count / 4)
                        continuation.yield(.tokens(text))

                    case .reasoning(let text):
                        guard !text.isEmpty else { continue }
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
                        if mergeReasoning {
                            // vmlx already stripped the family-specific
                            // reasoning markers; for merge families the inner
                            // text is plain visible content.
                            continuation.yield(.tokens(text))
                        } else {
                            continuation.yield(.reasoning(text))
                        }

                    case .toolCall(let call):
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
                            unclosedReasoning: sawReasoning && !suppressUnclosedReasoning
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
                InferenceProgressManager.shared.prefillDidFinishAsync()
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Helpers

    /// One log line + one signpost event per completion. Pulled out of
    /// `map` so the per-event switch reads as the wire-format translation
    /// it actually is.
    private static func logCompletionInfo(_ info: GenerateCompletionInfo) {
        mapperLog.info(
            "[perf] mlxStats promptTokens=\(info.promptTokenCount, privacy: .public) promptTps=\(info.promptTokensPerSecond, privacy: .public) promptMs=\(Int(info.promptTime * 1000), privacy: .public) genTokens=\(info.generationTokenCount, privacy: .public) genTps=\(info.tokensPerSecond, privacy: .public) genMs=\(Int(info.generateTime * 1000), privacy: .public) stop=\(String(describing: info.stopReason), privacy: .public) unclosedReasoning=\(info.unclosedReasoning, privacy: .public)"
        )
        mapperSignposter.emitEvent(
            "mlxStats",
            id: .exclusive,
            "prompt: \(info.promptTokenCount, privacy: .public) tok \(info.promptTokensPerSecond, privacy: .public) tok/s | gen: \(info.generationTokenCount, privacy: .public) tok \(info.tokensPerSecond, privacy: .public) tok/s"
        )
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
            let data = try JSONSerialization.data(withJSONObject: anyDict)
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
