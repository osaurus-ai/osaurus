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

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = provider.timeout
        // Resource timeout must be generous because image generation (non-streaming)
        // can take several minutes for thinking + rendering.
        config.timeoutIntervalForResource = max(provider.timeout * 2, 600)
        self.session = URLSession(configuration: config)
    }

    /// Minimum timeout for image generation models (5 minutes).
    private static let imageModelMinTimeout: TimeInterval = 300

    /// Returns `true` when the model name indicates an image-generation-capable model.
    fileprivate static func isImageCapableModel(_ modelName: String) -> Bool {
        Gemini31FlashImageProfile.matches(modelId: modelName) || GeminiProImageProfile.matches(modelId: modelName)
            || GeminiFlashImageProfile.matches(modelId: modelName)
    }

    /// Inactivity timeout for streaming: if no bytes arrive within this interval,
    /// assume the provider has stalled and end the stream.
    private var streamInactivityTimeout: TimeInterval { provider.timeout }

    /// Invalidate the URLSession to release its strong delegate reference.
    /// Must be called before discarding this service instance to avoid leaking.
    public func invalidateSession() {
        session.invalidateAndCancel()
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

        // Gemini image models don't support streamGenerateContent; fall back to generateContent.
        if provider.providerType == .gemini && Self.isImageCapableModel(modelName) {
            return try geminiImageGenerateContent(
                messages: messages,
                parameters: parameters,
                model: modelName,
                stopSequences: stopSequences,
                tools: nil,
                toolChoice: nil
            )
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
        let inactivityTimeout = self.streamInactivityTimeout

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
                var accumulatedToolCalls: [Int: (id: String?, name: String?, args: String, thoughtSignature: String?)] =
                    [:]

                // Parse SSE stream with UTF-8 decoding and inactivity timeout
                var buffer = ""
                var utf8Buffer = Data()
                let maxUtf8BufferSize = 1024
                let byteRef = ByteIteratorRef(bytes.makeAsyncIterator())

                while true {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    guard
                        let byte = try await Self.nextByte(
                            from: byteRef,
                            timeout: inactivityTimeout
                        )
                    else {
                        break
                    }

                    utf8Buffer.append(byte)
                    if let decoded = String(data: utf8Buffer, encoding: .utf8) {
                        buffer.append(decoded)
                        utf8Buffer.removeAll()
                    } else if utf8Buffer.count > maxUtf8BufferSize {
                        buffer.append(String(decoding: utf8Buffer, as: UTF8.self))
                        utf8Buffer.removeAll()
                    }

                    // Process complete lines
                    while let newlineIndex = buffer.firstIndex(where: { $0.isNewline }) {
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
                                if let invocation = Self.makeToolInvocation(from: accumulatedToolCalls) {
                                    continuation.finish(throwing: invocation)
                                    return
                                }
                                continuation.finish()
                                return
                            }

                            // Parse JSON chunk based on provider type
                            if let jsonData = dataContent.data(using: .utf8) {
                                do {
                                    if providerType == .gemini {
                                        // Parse Gemini SSE event (each chunk is a GeminiGenerateContentResponse)
                                        let chunk = try JSONDecoder().decode(
                                            GeminiGenerateContentResponse.self,
                                            from: jsonData
                                        )

                                        if let parts = chunk.candidates?.first?.content?.parts {
                                            for part in parts {
                                                if part.thought == true { continue }

                                                switch part.content {
                                                case .text(let text):
                                                    if accumulatedToolCalls.isEmpty, !text.isEmpty {
                                                        let output = Self.encodeTextWithSignature(
                                                            text,
                                                            signature: part.thoughtSignature
                                                        )
                                                        for seq in stopSequences {
                                                            if let range = output.range(of: seq) {
                                                                continuation.yield(String(output[..<range.lowerBound]))
                                                                continuation.finish()
                                                                return
                                                            }
                                                        }
                                                        continuation.yield(output)
                                                    }
                                                case .functionCall(let funcCall):
                                                    let idx = accumulatedToolCalls.count
                                                    let argsData = try? JSONSerialization.data(
                                                        withJSONObject: (funcCall.args ?? [:]).mapValues { $0.value }
                                                    )
                                                    let argsString =
                                                        argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                                                    accumulatedToolCalls[idx] = (
                                                        id: "gemini-\(UUID().uuidString.prefix(8))",
                                                        name: funcCall.name,
                                                        args: argsString,
                                                        thoughtSignature: funcCall.thoughtSignature
                                                    )
                                                case .inlineData(let imageData):
                                                    if accumulatedToolCalls.isEmpty {
                                                        continuation.yield(
                                                            Self.imageMarkdown(
                                                                imageData,
                                                                thoughtSignature: part.thoughtSignature
                                                            )
                                                        )
                                                    }
                                                case .functionResponse:
                                                    break
                                                }
                                            }
                                        }

                                        // Check for finish reason
                                        if let finishReason = chunk.candidates?.first?.finishReason {
                                            if finishReason == "SAFETY" {
                                                continuation.finish(
                                                    throwing: RemoteProviderServiceError.requestFailed(
                                                        "Content blocked by safety settings."
                                                    )
                                                )
                                                return
                                            }

                                            if finishReason == "STOP" || finishReason == "MAX_TOKENS" {
                                                if let invocation = Self.makeToolInvocation(from: accumulatedToolCalls)
                                                {
                                                    continuation.finish(throwing: invocation)
                                                    return
                                                }
                                                continuation.finish()
                                                return
                                            }
                                        }
                                    } else if providerType == .anthropic {
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
                                                            accumulatedToolCalls[idx] ?? (
                                                                id: nil, name: nil, args: "", thoughtSignature: nil
                                                            )
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
                                                            id: toolBlock.id, name: toolBlock.name, args: "",
                                                            thoughtSignature: nil
                                                        )
                                                    }
                                                }
                                            case "message_stop":
                                                if let invocation = Self.makeToolInvocation(from: accumulatedToolCalls)
                                                {
                                                    continuation.finish(throwing: invocation)
                                                    return
                                                }
                                                continuation.finish()
                                                return
                                            default:
                                                break
                                            }
                                        }
                                    } else if providerType == .openResponses {
                                        // Parse Open Responses SSE event
                                        if let eventType = try? JSONDecoder().decode(
                                            OpenResponsesSSEEvent.self,
                                            from: jsonData
                                        ) {
                                            switch eventType.type {
                                            case "response.output_text.delta":
                                                if let deltaEvent = try? JSONDecoder().decode(
                                                    OutputTextDeltaEvent.self,
                                                    from: jsonData
                                                ) {
                                                    var output = deltaEvent.delta
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
                                            case "response.output_item.added":
                                                if let addedEvent = try? JSONDecoder().decode(
                                                    OutputItemAddedEvent.self,
                                                    from: jsonData
                                                ) {
                                                    if case .functionCall(let funcCall) = addedEvent.item {
                                                        let idx = addedEvent.output_index
                                                        accumulatedToolCalls[idx] = (
                                                            id: funcCall.call_id, name: funcCall.name, args: "",
                                                            thoughtSignature: nil
                                                        )
                                                    }
                                                }
                                            case "response.function_call_arguments.delta":
                                                if let deltaEvent = try? JSONDecoder().decode(
                                                    FunctionCallArgumentsDeltaEvent.self,
                                                    from: jsonData
                                                ) {
                                                    let idx = deltaEvent.output_index
                                                    var current =
                                                        accumulatedToolCalls[idx] ?? (
                                                            id: deltaEvent.call_id, name: nil, args: "",
                                                            thoughtSignature: nil
                                                        )
                                                    current.args += deltaEvent.delta
                                                    accumulatedToolCalls[idx] = current
                                                }
                                            case "response.completed":
                                                if let invocation = Self.makeToolInvocation(from: accumulatedToolCalls)
                                                {
                                                    continuation.finish(throwing: invocation)
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

                                        // Accumulate tool calls by index FIRST (before yielding content)
                                        // This ensures we detect tool calls before deciding to yield content
                                        if let toolCalls = chunk.choices.first?.delta.tool_calls {
                                            for toolCall in toolCalls {
                                                let idx = toolCall.index ?? 0
                                                var current =
                                                    accumulatedToolCalls[idx] ?? (
                                                        id: nil, name: nil, args: "", thoughtSignature: nil
                                                    )

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

                                        // Only yield content if no tool calls have been detected
                                        // This prevents function-call JSON from leaking into the chat UI
                                        if accumulatedToolCalls.isEmpty,
                                            let delta = chunk.choices.first?.delta.content, !delta.isEmpty
                                        {
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

                                        // Emit tool calls on finish reason
                                        if let finishReason = chunk.choices.first?.finish_reason,
                                            !finishReason.isEmpty,
                                            let invocation = Self.makeToolInvocation(from: accumulatedToolCalls)
                                        {
                                            continuation.finish(throwing: invocation)
                                            return
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

                // Handle leftover buffer content (e.g. if the stream ended without a newline)
                if !buffer.trimmingCharacters(in: .whitespaces).isEmpty {
                    let line = buffer
                    if line.hasPrefix("data: ") {
                        let dataContent = String(line.dropFirst(6))

                        if let jsonData = dataContent.data(using: .utf8) {
                            do {
                                if providerType == .gemini {
                                    let chunk = try JSONDecoder().decode(
                                        GeminiGenerateContentResponse.self,
                                        from: jsonData
                                    )

                                    if let parts = chunk.candidates?.first?.content?.parts {
                                        for part in parts {
                                            if part.thought == true { continue }

                                            switch part.content {
                                            case .text(let text):
                                                if accumulatedToolCalls.isEmpty, !text.isEmpty {
                                                    let output = Self.encodeTextWithSignature(
                                                        text,
                                                        signature: part.thoughtSignature
                                                    )
                                                    for seq in stopSequences {
                                                        if let range = output.range(of: seq) {
                                                            continuation.yield(String(output[..<range.lowerBound]))
                                                            continuation.finish()
                                                            return
                                                        }
                                                    }
                                                    continuation.yield(output)
                                                }
                                            case .functionCall(let funcCall):
                                                let idx = accumulatedToolCalls.count
                                                let argsData = try? JSONSerialization.data(
                                                    withJSONObject: (funcCall.args ?? [:]).mapValues { $0.value }
                                                )
                                                let argsString =
                                                    argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                                                accumulatedToolCalls[idx] = (
                                                    id: "gemini-\(UUID().uuidString.prefix(8))",
                                                    name: funcCall.name,
                                                    args: argsString,
                                                    thoughtSignature: funcCall.thoughtSignature
                                                )
                                            case .inlineData(let imageData):
                                                if accumulatedToolCalls.isEmpty {
                                                    continuation.yield(
                                                        Self.imageMarkdown(
                                                            imageData,
                                                            thoughtSignature: part.thoughtSignature
                                                        )
                                                    )
                                                }
                                            case .functionResponse:
                                                break
                                            }
                                        }
                                    }
                                }
                            } catch {
                                // Leftover buffer parse failures are non-fatal
                            }
                        }
                    }
                }

                // Emit any accumulated tool calls at stream end
                if let invocation = Self.makeToolInvocation(from: accumulatedToolCalls) {
                    continuation.finish(throwing: invocation)
                    return
                }

                continuation.finish()
            } catch {
                if Task.isCancelled {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error)
                }
            }
        }

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
                toolCallId: firstCall.id,
                geminiThoughtSignature: firstCall.geminiThoughtSignature
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

        // Gemini image models don't support streamGenerateContent; fall back to generateContent.
        if provider.providerType == .gemini && Self.isImageCapableModel(modelName) {
            return try geminiImageGenerateContent(
                messages: messages,
                parameters: parameters,
                model: modelName,
                stopSequences: stopSequences,
                tools: tools.isEmpty ? nil : tools,
                toolChoice: toolChoice
            )
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
        let inactivityTimeout = self.streamInactivityTimeout

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
                var accumulatedToolCalls: [Int: (id: String?, name: String?, args: String, thoughtSignature: String?)] =
                    [:]

                // Track if we've seen any finish reason (for edge case handling)
                var lastFinishReason: String?

                // Accumulate yielded text content for fallback tool call detection.
                // Some models (e.g., Llama) embed tool calls inline in text instead
                // of using the structured tool_calls field.
                var accumulatedContent = ""

                // Parse SSE stream with UTF-8 decoding and inactivity timeout
                var buffer = ""
                var utf8Buffer = Data()
                let maxUtf8BufferSize = 1024
                let byteRef = ByteIteratorRef(bytes.makeAsyncIterator())

                while true {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    guard
                        let byte = try await Self.nextByte(
                            from: byteRef,
                            timeout: inactivityTimeout
                        )
                    else {
                        break
                    }

                    utf8Buffer.append(byte)
                    if let decoded = String(data: utf8Buffer, encoding: .utf8) {
                        buffer.append(decoded)
                        utf8Buffer.removeAll()
                    } else if utf8Buffer.count > maxUtf8BufferSize {
                        buffer.append(String(decoding: utf8Buffer, as: UTF8.self))
                        utf8Buffer.removeAll()
                    }

                    // Process complete lines
                    while let newlineIndex = buffer.firstIndex(where: { $0.isNewline }) {
                        let line = String(buffer[..<newlineIndex])
                        buffer = String(buffer[buffer.index(after: newlineIndex)...])

                        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                            continue
                        }

                        if line.hasPrefix("data: ") {
                            let dataContent = String(line.dropFirst(6))

                            if dataContent.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                                if let invocation = Self.makeToolInvocation(from: accumulatedToolCalls) {
                                    print("[Osaurus] Stream [DONE]: Emitting tool call '\(invocation.toolName)'")
                                    continuation.finish(throwing: invocation)
                                    return
                                }

                                // Fallback: detect inline tool calls in text content
                                if !accumulatedContent.isEmpty, !tools.isEmpty,
                                    let (name, args) = ToolDetection.detectInlineToolCall(
                                        in: accumulatedContent,
                                        tools: tools
                                    )
                                {
                                    print("[Osaurus] Fallback: Detected inline tool call '\(name)' in text")
                                    continuation.finish(
                                        throwing: ServiceToolInvocation(
                                            toolName: name,
                                            jsonArguments: args,
                                            toolCallId: nil
                                        )
                                    )
                                    return
                                }

                                continuation.finish()
                                return
                            }

                            if let jsonData = dataContent.data(using: .utf8) {
                                do {
                                    if providerType == .gemini {
                                        // Parse Gemini SSE event (each chunk is a GeminiGenerateContentResponse)
                                        let chunk = try JSONDecoder().decode(
                                            GeminiGenerateContentResponse.self,
                                            from: jsonData
                                        )

                                        if let parts = chunk.candidates?.first?.content?.parts {
                                            for part in parts {
                                                if part.thought == true { continue }

                                                switch part.content {
                                                case .text(let text):
                                                    if accumulatedToolCalls.isEmpty, !text.isEmpty {
                                                        let output = Self.encodeTextWithSignature(
                                                            text,
                                                            signature: part.thoughtSignature
                                                        )
                                                        for seq in stopSequences {
                                                            if let range = output.range(of: seq) {
                                                                let truncated = String(output[..<range.lowerBound])
                                                                accumulatedContent += truncated
                                                                continuation.yield(truncated)
                                                                continuation.finish()
                                                                return
                                                            }
                                                        }
                                                        accumulatedContent += output
                                                        continuation.yield(output)
                                                    }
                                                case .functionCall(let funcCall):
                                                    let idx = accumulatedToolCalls.count
                                                    let argsData = try? JSONSerialization.data(
                                                        withJSONObject: (funcCall.args ?? [:]).mapValues { $0.value }
                                                    )
                                                    let argsString =
                                                        argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                                                    accumulatedToolCalls[idx] = (
                                                        id: "gemini-\(UUID().uuidString.prefix(8))",
                                                        name: funcCall.name,
                                                        args: argsString,
                                                        thoughtSignature: funcCall.thoughtSignature
                                                    )
                                                    print(
                                                        "[Osaurus] Gemini tool call detected: index=\(idx), name=\(funcCall.name)"
                                                    )
                                                case .inlineData(let imageData):
                                                    if accumulatedToolCalls.isEmpty {
                                                        continuation.yield(
                                                            Self.imageMarkdown(
                                                                imageData,
                                                                thoughtSignature: part.thoughtSignature
                                                            )
                                                        )
                                                    }
                                                case .functionResponse:
                                                    break
                                                }
                                            }
                                        }

                                        // Check for finish reason
                                        if let finishReason = chunk.candidates?.first?.finishReason {
                                            lastFinishReason = finishReason

                                            if finishReason == "SAFETY" {
                                                continuation.finish(
                                                    throwing: RemoteProviderServiceError.requestFailed(
                                                        "Content blocked by safety settings."
                                                    )
                                                )
                                                return
                                            }

                                            if finishReason == "STOP" || finishReason == "MAX_TOKENS" {
                                                if let invocation = Self.makeToolInvocation(from: accumulatedToolCalls)
                                                {
                                                    print(
                                                        "[Osaurus] Gemini stream ended: Emitting tool call '\(invocation.toolName)'"
                                                    )
                                                    continuation.finish(throwing: invocation)
                                                    return
                                                }
                                                continuation.finish()
                                                return
                                            }
                                        }
                                    } else if providerType == .anthropic {
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
                                                            accumulatedToolCalls[idx] ?? (
                                                                id: nil, name: nil, args: "", thoughtSignature: nil
                                                            )
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
                                                            id: toolBlock.id, name: toolBlock.name, args: "",
                                                            thoughtSignature: nil
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
                                                if let invocation = Self.makeToolInvocation(from: accumulatedToolCalls)
                                                {
                                                    print(
                                                        "[Osaurus] Anthropic stream ended: Emitting tool call '\(invocation.toolName)'"
                                                    )
                                                    continuation.finish(throwing: invocation)
                                                    return
                                                }
                                                continuation.finish()
                                                return
                                            default:
                                                break
                                            }
                                        }
                                    } else if providerType == .openResponses {
                                        // Parse Open Responses SSE event
                                        if let eventType = try? JSONDecoder().decode(
                                            OpenResponsesSSEEvent.self,
                                            from: jsonData
                                        ) {
                                            switch eventType.type {
                                            case "response.output_text.delta":
                                                if let deltaEvent = try? JSONDecoder().decode(
                                                    OutputTextDeltaEvent.self,
                                                    from: jsonData
                                                ) {
                                                    var output = deltaEvent.delta
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
                                            case "response.output_item.added":
                                                if let addedEvent = try? JSONDecoder().decode(
                                                    OutputItemAddedEvent.self,
                                                    from: jsonData
                                                ) {
                                                    if case .functionCall(let funcCall) = addedEvent.item {
                                                        let idx = addedEvent.output_index
                                                        accumulatedToolCalls[idx] = (
                                                            id: funcCall.call_id, name: funcCall.name, args: "",
                                                            thoughtSignature: nil
                                                        )
                                                        print(
                                                            "[Osaurus] Open Responses tool call detected: index=\(idx), name=\(funcCall.name)"
                                                        )
                                                    }
                                                }
                                            case "response.function_call_arguments.delta":
                                                if let deltaEvent = try? JSONDecoder().decode(
                                                    FunctionCallArgumentsDeltaEvent.self,
                                                    from: jsonData
                                                ) {
                                                    let idx = deltaEvent.output_index
                                                    var current =
                                                        accumulatedToolCalls[idx] ?? (
                                                            id: deltaEvent.call_id, name: nil, args: "",
                                                            thoughtSignature: nil
                                                        )
                                                    current.args += deltaEvent.delta
                                                    accumulatedToolCalls[idx] = current
                                                }
                                            case "response.completed":
                                                lastFinishReason = "completed"
                                                if let invocation = Self.makeToolInvocation(from: accumulatedToolCalls)
                                                {
                                                    print(
                                                        "[Osaurus] Open Responses stream ended: Emitting tool call '\(invocation.toolName)'"
                                                    )
                                                    continuation.finish(throwing: invocation)
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

                                        // Handle tool call deltas FIRST - track by index for multiple parallel tool calls
                                        // This ensures we detect tool calls before deciding to yield content
                                        if let toolCalls = chunk.choices.first?.delta.tool_calls {
                                            for toolCall in toolCalls {
                                                let idx = toolCall.index ?? 0
                                                var current =
                                                    accumulatedToolCalls[idx] ?? (
                                                        id: nil, name: nil, args: "", thoughtSignature: nil
                                                    )

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

                                        // Only yield content if no tool calls have been detected
                                        // This prevents function-call JSON from leaking into the chat UI
                                        if accumulatedToolCalls.isEmpty,
                                            let delta = chunk.choices.first?.delta.content, !delta.isEmpty
                                        {
                                            var output = delta
                                            for seq in stopSequences {
                                                if let range = output.range(of: seq) {
                                                    output = String(output[..<range.lowerBound])
                                                    accumulatedContent += output
                                                    continuation.yield(output)
                                                    continuation.finish()
                                                    return
                                                }
                                            }
                                            accumulatedContent += output
                                            continuation.yield(output)
                                        }

                                        // Check finish reason — emit tool calls if available
                                        if let finishReason = chunk.choices.first?.finish_reason,
                                            !finishReason.isEmpty
                                        {
                                            lastFinishReason = finishReason
                                            if let invocation = Self.makeToolInvocation(from: accumulatedToolCalls) {
                                                print(
                                                    "[Osaurus] Emitting tool call '\(invocation.toolName)' on finish_reason '\(finishReason)'"
                                                )
                                                continuation.finish(throwing: invocation)
                                                return
                                            }
                                        }
                                    }
                                } catch {
                                    // Log parsing errors for debugging instead of silently ignoring
                                    print(
                                        "[Osaurus] Warning: Failed to parse SSE chunk: \(error.localizedDescription)"
                                    )
                                }
                            }
                        }
                    }
                }

                // Emit any accumulated tool call data at stream end
                if let invocation = Self.makeToolInvocation(from: accumulatedToolCalls) {
                    print(
                        "[Osaurus] Stream ended: Emitting tool call '\(invocation.toolName)' (finish_reason: \(lastFinishReason ?? "none"))"
                    )
                    continuation.finish(throwing: invocation)
                    return
                }

                // Fallback: detect inline tool calls in text content (e.g., Llama)
                if !accumulatedContent.isEmpty, !tools.isEmpty,
                    let (name, args) = ToolDetection.detectInlineToolCall(
                        in: accumulatedContent,
                        tools: tools
                    )
                {
                    print("[Osaurus] Fallback: Detected inline tool call '\(name)' in text")
                    continuation.finish(
                        throwing: ServiceToolInvocation(
                            toolName: name,
                            jsonArguments: args,
                            toolCallId: nil
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

    /// Actor wrapper around a byte iterator so it can be safely used inside escaping
    /// `addTask` closures (which cannot capture `inout` parameters directly).
    private final class ByteIteratorRef: @unchecked Sendable {
        private var iterator: URLSession.AsyncBytes.AsyncIterator
        private let lock = NSLock()
        init(_ iterator: URLSession.AsyncBytes.AsyncIterator) { self.iterator = iterator }
        func next() async throws -> UInt8? {
            // Only one task ever calls next() at a time (the other is just sleeping),
            // so the lock is uncontended but satisfies Sendable requirements.
            try await iterator.next()
        }
    }

    /// Reads the next byte from a `ByteIteratorRef`, racing against an inactivity timeout.
    /// Returns `nil` if the stream ended naturally or the timeout fired.
    private static func nextByte(
        from ref: ByteIteratorRef,
        timeout: TimeInterval
    ) async throws -> UInt8? {
        try await withThrowingTaskGroup(of: UInt8?.self) { group in
            group.addTask { try await ref.next() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// Creates a `ServiceToolInvocation` from the first accumulated tool call entry,
    /// validating the JSON arguments. Returns `nil` if there are no accumulated calls
    /// or the first entry has no name.
    private static func makeToolInvocation(
        from accumulated: [Int: (id: String?, name: String?, args: String, thoughtSignature: String?)]
    ) -> ServiceToolInvocation? {
        guard let first = accumulated.sorted(by: { $0.key < $1.key }).first,
            let name = first.value.name
        else { return nil }

        return ServiceToolInvocation(
            toolName: name,
            jsonArguments: validateToolCallJSON(first.value.args),
            toolCallId: first.value.id,
            geminiThoughtSignature: first.value.thoughtSignature
        )
    }

    /// Validates that tool call arguments JSON is well-formed.
    /// If the JSON is incomplete (e.g., stream was cut off mid-argument), attempts to repair it.
    /// Returns the original string if valid, or a best-effort repair.
    private static func validateToolCallJSON(_ json: String) -> String {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "{}" }

        // Quick validation: try to parse as-is
        if let data = trimmed.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) != nil
        {
            return trimmed
        }

        // Attempt repair: close unclosed braces/brackets
        var repaired = trimmed
        var braceCount = 0
        var bracketCount = 0
        var inString = false
        var isEscaped = false
        for ch in repaired {
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if ch == "\\" {
                    isEscaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    braceCount += 1
                } else if ch == "}" {
                    braceCount -= 1
                } else if ch == "[" {
                    bracketCount += 1
                } else if ch == "]" {
                    bracketCount -= 1
                }
            }
        }

        // Close any unclosed strings
        if inString {
            repaired += "\""
        }

        // Remove trailing comma before closing
        let trimmedForComma = repaired.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedForComma.hasSuffix(",") {
            repaired = String(trimmedForComma.dropLast())
        }

        // Close unclosed brackets and braces
        for _ in 0 ..< bracketCount {
            repaired += "]"
        }
        for _ in 0 ..< braceCount {
            repaired += "}"
        }

        // Verify the repair worked
        if let data = repaired.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) != nil
        {
            print("[Osaurus] Repaired incomplete tool call JSON (\(json.count) -> \(repaired.count) chars)")
            return repaired
        }

        // Repair failed - return original and let downstream handle the error
        print("[Osaurus] Warning: Tool call JSON is malformed and could not be repaired: \(json.prefix(200))")
        return json
    }

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
            tool_choice: toolChoice,
            modelOptions: parameters.modelOptions
        )
    }

    /// Non-streaming `generateContent` fallback for Gemini image models (Nano Banana).
    /// Image models don't support `streamGenerateContent`, so this wraps the
    /// single-shot response in an `AsyncThrowingStream` for the streaming callers.
    private func geminiImageGenerateContent(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        model: String,
        stopSequences: [String],
        tools: [Tool]?,
        toolChoice: ToolChoiceOption?
    ) throws -> AsyncThrowingStream<String, Error> {
        var request = buildChatRequest(
            messages: messages,
            parameters: parameters,
            model: model,
            stream: false,
            tools: tools,
            toolChoice: toolChoice
        )

        if !stopSequences.isEmpty {
            request.stop = stopSequences
        }

        let urlRequest = try buildURLRequest(for: request)
        let currentSession = self.session

        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()

        let producerTask = Task {
            do {
                let (data, response) = try await currentSession.data(for: urlRequest)

                guard let httpResponse = response as? HTTPURLResponse else {
                    continuation.finish(throwing: RemoteProviderServiceError.invalidResponse)
                    return
                }

                if httpResponse.statusCode >= 400 {
                    let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                    continuation.finish(
                        throwing: RemoteProviderServiceError.requestFailed(
                            "HTTP \(httpResponse.statusCode): \(errorMessage)"
                        )
                    )
                    return
                }

                let geminiResponse = try JSONDecoder().decode(
                    GeminiGenerateContentResponse.self,
                    from: data
                )

                if let parts = geminiResponse.candidates?.first?.content?.parts {
                    var pendingToolCall: ServiceToolInvocation? = nil

                    for part in parts {
                        if part.thought == true { continue }

                        switch part.content {
                        case .text(let text):
                            if !text.isEmpty {
                                continuation.yield(Self.encodeTextWithSignature(text, signature: part.thoughtSignature))
                            }
                        case .inlineData(let imageData):
                            continuation.yield(Self.imageMarkdown(imageData, thoughtSignature: part.thoughtSignature))
                        case .functionCall(let funcCall):
                            let argsData = try? JSONSerialization.data(
                                withJSONObject: (funcCall.args ?? [:]).mapValues { $0.value }
                            )
                            let argsString =
                                argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                            pendingToolCall = ServiceToolInvocation(
                                toolName: funcCall.name,
                                jsonArguments: argsString,
                                toolCallId: "gemini-\(UUID().uuidString.prefix(8))",
                                geminiThoughtSignature: funcCall.thoughtSignature
                            )
                        case .functionResponse:
                            break
                        }
                    }

                    if let invocation = pendingToolCall {
                        continuation.finish(throwing: invocation)
                        return
                    }
                }

                continuation.finish()
            } catch {
                if Task.isCancelled {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error)
                }
            }
        }

        continuation.onTermination = { @Sendable _ in
            producerTask.cancel()
        }

        return stream
    }

    /// Build a URLRequest for the chat completions endpoint
    private func buildURLRequest(for request: RemoteChatRequest) throws -> URLRequest {
        let url: URL

        if provider.providerType == .gemini {
            // Gemini uses model-in-URL pattern: /models/{model}:generateContent or :streamGenerateContent
            let action = request.stream ? "streamGenerateContent" : "generateContent"
            let endpoint = "/models/\(request.model):\(action)"
            guard let geminiURL = provider.url(for: endpoint) else {
                throw RemoteProviderServiceError.invalidURL
            }
            if request.stream {
                // Append ?alt=sse for SSE-formatted streaming
                guard var components = URLComponents(url: geminiURL, resolvingAgainstBaseURL: false) else {
                    throw RemoteProviderServiceError.invalidURL
                }
                components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "alt", value: "sse")]
                guard let sseURL = components.url else {
                    throw RemoteProviderServiceError.invalidURL
                }
                url = sseURL
            } else {
                url = geminiURL
            }
        } else {
            let endpoint = provider.providerType.chatEndpoint
            guard let standardURL = provider.url(for: endpoint) else {
                throw RemoteProviderServiceError.invalidURL
            }
            url = standardURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if Self.isImageCapableModel(request.model) {
            urlRequest.timeoutInterval = max(provider.timeout, Self.imageModelMinTimeout)
        }

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
        case .openResponses:
            let openResponsesRequest = request.toOpenResponsesRequest()
            bodyData = try encoder.encode(openResponsesRequest)
        case .gemini:
            let geminiRequest = request.toGeminiRequest()
            bodyData = try encoder.encode(geminiRequest)
        }
        urlRequest.httpBody = bodyData
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

        case .openResponses:
            let response = try JSONDecoder().decode(OpenResponsesResponse.self, from: data)
            var textContent = ""
            var toolCalls: [ToolCall] = []

            for item in response.output {
                switch item {
                case .message(let message):
                    for content in message.content {
                        if case .outputText(let text) = content {
                            textContent += text.text
                        }
                    }
                case .functionCall(let funcCall):
                    toolCalls.append(
                        ToolCall(
                            id: funcCall.call_id,
                            type: "function",
                            function: ToolCallFunction(name: funcCall.name, arguments: funcCall.arguments)
                        )
                    )
                }
            }

            return (textContent.isEmpty ? nil : textContent, toolCalls.isEmpty ? nil : toolCalls)

        case .gemini:
            let response = try JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data)
            var textContent = ""
            var toolCalls: [ToolCall] = []

            if let parts = response.candidates?.first?.content?.parts {
                for part in parts {
                    if part.thought == true { continue }

                    switch part.content {
                    case .text(let text):
                        textContent += Self.encodeTextWithSignature(text, signature: part.thoughtSignature)
                    case .functionCall(let funcCall):
                        let argsData = try? JSONSerialization.data(
                            withJSONObject: (funcCall.args ?? [:]).mapValues { $0.value }
                        )
                        let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        toolCalls.append(
                            ToolCall(
                                id: "gemini-\(UUID().uuidString.prefix(8))",
                                type: "function",
                                function: ToolCallFunction(name: funcCall.name, arguments: argsString),
                                geminiThoughtSignature: funcCall.thoughtSignature
                            )
                        )
                    case .inlineData(let imageData):
                        textContent += Self.imageMarkdown(imageData, thoughtSignature: part.thoughtSignature)
                    case .functionResponse:
                        break  // Not expected in responses from model
                    }
                }
            }

            return (textContent.isEmpty ? nil : textContent, toolCalls.isEmpty ? nil : toolCalls)
        }
    }

    // MARK: - Thought-Signature Round-Trip Helpers

    /// Embed a thought-signature in text via invisible ZWS delimiters: `\u{200B}ts:SIG\u{200B}`.
    static func encodeTextWithSignature(_ text: String, signature: String?) -> String {
        guard let sig = signature else { return text }
        return "\u{200B}ts:\(sig)\u{200B}" + text
    }

    /// Build markdown for an inline image, embedding the thought-signature in the alt text.
    static func imageMarkdown(_ data: GeminiInlineData, thoughtSignature: String?) -> String {
        let alt = thoughtSignature.map { "image|ts:\($0)" } ?? "image"
        return "\n\n![\(alt)](data:\(data.mimeType);base64,\(data.data))\n\n"
    }

    /// Strip a ZWS-delimited thought-signature marker from the start of a text segment.
    private static func stripTextSignature(_ text: String) -> (text: String, thoughtSignature: String?) {
        let prefix = "\u{200B}ts:"
        guard text.hasPrefix(prefix) else { return (text, nil) }
        let rest = text.dropFirst(prefix.count)
        guard let end = rest.firstIndex(of: "\u{200B}") else { return (text, nil) }
        return (String(rest[rest.index(after: end)...]), String(rest[rest.startIndex ..< end]))
    }

    /// Split assistant text into `GeminiPart` array, converting data-URI images to
    /// `inlineData` parts and recovering thought-signatures from both image alt-text
    /// markers (`image|ts:SIG`) and text ZWS markers.
    static func extractInlineImages(from text: String) -> [GeminiPart] {
        let pattern = #"!\[([^\]]*)\]\(data:([^;]+);base64,([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
            !regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).isEmpty
        else {
            let (cleaned, sig) = stripTextSignature(text)
            return [GeminiPart(content: .text(cleaned), thoughtSignature: sig)]
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var parts: [GeminiPart] = []
        var lastEnd = 0

        for match in matches {
            let matchRange = match.range

            if matchRange.location > lastEnd {
                let before = nsText.substring(with: NSRange(location: lastEnd, length: matchRange.location - lastEnd))
                let (cleaned, sig) = stripTextSignature(before)
                if !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(GeminiPart(content: .text(cleaned), thoughtSignature: sig))
                }
            }

            if let altRange = Range(match.range(at: 1), in: text),
                let mimeRange = Range(match.range(at: 2), in: text),
                let dataRange = Range(match.range(at: 3), in: text)
            {
                let altText = String(text[altRange])
                let sig: String? =
                    altText.hasPrefix("image|ts:")
                    ? String(altText.dropFirst("image|ts:".count)) : nil
                parts.append(
                    GeminiPart(
                        content: .inlineData(
                            GeminiInlineData(
                                mimeType: String(text[mimeRange]),
                                data: String(text[dataRange])
                            )
                        ),
                        thoughtSignature: sig
                    )
                )
            }

            lastEnd = matchRange.location + matchRange.length
        }

        if lastEnd < nsText.length {
            let after = nsText.substring(from: lastEnd)
            if !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(.text(after))
            }
        }

        return parts.isEmpty ? [.text(text)] : parts
    }
}

// MARK: - Helper for Anthropic SSE Event Type Detection

/// Simple struct to decode Anthropic SSE event type
private struct AnthropicSSEEvent: Decodable {
    let type: String
}

// MARK: - Helper for Open Responses SSE Event Type Detection

/// Simple struct to decode Open Responses SSE event type
private struct OpenResponsesSSEEvent: Decodable {
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
    let modelOptions: [String: ModelOptionValue]

    private enum CodingKeys: String, CodingKey {
        case model, messages, temperature, max_completion_tokens, stream
        case top_p, frequency_penalty, presence_penalty, stop, tools, tool_choice
    }

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

    /// Convert to Gemini GenerateContent API request format
    func toGeminiRequest() -> GeminiGenerateContentRequest {
        var geminiContents: [GeminiContent] = []
        var systemInstruction: GeminiContent? = nil

        // Collect consecutive function responses to batch them
        var pendingFunctionResponses: [GeminiPart] = []

        // Helper to flush pending function responses into a user content
        func flushFunctionResponses() {
            if !pendingFunctionResponses.isEmpty {
                geminiContents.append(GeminiContent(role: "user", parts: pendingFunctionResponses))
                pendingFunctionResponses = []
            }
        }

        for msg in messages {
            switch msg.role {
            case "system":
                // System messages become systemInstruction
                if let content = msg.content {
                    systemInstruction = GeminiContent(parts: [.text(content)])
                }

            case "user":
                flushFunctionResponses()
                var userParts: [GeminiPart] = []

                // Add text content
                if let content = msg.content, !content.isEmpty {
                    userParts.append(.text(content))
                }

                // Add image content from contentParts
                if let parts = msg.contentParts {
                    for part in parts {
                        if case .imageUrl(let url, _) = part {
                            // Parse data URLs: "data:<mimeType>;base64,<data>"
                            if url.hasPrefix("data:"),
                                let semicolonIdx = url.firstIndex(of: ";"),
                                let commaIdx = url.firstIndex(of: ",")
                            {
                                let mimeType = String(url[url.index(url.startIndex, offsetBy: 5) ..< semicolonIdx])
                                let base64Data = String(url[url.index(after: commaIdx)...])
                                userParts.append(
                                    .inlineData(GeminiInlineData(mimeType: mimeType, data: base64Data))
                                )
                            }
                        }
                    }
                }

                if !userParts.isEmpty {
                    geminiContents.append(GeminiContent(role: "user", parts: userParts))
                }

            case "assistant":
                flushFunctionResponses()
                var parts: [GeminiPart] = []

                if let content = msg.content, !content.isEmpty {
                    // Split text and embedded data-URI images into separate parts
                    // so the Gemini API receives images as inlineData (not markdown text)
                    let extracted = RemoteProviderService.extractInlineImages(from: content)
                    parts.append(contentsOf: extracted)
                }

                if let toolCalls = msg.tool_calls {
                    for toolCall in toolCalls {
                        var args: [String: AnyCodableValue] = [:]
                        if let argsData = toolCall.function.arguments.data(using: .utf8),
                            let argsDict = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                        {
                            args = argsDict.mapValues { AnyCodableValue($0) }
                        }
                        parts.append(
                            .functionCall(
                                GeminiFunctionCall(
                                    name: toolCall.function.name,
                                    args: args,
                                    thoughtSignature: toolCall.geminiThoughtSignature
                                )
                            )
                        )
                    }
                }

                if !parts.isEmpty {
                    geminiContents.append(GeminiContent(role: "model", parts: parts))
                }

            case "tool":
                // Tool results become functionResponse parts in a user message
                if let content = msg.content {
                    // Use the tool_call_id to find the function name, or use a placeholder
                    let funcName = msg.tool_call_id ?? "function"
                    var responseData: [String: AnyCodableValue] = [:]

                    // Try to parse the content as JSON first
                    if let data = content.data(using: .utf8),
                        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    {
                        responseData = json.mapValues { AnyCodableValue($0) }
                    } else {
                        responseData["result"] = AnyCodableValue(content)
                    }

                    pendingFunctionResponses.append(
                        .functionResponse(GeminiFunctionResponse(name: funcName, response: responseData))
                    )
                }

            default:
                flushFunctionResponses()
                if let content = msg.content {
                    geminiContents.append(GeminiContent(role: "user", parts: [.text(content)]))
                }
            }
        }

        // Flush any remaining function responses
        flushFunctionResponses()

        // Convert tools
        var geminiTools: [GeminiTool]? = nil
        if let tools = tools, !tools.isEmpty {
            let declarations = tools.map { tool in
                GeminiFunctionDeclaration(
                    name: tool.function.name,
                    description: tool.function.description,
                    parameters: tool.function.parameters
                )
            }
            geminiTools = [GeminiTool(functionDeclarations: declarations)]
        }

        // Convert tool choice
        var toolConfig: GeminiToolConfig? = nil
        if let choice = tool_choice {
            let mode: String
            switch choice {
            case .auto:
                mode = "AUTO"
            case .none:
                mode = "NONE"
            case .function:
                mode = "ANY"
            }
            toolConfig = GeminiToolConfig(
                functionCallingConfig: GeminiFunctionCallingConfig(mode: mode)
            )
        }

        // Build generation config, using the model profile for image-capable models
        let isImageCapable = RemoteProviderService.isImageCapableModel(model)
        let responseModalities: [String]? = {
            guard isImageCapable else { return nil }
            if modelOptions["outputType"]?.stringValue == "imageOnly" {
                return ["IMAGE"]
            }
            return ["TEXT", "IMAGE"]
        }()

        let imageConfig: GeminiImageConfig? = {
            guard isImageCapable else { return nil }
            let ratio = modelOptions["aspectRatio"]?.stringValue
            let size = modelOptions["imageSize"]?.stringValue
            let effectiveRatio = (ratio == "auto") ? nil : ratio
            let effectiveSize = (size == "auto") ? nil : size
            guard effectiveRatio != nil || effectiveSize != nil else { return nil }
            return GeminiImageConfig(aspectRatio: effectiveRatio, imageSize: effectiveSize)
        }()

        var generationConfig: GeminiGenerationConfig? = nil
        if temperature != nil || max_completion_tokens != nil || top_p != nil || stop != nil
            || responseModalities != nil || imageConfig != nil
        {
            generationConfig = GeminiGenerationConfig(
                temperature: temperature.map { Double($0) },
                maxOutputTokens: max_completion_tokens,
                topP: top_p.map { Double($0) },
                topK: nil,
                stopSequences: stop,
                responseModalities: responseModalities,
                imageConfig: imageConfig
            )
        }

        return GeminiGenerateContentRequest(
            contents: geminiContents,
            tools: geminiTools,
            toolConfig: toolConfig,
            systemInstruction: systemInstruction,
            generationConfig: generationConfig,
            safetySettings: nil
        )
    }

    /// Convert to Open Responses API request format
    func toOpenResponsesRequest() -> OpenResponsesRequest {
        var inputItems: [OpenResponsesInputItem] = []
        var instructions: String? = nil

        for msg in messages {
            switch msg.role {
            case "system":
                // System messages become instructions
                if let content = msg.content {
                    if let existing = instructions {
                        instructions = existing + "\n" + content
                    } else {
                        instructions = content
                    }
                }

            case "user":
                // User messages become message input items
                if let content = msg.content {
                    let msgContent = OpenResponsesMessageContent.text(content)
                    inputItems.append(.message(OpenResponsesMessageItem(role: "user", content: msgContent)))
                }

            case "assistant":
                // Assistant messages with tool calls need special handling
                if let toolCalls = msg.tool_calls, !toolCalls.isEmpty {
                    // First add any text content
                    if let content = msg.content, !content.isEmpty {
                        let msgContent = OpenResponsesMessageContent.text(content)
                        inputItems.append(.message(OpenResponsesMessageItem(role: "assistant", content: msgContent)))
                    }
                    // Note: function_call items from assistant are not input items in Open Responses
                    // They would be represented as prior output from the assistant
                } else if let content = msg.content {
                    let msgContent = OpenResponsesMessageContent.text(content)
                    inputItems.append(.message(OpenResponsesMessageItem(role: "assistant", content: msgContent)))
                }

            case "tool":
                // Tool results become function_call_output items
                if let toolCallId = msg.tool_call_id, let content = msg.content {
                    inputItems.append(
                        .functionCallOutput(
                            OpenResponsesFunctionCallOutputItem(
                                callId: toolCallId,
                                output: content
                            )
                        )
                    )
                }

            default:
                // Unknown role - treat as user message
                if let content = msg.content {
                    let msgContent = OpenResponsesMessageContent.text(content)
                    inputItems.append(.message(OpenResponsesMessageItem(role: "user", content: msgContent)))
                }
            }
        }

        // Convert tools
        var openResponsesTools: [OpenResponsesTool]? = nil
        if let tools = tools {
            openResponsesTools = tools.map { tool in
                OpenResponsesTool(
                    name: tool.function.name,
                    description: tool.function.description,
                    parameters: tool.function.parameters
                )
            }
        }

        // Convert tool choice
        var openResponsesToolChoice: OpenResponsesToolChoice? = nil
        if let choice = tool_choice {
            switch choice {
            case .auto:
                openResponsesToolChoice = .auto
            case .none:
                openResponsesToolChoice = OpenResponsesToolChoice.none
            case .function(let fn):
                openResponsesToolChoice = .function(name: fn.function.name)
            }
        }

        // Determine input format
        let input: OpenResponsesInput
        if inputItems.count == 1, case .message(let msg) = inputItems[0], msg.role == "user" {
            // Single user message - use text shorthand
            input = .text(msg.content.plainText)
        } else {
            input = .items(inputItems)
        }

        return OpenResponsesRequest(
            model: model,
            input: input,
            stream: stream,
            tools: openResponsesTools,
            tool_choice: openResponsesToolChoice,
            temperature: temperature,
            max_output_tokens: max_completion_tokens,
            top_p: top_p,
            instructions: instructions,
            previous_response_id: nil,
            metadata: nil
        )
    }
}

// MARK: - Static Factory for Creating Services

extension RemoteProviderService {
    /// Fetch models from a remote provider and create a service instance
    public static func fetchModels(from provider: RemoteProvider) async throws -> [String] {
        if provider.providerType == .anthropic {
            guard let baseURL = provider.url(for: "/models") else {
                throw RemoteProviderServiceError.invalidURL
            }
            return try await fetchAnthropicModels(
                baseURL: baseURL,
                headers: provider.resolvedHeaders(),
                timeout: min(provider.timeout, 30)
            )
        }

        // Gemini uses a different models response format
        if provider.providerType == .gemini {
            return try await fetchGeminiModels(from: provider)
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

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteProviderServiceError.invalidResponse
        }

        if httpResponse.statusCode >= 400 {
            let errorMessage = extractErrorMessage(from: data, statusCode: httpResponse.statusCode)
            throw RemoteProviderServiceError.requestFailed(errorMessage)
        }

        // Parse models response
        let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return modelsResponse.data.map { $0.id }
    }

    /// Fetch models from Gemini API (different response format from OpenAI)
    private static func fetchGeminiModels(from provider: RemoteProvider) async throws -> [String] {
        guard let url = provider.url(for: "/models") else {
            throw RemoteProviderServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Add provider headers (includes x-goog-api-key)
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
            let errorMessage = extractErrorMessage(from: data, statusCode: httpResponse.statusCode)
            throw RemoteProviderServiceError.requestFailed(errorMessage)
        }

        // Parse Gemini models response
        let modelsResponse = try JSONDecoder().decode(GeminiModelsResponse.self, from: data)

        // Filter to models that support generateContent and strip "models/" prefix
        let models = (modelsResponse.models ?? [])
            .filter { model in
                guard let methods = model.supportedGenerationMethods else { return false }
                return methods.contains("generateContent")
            }
            .map { $0.modelId }

        guard !models.isEmpty else {
            throw RemoteProviderServiceError.noModelsAvailable
        }

        return models
    }

    /// Fetch all models from the Anthropic `/v1/models` endpoint, handling pagination.
    ///
    /// Shared between `fetchModels(from:)` and `RemoteProviderManager.testAnthropicConnection`.
    static func fetchAnthropicModels(
        baseURL: URL,
        headers: [String: String],
        timeout: TimeInterval = 30
    ) async throws -> [String] {
        var allModels: [String] = []
        var afterId: String? = nil

        while true {
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                throw RemoteProviderServiceError.invalidURL
            }
            var queryItems = [URLQueryItem(name: "limit", value: "1000")]
            if let afterId = afterId {
                queryItems.append(URLQueryItem(name: "after_id", value: afterId))
            }
            components.queryItems = queryItems

            guard let url = components.url else {
                throw RemoteProviderServiceError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw RemoteProviderServiceError.invalidResponse
            }

            if httpResponse.statusCode >= 400 {
                let errorMessage = extractErrorMessage(from: data, statusCode: httpResponse.statusCode)
                throw RemoteProviderServiceError.requestFailed(errorMessage)
            }

            let modelsResponse = try JSONDecoder().decode(AnthropicModelsResponse.self, from: data)
            allModels.append(contentsOf: modelsResponse.data.map { $0.id })

            if modelsResponse.has_more, let lastId = modelsResponse.last_id {
                afterId = lastId
            } else {
                break
            }
        }

        return allModels
    }

    /// Extract a human-readable error message from API error response data
    private static func extractErrorMessage(from data: Data, statusCode: Int) -> String {
        // Try to parse as JSON error response (OpenAI/xAI format)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // OpenAI/xAI format: {"error": {"message": "...", "type": "...", "code": "..."}}
            if let error = json["error"] as? [String: Any] {
                if let message = error["message"] as? String {
                    // Include error code if available for more context
                    if let code = error["code"] as? String {
                        return "\(message) (code: \(code))"
                    }
                    return message
                }
            }
            // Alternative format: {"message": "..."}
            if let message = json["message"] as? String {
                return message
            }
            // Alternative format: {"detail": "..."}
            if let detail = json["detail"] as? String {
                return detail
            }
        }

        // Fallback to raw string if JSON parsing fails
        if let rawMessage = String(data: data, encoding: .utf8), !rawMessage.isEmpty {
            // Truncate very long error messages
            let truncated = rawMessage.count > 200 ? String(rawMessage.prefix(200)) + "..." : rawMessage
            return "HTTP \(statusCode): \(truncated)"
        }

        return "HTTP \(statusCode): Unknown error"
    }
}
