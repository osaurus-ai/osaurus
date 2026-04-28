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

    /// Map a `Generation` stream into the typed `ModelRuntimeEvent` stream
    /// callers (HTTP handlers, ChatView, plugin runners) consume.
    static func map(
        events: AsyncStream<Generation>
    ) -> AsyncThrowingStream<ModelRuntimeEvent, Error> {
        AsyncThrowingStream<ModelRuntimeEvent, Error> { continuation in
            let task = Task {
                let interval = mapperSignposter.beginInterval(
                    "generation",
                    id: mapperSignposter.makeSignpostID()
                )
                let startedAt = CFAbsoluteTimeGetCurrent()
                var firstChunk = true
                var finalTokenCount = 0

                for await event in events {
                    if Task.isCancelled { break }
                    switch event {
                    case .chunk(let text):
                        if firstChunk {
                            firstChunk = false
                            InferenceProgressManager.shared.prefillDidFinishAsync()
                        }
                        guard !text.isEmpty else { continue }
                        continuation.yield(.tokens(text))

                    case .reasoning(let text):
                        guard !text.isEmpty else { continue }
                        continuation.yield(.reasoning(text))

                    case .toolCall(let call):
                        let argsJSON = serializeArguments(
                            call.function.arguments,
                            toolName: call.function.name
                        )
                        continuation.yield(
                            .toolInvocation(name: call.function.name, argsJSON: argsJSON)
                        )

                    case .info(let info):
                        finalTokenCount = info.generationTokenCount
                        logCompletionInfo(info)
                        continuation.yield(
                            .completionInfo(
                                tokenCount: info.generationTokenCount,
                                tokensPerSecond: info.tokensPerSecond,
                                unclosedReasoning: info.unclosedReasoning
                            )
                        )

                    @unknown default:
                        // Forward-compat: unknown future cases are skipped
                        // so a library bump cannot leak raw markers to the UI.
                        continue
                    }
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
