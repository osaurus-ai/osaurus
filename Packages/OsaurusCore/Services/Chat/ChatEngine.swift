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
    private let remoteServicesProvider: @Sendable () async -> [ModelService]

    /// Source of the inference (for logging purposes)
    private var inferenceSource: InferenceSource = .httpAPI

    init(
        services: [ModelService] = [FoundationModelService(), MLXService()],
        installedModelsProvider: @escaping @Sendable () -> [String] = {
            MLXService.getAvailableModels()
        },
        remoteServicesProvider: @escaping @Sendable () async -> [ModelService] = {
            await MainActor.run {
                RemoteProviderManager.shared.connectedServices().map { $0 as ModelService }
            }
        },
        source: InferenceSource = .httpAPI
    ) {
        self.services = services
        self.installedModelsProvider = installedModelsProvider
        self.remoteServicesProvider = remoteServicesProvider
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
        let maxTokens = request.resolvedMaxTokens ?? 16384
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
        var modelOptions = Self.normalizedModelOptions(
            for: request.model,
            requestOptions: request.modelOptions
        )
        let isHy3 = Hy3ReasoningProfile.matches(modelId: request.model)
        let requestReasoningEffort: String? = {
            guard
                let value = request.reasoning_effort?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            else { return nil }
            return value
        }()

        if isHy3 {
            if let requestReasoningEffort {
                modelOptions["reasoningEffort"] = .string(
                    Hy3ReasoningProfile.normalizedEffort(requestReasoningEffort)
                )
            } else if modelOptions["reasoningEffort"] == nil,
                let enableThinking = request.enable_thinking
            {
                modelOptions["reasoningEffort"] = .string(enableThinking ? "high" : "no_think")
            }
            modelOptions.removeValue(forKey: "disableThinking")
        } else {
            if let enableThinking = request.enable_thinking {
                modelOptions["disableThinking"] = .bool(!enableThinking)
            }
            if let requestReasoningEffort {
                modelOptions["reasoningEffort"] = .string(requestReasoningEffort)
            }
        }

        let params = GenerationParameters(
            temperature: temperature,
            maxTokens: maxTokens,
            maxTokensExplicit: request.resolvedMaxTokens != nil,
            topPOverride: request.top_p,
            repetitionPenalty: repPenalty,
            samplingParametersAreImplicit: request.samplingParametersAreImplicit,
            frequencyPenalty: request.frequency_penalty,
            presencePenalty: request.presence_penalty,
            seed: seedBits,
            jsonMode: isJSONObject,
            modelOptions: modelOptions,
            sessionId: request.session_id,
            ttftTrace: trace
        )

        let services = self.services
        trace?.mark("route_resolve_local")
        let localRoute = ModelServiceRouter.resolve(
            requestedModel: request.model,
            services: services,
            remoteServices: []
        )
        if case .service = localRoute {
            return Dispatch(route: localRoute, params: params, remoteServices: [])
        }

        // Only touch remote provider state after local services decline the
        // model. Provider startup can block on Keychain; local MLX requests
        // must not inherit that unrelated startup dependency.
        trace?.mark("fetch_remote_services")
        let remoteServices = await remoteServicesProvider()
        trace?.mark("route_resolve")
        let route = ModelServiceRouter.resolve(
            requestedModel: request.model,
            services: services,
            remoteServices: remoteServices
        )
        return Dispatch(route: route, params: params, remoteServices: remoteServices)
    }

    private static func normalizedModelOptions(
        for model: String,
        requestOptions: [String: ModelOptionValue]?
    ) -> [String: ModelOptionValue] {
        guard let requestOptions else {
            return [:]
        }
        guard ModelProfileRegistry.profile(for: model) != nil else {
            return requestOptions
        }
        return ModelProfileRegistry.normalizedOptions(for: model, persisted: requestOptions)
    }

    private func estimateInputTokens(_ messages: [ChatMessage]) -> Int {
        let totalChars = messages.reduce(0) { sum, msg in
            var chars = msg.content?.count ?? 0
            if let calls = msg.tool_calls {
                for call in calls {
                    chars += call.function.name.count
                    chars += call.function.arguments.count
                    chars += TokenEstimator.toolCallEnvelopeChars
                }
            }
            return sum + chars
        }
        return max(1, totalChars / TokenEstimator.charsPerToken)
    }

    /// Pretty-print a `ChatCompletionRequest` for the Insights ring buffer.
    /// Encoding routes through `ChatCompletionRequest.CodingKeys`, which
    /// already excludes runtime-only fields (`modelOptions`, `ttftTrace`),
    /// so the captured body matches what an HTTP client would have sent.
    /// Returns nil only if encoding fails — in which case the caller
    /// gracefully degrades to logging without a body.
    static func serializeRequestForLog(_ request: ChatCompletionRequest) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(request),
            let s = String(data: data, encoding: .utf8)
        else { return nil }
        return s
    }

    /// Pretty-print a `ChatCompletionResponse` for the Insights ring buffer.
    /// Used by `completeChat` paths so the Response tab shows the structured
    /// envelope (id, choices, usage, tool_calls) instead of just the raw
    /// assistant text.
    static func serializeResponseForLog(_ response: ChatCompletionResponse) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(response),
            let s = String(data: data, encoding: .utf8)
        else { return nil }
        return s
    }

    private static func allowsLocalToolDispatch(_ toolChoice: ToolChoiceOption?) -> Bool {
        if case .some(.none) = toolChoice {
            return false
        }
        return true
    }

    static func localToolChoiceForDispatch(
        _ toolChoice: ToolChoiceOption?,
        tools: [Tool]?
    ) -> ToolChoiceOption? {
        guard case .some(.required) = toolChoice,
            let tools,
            tools.count == 1
        else {
            return toolChoice
        }
        return .function(
            ToolChoiceOption.FunctionName(
                type: "function",
                function: ToolChoiceOption.Name(name: tools[0].function.name)
            )
        )
    }

    /// Build the response body to log for a streamed chat completion.
    /// Prefers a JSON envelope when the stream resolved to a tool call so
    /// the Insights Response tab still shows something meaningful (the
    /// stream produces no assistant text in that case). Falls back to the
    /// accumulated assistant deltas, or nil if neither is available.
    /// Uses `JSONSerialization` rather than string interpolation so tool
    /// names / arguments containing quotes can't corrupt the JSON shape.
    static func streamResponseBody(
        accumulated: String,
        toolInvocation: (name: String, args: String)?
    ) -> String? {
        if let (name, args) = toolInvocation {
            // Try to embed `args` as a parsed JSON object so the UI can
            // pretty-print it; fall back to a string if it isn't valid JSON.
            let argsValue: Any =
                (args.data(using: .utf8)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) }) ?? args
            let envelope: [String: Any] = [
                "tool_calls": [["name": name, "arguments": argsValue]]
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: envelope,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ),
                let s = String(data: data, encoding: .utf8)
            {
                return s
            }
        }
        return accumulated.isEmpty ? nil : accumulated
    }

    private static func canonicalToolArgumentsJSON(
        _ json: String,
        schema: JSONValue? = nil,
        toolName: String? = nil
    ) -> String {
        let candidates = [
            json,
            json.replacingOccurrences(of: #"\""#, with: #"""#),
        ]
        guard
            let object = candidates.lazy.compactMap({ candidate -> Any? in
                guard let data = candidate.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data)
            }).first
        else {
            return json
        }
        let normalized = normalizeNestedJSONStringValues(object)
        let coerced: Any
        if let schema {
            let candidate = SchemaValidator.coerceArguments(normalized, against: schema)
            let result = SchemaValidator.validate(arguments: candidate, against: schema)
            if result.isValid {
                coerced = candidate
            } else if let invalid = invalidToolArgumentsJSON(
                toolName: toolName,
                result: result
            ) {
                return invalid
            } else {
                coerced = normalized
            }
        } else {
            coerced = normalized
        }
        guard JSONSerialization.isValidJSONObject(coerced),
            let data = try? JSONSerialization.data(withJSONObject: coerced, options: .osaurusCanonical),
            let string = String(data: data, encoding: .utf8)
        else {
            return json
        }
        return string
    }

    private static func invalidToolArgumentsJSON(
        toolName: String?,
        result: SchemaValidator.ValidationResult
    ) -> String? {
        var object: [String: Any] = [
            "_error": "invalid_tool_arguments",
            "_message": result.errorMessage ?? "invalid tool arguments",
            "_expected": "schema-compliant arguments",
        ]
        if let field = result.field {
            object["_field"] = field
        }
        if let toolName {
            object["_tool"] = toolName
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: .osaurusCanonical
            ),
            let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }

    private static func normalizeNestedJSONStringValues(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(normalizeNestedJSONStringValues(_:))
        }
        if let array = value as? [Any] {
            return array.map(normalizeNestedJSONStringValues(_:))
        }
        if let string = value as? String,
            let data = string.data(using: .utf8),
            let nested = try? JSONSerialization.jsonObject(with: data)
        {
            return normalizeNestedJSONStringValues(nested)
        }
        return value
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
        maxTokens: Int,
        requestBodyJSON: String? = nil,
        tools: [Tool]? = nil
    ) -> ChatCompletionResponse {
        let schemasByName = Dictionary(
            uniqueKeysWithValues: (tools ?? []).map { ($0.function.name, $0.function.parameters) }
        )
        let toolCalls: [ToolCall] = invocations.map { inv in
            let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let callId = inv.toolCallId ?? "call_" + String(raw.prefix(24))
            return ToolCall(
                id: callId,
                type: "function",
                function: ToolCallFunction(
                    name: inv.toolName,
                    arguments: canonicalToolArgumentsJSON(
                        inv.jsonArguments,
                        schema: schemasByName[inv.toolName] ?? nil,
                        toolName: inv.toolName
                    )
                ),
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

        let response = ChatCompletionResponse(
            id: responseId,
            created: created,
            model: effectiveModel,
            choices: [choice],
            usage: usage,
            system_fingerprint: nil
        )

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
                finishReason: .toolCalls,
                requestBody: requestBodyJSON,
                responseBody: serializeResponseForLog(response)
            )
        }

        return response
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
        let maxTokens = request.resolvedMaxTokens ?? 16384

        let dispatch = await prepareDispatch(request: request, trace: trace)
        let params = dispatch.params
        let route = dispatch.route
        debugLog("[ChatEngine] streamChat: route=\(route)")

        switch route {
        case .service(let service, let effectiveModel):
            let innerStream: AsyncThrowingStream<String, Error>

            // If tools were provided and supported, use message-based tool streaming
            if Self.allowsLocalToolDispatch(request.tool_choice),
                let tools = request.tools, !tools.isEmpty, let toolSvc = service as? ToolCapableService
            {
                let stopSequences = request.stop ?? []
                let dispatchToolChoice = Self.localToolChoiceForDispatch(
                    request.tool_choice,
                    tools: tools
                )
                debugLog("[ChatEngine] streamChat: calling streamWithTools tools=\(tools.count)")
                trace?.mark("chatengine_streamWithTools_start")
                innerStream = try await toolSvc.streamWithTools(
                    messages: messages,
                    parameters: params,
                    stopSequences: stopSequences,
                    tools: tools,
                    toolChoice: dispatchToolChoice,
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
            // Capture the request body up-front so the producer task does not
            // need to retain `request` (a non-Sendable in Swift 6 strict mode).
            let requestBodyJSON = source == .chatUI ? Self.serializeRequestForLog(request) : nil

            return wrapStreamWithLogging(
                innerStream,
                source: source,
                model: model,
                inputTokens: inputTokens,
                temperature: temp,
                maxTokens: maxTok,
                requestBodyJSON: requestBodyJSON
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
        maxTokens: Int,
        requestBodyJSON: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()

        // Capture the background-task id at construction time (still on
        // the parent task) so the detached producer below can forward
        // token-usage deltas to `BackgroundTaskManager.recordUsage(...)`
        // for mid-stream budget enforcement (spec §11.3). Task-local
        // values are not visible inside `Task.detached` blocks, so the
        // capture has to happen here.
        let bgId = ChatExecutionContext.currentBackgroundId
        // Forward the input-token count once on stream start. It's a
        // single fixed value and we want budget overruns to fire as
        // soon as the request lands, not only after output streams.
        let initialInputTokens = inputTokens
        if let bgId, initialInputTokens > 0 {
            Task { @MainActor in
                BackgroundTaskManager.shared.recordUsage(
                    backgroundId: bgId,
                    tokensInDelta: initialInputTokens
                )
            }
        }

        // Create the producer task and store reference for cancellation
        // IMPORTANT: Use Task.detached to run on cooperative thread pool instead of
        // ChatEngine actor's executor. This prevents deadlocks when the MainActor
        // consumes this stream while waiting for actor-isolated yields.
        let producerTask = Task.detached(priority: .userInitiated) {
            // Mark the chat generation as in-flight so background paths
            // (notably `MemoryService.distillSession` via
            // `DistillationCoordinator`) can defer until the user's
            // chat completes — see InferenceLoadCoordinator's header
            // for the OOM/jetsam rationale on heavy MLX core models.
            // The begin/end calls form a refcount so multiple
            // concurrent chat windows are tracked correctly.
            await InferenceLoadCoordinator.shared.beginChatGeneration()
            defer {
                // `defer` can't be async; fire-and-forget the actor
                // hop. Decrementing slightly after the producer task
                // returns is fine — distillation's idle waiter doesn't
                // care about microsecond accuracy.
                Task { await InferenceLoadCoordinator.shared.endChatGeneration() }
            }

            let startTime = Date()
            var outputTokenCount = 0
            // Track the last cumulative output-token count we forwarded
            // to `BackgroundTaskManager.recordUsage` so we only ever
            // post the delta. Provider-emitted `StreamingStatsHint`
            // payloads are cumulative; the text-delta fallback
            // increments per chunk — both feed into this counter so
            // mid-stream budget enforcement sees a monotonically
            // growing total without double-counting either source.
            var reportedOutputTokens = 0
            var deltaCount = 0
            var finishReason: InferenceLog.FinishReason = .stop
            var errorMsg: String? = nil
            var toolInvocation: (name: String, args: String)? = nil
            var lastDeltaTime = startTime
            // Accumulate the streamed assistant text so the Insights Response
            // tab can show what was produced. Only retained when logging is
            // active (chatUI) and capped soft via maxBodySize on storage.
            // Only accumulate streamed text when we'll actually log it
            // (Chat UI source). HTTP API requests are logged by HTTPHandler
            // with the upstream body, so accumulating here would just waste
            // memory as the buffer grows with the stream.
            let shouldAccumulate = source == .chatUI
            var responseAccumulator = ""

            print("[Osaurus][Stream] Starting stream wrapper for model: \(model)")

            do {
                for try await delta in inner {
                    if let stats = StreamingStatsHint.decode(delta) {
                        outputTokenCount = stats.tokenCount
                        // Stats hint carries the authoritative cumulative
                        // output-token count from the model runtime. Push
                        // only the delta since our last report so we
                        // don't double-count the text-delta estimates
                        // accumulated below.
                        if let bgId, outputTokenCount > reportedOutputTokens {
                            let outDelta = outputTokenCount - reportedOutputTokens
                            reportedOutputTokens = outputTokenCount
                            Task { @MainActor in
                                BackgroundTaskManager.shared.recordUsage(
                                    backgroundId: bgId,
                                    tokensOutDelta: outDelta
                                )
                            }
                        }
                        if let stopReason = stats.stopReason,
                            let loggedReason = InferenceLog.FinishReason(rawValue: stopReason)
                        {
                            finishReason = loggedReason
                        }
                        continuation.yield(delta)
                        continue
                    }

                    // Check for task cancellation to allow early termination
                    if Task.isCancelled {
                        print("[Osaurus][Stream] Task cancelled after \(deltaCount) deltas")
                        continuation.finish()
                        return
                    }

                    if let reasoning = StreamingReasoningHint.decode(delta) {
                        deltaCount += 1
                        let estimated = TokenEstimator.estimate(reasoning)
                        outputTokenCount += estimated
                        if let bgId, estimated > 0 {
                            reportedOutputTokens += estimated
                            Task { @MainActor in
                                BackgroundTaskManager.shared.recordUsage(
                                    backgroundId: bgId,
                                    tokensOutDelta: estimated
                                )
                            }
                        }
                        continuation.yield(delta)
                        continue
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

                    if shouldAccumulate {
                        responseAccumulator.append(delta)
                    }

                    // Estimate tokens: each delta chunk is roughly proportional to tokens
                    // More accurate: count whitespace-separated words, or use tokenizer
                    let estimated = TokenEstimator.estimate(delta)
                    outputTokenCount += estimated
                    // Forward the per-delta estimate to the budget
                    // tracker as well; if a stats hint later arrives
                    // with a higher cumulative count, the gap will be
                    // pushed in the hint branch above. The local
                    // `reportedOutputTokens` watermark prevents this
                    // text-delta path and the hint path from
                    // double-counting against each other.
                    if let bgId, estimated > 0 {
                        reportedOutputTokens += estimated
                        Task { @MainActor in
                            BackgroundTaskManager.shared.recordUsage(
                                backgroundId: bgId,
                                tokensOutDelta: estimated
                            )
                        }
                    }
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
                let toolCallsLog = toolInvocation.map { [ToolCallLog(name: $0.name, arguments: $0.args)] }

                InsightsService.logInference(
                    source: source,
                    model: model,
                    inputTokens: inputTokens,
                    outputTokens: outputTokenCount,
                    durationMs: durationMs,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    toolCalls: toolCallsLog,
                    finishReason: finishReason,
                    errorMessage: errorMsg,
                    requestBody: requestBodyJSON,
                    responseBody: Self.streamResponseBody(
                        accumulated: responseAccumulator,
                        toolInvocation: toolInvocation
                    )
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
        let maxTokens = request.resolvedMaxTokens ?? 16384
        // Capture the request body once so all four downstream log paths
        // (text-only, text-with-tools, tool-calls batch, tool-calls single)
        // surface the same prompt + tools in the Insights detail pane.
        let requestBodyJSON = inferenceSource == .chatUI ? Self.serializeRequestForLog(request) : nil
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
            // Match the streaming path — register the chat generation
            // for the lifetime of the LLM dispatch so distillation can
            // defer. Detached fire-and-forget for the end-decrement
            // mirrors the streaming wrapper above.
            await InferenceLoadCoordinator.shared.beginChatGeneration()
            defer {
                Task { await InferenceLoadCoordinator.shared.endChatGeneration() }
            }
            // If tools were provided and the service supports them, use the message-based API
            if Self.allowsLocalToolDispatch(request.tool_choice),
                let tools = request.tools, !tools.isEmpty, let toolSvc = service as? ToolCapableService
            {
                let stopSequences = request.stop ?? []
                let dispatchToolChoice = Self.localToolChoiceForDispatch(
                    request.tool_choice,
                    tools: tools
                )
                do {
                    let stream = try await toolSvc.streamWithTools(
                        messages: messages,
                        parameters: params,
                        stopSequences: stopSequences,
                        tools: tools,
                        toolChoice: dispatchToolChoice,
                        requestedModel: request.model
                    )
                    var text = ""
                    var reasoning = ""
                    var terminalStopReason = "stop"
                    for try await delta in stream {
                        try Task.checkCancellation()
                        if let stats = StreamingStatsHint.decode(delta) {
                            if let stopReason = stats.stopReason, !stopReason.isEmpty {
                                terminalStopReason = stopReason
                            }
                            continue
                        }
                        if let reasoningDelta = StreamingReasoningHint.decode(delta) {
                            reasoning += reasoningDelta
                            continue
                        }
                        if StreamingToolHint.isSentinel(delta) { continue }
                        text += delta
                    }
                    let outputTokens = TokenEstimator.estimate(text)
                    let choice = ChatChoice(
                        index: 0,
                        message: ChatMessage(
                            role: "assistant",
                            content: text,
                            tool_calls: nil,
                            tool_call_id: nil,
                            reasoning_content: reasoning.isEmpty ? nil : reasoning
                        ),
                        finish_reason: terminalStopReason
                    )
                    let usage = Usage(
                        prompt_tokens: inputTokens,
                        completion_tokens: outputTokens,
                        total_tokens: inputTokens + outputTokens
                    )

                    let response = ChatCompletionResponse(
                        id: responseId,
                        created: created,
                        model: effectiveModel,
                        choices: [choice],
                        usage: usage,
                        system_fingerprint: nil
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
                            finishReason: RequestLog.FinishReason(rawValue: terminalStopReason) ?? .stop,
                            requestBody: requestBodyJSON,
                            responseBody: Self.serializeResponseForLog(response)
                        )
                    }

                    return response
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
                        maxTokens: maxTokens,
                        requestBodyJSON: requestBodyJSON,
                        tools: tools
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
                        maxTokens: maxTokens,
                        requestBodyJSON: requestBodyJSON,
                        tools: tools
                    )
                }
            }

            // Fallback to plain generation (no tools). Use the streaming
            // service path even for non-streaming HTTP so the terminal stats
            // sentinel preserves vmlx's authoritative token count and stop
            // reason (`length` vs natural `stop`).
            let stopSequences = request.stop ?? []
            let stream = try await service.streamDeltas(
                messages: messages,
                parameters: params,
                requestedModel: request.model,
                stopSequences: stopSequences
            )
            var text = ""
            var reasoning = ""
            var terminalStopReason = "stop"
            var authoritativeOutputTokens: Int?
            for try await delta in stream {
                try Task.checkCancellation()
                if let stats = StreamingStatsHint.decode(delta) {
                    authoritativeOutputTokens = stats.tokenCount
                    if let stopReason = stats.stopReason, !stopReason.isEmpty {
                        terminalStopReason = stopReason
                    }
                    continue
                }
                if let reasoningDelta = StreamingReasoningHint.decode(delta) {
                    reasoning += reasoningDelta
                    continue
                }
                if StreamingToolHint.isSentinel(delta) { continue }
                text += delta
            }
            let outputTokens = authoritativeOutputTokens ?? TokenEstimator.estimate(text)
            let choice = ChatChoice(
                index: 0,
                message: ChatMessage(
                    role: "assistant",
                    content: text,
                    tool_calls: nil,
                    tool_call_id: nil,
                    reasoning_content: reasoning.isEmpty ? nil : reasoning
                ),
                finish_reason: terminalStopReason
            )
            let usage = Usage(
                prompt_tokens: inputTokens,
                completion_tokens: outputTokens,
                total_tokens: inputTokens + outputTokens
            )

            let response = ChatCompletionResponse(
                id: responseId,
                created: created,
                model: effectiveModel,
                choices: [choice],
                usage: usage,
                system_fingerprint: nil
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
                    finishReason: RequestLog.FinishReason(rawValue: terminalStopReason) ?? .stop,
                    requestBody: requestBodyJSON,
                    responseBody: Self.serializeResponseForLog(response)
                )
            }

            return response
        case .none:
            throw EngineError(kind: .modelNotFound(requested: request.model))
        }
    }

    // MARK: - Remote Provider Services

}
