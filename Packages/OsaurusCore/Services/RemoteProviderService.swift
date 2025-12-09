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
              !model.isEmpty else {
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
              !model.isEmpty else {
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
        
        let chatResponse = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        return chatResponse.choices.first?.message.content ?? ""
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
        
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    
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
                        continuation.finish(throwing: RemoteProviderServiceError.requestFailed("HTTP \(httpResponse.statusCode): \(errorMessage)"))
                        return
                    }
                    
                    // Parse SSE stream
                    var buffer = ""
                    for try await byte in bytes {
                        buffer.append(Character(UnicodeScalar(byte)))
                        
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
                                
                                // Check for stream end
                                if dataContent.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                                    continuation.finish()
                                    return
                                }
                                
                                // Parse JSON chunk
                                if let jsonData = dataContent.data(using: .utf8) {
                                    do {
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
                                        
                                        // Check for finish reason
                                        if let finishReason = chunk.choices.first?.finish_reason,
                                           !finishReason.isEmpty {
                                            // Handle tool calls if present
                                            if finishReason == "tool_calls",
                                               let toolCalls = chunk.choices.first?.delta.tool_calls,
                                               let firstCall = toolCalls.first,
                                               let name = firstCall.function?.name,
                                               let args = firstCall.function?.arguments {
                                                continuation.finish(throwing: ServiceToolInvocation(toolName: name, jsonArguments: args))
                                                return
                                            }
                                        }
                                    } catch {
                                        // Skip malformed chunks
                                    }
                                }
                            }
                        }
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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
        
        let chatResponse = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        
        // Check for tool calls
        if let toolCalls = chatResponse.choices.first?.message.tool_calls,
           let firstCall = toolCalls.first {
            throw ServiceToolInvocation(
                toolName: firstCall.function.name,
                jsonArguments: firstCall.function.arguments
            )
        }
        
        return chatResponse.choices.first?.message.content ?? ""
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
        
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    
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
                        continuation.finish(throwing: RemoteProviderServiceError.requestFailed("HTTP \(httpResponse.statusCode): \(errorMessage)"))
                        return
                    }
                    
                    // Track accumulated tool call data
                    var accumulatedToolName: String?
                    var accumulatedToolArgs = ""
                    
                    // Parse SSE stream
                    var buffer = ""
                    for try await byte in bytes {
                        buffer.append(Character(UnicodeScalar(byte)))
                        
                        while let newlineIndex = buffer.firstIndex(of: "\n") {
                            let line = String(buffer[..<newlineIndex])
                            buffer = String(buffer[buffer.index(after: newlineIndex)...])
                            
                            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                                continue
                            }
                            
                            if line.hasPrefix("data: ") {
                                let dataContent = String(line.dropFirst(6))
                                
                                if dataContent.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                                    // If we accumulated a tool call, emit it
                                    if let toolName = accumulatedToolName {
                                        continuation.finish(throwing: ServiceToolInvocation(
                                            toolName: toolName,
                                            jsonArguments: accumulatedToolArgs
                                        ))
                                        return
                                    }
                                    continuation.finish()
                                    return
                                }
                                
                                if let jsonData = dataContent.data(using: .utf8) {
                                    do {
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
                                        
                                        // Handle tool call deltas
                                        if let toolCalls = chunk.choices.first?.delta.tool_calls {
                                            for toolCall in toolCalls {
                                                if let name = toolCall.function?.name {
                                                    accumulatedToolName = name
                                                }
                                                if let args = toolCall.function?.arguments {
                                                    accumulatedToolArgs += args
                                                }
                                            }
                                        }
                                        
                                        // Check finish reason
                                        if let finishReason = chunk.choices.first?.finish_reason,
                                           finishReason == "tool_calls",
                                           let toolName = accumulatedToolName {
                                            continuation.finish(throwing: ServiceToolInvocation(
                                                toolName: toolName,
                                                jsonArguments: accumulatedToolArgs
                                            ))
                                            return
                                        }
                                    } catch {
                                        // Skip malformed chunks
                                    }
                                }
                            }
                        }
                    }
                    
                    // If we have accumulated tool call data at stream end
                    if let toolName = accumulatedToolName {
                        continuation.finish(throwing: ServiceToolInvocation(
                            toolName: toolName,
                            jsonArguments: accumulatedToolArgs
                        ))
                        return
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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
        guard let url = provider.url(for: "/chat/completions") else {
            throw RemoteProviderServiceError.invalidURL
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Add provider headers (including auth)
        for (key, value) in provider.resolvedHeaders() {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        
        // Encode request body
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let bodyData = try encoder.encode(request)
        urlRequest.httpBody = bodyData
        
        // Debug: print the request body
        if let jsonString = String(data: bodyData, encoding: .utf8) {
            print("[Osaurus] Remote Provider Request Body:\n\(jsonString)")
        }
        
        return urlRequest
    }
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
}

// MARK: - Static Factory for Creating Services

extension RemoteProviderService {
    /// Fetch models from a remote provider and create a service instance
    public static func fetchModels(from provider: RemoteProvider) async throws -> [String] {
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
}

