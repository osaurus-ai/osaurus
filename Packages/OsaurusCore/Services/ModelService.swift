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
}

struct ServiceToolInvocation: Error, Sendable {
    let toolName: String
    let jsonArguments: String
    /// Optional tool call ID preserved from the streaming response (OpenAI format: "call_xxx")
    /// If nil, the caller should generate a new ID
    let toolCallId: String?

    init(toolName: String, jsonArguments: String, toolCallId: String? = nil) {
        self.toolName = toolName
        self.jsonArguments = jsonArguments
        self.toolCallId = toolCallId
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
