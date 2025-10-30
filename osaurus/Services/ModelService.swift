//
//  ModelService.swift
//  osaurus
//
//  Created by Terence on 10/14/25.
//

import Foundation

struct GenerationParameters {
  let temperature: Float
  let maxTokens: Int
}

struct ServiceToolInvocation: Error {
  let toolName: String
  let jsonArguments: String
}

protocol ModelService {
  /// Stable identifier for the service (e.g., "foundation").
  var id: String { get }

  /// Whether the underlying engine is available on this system.
  func isAvailable() -> Bool

  /// Whether this service should handle the given requested model identifier.
  /// For example, the Foundation service returns true for nil/empty/"default".
  func handles(requestedModel: String?) -> Bool

  /// Stream incremental text deltas for the provided prompt.
  func streamDeltas(
    prompt: String,
    parameters: GenerationParameters,
    requestedModel: String?
  ) async throws -> AsyncStream<String>

  /// Generate a single-shot response for the provided prompt.
  func generateOneShot(
    prompt: String,
    parameters: GenerationParameters,
    requestedModel: String?
  ) async throws -> String
}

/// Optional capability for services that can natively handle OpenAI-style tools.
protocol ToolCapableService: ModelService {
  func respondWithTools(
    prompt: String,
    parameters: GenerationParameters,
    stopSequences: [String],
    tools: [Tool],
    toolChoice: ToolChoiceOption?
  ) async throws -> String

  func streamWithTools(
    prompt: String,
    parameters: GenerationParameters,
    stopSequences: [String],
    tools: [Tool],
    toolChoice: ToolChoiceOption?
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
  ///   - installedModels: Names of installed MLX models.
  ///   - services: Candidate services to consider (default includes FoundationModels service when present).
  static func resolve(
    requestedModel: String?,
    installedModels: [String],
    services: [ModelService]
  ) -> ModelRoute {
    let trimmed = requestedModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let isDefault = trimmed.isEmpty || trimmed.caseInsensitiveCompare("default") == .orderedSame

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
