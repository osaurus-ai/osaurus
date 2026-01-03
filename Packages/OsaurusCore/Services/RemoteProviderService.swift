//
//  RemoteProviderService.swift
//  osaurus
//
//  Service for proxying requests to remote OpenAI-compatible API providers.
//

import Foundation

/// Errors specific to remote provider operations
public enum RemoteProviderServiceError: LocalizedError {
    case invalidURL
    case notConnected
    case requestFailed(String)
    case invalidResponse
    case streamingError(String)
    case noModelsAvailable

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid provider URL configuration"
        case .notConnected:
            return "Provider is not connected"
        case .requestFailed(let message):
            return "Request failed: \(message)"
        case .invalidResponse:
            return "Invalid response from provider"
        case .streamingError(let message):
            return "Streaming error: \(message)"
        case .noModelsAvailable:
            return "No models available from provider"
        }
    }
}

/// Service that proxies requests to a remote OpenAI-compatible API provider
public actor RemoteProviderService: ToolCapableService {

    public let provider: RemoteProvider
    private let providerPrefix: String
    private var availableModels: [String]
    private var session: URLSession

    public nonisolated var id: String {
        "remote-\(provider.id.uuidString)"
    }

    public init(provider: RemoteProvider, models: [String]) {
        self.provider = provider
        self.availableModels = models
        // Create a unique prefix for model names (lowercase, sanitized)
        self.providerPrefix = provider.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")

        // Configure URLSession with provider timeout
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = provider.timeout
        config.timeoutIntervalForResource = provider.timeout * 2
        self.session = URLSession(configuration: config)
    }

    /// Update available models (called when connection refreshes)
    public func updateModels(_ models: [String]) {
        self.availableModels = models
    }

    /// Get the prefixed model names for this provider
    public func getPrefixedModels() -> [String] {
        availableModels.map { "\(providerPrefix)/\($0)" }
    }

    /// Get the raw model names without prefix
    public func getRawModels() -> [String] {
        availableModels
    }

    // MARK: - ModelService Protocol

    public nonisolated func isAvailable() -> Bool {
        return provider.enabled
    }

    public nonisolated func handles(requestedModel: String?) -> Bool {
        guard let model = requestedModel?.trimmingCharacters(in: .whitespacesAndNewlines),
            !model.isEmpty
        else {
            return false
        }

        // Check if model starts with our provider prefix
        let prefix = provider.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")

        return model.lowercased().hasPrefix(prefix + "/")
    }

    /// Extract the actual model name without provider prefix
    private func extractModelName(_ requestedModel: String?) -> String? {
        guard let model = requestedModel?.trimmingCharacters(in: .whitespacesAndNewlines),
            !model.isEmpty
        else {
            return nil
        }

        // Remove provider prefix if present
        if model.lowercased().hasPrefix(providerPrefix + "/") {
            let startIndex = model.index(model.startIndex, offsetBy: providerPrefix.count + 1)
            return String(model[startIndex...])
        }

        return model
    }

    func generateOneShot(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?
    ) async throws -> String {
        guard let modelName = extractModelName(requestedModel) else {
            throw RemoteProviderServiceError.noModelsAvailable
        }

        let request = buildChatRequest(
            messages: messages,
            parameters: parameters,
            model: modelName,
            stream: false,
            tools: nil,
            toolChoice: nil
        )

        let (data, response) = try await session.data(for: try buildURLRequest(for: request))

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteProviderServiceError.invalidResponse
        }

        if httpResponse.statusCode >= 400 {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw RemoteProviderServiceError.requestFailed("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        let (content, _) = try parseResponse(data)
        return content ?? ""
    }

    func streamDeltas(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?,
        stopSequences: [String]
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let modelName = extractModelName(requestedModel) else {
            throw RemoteProviderServiceError.noModelsAvailable
        }

        var request = buildChatRequest(
            messages: messages,
            parameters: parameters,
            model: modelName,
            stream: true,
            tools: nil,
            toolChoice: nil
        )

        // Add stop sequences if provided
        if !stopSequences.isEmpty {
            request.stop = stopSequences
        }

        let urlRequest = try buildURLRequest(for: request)
        let currentSession = self.session
        let providerType = self.provider.providerType

        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()

        let producerTask = Task {
            do {
                let (bytes, response) = try await currentSession.bytes(for: urlRequest)

                guard let httpResponse = response as? HTTPURLResponse else {
                    continuation.finish(throwing: RemoteProviderServiceError.invalidResponse)
                    return
                }

                if httpResponse.statusCode >= 400 {
                    var errorData = Data()
                    for try await byte in bytes {
                        errorData.append(byte)
                    }
                    let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    continuation.finish(
                        throwing: RemoteProviderServiceError.requestFailed(
                            "HTTP \(httpResponse.statusCode): \(errorMessage)"
                        )
                    )
                    return
                }

                // Track accumulated tool calls by index (even in streamDeltas for robustness)
                var accumulatedToolCalls: [Int: (id: String?, name: String?, args: String)] = [:]

                // Parse SSE stream with proper UTF-8 decoding
                var buffer = ""
                var utf8Buffer = Data()
                for try await byte in bytes {
                    // Check for task cancellation to allow early termination
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    utf8Buffer.append(byte)
                    // Try to decode accumulated bytes as UTF-8
                    if let decoded = String(data: utf8Buffer, encoding: .utf8) {
                        buffer.append(decoded)
                        utf8Buffer.removeAll()
                    }
                    // If decoding fails, we have an incomplete multi-byte sequence - keep accumulating

                    // Process complete lines
                    while let newlineIndex = buffer.firstIndex(of: "\n") {
                        let line = String(buffer[..<newlineIndex])
                        buffer = String(buffer[buffer.index(after: newlineIndex)...])

                        // Skip empty lines
                        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                            continue
                        }

                        // Parse SSE data line
                        if line.hasPrefix("data: ") {
                            let dataContent = String(line.dropFirst(6))

                            // Check for stream end (OpenAI format)
                            if dataContent.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                                // Check for accumulated tool calls before finishing
                                if let firstToolCall = accumulatedToolCalls.sorted(by: { $0.key < $1.key }).first,
                                    let toolName = firstToolCall.value.name
                                {
                                    continuation.finish(
                                        throwing: ServiceToolInvocation(
                                            toolName: toolName,
                                            jsonArguments: firstToolCall.value.args,
                                            toolCallId: firstToolCall.value.id
                                        )
                                    )
                                    return
                                }
                                continuation.finish()
                                return
                            }

                            // Parse JSON chunk based on provider type
                            if let jsonData = dataContent.data(using: .utf8) {
                                do {
                                    if providerType == .anthropic {
                                        // Parse Anthropic SSE event
                                        if let eventType = try? JSONDecoder().decode(
                                            AnthropicSSEEvent.self,
                                            from: jsonData
                                        ) {
                                            switch eventType.type {
                                            case "content_block_delta":
                                                if let deltaEvent = try? JSONDecoder().decode(
                                                    ContentBlockDeltaEvent.self,
                                                    from: jsonData
                                                ) {
                                                    if case .textDelta(let textDelta) = deltaEvent.delta {
                                                        var output = textDelta.text
                                                        for seq in stopSequences {
                                                            if let range = output.range(of: seq) {
                                                                output = String(output[..<range.lowerBound])
                                                                continuation.yield(output)
                                                                continuation.finish()
                                                                return
                                                            }
                                                        }
                                                        continuation.yield(output)
                                                    } else if case .inputJsonDelta(let jsonDelta) = deltaEvent.delta {
                                                        // Accumulate tool call JSON
                                                        let idx = deltaEvent.index
                                                        var current =
                                                            accumulatedToolCalls[idx] ?? (id: nil, name: nil, args: "")
                                                        current.args += jsonDelta.partial_json
                                                        accumulatedToolCalls[idx] = current
                                                    }
                                                }
                                            case "content_block_start":
                                                if let startEvent = try? JSONDecoder().decode(
                                                    ContentBlockStartEvent.self,
                                                    from: jsonData
                                                ) {
                                                    if case .toolUse(let toolBlock) = startEvent.content_block {
                                                        let idx = startEvent.index
                                                        accumulatedToolCalls[idx] = (
                                                            id: toolBlock.id, name: toolBlock.name, args: ""
                                                        )
                                                    }
                                                }
                                            case "message_stop":
                                                // Check for accumulated tool calls before finishing
                                                if let firstToolCall = accumulatedToolCalls.sorted(by: {
                                                    $0.key < $1.key
                                                }).first,
                                                    let toolName = firstToolCall.value.name
                                                {
                                                    continuation.finish(
                                                        throwing: ServiceToolInvocation(
                                                            toolName: toolName,
                                                            jsonArguments: firstToolCall.value.args,
                                                            toolCallId: firstToolCall.value.id
                                                        )
                                                    )
                                                    return
                                                }
                                                continuation.finish()
                                                return
                                            default:
                                                break
                                            }
                                        }
                                    } else {
                                        // OpenAI format
                                        let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: jsonData)
                                        if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                                            // Check stop sequences
                                            var output = delta
                                            for seq in stopSequences {
                                                if let range = output.range(of: seq) {
                                                    output = String(output[..<range.lowerBound])
                                                    continuation.yield(output)
                                                    continuation.finish()
                                                    return
                                                }
                                            }
                                            continuation.yield(output)
                                        }

                                        // Accumulate tool calls by index
                                        if let toolCalls = chunk.choices.first?.delta.tool_calls {
                                            for toolCall in toolCalls {
                                                let idx = toolCall.index ?? 0
                                                var current =
                                                    accumulatedToolCalls[idx] ?? (id: nil, name: nil, args: "")

                                                if let id = toolCall.id {
                                                    current.id = id
                                                }
                                                if let name = toolCall.function?.name {
                                                    current.name = name
                                                }
                                                if let args = toolCall.function?.arguments {
                                                    current.args += args
                                                }
                                                accumulatedToolCalls[idx] = current
                                            }
                                        }

                                        // Check for finish reason - emit tool calls if we have any
                                        if let finishReason = chunk.choices.first?.finish_reason,
                                            !finishReason.isEmpty,
                                            !accumulatedToolCalls.isEmpty
                                        {
                                            if let firstToolCall = accumulatedToolCalls.sorted(by: { $0.key < $1.key })
                                                .first,
                                                let toolName = firstToolCall.value.name
                                            {
                                                continuation.finish(
                                                    throwing: ServiceToolInvocation(
                                                        toolName: toolName,
                                                        jsonArguments: firstToolCall.value.args,
                                                        toolCallId: firstToolCall.value.id
                                                    )
                                                )
                                                return
                                            }
                                        }
                                    }
                                } catch {
                                    // Log parsing errors for debugging
                                    print(
                                        "[Osaurus] Warning: Failed to parse SSE chunk in streamDeltas: \(error.localizedDescription)"
                                    )
                                }
                            }
                        }
                    }
                }

                // Check for accumulated tool calls at stream end
                if let firstToolCall = accumulatedToolCalls.sorted(by: { $0.key < $1.key }).first,
                    let toolName = firstToolCall.value.name
                {
                    continuation.finish(
                        throwing: ServiceToolInvocation(
                            toolName: toolName,
                            jsonArguments: firstToolCall.value.args,
                            toolCallId: firstToolCall.value.id
                        )
                    )
                    return
                }

                continuation.finish()
            } catch {
                // Handle cancellation gracefully
                if Task.isCancelled {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error)
                }
            }
        }

        // Cancel producer task when consumer stops consuming
        continuation.onTermination = { @Sendable _ in
            producerTask.cancel()
        }

        return stream
    }

    // MARK: - ToolCapableService Protocol

    func respondWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        requestedModel: String?
    ) async throws -> String {
        guard let modelName = extractModelName(requestedModel) else {
            throw RemoteProviderServiceError.noModelsAvailable
        }

        var request = buildChatRequest(
            messages: messages,
            parameters: parameters,
            model: modelName,
            stream: false,
            tools: tools.isEmpty ? nil : tools,
            toolChoice: toolChoice
        )

        if !stopSequences.isEmpty {
            request.stop = stopSequences
        }

        let (data, response) = try await session.data(for: try buildURLRequest(for: request))

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteProviderServiceError.invalidResponse
        }

        if httpResponse.statusCode >= 400 {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw RemoteProviderServiceError.requestFailed("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        let (content, toolCalls) = try parseResponse(data)

        // Check for tool calls
        if let toolCalls = toolCalls, let firstCall = toolCalls.first {
            throw ServiceToolInvocation(
                toolName: firstCall.function.name,
                jsonArguments: firstCall.function.arguments,
                toolCallId: firstCall.id
            )
        }

        return content ?? ""
    }

    func streamWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        requestedModel: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let modelName = extractModelName(requestedModel) else {
            throw RemoteProviderServiceError.noModelsAvailable
        }

        var request = buildChatRequest(
            messages: messages,
            parameters: parameters,
            model: modelName,
            stream: true,
            tools: tools.isEmpty ? nil : tools,
            toolChoice: toolChoice
        )

        if !stopSequences.isEmpty {
            request.stop = stopSequences
        }

        let urlRequest = try buildURLRequest(for: request)
        let currentSession = self.session
        let providerType = self.provider.providerType

        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()

        let producerTask = Task {
            do {
                let (bytes, response) = try await currentSession.bytes(for: urlRequest)

                guard let httpResponse = response as? HTTPURLResponse else {
                    continuation.finish(throwing: RemoteProviderServiceError.invalidResponse)
                    return
                }

                if httpResponse.statusCode >= 400 {
                    var errorData = Data()
                    for try await byte in bytes {
                        errorData.append(byte)
                    }
                    let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    continuation.finish(
                        throwing: RemoteProviderServiceError.requestFailed(
                            "HTTP \(httpResponse.statusCode): \(errorMessage)"
                        )
                    )
                    return
                }

                // Track accumulated tool calls by index (supports multiple parallel tool calls)
                // Structure: [index: (id, name, arguments)]
                var accumulatedToolCalls: [Int: (id: String?, name: String?, args: String)] = [:]

                // Track if we've seen any finish reason (for edge case handling)
                var lastFinishReason: String?

                // Parse SSE stream with proper UTF-8 decoding
                var buffer = ""
                var utf8Buffer = Data()
                for try await byte in bytes {
                    // Check for task cancellation to allow early termination
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    utf8Buffer.append(byte)
                    // Try to decode accumulated bytes as UTF-8
                    if let decoded = String(data: utf8Buffer, encoding: .utf8) {
                        buffer.append(decoded)
                        utf8Buffer.removeAll()
                    }
                    // If decoding fails, we have an incomplete multi-byte sequence - keep accumulating

                    while let newlineIndex = buffer.firstIndex(of: "\n") {
                        let line = String(buffer[..<newlineIndex])
                        buffer = String(buffer[buffer.index(after: newlineIndex)...])

                        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                            continue
                        }

                        if line.hasPrefix("data: ") {
                            let dataContent = String(line.dropFirst(6))

                            if dataContent.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                                // If we accumulated any tool calls, emit the first one
                                // (subsequent tool calls will be handled in the next loop iteration)
                                if let firstToolCall = accumulatedToolCalls.sorted(by: { $0.key < $1.key }).first,
                                    let toolName = firstToolCall.value.name
                                {
                                    print(
                                        "[Osaurus] Stream [DONE]: Emitting accumulated tool call '\(toolName)' with \(firstToolCall.value.args.count) bytes of arguments"
                                    )
                                    continuation.finish(
                                        throwing: ServiceToolInvocation(
                                            toolName: toolName,
                                            jsonArguments: firstToolCall.value.args,
                                            toolCallId: firstToolCall.value.id
                                        )
                                    )
                                    return
                                }
                                continuation.finish()
                                return
                            }

                            if let jsonData = dataContent.data(using: .utf8) {
                                do {
                                    if providerType == .anthropic {
                                        // Parse Anthropic SSE event
                                        if let eventType = try? JSONDecoder().decode(
                                            AnthropicSSEEvent.self,
                                            from: jsonData
                                        ) {
                                            switch eventType.type {
                                            case "content_block_delta":
                                                if let deltaEvent = try? JSONDecoder().decode(
                                                    ContentBlockDeltaEvent.self,
                                                    from: jsonData
                                                ) {
                                                    if case .textDelta(let textDelta) = deltaEvent.delta {
                                                        var output = textDelta.text
                                                        for seq in stopSequences {
                                                            if let range = output.range(of: seq) {
                                                                output = String(output[..<range.lowerBound])
                                                                continuation.yield(output)
                                                                continuation.finish()
                                                                return
                                                            }
                                                        }
                                                        continuation.yield(output)
                                                    } else if case .inputJsonDelta(let jsonDelta) = deltaEvent.delta {
                                                        // Accumulate tool call JSON
                                                        let idx = deltaEvent.index
                                                        var current =
                                                            accumulatedToolCalls[idx] ?? (id: nil, name: nil, args: "")
                                                        current.args += jsonDelta.partial_json
                                                        accumulatedToolCalls[idx] = current
                                                    }
                                                }
                                            case "content_block_start":
                                                if let startEvent = try? JSONDecoder().decode(
                                                    ContentBlockStartEvent.self,
                                                    from: jsonData
                                                ) {
                                                    if case .toolUse(let toolBlock) = startEvent.content_block {
                                                        let idx = startEvent.index
                                                        accumulatedToolCalls[idx] = (
                                                            id: toolBlock.id, name: toolBlock.name, args: ""
                                                        )
                                                        print(
                                                            "[Osaurus] Tool call detected: index=\(idx), name=\(toolBlock.name)"
                                                        )
                                                    }
                                                }
                                            case "message_delta":
                                                if let deltaEvent = try? JSONDecoder().decode(
                                                    MessageDeltaEvent.self,
                                                    from: jsonData
                                                ) {
                                                    if let stopReason = deltaEvent.delta.stop_reason {
                                                        lastFinishReason = stopReason
                                                    }
                                                }
                                            case "message_stop":
                                                // Check for accumulated tool calls before finishing
                                                if let firstToolCall = accumulatedToolCalls.sorted(by: {
                                                    $0.key < $1.key
                                                }).first,
                                                    let toolName = firstToolCall.value.name
                                                {
                                                    print(
                                                        "[Osaurus] Anthropic stream ended: Emitting tool call '\(toolName)'"
                                                    )
                                                    continuation.finish(
                                                        throwing: ServiceToolInvocation(
                                                            toolName: toolName,
                                                            jsonArguments: firstToolCall.value.args,
                                                            toolCallId: firstToolCall.value.id
                                                        )
                                                    )
                                                    return
                                                }
                                                continuation.finish()
                                                return
                                            default:
                                                break
                                            }
                                        }
                                    } else {
                                        // OpenAI format
                                        let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: jsonData)

                                        // Handle content delta
                                        if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                                            var output = delta
                                            for seq in stopSequences {
                                                if let range = output.range(of: seq) {
                                                    output = String(output[..<range.lowerBound])
                                                    continuation.yield(output)
                                                    continuation.finish()
                                                    return
                                                }
                                            }
                                            continuation.yield(output)
                                        }

                                        // Handle tool call deltas - track by index for multiple parallel tool calls
                                        if let toolCalls = chunk.choices.first?.delta.tool_calls {
                                            for toolCall in toolCalls {
                                                let idx = toolCall.index ?? 0
                                                var current =
                                                    accumulatedToolCalls[idx] ?? (id: nil, name: nil, args: "")

                                                // Preserve tool call ID from the stream
                                                if let id = toolCall.id {
                                                    current.id = id
                                                }
                                                if let name = toolCall.function?.name {
                                                    current.name = name
                                                    print("[Osaurus] Tool call detected: index=\(idx), name=\(name)")
                                                }
                                                if let args = toolCall.function?.arguments {
                                                    current.args += args
                                                }
                                                accumulatedToolCalls[idx] = current
                                            }
                                        }

                                        // Check finish reason - handle various formats from different providers
                                        if let finishReason = chunk.choices.first?.finish_reason,
                                            !finishReason.isEmpty
                                        {
                                            lastFinishReason = finishReason
                                            print(
                                                "[Osaurus] Received finish_reason: '\(finishReason)', accumulated tool calls: \(accumulatedToolCalls.count)"
                                            )

                                            // Emit tool call if we have accumulated data and finish reason indicates tool calls
                                            // Some providers use "tool_calls", others might use "function_call" or just "stop"
                                            if !accumulatedToolCalls.isEmpty {
                                                if let firstToolCall = accumulatedToolCalls.sorted(by: {
                                                    $0.key < $1.key
                                                }).first,
                                                    let toolName = firstToolCall.value.name
                                                {
                                                    print(
                                                        "[Osaurus] Emitting tool call '\(toolName)' on finish_reason '\(finishReason)'"
                                                    )
                                                    continuation.finish(
                                                        throwing: ServiceToolInvocation(
                                                            toolName: toolName,
                                                            jsonArguments: firstToolCall.value.args,
                                                            toolCallId: firstToolCall.value.id
                                                        )
                                                    )
                                                    return
                                                }
                                            }
                                        }
                                    }
                                } catch {
                                    // Log parsing errors for debugging instead of silently ignoring
                                    print(
                                        "[Osaurus] Warning: Failed to parse SSE chunk: \(error.localizedDescription)"
                                    )
                                    print("[Osaurus] Raw chunk data: \(dataContent.prefix(500))")
                                }
                            }
                        }
                    }
                }

                // If we have accumulated tool call data at stream end (without [DONE] or explicit finish_reason)
                if let firstToolCall = accumulatedToolCalls.sorted(by: { $0.key < $1.key }).first,
                    let toolName = firstToolCall.value.name
                {
                    print(
                        "[Osaurus] Stream ended: Emitting accumulated tool call '\(toolName)' (finish_reason was: \(lastFinishReason ?? "none"))"
                    )
                    continuation.finish(
                        throwing: ServiceToolInvocation(
                            toolName: toolName,
                            jsonArguments: firstToolCall.value.args,
                            toolCallId: firstToolCall.value.id
                        )
                    )
                    return
                }

                continuation.finish()
            } catch {
                // Handle cancellation gracefully
                if Task.isCancelled {
                    continuation.finish()
                } else {
                    print("[Osaurus] Stream error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }

        // Cancel producer task when consumer stops consuming
        continuation.onTermination = { @Sendable _ in
            producerTask.cancel()
        }

        return stream
    }

    // MARK: - Private Helpers

    /// Build a chat completion request structure
    private func buildChatRequest(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        model: String,
        stream: Bool,
        tools: [Tool]?,
        toolChoice: ToolChoiceOption?
    ) -> RemoteChatRequest {
        return RemoteChatRequest(
            model: model,
            messages: messages,
            temperature: parameters.temperature,
            max_completion_tokens: parameters.maxTokens,
            stream: stream,
            top_p: parameters.topPOverride,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            tools: tools,
            tool_choice: toolChoice
        )
    }

    /// Build a URLRequest for the chat completions endpoint
    private func buildURLRequest(for request: RemoteChatRequest) throws -> URLRequest {
        let endpoint = provider.providerType.chatEndpoint
        guard let url = provider.url(for: endpoint) else {
            throw RemoteProviderServiceError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Set Accept header based on streaming mode
        if request.stream {
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        } else {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        // Add provider headers (including auth)
        for (key, value) in provider.resolvedHeaders() {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        // Encode request body based on provider type
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        let bodyData: Data
        switch provider.providerType {
        case .anthropic:
            let anthropicRequest = request.toAnthropicRequest()
            bodyData = try encoder.encode(anthropicRequest)
        case .openai:
            bodyData = try encoder.encode(request)
        }
        urlRequest.httpBody = bodyData

        // Debug: print the request body
        if let jsonString = String(data: bodyData, encoding: .utf8) {
            print("[Osaurus] Remote Provider (\(provider.providerType.rawValue)) Request Body:\n\(jsonString)")
        }

        return urlRequest
    }

    /// Parse response based on provider type
    private func parseResponse(_ data: Data) throws -> (content: String?, toolCalls: [ToolCall]?) {
        switch provider.providerType {
        case .anthropic:
            let response = try JSONDecoder().decode(AnthropicMessagesResponse.self, from: data)
            var textContent = ""
            var toolCalls: [ToolCall] = []

            for block in response.content {
                switch block {
                case .text(_, let text):
                    textContent += text
                case .toolUse(_, let id, let name, let input):
                    let argsData = try? JSONSerialization.data(withJSONObject: input.mapValues { $0.value })
                    let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    toolCalls.append(
                        ToolCall(
                            id: id,
                            type: "function",
                            function: ToolCallFunction(name: name, arguments: argsString)
                        )
                    )
                }
            }

            return (textContent.isEmpty ? nil : textContent, toolCalls.isEmpty ? nil : toolCalls)

        case .openai:
            let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            let content = response.choices.first?.message.content
            let toolCalls = response.choices.first?.message.tool_calls
            return (content, toolCalls)
        }
    }
}

// MARK: - Helper for Anthropic SSE Event Type Detection

/// Simple struct to decode Anthropic SSE event type
private struct AnthropicSSEEvent: Decodable {
    let type: String
}

// MARK: - Request/Response Models for Remote Provider

/// Chat request structure for remote providers (matches OpenAI format)
private struct RemoteChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Float?
    let max_completion_tokens: Int?  // OpenAI's newer parameter name
    let stream: Bool
    let top_p: Float?
    let frequency_penalty: Float?
    let presence_penalty: Float?
    var stop: [String]?
    let tools: [Tool]?
    let tool_choice: ToolChoiceOption?

    /// Convert to Anthropic Messages API request format
    func toAnthropicRequest() -> AnthropicMessagesRequest {
        var systemContent: AnthropicSystemContent? = nil
        var anthropicMessages: [AnthropicMessage] = []

        // Collect consecutive tool_result blocks to batch them into a single user message
        // Anthropic requires all tool_results for a tool_use to be in the immediately following user message
        var pendingToolResults: [AnthropicContentBlock] = []

        // Helper to flush pending tool results into a single user message
        func flushToolResults() {
            if !pendingToolResults.isEmpty {
                anthropicMessages.append(
                    AnthropicMessage(
                        role: "user",
                        content: .blocks(pendingToolResults)
                    )
                )
                pendingToolResults = []
            }
        }

        for msg in messages {
            switch msg.role {
            case "system":
                // Flush any pending tool results before system message
                flushToolResults()
                // Collect system messages
                if let content = msg.content {
                    systemContent = .text(content)
                }

            case "user":
                // Flush any pending tool results before user message
                flushToolResults()
                // Convert user messages
                if let content = msg.content {
                    anthropicMessages.append(
                        AnthropicMessage(
                            role: "user",
                            content: .text(content)
                        )
                    )
                }

            case "assistant":
                // Flush any pending tool results before assistant message
                flushToolResults()
                // Convert assistant messages, including tool calls
                var blocks: [AnthropicContentBlock] = []

                if let content = msg.content, !content.isEmpty {
                    blocks.append(.text(AnthropicTextBlock(text: content)))
                }

                if let toolCalls = msg.tool_calls {
                    for toolCall in toolCalls {
                        var input: [String: AnyCodableValue] = [:]

                        if let argsData = toolCall.function.arguments.data(using: .utf8),
                            let argsDict = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                        {
                            input = argsDict.mapValues { AnyCodableValue($0) }
                        }

                        blocks.append(
                            .toolUse(
                                AnthropicToolUseBlock(
                                    id: toolCall.id,
                                    name: toolCall.function.name,
                                    input: input
                                )
                            )
                        )
                    }
                }

                if !blocks.isEmpty {
                    anthropicMessages.append(
                        AnthropicMessage(
                            role: "assistant",
                            content: .blocks(blocks)
                        )
                    )
                }

            case "tool":
                // Collect tool results - they will be batched into a single user message
                // when we encounter a non-tool message or reach the end
                if let toolCallId = msg.tool_call_id, let content = msg.content {
                    pendingToolResults.append(
                        .toolResult(
                            AnthropicToolResultBlock(
                                type: "tool_result",
                                tool_use_id: toolCallId,
                                content: .text(content),
                                is_error: nil
                            )
                        )
                    )
                }

            default:
                // Flush any pending tool results before unknown message type
                flushToolResults()
                break
            }
        }

        // Flush any remaining tool results at the end
        flushToolResults()

        // Convert tools
        var anthropicTools: [AnthropicTool]? = nil
        if let tools = tools {
            anthropicTools = tools.map { tool in
                AnthropicTool(
                    name: tool.function.name,
                    description: tool.function.description,
                    input_schema: tool.function.parameters
                )
            }
        }

        // Convert tool choice
        var anthropicToolChoice: AnthropicToolChoice? = nil
        if let choice = tool_choice {
            switch choice {
            case .auto:
                anthropicToolChoice = .auto
            case .none:
                anthropicToolChoice = AnthropicToolChoice.none
            case .function(let fn):
                anthropicToolChoice = .tool(name: fn.function.name)
            }
        }

        return AnthropicMessagesRequest(
            model: model,
            max_tokens: max_completion_tokens ?? 4096,
            system: systemContent,
            messages: anthropicMessages,
            stream: stream,
            temperature: temperature.map { Double($0) },
            top_p: top_p.map { Double($0) },
            top_k: nil,
            stop_sequences: stop,
            tools: anthropicTools,
            tool_choice: anthropicToolChoice,
            metadata: nil
        )
    }
}

// MARK: - Static Factory for Creating Services

extension RemoteProviderService {
    /// Known Anthropic models (Anthropic doesn't have a /models endpoint)
    /// Using aliases where available for cleaner names
    private static let anthropicModels = [
        // Claude 4.5 (current)
        "claude-sonnet-4-5",
        "claude-haiku-4-5",
        "claude-opus-4-5",
        // Claude 4.1 (legacy)
        "claude-opus-4-1",
        // Claude 4 (legacy)
        "claude-sonnet-4-0",
        "claude-opus-4-0",
        // Claude 3.7 (legacy)
        "claude-3-7-sonnet-latest",
        // Claude 3 (legacy)
        "claude-3-haiku-20240307",
    ]

    /// Fetch models from a remote provider and create a service instance
    public static func fetchModels(from provider: RemoteProvider) async throws -> [String] {
        // Anthropic doesn't have a /models endpoint, so we return known models
        // and validate the API key with a minimal request
        if provider.providerType == .anthropic {
            // Validate the API key by making a minimal request
            try await validateAnthropicConnection(provider: provider)
            return anthropicModels
        }

        // OpenAI-compatible providers use /models endpoint
        guard let url = provider.url(for: "/models") else {
            throw RemoteProviderServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Add provider headers
        for (key, value) in provider.resolvedHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = min(provider.timeout, 30)
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteProviderServiceError.invalidResponse
        }

        if httpResponse.statusCode >= 400 {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw RemoteProviderServiceError.requestFailed("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        // Parse models response
        let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return modelsResponse.data.map { $0.id }
    }

    /// Validate Anthropic connection by making a minimal API request
    private static func validateAnthropicConnection(provider: RemoteProvider) async throws {
        guard let url = provider.url(for: "/messages") else {
            throw RemoteProviderServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Add provider headers
        for (key, value) in provider.resolvedHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Minimal valid request to test authentication
        let testBody: [String: Any] = [
            "model": "claude-3-haiku-20240307",
            "max_tokens": 1,
            "messages": [
                ["role": "user", "content": "Hi"]
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: testBody)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = min(provider.timeout, 30)
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteProviderServiceError.invalidResponse
        }

        // 401 = invalid API key, 400 = might be rate limit or other issue
        // 200 = success (we made a valid request)
        // 529 = overloaded (but connection works)
        if httpResponse.statusCode == 401 {
            throw RemoteProviderServiceError.requestFailed("Invalid API key")
        } else if httpResponse.statusCode >= 500 {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Server error"
            throw RemoteProviderServiceError.requestFailed("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }
        // Any 2xx or 4xx (except 401) means the connection works
    }
}
