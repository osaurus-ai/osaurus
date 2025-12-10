//
//  RequestLog.swift
//  osaurus
//
//  Model for in-memory request/response logging used by InsightsService.
//

import Foundation

/// Represents a logged tool call within an inference
struct ToolCallLog: Identifiable, Sendable {
    let id: UUID
    let name: String
    let arguments: String
    let result: String?
    let durationMs: Double?
    let isError: Bool

    init(
        id: UUID = UUID(),
        name: String,
        arguments: String,
        result: String? = nil,
        durationMs: Double? = nil,
        isError: Bool = false
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.result = result
        self.durationMs = durationMs
        self.isError = isError
    }
}

/// Source of the request
enum RequestSource: String, Sendable, CaseIterable {
    case chatUI = "Chat UI"
    case httpAPI = "HTTP API"
}

/// Represents a single request log entry with optional inference data
struct RequestLog: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let source: RequestSource

    // HTTP request/response fields
    let method: String
    let path: String
    let statusCode: Int
    let durationMs: Double
    let requestBody: String?
    let responseBody: String?
    let userAgent: String?

    // Optional inference fields (only for chat endpoints)
    let model: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let tokensPerSecond: Double?
    let temperature: Float?
    let maxTokens: Int?
    let toolCalls: [ToolCallLog]?
    let finishReason: FinishReason?
    let errorMessage: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: RequestSource,
        method: String,
        path: String,
        statusCode: Int,
        durationMs: Double,
        requestBody: String? = nil,
        responseBody: String? = nil,
        userAgent: String? = nil,
        model: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        toolCalls: [ToolCallLog]? = nil,
        finishReason: FinishReason? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.method = method
        self.path = path
        self.statusCode = statusCode
        self.durationMs = durationMs
        self.requestBody = requestBody
        self.responseBody = responseBody
        self.userAgent = userAgent
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.toolCalls = toolCalls
        self.finishReason = finishReason
        self.errorMessage = errorMessage

        // Calculate tokens per second if we have inference data
        if let outputTokens = outputTokens, durationMs > 0 {
            self.tokensPerSecond = Double(outputTokens) / (durationMs / 1000.0)
        } else {
            self.tokensPerSecond = nil
        }
    }

    enum FinishReason: String, Sendable {
        case stop = "stop"
        case length = "length"
        case toolCalls = "tool_calls"
        case error = "error"
        case cancelled = "cancelled"
    }

    // MARK: - Computed Properties

    /// Whether this is an inference request (chat endpoint)
    var isInference: Bool {
        path.contains("chat")
    }

    /// Whether the request was successful (2xx status)
    var isSuccess: Bool {
        statusCode >= 200 && statusCode < 300
    }

    /// Is this an error state?
    var isError: Bool {
        !isSuccess || finishReason == .error || errorMessage != nil
    }

    /// Formatted timestamp for display
    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }

    /// Formatted duration for display
    var formattedDuration: String {
        if durationMs < 1000 {
            return String(format: "%.0fms", durationMs)
        } else {
            return String(format: "%.1fs", durationMs / 1000)
        }
    }

    /// Formatted tokens per second
    var formattedSpeed: String {
        if let speed = tokensPerSecond, speed > 0 {
            return String(format: "%.1f tok/s", speed)
        }
        return "-"
    }

    /// Short model name for display
    var shortModelName: String {
        guard let model = model else { return "-" }
        if model.lowercased() == "foundation" { return "Foundation" }
        if let lastPart = model.split(separator: "/").last {
            return String(lastPart)
        }
        return model
    }

    /// Truncated request body for display (max 500 chars)
    var truncatedRequestBody: String? {
        guard let body = requestBody else { return nil }
        if body.count > 500 {
            return String(body.prefix(500)) + "..."
        }
        return body
    }

    /// Truncated response body for display (max 1000 chars)
    var truncatedResponseBody: String? {
        guard let body = responseBody else { return nil }
        if body.count > 1000 {
            return String(body.prefix(1000)) + "..."
        }
        return body
    }

    /// Pretty-printed request body if JSON
    var formattedRequestBody: String? {
        guard let body = requestBody, let data = body.data(using: .utf8) else { return requestBody }
        if let json = try? JSONSerialization.jsonObject(with: data, options: []),
            let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
            let prettyString = String(data: prettyData, encoding: .utf8)
        {
            return prettyString
        }
        return body
    }

    /// Pretty-printed response body if JSON
    var formattedResponseBody: String? {
        guard let body = responseBody, let data = body.data(using: .utf8) else { return responseBody }
        if let json = try? JSONSerialization.jsonObject(with: data, options: []),
            let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
            let prettyString = String(data: prettyData, encoding: .utf8)
        {
            return prettyString
        }
        return body
    }
}

/// Pending inference metadata captured at start
struct PendingInference: Sendable {
    let id: UUID
    let startTime: Date
    let source: RequestSource
    let model: String
    let inputTokens: Int
    let temperature: Float
    let maxTokens: Int

    init(
        id: UUID = UUID(),
        startTime: Date = Date(),
        source: RequestSource,
        model: String,
        inputTokens: Int,
        temperature: Float,
        maxTokens: Int
    ) {
        self.id = id
        self.startTime = startTime
        self.source = source
        self.model = model
        self.inputTokens = inputTokens
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

// MARK: - Legacy type alias for backward compatibility

typealias InferenceLog = RequestLog
typealias InferenceSource = RequestSource
