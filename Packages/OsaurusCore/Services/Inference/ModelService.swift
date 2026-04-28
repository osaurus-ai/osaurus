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
    /// Optional repetition penalty (applies when supported by backend).
    /// Mapped from OpenAI `frequency_penalty` only — `presence_penalty`
    /// has no MLX analog. The raw OpenAI values below are kept on the
    /// struct so remote services that natively support both can forward
    /// them straight through.
    let repetitionPenalty: Float?
    /// Raw OpenAI `frequency_penalty`, forwarded as-is to remote services
    /// that support it (most OpenAI-compatible upstreams).
    let frequencyPenalty: Float?
    /// Raw OpenAI `presence_penalty`, forwarded as-is to remote services
    /// that support it. Has no MLX analog so local services ignore it.
    let presencePenalty: Float?
    /// Deterministic sampling seed. When non-nil, services that support
    /// it (MLX via `MLXRandom.seed`, OpenAI-compatible remotes) will
    /// produce reproducible output for identical inputs.
    let seed: UInt64?
    /// Whether the response must be a JSON object (`response_format:
    /// {type: json_object}`). Local services inject a system instruction
    /// + post-validate; remotes forward natively when the upstream
    /// supports it.
    let jsonMode: Bool
    /// Model-specific options resolved from the active `ModelProfile` (e.g. aspect ratio).
    let modelOptions: [String: ModelOptionValue]
    /// Session identifier for chat/history grouping. Not threaded into the
    /// MLX cache layer — vmlx's `CacheCoordinator` handles prefix reuse
    /// autonomously via content addressing.
    let sessionId: String?
    /// Optional TTFT trace for diagnostic timing instrumentation.
    let ttftTrace: TTFTTrace?

    init(
        temperature: Float?,
        maxTokens: Int,
        topPOverride: Float? = nil,
        repetitionPenalty: Float? = nil,
        frequencyPenalty: Float? = nil,
        presencePenalty: Float? = nil,
        seed: UInt64? = nil,
        jsonMode: Bool = false,
        modelOptions: [String: ModelOptionValue] = [:],
        sessionId: String? = nil,
        ttftTrace: TTFTTrace? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topPOverride = topPOverride
        self.repetitionPenalty = repetitionPenalty
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.seed = seed
        self.jsonMode = jsonMode
        self.modelOptions = modelOptions
        self.sessionId = sessionId
        self.ttftTrace = ttftTrace
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

/// Batch of tool invocations parsed out of a single model completion.
///
/// Local (MLX) models can emit multiple tool-call blocks per response.
/// vmlx-swift-lm's `BatchEngine.generate` surfaces each as its own
/// `Generation.toolCall(ToolCall)` event; `GenerationEventMapper`
/// translates them to `ModelRuntimeEvent.toolInvocation(...)`, and
/// `ModelRuntime.streamWithTools` collects them into this batch error so
/// the caller (Work loop, HTTP agent loop, plugin streaming) can execute
/// every call in a single iteration instead of one round-trip per call.
///
/// `invocations` is guaranteed non-empty. Consumers should `catch let invs as
/// ServiceToolInvocations` BEFORE `catch let inv as ServiceToolInvocation`
/// because some provider paths still throw the single form for genuinely
/// one-at-a-time streams (OpenAI server-side tool calls).
struct ServiceToolInvocations: Error, Sendable {
    let invocations: [ServiceToolInvocation]
}

/// In-band signaling for tool name and argument detection during streaming.
/// The stream type is `AsyncThrowingStream<String, Error>`, so we encode the
/// detected tool name (and argument fragments) as sentinel strings using a
/// Unicode non-character prefix that can never appear in normal LLM output.
public enum StreamingToolHint: Sendable {
    private static let sentinel: Character = "\u{FFFE}"
    private static let toolPrefix = "\u{FFFE}tool:"
    private static let argsPrefix = "\u{FFFE}args:"
    private static let donePrefix = "\u{FFFE}done:"

    public static func encode(_ toolName: String) -> String { toolPrefix + toolName }
    public static func encodeArgs(_ fragment: String) -> String { argsPrefix + fragment }

    /// Encodes a completed server-side tool call so the client can display it in the chat log.
    public static func encodeDone(callId: String, name: String, arguments: String, result: String) -> String {
        struct Payload: Encodable { let id, name, arguments, result: String }
        let json =
            (try? JSONEncoder().encode(Payload(id: callId, name: name, arguments: arguments, result: result)))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return donePrefix + json
    }

    /// Decoded payload from a done sentinel.
    public struct ToolCallDone: Sendable, Equatable {
        public let callId: String
        public let name: String
        public let arguments: String
        public let result: String
    }

    public static func decodeDone(_ delta: String) -> ToolCallDone? {
        guard delta.hasPrefix(donePrefix) else { return nil }
        let json = String(delta.dropFirst(donePrefix.count))
        struct Payload: Decodable { let id, name, arguments, result: String }
        guard let data = json.data(using: .utf8),
            let p = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }
        return ToolCallDone(callId: p.id, name: p.name, arguments: p.arguments, result: p.result)
    }

    /// O(1) check — only inspects the first character. Covers both tool and args sentinels.
    public static func isSentinel(_ delta: String) -> Bool { delta.first == sentinel }

    /// Extracts the tool name from a sentinel delta, or nil if not a sentinel.
    public static func decode(_ delta: String) -> String? {
        guard delta.hasPrefix(toolPrefix) else { return nil }
        return String(delta.dropFirst(toolPrefix.count))
    }

    /// Extracts an argument fragment from a sentinel delta, or nil if not an args sentinel.
    public static func decodeArgs(_ delta: String) -> String? {
        guard delta.hasPrefix(argsPrefix) else { return nil }
        return String(delta.dropFirst(argsPrefix.count))
    }
}

/// In-band signaling for streamed reasoning text. Mirrors `StreamingToolHint`
/// so the existing `\u{FFFE}` sentinel filter in HTTP handlers and ChatView
/// catches it the same way. Used by:
///   - `ModelRuntime.streamWithTools` once `BatchEngine.generate` starts
///     emitting `Generation.reasoning(String)` (forward-compat — see
///     `GenerationEventMapper`).
///   - `RemoteProviderService` for OpenAI-compatible providers that stream
///     reasoning on a dedicated `reasoning_content` field (DeepSeek, Qwen,
///     vLLM, etc.) — replaces the previous synthetic `<think>` wrapping.
enum StreamingReasoningHint: Sendable {
    private static let reasoningPrefix = "\u{FFFE}reasoning:"

    static func encode(_ text: String) -> String { reasoningPrefix + text }

    static func decode(_ delta: String) -> String? {
        guard delta.hasPrefix(reasoningPrefix) else { return nil }
        return String(delta.dropFirst(reasoningPrefix.count))
    }
}

/// In-band signaling for generation benchmarks (tok/s, token count).
/// Uses the same `\u{FFFE}` sentinel pattern as `StreamingToolHint`.
///
/// Wire format: `<sentinel>stats:<tokenCount>;<tokensPerSecond>[;<flags>]`.
/// The optional third field carries comma-separated flags so future
/// observability signals can be added without breaking older decoders —
/// today's only flag is `unclosed`, set when vmlx's
/// `GenerateCompletionInfo.unclosedReasoning == true` (the model ended
/// the stream still inside a `<think>` block, i.e. trapped-thinking).
enum StreamingStatsHint: Sendable {
    private static let statsPrefix = "\u{FFFE}stats:"
    private static let posixLocale = Locale(identifier: "en_US_POSIX")
    private static let unclosedFlag = "unclosed"

    static func encode(
        tokenCount: Int,
        tokensPerSecond: Double,
        unclosedReasoning: Bool = false
    ) -> String {
        let tps = String(format: "%.4f", locale: posixLocale, tokensPerSecond)
        let suffix = unclosedReasoning ? ";\(unclosedFlag)" : ""
        return "\(statsPrefix)\(tokenCount);\(tps)\(suffix)"
    }

    static func decode(
        _ delta: String
    ) -> (tokenCount: Int, tokensPerSecond: Double, unclosedReasoning: Bool)? {
        guard delta.hasPrefix(statsPrefix) else { return nil }
        let payload = delta.dropFirst(statsPrefix.count)
        // Split into at most 3 parts: count, tps, optional flags. `maxSplits=2`
        // means a future flags-string containing extra `;` separators stays
        // in the third field intact — forward-compat for new flags.
        let parts = payload.split(separator: ";", maxSplits: 2)
        guard parts.count >= 2,
            let count = Int(parts[0]),
            let tps = Double(parts[1])
        else { return nil }
        let flags = parts.count >= 3 ? parts[2].split(separator: ",") : []
        let unclosed = flags.contains { $0 == Substring(unclosedFlag) }
        return (count, tps, unclosed)
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
