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
    struct EngineError: Error {}

    private func enrichMessagesWithSystemPrompt(_ messages: [ChatMessage]) async -> [ChatMessage] {
        // Check if a system prompt is already present
        if messages.contains(where: { $0.role == "system" }) {
            return messages
        }

        // If not, fetch the global system prompt
        let systemPrompt = await MainActor.run {
            ChatConfigurationStore.load().systemPrompt
        }

        let trimmed = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return messages }

        // Prepend the system prompt
        let systemMessage = ChatMessage(role: "system", content: trimmed)
        return [systemMessage] + messages
    }

    /// Estimate input tokens from messages (rough heuristic: ~4 chars per token)
    private func estimateInputTokens(_ messages: [ChatMessage]) -> Int {
        let totalChars = messages.reduce(0) { sum, msg in
            sum + (msg.content?.count ?? 0)
        }
        return max(1, totalChars / 4)
    }

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        let messages = await enrichMessagesWithSystemPrompt(request.messages)
        let temperature = request.temperature
        let maxTokens = request.max_tokens ?? 16384
        let repPenalty: Float? = {
            // Map OpenAI penalties (presence/frequency) to a simple repetition penalty if provided
            if let fp = request.frequency_penalty, fp > 0 { return 1.0 + fp }
            if let pp = request.presence_penalty, pp > 0 { return 1.0 + pp }
            return nil
        }()
        let params = GenerationParameters(
            temperature: temperature,
            maxTokens: maxTokens,
            topPOverride: request.top_p,
            repetitionPenalty: repPenalty
        )

        // Candidate services and installed models (injected for testability)
        let services = self.services

        // Get remote provider services
        let remoteServices = await getRemoteProviderServices()

        let route = ModelServiceRouter.resolve(
            requestedModel: request.model,
            services: services,
            remoteServices: remoteServices
        )

        switch route {
        case .service(let service, let effectiveModel):
            let innerStream: AsyncThrowingStream<String, Error>

            // If tools were provided and supported, use message-based tool streaming
            if let tools = request.tools, !tools.isEmpty, let toolSvc = service as? ToolCapableService {
                let stopSequences = request.stop ?? []
                innerStream = try await toolSvc.streamWithTools(
                    messages: messages,
                    parameters: params,
                    stopSequences: stopSequences,
                    tools: tools,
                    toolChoice: request.tool_choice,
                    requestedModel: request.model
                )
            } else {
                innerStream = try await service.streamDeltas(
                    messages: messages,
                    parameters: params,
                    requestedModel: request.model,
                    stopSequences: request.stop ?? []
                )
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
            throw EngineError()
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
        let messages = await enrichMessagesWithSystemPrompt(request.messages)
        let inputTokens = estimateInputTokens(messages)
        let temperature = request.temperature
        let maxTokens = request.max_tokens ?? 16384
        let repPenalty2: Float? = {
            if let fp = request.frequency_penalty, fp > 0 { return 1.0 + fp }
            if let pp = request.presence_penalty, pp > 0 { return 1.0 + pp }
            return nil
        }()
        let params = GenerationParameters(
            temperature: temperature,
            maxTokens: maxTokens,
            topPOverride: request.top_p,
            repetitionPenalty: repPenalty2
        )

        let services = self.services

        // Get remote provider services
        let remoteServices = await getRemoteProviderServices()

        let route = ModelServiceRouter.resolve(
            requestedModel: request.model,
            services: services,
            remoteServices: remoteServices
        )

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
                } catch let inv as ServiceToolInvocation {
                    // Convert tool invocation to OpenAI-style non-stream response
                    let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    let callId = "call_" + String(raw.prefix(24))
                    let toolCall = ToolCall(
                        id: callId,
                        type: "function",
                        function: ToolCallFunction(name: inv.toolName, arguments: inv.jsonArguments)
                    )
                    let assistant = ChatMessage(
                        role: "assistant",
                        content: nil,
                        tool_calls: [toolCall],
                        tool_call_id: nil
                    )
                    let choice = ChatChoice(index: 0, message: assistant, finish_reason: "tool_calls")
                    let usage = Usage(prompt_tokens: inputTokens, completion_tokens: 0, total_tokens: inputTokens)

                    // Log the inference (only for Chat UI - HTTP requests are logged by HTTPHandler)
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
                            toolCalls: [ToolCallLog(name: inv.toolName, arguments: inv.jsonArguments)],
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
            throw EngineError()
        }
    }

    // MARK: - Remote Provider Services

    /// Fetch connected remote provider services from the manager
    private func getRemoteProviderServices() async -> [ModelService] {
        return await MainActor.run {
            RemoteProviderManager.shared.connectedServices()
        }
    }
}
