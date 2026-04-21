//
//  ModelService.swift
//  osaurus
//
//  Created by Terence on 10/14/25.
//

import Foundation

struct GenerationParameters: Sendable {
    let temperature: Float?
    let maxTokens: Int
    /// Optional per-request top_p override (falls back to server configuration when nil)
    let topPOverride: Float?
    /// Optional repetition penalty (applies when supported by backend)
    let repetitionPenalty: Float?
    /// Model-specific options resolved from the active `ModelProfile` (e.g. aspect ratio).
    let modelOptions: [String: ModelOptionValue]
    /// Session identifier for KV cache reuse across turns
    let sessionId: String?
    /// Explicit prefix cache key override (API callers can use this to share a
    /// prefix cache across requests with varying system prompts).
    let cacheHint: String?
    /// Static system prompt content for prefix cache building.
    /// When set, the prefix cache is built from this content only (excluding
    /// dynamic sections like memory), producing a KV cache that exactly matches
    /// the reusable portion across requests.
    let staticPrefix: String?
    /// Optional TTFT trace for diagnostic timing instrumentation.
    let ttftTrace: TTFTTrace?
    /// Scheduler priority. When nil the runtime uses `.plugin` as a safe default
    /// (mid-range — won't starve maintenance, won't preempt typing).
    let priority: InferencePriority?

    init(
        temperature: Float?,
        maxTokens: Int,
        topPOverride: Float? = nil,
        repetitionPenalty: Float? = nil,
        modelOptions: [String: ModelOptionValue] = [:],
        sessionId: String? = nil,
        cacheHint: String? = nil,
        staticPrefix: String? = nil,
        ttftTrace: TTFTTrace? = nil,
        priority: InferencePriority? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topPOverride = topPOverride
        self.repetitionPenalty = repetitionPenalty
        self.modelOptions = modelOptions
        self.sessionId = sessionId
        self.cacheHint = cacheHint
        self.staticPrefix = staticPrefix
        self.ttftTrace = ttftTrace
        self.priority = priority
    }
}

struct ServiceToolInvocation: Error, Sendable {
    let toolName: String
    let jsonArguments: String
    /// Optional tool call ID preserved from the streaming response (OpenAI format: "call_xxx")
    /// If nil, the caller should generate a new ID
    let toolCallId: String?
    /// Optional thought signature for Gemini thinking-mode models (e.g. Gemini 2.5)
    let geminiThoughtSignature: String?

    init(toolName: String, jsonArguments: String, toolCallId: String? = nil, geminiThoughtSignature: String? = nil) {
        self.toolName = toolName
        self.jsonArguments = jsonArguments
        self.toolCallId = toolCallId
        self.geminiThoughtSignature = geminiThoughtSignature
    }
}

/// In-band signaling for tool name and argument detection during streaming.
/// The stream type is `AsyncThrowingStream<String, Error>`, so we encode the
/// detected tool name (and argument fragments) as sentinel strings using a
/// Unicode non-character prefix that can never appear in normal LLM output.
enum StreamingToolHint: Sendable {
    private static let sentinel: Character = "\u{FFFE}"
    private static let toolPrefix = "\u{FFFE}tool:"
    private static let argsPrefix = "\u{FFFE}args:"
    private static let donePrefix = "\u{FFFE}done:"

    static func encode(_ toolName: String) -> String { toolPrefix + toolName }
    static func encodeArgs(_ fragment: String) -> String { argsPrefix + fragment }

    /// Encodes a completed server-side tool call so the client can display it in the chat log.
    static func encodeDone(callId: String, name: String, arguments: String, result: String) -> String {
        struct Payload: Encodable { let id, name, arguments, result: String }
        let json =
            (try? JSONEncoder().encode(Payload(id: callId, name: name, arguments: arguments, result: result)))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return donePrefix + json
    }

    /// Decoded payload from a done sentinel.
    struct ToolCallDone {
        let callId: String
        let name: String
        let arguments: String
        let result: String
    }

    static func decodeDone(_ delta: String) -> ToolCallDone? {
        guard delta.hasPrefix(donePrefix) else { return nil }
        let json = String(delta.dropFirst(donePrefix.count))
        struct Payload: Decodable { let id, name, arguments, result: String }
        guard let data = json.data(using: .utf8),
            let p = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }
        return ToolCallDone(callId: p.id, name: p.name, arguments: p.arguments, result: p.result)
    }

    /// O(1) check — only inspects the first character. Covers both tool and args sentinels.
    static func isSentinel(_ delta: String) -> Bool { delta.first == sentinel }

    /// Extracts the tool name from a sentinel delta, or nil if not a sentinel.
    static func decode(_ delta: String) -> String? {
        guard delta.hasPrefix(toolPrefix) else { return nil }
        return String(delta.dropFirst(toolPrefix.count))
    }

    /// Extracts an argument fragment from a sentinel delta, or nil if not an args sentinel.
    static func decodeArgs(_ delta: String) -> String? {
        guard delta.hasPrefix(argsPrefix) else { return nil }
        return String(delta.dropFirst(argsPrefix.count))
    }
}

/// In-band signaling for generation benchmarks (tok/s, token count).
/// Uses the same `\u{FFFE}` sentinel pattern as `StreamingToolHint`.
enum StreamingStatsHint: Sendable {
    private static let statsPrefix = "\u{FFFE}stats:"
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    static func encode(tokenCount: Int, tokensPerSecond: Double) -> String {
        let tps = String(format: "%.4f", locale: posixLocale, tokensPerSecond)
        return "\(statsPrefix)\(tokenCount);\(tps)"
    }

    static func decode(_ delta: String) -> (tokenCount: Int, tokensPerSecond: Double)? {
        guard delta.hasPrefix(statsPrefix) else { return nil }
        let payload = delta.dropFirst(statsPrefix.count)
        let parts = payload.split(separator: ";", maxSplits: 1)
        guard parts.count == 2,
            let count = Int(parts[0]),
            let tps = Double(parts[1])
        else { return nil }
        return (count, tps)
    }
}

protocol ModelService: Sendable {
    /// Stable identifier for the service (e.g., "foundation").
    var id: String { get }

    /// Whether the underlying engine is available on this system.
    func isAvailable() -> Bool

    /// Whether this service should handle the given requested model identifier.
    /// For example, the Foundation service returns true for nil/empty/"default".
    func handles(requestedModel: String?) -> Bool

    /// Generate a single-shot response for the provided message history.
    func generateOneShot(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?
    ) async throws -> String

    func streamDeltas(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?,
        stopSequences: [String]
    ) async throws -> AsyncThrowingStream<String, Error>
}

/// Optional capability for services that can natively handle OpenAI-style tools (message-based only).
protocol ToolCapableService: ModelService {
    func respondWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        requestedModel: String?
    ) async throws -> String

    func streamWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        requestedModel: String?
    ) async throws -> AsyncThrowingStream<String, Error>
}

/// Simple router that selects a service based on the request and environment.
enum ModelRoute {
    case service(service: ModelService, effectiveModel: String)
    case none
}

struct ModelServiceRouter {
    /// Decide which service should handle this request.
    /// - Parameters:
    ///   - requestedModel: Model string requested by client. "default" or empty means system default.
    ///   - services: Candidate services to consider (default includes FoundationModels service when present).
    ///   - remoteServices: Optional array of remote provider services to also consider.
    static func resolve(
        requestedModel: String?,
        services: [ModelService],
        remoteServices: [ModelService] = []
    ) -> ModelRoute {
        let trimmed = requestedModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isDefault = trimmed.isEmpty || trimmed.caseInsensitiveCompare("default") == .orderedSame

        // First, check remote provider services (they use prefixed model names like "openai/gpt-4")
        // These take priority for explicit model requests with provider prefixes
        if !isDefault {
            for svc in remoteServices {
                guard svc.isAvailable() else { continue }
                if svc.handles(requestedModel: trimmed) {
                    return .service(service: svc, effectiveModel: trimmed)
                }
            }
        }

        // Then check local services
        for svc in services {
            guard svc.isAvailable() else { continue }
            // Route default to a service that handles it
            if isDefault && svc.handles(requestedModel: requestedModel) {
                return .service(service: svc, effectiveModel: "foundation")
            }
            // Allow explicit "foundation" (or other service-specific id) to select the service
            if svc.handles(requestedModel: trimmed), !isDefault {
                return .service(service: svc, effectiveModel: trimmed)
            }
        }

        return .none
    }
}
