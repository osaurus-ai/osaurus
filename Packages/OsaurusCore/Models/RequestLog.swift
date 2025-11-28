//
//  InferenceLog.swift
//  osaurus
//
//  Model for in-memory inference logging used by InsightsService.
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

/// Source of the inference request
enum InferenceSource: String, Sendable {
    case chatUI = "Chat UI"
    case httpAPI = "HTTP API"
    case sdk = "SDK"
}

/// Represents a single inference log entry
struct InferenceLog: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let source: InferenceSource
    let model: String
    let inputTokens: Int  // Estimated from prompt
    let outputTokens: Int  // Count of generated tokens
    let durationMs: Double
    let tokensPerSecond: Double  // Output tokens / duration
    let temperature: Float
    let maxTokens: Int
    let toolCalls: [ToolCallLog]?
    let finishReason: FinishReason
    let errorMessage: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: InferenceSource,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        durationMs: Double,
        temperature: Float,
        maxTokens: Int,
        toolCalls: [ToolCallLog]? = nil,
        finishReason: FinishReason = .stop,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.durationMs = durationMs
        self.tokensPerSecond = durationMs > 0 ? Double(outputTokens) / (durationMs / 1000.0) : 0
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.toolCalls = toolCalls
        self.finishReason = finishReason
        self.errorMessage = errorMessage
    }

    enum FinishReason: String, Sendable {
        case stop = "stop"
        case length = "length"
        case toolCalls = "tool_calls"
        case error = "error"
        case cancelled = "cancelled"
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
        if tokensPerSecond > 0 {
            return String(format: "%.1f tok/s", tokensPerSecond)
        }
        return "-"
    }

    /// Short model name for display
    var shortModelName: String {
        if model.lowercased() == "foundation" { return "Foundation" }
        if let lastPart = model.split(separator: "/").last {
            return String(lastPart)
        }
        return model
    }

    /// Is this an error state?
    var isError: Bool {
        finishReason == .error || errorMessage != nil
    }
}

/// Pending inference metadata captured at start
struct PendingInference: Sendable {
    let id: UUID
    let startTime: Date
    let source: InferenceSource
    let model: String
    let inputTokens: Int
    let temperature: Float
    let maxTokens: Int

    init(
        id: UUID = UUID(),
        startTime: Date = Date(),
        source: InferenceSource,
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

// MARK: - Legacy aliases for HTTP logging compatibility

typealias RequestLog = InferenceLog
