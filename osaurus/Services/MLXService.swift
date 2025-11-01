//
//  MLXService.swift
//  osaurus
//
//  Migrated to Swift 6 actors; delegates runtime state to ModelManager/ModelRuntime.
//

import Foundation

/// Lightweight reference to a local MLX model (name + repo id)
private struct LocalModelRef {
  let name: String
  let modelId: String
}

actor MLXService: ToolCapableService {
  static let shared = MLXService()

  nonisolated var id: String { "mlx" }

  // MARK: - Availability / Routing

  nonisolated func isAvailable() -> Bool {
    return !Self.getAvailableModels().isEmpty
  }

  nonisolated func handles(requestedModel: String?) -> Bool {
    let trimmed = (requestedModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    return Self.findModel(named: trimmed) != nil
  }

  // MARK: - Static discovery wrappers (delegate to ModelManager)

  nonisolated static func getAvailableModels() -> [String] {
    return ModelManager.installedModelNames()
  }

  fileprivate nonisolated static func findModel(named name: String) -> LocalModelRef? {
    if let found = ModelManager.findInstalledModel(named: name) {
      return LocalModelRef(name: found.name, modelId: found.id)
    }
    return nil
  }

  // MARK: - Warm-up

  func warmUp(modelName: String? = nil, prefillChars: Int = 0, maxTokens: Int = 1) async {
    let chosen: LocalModelRef? = {
      if let name = modelName, let m = Self.findModel(named: name) { return m }
      if let first = Self.getAvailableModels().first, let m = Self.findModel(named: first) {
        return m
      }
      return nil
    }()
    guard let model = chosen else { return }
    await ModelManager.shared.runtime.warmUp(
      modelId: model.modelId, modelName: model.name, prefillChars: prefillChars,
      maxTokens: maxTokens)
  }

  // MARK: - ModelService

  func streamDeltas(
    prompt: String,
    parameters: GenerationParameters,
    requestedModel: String?
  ) async throws -> AsyncStream<String> {
    let model = try selectModel(requestedName: requestedModel)
    let messages = [Message(role: .user, content: prompt)]
    return try await ModelManager.shared.runtime.deltasStream(
      messages: messages,
      modelId: model.modelId,
      modelName: model.name,
      temperature: parameters.temperature,
      maxTokens: parameters.maxTokens,
      tools: nil,
      toolChoice: nil
    )
  }

  func generateOneShot(
    prompt: String,
    parameters: GenerationParameters,
    requestedModel: String?
  ) async throws -> String {
    let stream = try await streamDeltas(
      prompt: prompt, parameters: parameters, requestedModel: requestedModel)
    var out = ""
    for await s in stream { out += s }
    return out
  }

  // MARK: - Tool-capable bridge

  func respondWithTools(
    prompt: String,
    parameters: GenerationParameters,
    stopSequences: [String],
    tools: [Tool],
    toolChoice: ToolChoiceOption?,
    requestedModel: String?
  ) async throws -> String {
    let model = try selectModel(requestedName: requestedModel)
    return try await ModelManager.shared.runtime.respondWithTools(
      prompt: prompt,
      parameters: parameters,
      stopSequences: stopSequences,
      tools: tools,
      toolChoice: toolChoice,
      modelId: model.modelId,
      modelName: model.name
    )
  }

  func streamWithTools(
    prompt: String,
    parameters: GenerationParameters,
    stopSequences: [String],
    tools: [Tool],
    toolChoice: ToolChoiceOption?,
    requestedModel: String?
  ) async throws -> AsyncThrowingStream<String, Error> {
    let model = try selectModel(requestedName: requestedModel)
    return try await ModelManager.shared.runtime.streamWithTools(
      prompt: prompt,
      parameters: parameters,
      stopSequences: stopSequences,
      tools: tools,
      toolChoice: toolChoice,
      modelId: model.modelId,
      modelName: model.name
    )
  }

  // MARK: - Helpers

  private func selectModel(requestedName: String?) throws -> LocalModelRef {
    let trimmed = (requestedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw NSError(
        domain: "MLXService", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Requested model is required"])
    }
    if let m = Self.findModel(named: trimmed) { return m }
    throw NSError(
      domain: "MLXService", code: 4,
      userInfo: [NSLocalizedDescriptionKey: "Requested model not found: \(trimmed)"])
  }
}
