//
//  ChatEngine.swift
//  osaurus
//
//  Actor encapsulating model routing and generation streaming.
//

import Foundation

actor ChatEngine: Sendable, ChatEngineProtocol {
  private let services: [ModelService]
  private let installedModelsProvider: @Sendable () -> [String]

  init(
    services: [ModelService] = [FoundationModelService(), MLXService()],
    installedModelsProvider: @escaping @Sendable () -> [String] = {
      MLXService.getAvailableModels()
    }
  ) {
    self.services = services
    self.installedModelsProvider = installedModelsProvider
  }
  struct EngineError: Error {}

  func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error>
  {
    let messages = request.toInternalMessages()
    let prompt = PromptBuilder.buildPrompt(from: messages)

    let temperature = request.temperature ?? 1.0
    let maxTokens = request.max_tokens ?? 512
    let params = GenerationParameters(temperature: temperature, maxTokens: maxTokens)

    // Candidate services and installed models (injected for testability)
    let services = self.services
    let installed = self.installedModelsProvider()

    let route = ModelServiceRouter.resolve(
      requestedModel: request.model,
      installedModels: installed,
      services: services
    )

    switch route {
    case .service(let service, _):
      guard let throwingService = service as? ThrowingStreamingService else {
        throw EngineError()
      }
      return try await throwingService.streamDeltasThrowing(
        prompt: prompt,
        parameters: params,
        requestedModel: request.model
      )
    case .none:
      throw EngineError()
    }
  }

  func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
    let messages = request.toInternalMessages()
    let prompt = PromptBuilder.buildPrompt(from: messages)

    let temperature = request.temperature ?? 1.0
    let maxTokens = request.max_tokens ?? 512
    let params = GenerationParameters(temperature: temperature, maxTokens: maxTokens)

    let services = self.services
    let installed = self.installedModelsProvider()

    let route = ModelServiceRouter.resolve(
      requestedModel: request.model,
      installedModels: installed,
      services: services
    )

    let created = Int(Date().timeIntervalSince1970)
    let responseId =
      "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"

    switch route {
    case .service(let service, let effectiveModel):
      let text = try await service.generateOneShot(
        prompt: prompt,
        parameters: params,
        requestedModel: request.model
      )
      let choice = ChatChoice(
        index: 0,
        message: ChatMessage(role: "assistant", content: text, tool_calls: nil, tool_call_id: nil),
        finish_reason: "stop"
      )
      // Usage accounting not available here; return zeros for now
      let usage = Usage(prompt_tokens: 0, completion_tokens: 0, total_tokens: 0)
      return ChatCompletionResponse(
        id: responseId,
        created: created,
        model: effectiveModel,
        choices: [choice],
        usage: usage,
        system_fingerprint: nil
      )
    case .none:
      throw EngineError()
    }
  }
}
