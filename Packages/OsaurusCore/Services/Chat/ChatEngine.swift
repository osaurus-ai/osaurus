//
//  ChatEngine.swift
//  osaurus
//
//  Actor encapsulating model routing and generation streaming.
//

import Foundation

actor ChatEngine: Sendable, ChatEngineProtocol {
    private let services: [ModelService]
    private let installedModelsProvider: @Sendable () -> [String]

    /// Source of the inference (for logging purposes)
    private var inferenceSource: InferenceSource = .httpAPI

    init(
        services: [ModelService] = [FoundationModelService(), MLXService()],
        installedModelsProvider: @escaping @Sendable () -> [String] = {
            MLXService.getAvailableModels()
        },
        source: InferenceSource = .httpAPI
    ) {
        self.services = services
        self.installedModelsProvider = installedModelsProvider
        self.inferenceSource = source
    }
    /// Errors thrown by `ChatEngine` that carry a classification so the
    /// HTTP layer can emit a proper 4xx/5xx instead of a generic 500.
    /// Before this type was specialized, `EngineError` was an empty
    /// struct `{}` and every failure (unknown model, routing collapse,
    /// etc.) surfaced as HTTP 500 → consumers labelled it "Server Error
    /// / service temporarily unavailable" when the real cause was user
    /// input (issue #858).
    struct EngineError: Error, LocalizedError {
        enum Kind {
            /// No service or remote provider could handle the requested model ID.
            /// Maps to HTTP 404 (or 400 if you prefer "bad request"; we use 404
            /// because the resource — the model — is what's missing).
            case modelNotFound(requested: String)
            /// Routing returned `.none` for a non-empty model request for some
            /// other reason (e.g. provider marked disconnected). Maps to 503.
            case noServiceAvailable(requested: String)
        }

        let kind: Kind

        var errorDescription: String? {
            switch kind {
            case .modelNotFound(let requested):
                return "Model '\(requested)' is not installed or registered with any provider."
            case .noServiceAvailable(let requested):
                return "No service is currently available to handle model '\(requested)'."
            }
        }

        /// The HTTP status code the API layer should return for this error.
        var httpStatus: Int {
            switch kind {
            case .modelNotFound: return 404
            case .noServiceAvailable: return 503
            }
        }
    }

    /// Estimate input tokens from messages (rough heuristic: ~4 chars per token).
    ///
    /// Includes assistant `tool_calls` payloads and `tool` role bodies so
    /// tool-heavy sessions don't under-report prompt size in metrics and
    /// downstream budget-adjacent decisions.
    /// Per-request dispatch context returned by `prepareDispatch`. Folds
    /// together the resolved `ModelRoute`, the `GenerationParameters` to
    /// pass to the route's service, and the snapshot of remote services
    /// fetched off the main actor. Both `streamChat` and `completeChat`
    /// share this prep step — the only divergence afterwards is whether
    /// they wrap the output in a stream wrapper or a single response.
    private struct Dispatch {
        let route: ModelRoute
        let params: GenerationParameters
        let remoteServices: [ModelService]
    }

    /// Build the shared dispatch context for `streamChat` / `completeChat`.
    /// Threads the optional `ttftTrace` so non-streaming callers carry the
    /// same trace as streaming ones (parity fix — `completeChat` used to
    /// drop the trace).
    private func prepareDispatch(
        request: ChatCompletionRequest,
        trace: TTFTTrace?
    ) async -> Dispatch {
        let temperature = request.temperature
        let maxTokens = request.max_tokens ?? 16384
        // Map only OpenAI `frequency_penalty` to repetition_penalty here.
        // `presence_penalty` has no MLX analog — leaving the previous
        // "either-or" mapping in place silently collapsed two distinct
        // knobs. Both raw values are forwarded on `GenerationParameters`
        // so remote services can pass them through natively.
        let repPenalty: Float? = {
            if let fp = request.frequency_penalty, fp > 0 { return 1.0 + fp }
            return nil
        }()
        let seedBits: UInt64? = request.seed.map { UInt64(bitPattern: Int64($0)) }
        let isJSONObject = (request.response_format?.type == "json_object")
        let params = GenerationParameters(
            temperature: temperature,
            maxTokens: maxTokens,
            topPOverride: request.top_p,
            repetitionPenalty: repPenalty,
            frequencyPenalty: request.frequency_penalty,
            presencePenalty: request.presence_penalty,
            seed: seedBits,
            jsonMode: isJSONObject,
            modelOptions: request.modelOptions ?? [:],
            sessionId: request.session_id,
            ttftTrace: trace
        )

        let services = self.services
        // Fetch remote services on the MainActor so routing reflects the
        // latest connected Bonjour/remote agents per request.
        trace?.mark("fetch_remote_services")
        let remoteServices = await MainActor.run {
            RemoteProviderManager.shared.connectedServices()
        }
        trace?.mark("route_resolve")
        let route = ModelServiceRouter.resolve(
            requestedModel: request.model,
            services: services,
            remoteServices: remoteServices
        )
        return Dispatch(route: route, params: params, remoteServices: remoteServices)
    }

    private func estimateInputTokens(_ messages: [ChatMessage]) -> Int {
        let totalChars = messages.reduce(0) { sum, msg in
            var chars = msg.content?.count ?? 0
            if let calls = msg.tool_calls {
                for call in calls {
                    chars += call.function.name.count
                    chars += call.function.arguments.count
                    // ~20 chars overhead per call for JSON envelope shape
                    chars += 20
                }
            }
            return sum + chars
        }
        return max(1, totalChars / 4)
    }

    /// Build a non-stream OpenAI-style response from one or more tool
    /// invocations parsed out of a single completion. Local models can emit
    /// multiple `<tool_call>` blocks per response; OpenAI clients expect a
    /// single assistant message with all `tool_calls` attached, which is
    /// what we produce here.
    static func makeToolCallResponse(
        invocations: [ServiceToolInvocation],
        responseId: String,
        created: Int,
        effectiveModel: String,
        inputTokens: Int,
        startTime: Date,
        inferenceSource: InferenceSource,
        temperature: Float?,
        maxTokens: Int
    ) -> ChatCompletionResponse {
        let toolCalls: [ToolCall] = invocations.map { inv in
            let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let callId = inv.toolCallId ?? "call_" + String(raw.prefix(24))
            return ToolCall(
                id: callId,
                type: "function",
                function: ToolCallFunction(name: inv.toolName, arguments: inv.jsonArguments),
                geminiThoughtSignature: inv.geminiThoughtSignature
            )
        }
        let assistant = ChatMessage(
            role: "assistant",
            content: nil,
            tool_calls: toolCalls,
            tool_call_id: nil
        )
        let choice = ChatChoice(index: 0, message: assistant, finish_reason: "tool_calls")
        let usage = Usage(prompt_tokens: inputTokens, completion_tokens: 0, total_tokens: inputTokens)

        if inferenceSource == .chatUI {
            let durationMs = Date().timeIntervalSince(startTime) * 1000
            InsightsService.logInference(
                source: inferenceSource,
                model: effectiveModel,
                inputTokens: inputTokens,
                outputTokens: 0,
                durationMs: durationMs,
                temperature: temperature,
                maxTokens: maxTokens,
                toolCalls: invocations.map {
                    ToolCallLog(name: $0.toolName, arguments: $0.jsonArguments)
                },
                finishReason: .toolCalls
            )
        }

        return ChatCompletionResponse(
            id: responseId,
            created: created,
            model: effectiveModel,
            choices: [choice],
            usage: usage,
            system_fingerprint: nil
        )
    }

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        debugLog("[ChatEngine] streamChat: start model=\(request.model)")
        let trace = request.ttftTrace
        trace?.mark("chatengine_start")
        let messages = request.messages
        debugLog("[ChatEngine] streamChat: messages count=\(messages.count), fetching remote services")

        // Tool diagnostics: log the final tool list (count + names + choice)
        // immediately before dispatch so silent "model didn't see the tools"
        // failures are easy to triage from logs.
        let toolNames = (request.tools ?? []).map { $0.function.name }.sorted()
        let toolChoiceDesc = request.tool_choice.map { String(describing: $0) } ?? "nil"
        debugLog(
            "[Tools] streamChat model=\(request.model) source=\(inferenceSource) count=\(toolNames.count) choice=\(toolChoiceDesc) names=[\(toolNames.joined(separator: ", "))]"
        )
        trace?.set("toolListSent", String(toolNames.count))

        // Pulled out for logging convenience; the actual dispatch values
        // (incl. these two) live on `dispatch.params`.
        let temperature = request.temperature
        let maxTokens = request.max_tokens ?? 16384

        let dispatch = await prepareDispatch(request: request, trace: trace)
        let params = dispatch.params
        let route = dispatch.route
        debugLog("[ChatEngine] streamChat: route=\(route)")

        switch route {
        case .service(let service, let effectiveModel):
            let innerStream: AsyncThrowingStream<String, Error>

            // If tools were provided and supported, use message-based tool streaming
            if let tools = request.tools, !tools.isEmpty, let toolSvc = service as? ToolCapableService {
                let stopSequences = request.stop ?? []
                debugLog("[ChatEngine] streamChat: calling streamWithTools tools=\(tools.count)")
                trace?.mark("chatengine_streamWithTools_start")
                innerStream = try await toolSvc.streamWithTools(
                    messages: messages,
                    parameters: params,
                    stopSequences: stopSequences,
                    tools: tools,
                    toolChoice: request.tool_choice,
                    requestedModel: request.model
                )
                trace?.mark("chatengine_streamWithTools_done")
                debugLog("[ChatEngine] streamChat: streamWithTools returned")
            } else {
                debugLog("[ChatEngine] streamChat: calling streamDeltas")
                trace?.mark("chatengine_streamDeltas_start")
                innerStream = try await service.streamDeltas(
                    messages: messages,
                    parameters: params,
                    requestedModel: request.model,
                    stopSequences: request.stop ?? []
                )
                trace?.mark("chatengine_streamDeltas_done")
                debugLog("[ChatEngine] streamChat: streamDeltas returned")
            }

            // Wrap stream to count tokens and log when complete
            let source = self.inferenceSource
            let inputTokens = estimateInputTokens(messages)
            let model = effectiveModel
            let temp = temperature
            let maxTok = maxTokens

            return wrapStreamWithLogging(
                innerStream,
                source: source,
                model: model,
                inputTokens: inputTokens,
                temperature: temp,
                maxTokens: maxTok
            )

        case .none:
            throw EngineError(kind: .modelNotFound(requested: request.model))
        }
    }

    /// Wraps an async stream to count output tokens and log on completion.
    /// Uses Task.detached to avoid actor isolation deadlocks when consumed from MainActor.
    /// Properly handles cancellation via onTermination handler to prevent orphaned tasks.
    private func wrapStreamWithLogging(
        _ inner: AsyncThrowingStream<String, Error>,
        source: InferenceSource,
        model: String,
        inputTokens: Int,
        temperature: Float?,
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()

        // Create the producer task and store reference for cancellation
        // IMPORTANT: Use Task.detached to run on cooperative thread pool instead of
        // ChatEngine actor's executor. This prevents deadlocks when the MainActor
        // consumes this stream while waiting for actor-isolated yields.
        let producerTask = Task.detached(priority: .userInitiated) {
            let startTime = Date()
            var outputTokenCount = 0
            var deltaCount = 0
            var finishReason: InferenceLog.FinishReason = .stop
            var errorMsg: String? = nil
            var toolInvocation: (name: String, args: String)? = nil
            var lastDeltaTime = startTime

            print("[Osaurus][Stream] Starting stream wrapper for model: \(model)")

            do {
                for try await delta in inner {
                    // Check for task cancellation to allow early termination
                    if Task.isCancelled {
                        print("[Osaurus][Stream] Task cancelled after \(deltaCount) deltas")
                        continuation.finish()
                        return
                    }

                    // Pass through tool-hint sentinels without counting as tokens
                    if StreamingToolHint.isSentinel(delta) {
                        continuation.yield(delta)
                        continue
                    }

                    deltaCount += 1
                    let now = Date()
                    let timeSinceStart = now.timeIntervalSince(startTime)
                    let timeSinceLastDelta = now.timeIntervalSince(lastDeltaTime)
                    lastDeltaTime = now

                    // Log every 50th delta or if there's a long gap (potential freeze indicator)
                    if deltaCount % 50 == 1 || timeSinceLastDelta > 2.0 {
                        print(
                            "[Osaurus][Stream] Delta #\(deltaCount): +\(String(format: "%.2f", timeSinceStart))s total, gap=\(String(format: "%.3f", timeSinceLastDelta))s, len=\(delta.count)"
                        )
                    }

                    // Estimate tokens: each delta chunk is roughly proportional to tokens
                    // More accurate: count whitespace-separated words, or use tokenizer
                    outputTokenCount += max(1, delta.count / 4)
                    continuation.yield(delta)
                }

                let totalTime = Date().timeIntervalSince(startTime)
                print(
                    "[Osaurus][Stream] Stream completed: \(deltaCount) deltas in \(String(format: "%.2f", totalTime))s"
                )

                continuation.finish()
            } catch let invs as ServiceToolInvocations {
                print("[Osaurus][Stream] Tool invocations (batch): count=\(invs.invocations.count)")
                if let first = invs.invocations.first {
                    toolInvocation = (first.toolName, first.jsonArguments)
                }
                finishReason = .toolCalls
                continuation.finish(throwing: invs)
            } catch let inv as ServiceToolInvocation {
                print("[Osaurus][Stream] Tool invocation: \(inv.toolName)")
                toolInvocation = (inv.toolName, inv.jsonArguments)
                finishReason = .toolCalls
                continuation.finish(throwing: inv)
            } catch {
                // Check if this is a CancellationError (expected when consumer stops)
                if Task.isCancelled || error is CancellationError {
                    print("[Osaurus][Stream] Stream cancelled after \(deltaCount) deltas")
                    continuation.finish()
                    return
                }
                print("[Osaurus][Stream] Stream error after \(deltaCount) deltas: \(error.localizedDescription)")
                finishReason = .error
                errorMsg = error.localizedDescription
                continuation.finish(throwing: error)
            }

            // Log the completed inference (only for Chat UI - HTTP requests are logged by HTTPHandler)
            if source == .chatUI {
                let durationMs = Date().timeIntervalSince(startTime) * 1000
                var toolCalls: [ToolCallLog]? = nil
                if let (name, args) = toolInvocation {
                    toolCalls = [ToolCallLog(name: name, arguments: args)]
                }

                InsightsService.logInference(
                    source: source,
                    model: model,
                    inputTokens: inputTokens,
                    outputTokens: outputTokenCount,
                    durationMs: durationMs,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    toolCalls: toolCalls,
                    finishReason: finishReason,
                    errorMessage: errorMsg
                )
            }
        }

        // Set up termination handler to cancel the producer task when consumer stops consuming
        // This ensures proper cleanup when the UI task is cancelled or completes early
        continuation.onTermination = { @Sendable termination in
            switch termination {
            case .cancelled:
                print("[Osaurus][Stream] Consumer cancelled - stopping producer task")
                producerTask.cancel()
            case .finished:
                // Normal completion, producer should already be done
                break
            @unknown default:
                producerTask.cancel()
            }
        }

        return stream
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        let startTime = Date()
        let messages = request.messages
        let inputTokens = estimateInputTokens(messages)
        let temperature = request.temperature
        let maxTokens = request.max_tokens ?? 16384
        // Carry the caller's `ttftTrace` through to non-streaming requests
        // for parity with `streamChat` — useful when an HTTP route runs the
        // same `request.ttftTrace` across both code paths.
        let dispatch = await prepareDispatch(request: request, trace: request.ttftTrace)
        let params = dispatch.params
        let route = dispatch.route

        let created = Int(Date().timeIntervalSince1970)
        let responseId =
            "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"

        switch route {
        case .service(let service, let effectiveModel):
            // If tools were provided and the service supports them, use the message-based API
            if let tools = request.tools, !tools.isEmpty, let toolSvc = service as? ToolCapableService {
                let stopSequences = request.stop ?? []
                do {
                    let text = try await toolSvc.respondWithTools(
                        messages: messages,
                        parameters: params,
                        stopSequences: stopSequences,
                        tools: tools,
                        toolChoice: request.tool_choice,
                        requestedModel: request.model
                    )
                    let outputTokens = max(1, text.count / 4)
                    let choice = ChatChoice(
                        index: 0,
                        message: ChatMessage(
                            role: "assistant",
                            content: text,
                            tool_calls: nil,
                            tool_call_id: nil
                        ),
                        finish_reason: "stop"
                    )
                    let usage = Usage(
                        prompt_tokens: inputTokens,
                        completion_tokens: outputTokens,
                        total_tokens: inputTokens + outputTokens
                    )

                    // Log the inference (only for Chat UI - HTTP requests are logged by HTTPHandler)
                    if inferenceSource == .chatUI {
                        let durationMs = Date().timeIntervalSince(startTime) * 1000
                        InsightsService.logInference(
                            source: inferenceSource,
                            model: effectiveModel,
                            inputTokens: inputTokens,
                            outputTokens: outputTokens,
                            durationMs: durationMs,
                            temperature: temperature,
                            maxTokens: maxTokens,
                            finishReason: .stop
                        )
                    }

                    return ChatCompletionResponse(
                        id: responseId,
                        created: created,
                        model: effectiveModel,
                        choices: [choice],
                        usage: usage,
                        system_fingerprint: nil
                    )
                } catch let invs as ServiceToolInvocations {
                    return Self.makeToolCallResponse(
                        invocations: invs.invocations,
                        responseId: responseId,
                        created: created,
                        effectiveModel: effectiveModel,
                        inputTokens: inputTokens,
                        startTime: startTime,
                        inferenceSource: inferenceSource,
                        temperature: temperature,
                        maxTokens: maxTokens
                    )
                } catch let inv as ServiceToolInvocation {
                    return Self.makeToolCallResponse(
                        invocations: [inv],
                        responseId: responseId,
                        created: created,
                        effectiveModel: effectiveModel,
                        inputTokens: inputTokens,
                        startTime: startTime,
                        inferenceSource: inferenceSource,
                        temperature: temperature,
                        maxTokens: maxTokens
                    )
                }
            }

            // Fallback to plain generation (no tools)
            let text = try await service.generateOneShot(
                messages: messages,
                parameters: params,
                requestedModel: request.model
            )
            let outputTokens = max(1, text.count / 4)
            let choice = ChatChoice(
                index: 0,
                message: ChatMessage(role: "assistant", content: text, tool_calls: nil, tool_call_id: nil),
                finish_reason: "stop"
            )
            let usage = Usage(
                prompt_tokens: inputTokens,
                completion_tokens: outputTokens,
                total_tokens: inputTokens + outputTokens
            )

            // Log the inference (only for Chat UI - HTTP requests are logged by HTTPHandler)
            if inferenceSource == .chatUI {
                let durationMs = Date().timeIntervalSince(startTime) * 1000
                InsightsService.logInference(
                    source: inferenceSource,
                    model: effectiveModel,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    durationMs: durationMs,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    finishReason: .stop
                )
            }

            return ChatCompletionResponse(
                id: responseId,
                created: created,
                model: effectiveModel,
                choices: [choice],
                usage: usage,
                system_fingerprint: nil
            )
        case .none:
            throw EngineError(kind: .modelNotFound(requested: request.model))
        }
    }

    // MARK: - Remote Provider Services

}
