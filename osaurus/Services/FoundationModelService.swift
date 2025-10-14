//
//  FoundationModelService.swift
//  osaurus
//
//  Created by Terence on 10/14/25.
//

import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

enum FoundationModelServiceError: Error {
  case notAvailable
  case generationFailed
}

/// Thin wrapper around Apple's FoundationModels LanguageModelSession so we can
/// optionally use the system default model when no MLX models are present or
/// when the request asks for the "default" model.
final class FoundationModelService: ModelService {
  let id: String = "foundation"
  /// Returns true if the system default language model is available on this device/OS.
  static func isDefaultModelAvailable() -> Bool {
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        return SystemLanguageModel.default.isAvailable
      } else {
        return false
      }
    #else
      return false
    #endif
  }

  func isAvailable() -> Bool { Self.isDefaultModelAvailable() }

  func handles(requestedModel: String?) -> Bool {
    let t = (requestedModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty || t.caseInsensitiveCompare("default") == .orderedSame
  }

  /// Generate a single response from the system default language model.
  /// Falls back to throwing when the framework is unavailable.
  static func generateOneShot(
    prompt: String,
    temperature: Float,
    maxTokens: Int
  ) async throws -> String {
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        // Start a session with the system default model.
        let session = LanguageModelSession()

        // Use the LanguageModelSession.respond APIs (current SDK naming).
        let options = GenerationOptions(
          sampling: nil,
          temperature: Double(temperature),
          maximumResponseTokens: maxTokens
        )
        let response = try await session.respond(to: prompt, options: options)
        return response.content
      } else {
        throw FoundationModelServiceError.notAvailable
      }
    #else
      throw FoundationModelServiceError.notAvailable
    #endif
  }

  func streamDeltas(
    prompt: String,
    parameters: GenerationParameters
  ) async throws -> AsyncStream<String> {
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        let session = LanguageModelSession()

        // Stream using LanguageModelSession.streamResponse (current SDK naming).
        let options = GenerationOptions(
          sampling: nil,
          temperature: Double(parameters.temperature),
          maximumResponseTokens: parameters.maxTokens
        )
        let stream = session.streamResponse(to: prompt, options: options)

        return AsyncStream<String> { continuation in
          Task {
            var previous = ""
            do {
              for try await snapshot in stream {
                let current = snapshot.content
                let delta: String
                if current.hasPrefix(previous) {
                  delta = String(current.dropFirst(previous.count))
                } else {
                  delta = current
                }
                if !delta.isEmpty {
                  continuation.yield(delta)
                }
                previous = current
              }
            } catch {
              // Ignore stream errors; caller can decide how to surface them
            }
            continuation.finish()
          }
        }
      } else {
        throw FoundationModelServiceError.notAvailable
      }
    #else
      throw FoundationModelServiceError.notAvailable
    #endif
  }

  func generateOneShot(
    prompt: String,
    parameters: GenerationParameters
  ) async throws -> String {
    return try await Self.generateOneShot(
      prompt: prompt, temperature: parameters.temperature, maxTokens: parameters.maxTokens)
  }

  // Leave prompt-building responsibility to callers for flexibility across services
}
