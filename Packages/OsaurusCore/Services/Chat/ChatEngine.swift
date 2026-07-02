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
            /// A Mode 2 remote-agent run was requested but the paired agent's
            /// provider isn't among the connected services (e.g. it
            /// disconnected mid-flight). Fails closed instead of falling back
            /// to model-string routing, which could silently retarget a
            /// different local provider. Maps to 503.
            case remoteAgentUnavailable
        }

        let kind: Kind

        var errorDescription: String? {
            switch kind {
            case .modelNotFound(let requested):
                return "Model '\(requested)' is not installed or registered with any provider."
            case .noServiceAvailable(let requested):
                return "No service is currently available to handle model '\(requested)'."
            case .remoteAgentUnavailable:
                return "The selected remote agent isn't connected. Reconnect to the agent and try again."
            }
        }

        /// The HTTP status code the API layer should return for this error.
        var httpStatus: Int {
            switch kind {
            case .modelNotFound: return 404
            case .noServiceAvailable: return 503
            case .remoteAgentUnavailable: return 503
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
        // OpenAI `frequency_penalty` / `presence_penalty` ride
        // `GenerationParameters` verbatim: vmlx natively implements both as
        // additive count-scaled penalties (`GenerateParameters
        // .frequencyPenalty`/`.presencePenalty`), so the old lossy mapping
        // of frequency_penalty onto a multiplicative repetition penalty
        // (which also silently dropped negative values) is gone. A
        // per-request repetition_penalty is not an OpenAI field; model
        // bundle / server defaults still apply downstream.
        let repPenalty: Float? = nil
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
            topKOverride: request.top_k,
            minPOverride: request.min_p,
            repetitionPenalty: repPenalty,
            samplingParametersAreImplicit: request.samplingParametersAreImplicit,
            frequencyPenalty: request.frequency_penalty,
            presencePenalty: request.presence_penalty,
            seed: seedBits,
            jsonMode: isJSONObject,
            modelOptions: modelOptions,
            sessionId: request.session_id,
            ttftTrace: trace,
            idempotencyKey: request.idempotencyKey,
            runAsRemoteAgent: request.runAsRemoteAgent
        )

        // Mode 2 (remote agent run): route to the *selected agent's provider*,
        // never by the model string. A stale `selectedModel` left over from
        // earlier local testing (e.g. "fugu/...") must not redirect an agent
        // run to a different local provider — that produced opaque upstream
        // 404s ("Model default not found"). The peer resolves its own
        // effective model server-side, so the model field here is irrelevant.
        if request.runAsRemoteAgent, let agentProviderId = request.remoteAgentProviderId {
            let remoteServices = await remoteServicesProvider()
            if let agentService = Self.remoteAgentService(
                providerId: agentProviderId,
                in: remoteServices
            ) {
                let effective = request.remoteAgentLogModel ?? request.model
                RemoteAgentRunLog.client(
                    "dispatch route=provider providerId=\(agentProviderId.uuidString) effectiveModel=\(effective) reqModel=\(request.model)"
                )
                return Dispatch(
                    route: .service(service: agentService, effectiveModel: effective),
                    params: params,
                    remoteServices: remoteServices
                )
            }
            RemoteAgentRunLog.clientError(
                "dispatch remote agent providerId=\(agentProviderId.uuidString) not in connected services; failing closed"
            )
            return Dispatch(route: .none, params: params, remoteServices: remoteServices)
        }

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

    /// Emit the opt-in `message_sent` KPI event for a top-level chat turn.
    ///
    /// De-dup rule (no protocol/flag plumbing): a "message" is a fresh
    /// user/client turn, identified by the request's last message being a
    /// `user` message. Tool-loop continuations — the agent-run server loop,
    /// the Chat UI tool loop, and plugin loops — re-enter the engine with a
    /// trailing `tool`/`assistant` message appended, so they are naturally
    /// skipped and never inflate the count. Only the role enum is inspected;
    /// no message content is read. Fired fire-and-forget on the main actor
    /// (where `TelemetryService` lives) so it never blocks dispatch, and the
    /// service itself no-ops unless the user opted in.
    private func emitMessageSentIfPrimaryTurn(
        request: ChatCompletionRequest,
        service: ModelService,
        effectiveModel: String,
        stream: Bool
    ) {
        guard FeatureTelemetry.isPrimaryUserTurn(request.messages) else { return }
        let info = FeatureTelemetry.messageInfo(
            service: service,
            effectiveModel: effectiveModel,
            source: inferenceSource,
            isAgent: request.isAgentRequest,
            stream: stream
        )
        Task { @MainActor in FeatureTelemetry.messageSent(info) }
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
        return redactInlineImagePayloads(in: s)
    }

    /// Replace inline base64 image payloads (e.g. Computer Use screenshots) with
    /// a short marker before the request is handed to the Insights ring buffer.
    /// Even a `FrameScrubber`-redacted frame shouldn't be retained verbatim in a
    /// local debug buffer — the marker keeps the request shape inspectable
    /// without persisting pixels. Text content is left intact (it's already on
    /// the user's screen, and the panel exists to inspect the request).
    static func redactInlineImagePayloads(in json: String) -> String {
        guard
            let regex = try? NSRegularExpression(pattern: "(;base64,)([A-Za-z0-9+/=]{64,})")
        else { return json }
        let matches = regex.matches(
            in: json,
            range: NSRange(location: 0, length: (json as NSString).length)
        )
        guard !matches.isEmpty else { return json }
        var result = json as NSString
        // Apply replacements back-to-front so earlier ranges stay valid.
        for match in matches.reversed() {
            let payload = match.range(at: 2)
            guard payload.location != NSNotFound else { continue }
            result =
                result.replacingCharacters(
                    in: payload,
                    with: "[redacted \(payload.length)-char image]"
                ) as NSString
        }
        return result as String
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

    private static func requiresLocalToolCall(_ toolChoice: ToolChoiceOption?) -> Bool {
        guard let toolChoice else { return false }
        switch toolChoice {
        case .required, .function:
            return true
        case .auto, .none:
            return false
        }
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
        tokensPerSecond: Double? = nil,
        turnId: UUID? = nil,
        requestId: String? = nil,
        requestBodyJSON: String? = nil,
        tools: [Tool]? = nil,
        connection: RequestConnectionInfo? = nil,
        logPath: String? = nil
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
        // `tokens_per_second` is the model's decode speed for the step that
        // produced this tool call. The streaming runtime forwards it as a
        // stats hint just before finishing-by-throw (see
        // `ModelRuntime.streamWithTools`), so a tool-call turn no longer drops
        // its decode telemetry. Token counts stay 0 here (the assistant
        // emitted no user-visible completion text), matching the historical
        // tool-call `usage` shape consumers depend on.
        let usage = Usage(
            prompt_tokens: inputTokens,
            completion_tokens: 0,
            total_tokens: inputTokens,
            tokens_per_second: tokensPerSecond
        )

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
                turnId: turnId,
                requestId: requestId,
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
                responseBody: serializeResponseForLog(response),
                connection: connection,
                path: logPath ?? "/chat/completions"
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
            emitMessageSentIfPrimaryTurn(
                request: request,
                service: service,
                effectiveModel: effectiveModel,
                stream: true
            )

            let source = self.inferenceSource
            // Connection metadata for a remote send (relay/host, endpoint,
            // transport, mode). nil for local routes. Only built for chatUI —
            // HTTP API rows are logged with their own attribution by
            // HTTPHandler.
            let remoteConn =
                source == .chatUI
                ? Self.remoteConnectionInfo(for: service, runAsRemoteAgent: params.runAsRemoteAgent)
                : nil
            // Wire-verification probe: capture the real post-scrub request +
            // raw response bytes for the Insights "Server" toggle. Set the
            // task-local around the stream-open so `RemoteProviderService`
            // snapshots it on producer entry. No probe for local routes.
            let wireProbe: WireTransportProbe? = remoteConn != nil ? WireTransportProbe() : nil

            let innerStream: AsyncThrowingStream<String, Error>
            if let wireProbe {
                innerStream = try await WireTransportProbe.$current.withValue(wireProbe) {
                    try await self.openInnerStream(
                        request: request,
                        messages: messages,
                        service: service,
                        params: params,
                        trace: trace
                    )
                }
            } else {
                innerStream = try await self.openInnerStream(
                    request: request,
                    messages: messages,
                    service: service,
                    params: params,
                    trace: trace
                )
            }

            // Wrap stream to count tokens and log when complete
            let inputTokens = estimateInputTokens(messages)
            let model = Self.loggedModel(
                for: request,
                remoteConn: remoteConn,
                fallback: effectiveModel
            )
            let temp = temperature
            let maxTok = maxTokens
            // Capture the request body up-front so the producer task does not
            // need to retain `request` (a non-Sendable in Swift 6 strict mode).
            let requestBodyJSON = source == .chatUI ? Self.serializeRequestForLog(request) : nil
            // `turnId` is a Sendable UUID, so capturing it (unlike `request`)
            // is safe for the detached producer — correlates the log back to
            // the chat assistant turn for the per-message Insights button.
            let turnId = request.turnId
            let requestId = request.idempotencyKey

            return wrapStreamWithLogging(
                innerStream,
                source: source,
                turnId: turnId,
                requestId: requestId,
                model: model,
                inputTokens: inputTokens,
                temperature: temp,
                maxTokens: maxTok,
                requestBodyJSON: requestBodyJSON,
                connection: remoteConn?.info,
                logPath: remoteConn?.path,
                wireProbe: wireProbe
            )

        case .none:
            if request.runAsRemoteAgent, request.remoteAgentProviderId != nil {
                throw EngineError(kind: .remoteAgentUnavailable)
            }
            throw EngineError(kind: .modelNotFound(requested: request.model))
        }
    }

    /// Open the underlying service stream (tools vs plain), preserving the
    /// debug/trace breadcrumbs. Factored out of `streamChat` so the caller can
    /// run it inside a `WireTransportProbe.$current` task-local scope for
    /// remote sends without duplicating the dispatch branch.
    private func openInnerStream(
        request: ChatCompletionRequest,
        messages: [ChatMessage],
        service: ModelService,
        params: GenerationParameters,
        trace: TTFTTrace?
    ) async throws -> AsyncThrowingStream<String, Error> {
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
            let toolStream = try await toolSvc.streamWithTools(
                messages: messages,
                parameters: params,
                stopSequences: stopSequences,
                tools: tools,
                toolChoice: dispatchToolChoice,
                requestedModel: request.model
            )
            trace?.mark("chatengine_streamWithTools_done")
            debugLog("[ChatEngine] streamChat: streamWithTools returned")
            return toolStream
        } else {
            debugLog("[ChatEngine] streamChat: calling streamDeltas")
            trace?.mark("chatengine_streamDeltas_start")
            let plainStream = try await service.streamDeltas(
                messages: messages,
                parameters: params,
                requestedModel: request.model,
                stopSequences: request.stop ?? []
            )
            trace?.mark("chatengine_streamDeltas_done")
            debugLog("[ChatEngine] streamChat: streamDeltas returned")
            return plainStream
        }
    }

    /// Mode 2 routing primitive: pick the paired agent's `RemoteProviderService`
    /// by its `provider.id`, never by the model string — a stale `selectedModel`
    /// (e.g. a leftover local provider prefix) must not redirect a remote-agent
    /// run to a different provider. `static` and pure over the immutable
    /// `provider` `let`, so it's unit-testable without standing up an engine.
    static func remoteAgentService(
        providerId: UUID,
        in remoteServices: [ModelService]
    ) -> ModelService? {
        remoteServices.first { ($0 as? RemoteProviderService)?.provider.id == providerId }
    }

    /// Build Insights connection + attribution metadata for a remote send so a
    /// remote run shows the real relay/host, endpoint, transport, and mode
    /// instead of a bare, local-looking model badge. Returns nil for local
    /// services (nothing remote to describe). Pure function of the immutable
    /// `RemoteProvider`, so it's safe to call synchronously off the actor.
    static func remoteConnectionInfo(
        for service: ModelService,
        runAsRemoteAgent: Bool
    ) -> (info: RequestConnectionInfo, path: String)? {
        guard let remote = service as? RemoteProviderService else { return nil }
        let provider = remote.provider
        let isOsaurus = provider.providerType == .osaurus
        // Mode 2 is the native server-side agent run; everything else routed to
        // a remote provider is plain inference (Mode 1).
        let mode: RequestMode = (isOsaurus && runAsRemoteAgent) ? .remoteAgentRun : .remoteInference
        // Native Osaurus peers always ride the Secure Channel; third-party
        // providers go direct (TLS) — see `_streamRemote`'s `secureProvider`.
        let transport: RequestTransport = isOsaurus ? .secureChannel : .direct
        let endpointURL: URL? =
            isOsaurus
            ? remote.osaurusEndpointURL(runAsRemoteAgent: runAsRemoteAgent)
            : provider.url(for: "/chat/completions")
        let info = RequestConnectionInfo(
            providerId: provider.id,
            remoteEndpoint: endpointURL?.absoluteString ?? provider.displayEndpoint,
            transport: transport,
            mode: mode
        )
        return (info, endpointURL?.path ?? "/chat/completions")
    }

    /// Mode 2 honesty: prefer the remote agent's live effective model (carried
    /// on the request) over the local prefixed fallback the picker pinned, so
    /// the Insights row doesn't imply the local Apple model ran. Falls back for
    /// every other route.
    private static func loggedModel(
        for request: ChatCompletionRequest,
        remoteConn: (info: RequestConnectionInfo, path: String)?,
        fallback: String
    ) -> String {
        guard remoteConn?.info.mode == .remoteAgentRun,
            let m = request.remoteAgentLogModel?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !m.isEmpty
        else { return fallback }
        return m
    }

    /// Wraps an async stream to count output tokens and log on completion.
    /// Uses Task.detached to avoid actor isolation deadlocks when consumed from MainActor.
    /// Properly handles cancellation via onTermination handler to prevent orphaned tasks.
    private func wrapStreamWithLogging(
        _ inner: AsyncThrowingStream<String, Error>,
        source: InferenceSource,
        turnId: UUID? = nil,
        requestId: String? = nil,
        model: String,
        inputTokens: Int,
        temperature: Float?,
        maxTokens: Int,
        requestBodyJSON: String? = nil,
        connection: RequestConnectionInfo? = nil,
        logPath: String? = nil,
        wireProbe: WireTransportProbe? = nil
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

            // Capture the MLX error sequence before generation so we can tell
            // whether a (swallowed) MLX C++ forward-pass error fired during
            // this stream and surface it instead of finishing blank.
            let mlxErrorEpoch = MLXErrorRecovery.errorSequence()

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
            var statsHintCount = 0
            var reasoningHintCount = 0
            var toolHintCount = 0
            var billingHintCount = 0
            var prefillHintCount = 0
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
                        statsHintCount += 1
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
                        reasoningHintCount += 1
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

                    if StreamingBillingHint.decode(delta) != nil {
                        billingHintCount += 1
                        continuation.yield(delta)
                        continue
                    }

                    if StreamingPrefillProgressHint.decode(delta) != nil {
                        prefillHintCount += 1
                        continuation.yield(delta)
                        continue
                    }

                    // Pass through tool-hint sentinels without counting as tokens
                    if StreamingToolHint.isSentinel(delta) {
                        toolHintCount += 1
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
                let sentinelCount =
                    statsHintCount + toolHintCount + billingHintCount + prefillHintCount
                let zeroDeltaClassification =
                    deltaCount == 0
                    ? (sentinelCount > 0 ? "sentinel-only" : "empty")
                    : "non-empty"
                print(
                    "[Osaurus][Stream] Stream completed: \(deltaCount) content/reasoning deltas in \(String(format: "%.2f", totalTime))s classification=\(zeroDeltaClassification) reasoning=\(reasoningHintCount) stats=\(statsHintCount) toolHints=\(toolHintCount) billingHints=\(billingHintCount) prefillHints=\(prefillHintCount)"
                )

                // A blank stream that coincides with a fresh MLX C++ error is
                // almost certainly that error (the global handler swallowed the
                // would-be fatalError, so generation just produced nothing).
                // Surface it as a failed stream rather than an empty success.
                if deltaCount == 0, let mlxErr = MLXErrorRecovery.errorSince(mlxErrorEpoch) {
                    print("[Osaurus][Stream] Empty stream after MLX error: \(mlxErr)")
                    finishReason = .error
                    errorMsg = mlxErr
                    continuation.finish(throwing: MLXForwardPassError(message: mlxErr))
                } else {
                    continuation.finish()
                }
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

                // Snapshot the real wire bytes (post-scrub request + raw
                // pre-unscrub response) so the Insights "Server" toggle shows
                // exactly what crossed the network — e.g. the Mode 2
                // `/agents/{addr}/run` body with `model:"default"`. nil for
                // local routes (no probe).
                let wireSnapshot = wireProbe?.snapshot()

                InsightsService.logInference(
                    source: source,
                    turnId: turnId,
                    requestId: requestId,
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
                    ),
                    wireRequestBody: wireSnapshot?.request,
                    wireResponseBody: (wireSnapshot?.response).flatMap { $0.isEmpty ? nil : $0 },
                    connection: connection,
                    path: logPath ?? "/chat/completions"
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
        let requestId = request.idempotencyKey
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
            emitMessageSentIfPrimaryTurn(
                request: request,
                service: service,
                effectiveModel: effectiveModel,
                stream: false
            )

            // Remote connection metadata + Mode 2 model honesty, mirroring the
            // streaming path so non-streamed chatUI rows are equally honest
            // about relay/host/mode. (Wire-body capture stays on the streaming
            // path, which is what the chat surface actually drives.)
            let remoteConn =
                inferenceSource == .chatUI
                ? Self.remoteConnectionInfo(for: service, runAsRemoteAgent: params.runAsRemoteAgent)
                : nil
            let loggedModel = Self.loggedModel(
                for: request,
                remoteConn: remoteConn,
                fallback: effectiveModel
            )
            let loggedPath = remoteConn?.path ?? "/chat/completions"

            // Match the streaming path — register the chat generation
            // for the lifetime of the LLM dispatch so distillation can
            // defer. Detached fire-and-forget for the end-decrement
            // mirrors the streaming wrapper above.
            await InferenceLoadCoordinator.shared.beginChatGeneration()
            defer {
                Task { await InferenceLoadCoordinator.shared.endChatGeneration() }
            }
            // Capture the MLX error sequence so a blank, error-coincident
            // response is surfaced as a thrown error (→ HTTP 500 / failed
            // chunk) instead of an empty 200.
            let mlxErrorEpoch = MLXErrorRecovery.errorSequence()
            // If tools were provided and the service supports them, use the message-based API
            if Self.allowsLocalToolDispatch(request.tool_choice),
                let tools = request.tools, !tools.isEmpty, let toolSvc = service as? ToolCapableService
            {
                let stopSequences = request.stop ?? []
                let dispatchToolChoice = Self.localToolChoiceForDispatch(
                    request.tool_choice,
                    tools: tools
                )
                // Decode tok/s for the step, captured from the streamWithTools
                // stats hint. Held OUTSIDE the `do` so the tool-call `catch`
                // (which builds the response via `makeToolCallResponse`) can
                // thread it into `usage` — the value is otherwise lost when the
                // stream throws to surface the tool call, which is why tool-call
                // turns historically reported no tok/s.
                var toolStepTokensPerSecond: Double?
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
                            toolStepTokensPerSecond = stats.tokensPerSecond
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
                    if text.isEmpty, reasoning.isEmpty,
                        let mlxErr = MLXErrorRecovery.errorSince(mlxErrorEpoch)
                    {
                        throw MLXForwardPassError(message: mlxErr)
                    }
                    if Self.requiresLocalToolCall(dispatchToolChoice) {
                        let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        throw NSError(
                            domain: "OsaurusToolChoice",
                            code: 422,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "The model did not produce a valid required tool call.",
                                "model": effectiveModel,
                                "tool_choice": String(describing: dispatchToolChoice),
                                "suppressed_content_preview": String(preview.prefix(160)),
                            ]
                        )
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
                        total_tokens: inputTokens + outputTokens,
                        tokens_per_second: toolStepTokensPerSecond
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
                            turnId: request.turnId,
                            requestId: requestId,
                            model: loggedModel,
                            inputTokens: inputTokens,
                            outputTokens: outputTokens,
                            durationMs: durationMs,
                            temperature: temperature,
                            maxTokens: maxTokens,
                            finishReason: RequestLog.FinishReason(rawValue: terminalStopReason) ?? .stop,
                            requestBody: requestBodyJSON,
                            responseBody: Self.serializeResponseForLog(response),
                            connection: remoteConn?.info,
                            path: loggedPath
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
                        tokensPerSecond: toolStepTokensPerSecond,
                        turnId: request.turnId,
                        requestId: requestId,
                        requestBodyJSON: requestBodyJSON,
                        tools: tools,
                        connection: remoteConn?.info,
                        logPath: loggedPath
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
                        tokensPerSecond: toolStepTokensPerSecond,
                        turnId: request.turnId,
                        requestId: requestId,
                        requestBodyJSON: requestBodyJSON,
                        tools: tools,
                        connection: remoteConn?.info,
                        logPath: loggedPath
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
            var authoritativeTokensPerSecond: Double?
            for try await delta in stream {
                try Task.checkCancellation()
                if let stats = StreamingStatsHint.decode(delta) {
                    authoritativeOutputTokens = stats.tokenCount
                    authoritativeTokensPerSecond = stats.tokensPerSecond
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
            if text.isEmpty, reasoning.isEmpty,
                let mlxErr = MLXErrorRecovery.errorSince(mlxErrorEpoch)
            {
                throw MLXForwardPassError(message: mlxErr)
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
                total_tokens: inputTokens + outputTokens,
                tokens_per_second: authoritativeTokensPerSecond
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
                    turnId: request.turnId,
                    requestId: requestId,
                    model: loggedModel,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    durationMs: durationMs,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    finishReason: RequestLog.FinishReason(rawValue: terminalStopReason) ?? .stop,
                    requestBody: requestBodyJSON,
                    responseBody: Self.serializeResponseForLog(response),
                    connection: remoteConn?.info,
                    path: loggedPath
                )
            }

            return response
        case .none:
            if request.runAsRemoteAgent, request.remoteAgentProviderId != nil {
                throw EngineError(kind: .remoteAgentUnavailable)
            }
            throw EngineError(kind: .modelNotFound(requested: request.model))
        }
    }

    // MARK: - Remote Provider Services

}
