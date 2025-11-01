//
//  ChatEngine.swift
//  osaurus
//
//  Actor encapsulating model routing and generation streaming.
//

import Foundation

actor ChatEngine: Sendable {
  struct EngineError: Error {}

  func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
    let messages = request.toInternalMessages()
    let prompt = PromptBuilder.buildPrompt(from: messages)

    let temperature = request.temperature ?? 1.0
    let maxTokens = request.max_tokens ?? 512
    let params = GenerationParameters(temperature: temperature, maxTokens: maxTokens)

    // Candidate services; expand as additional engines are migrated
    var services: [ModelService] = []
    services.append(FoundationModelService())

    let route = ModelServiceRouter.resolve(
      requestedModel: request.model,
      installedModels: [],
      services: services
    )

    switch route {
    case .service(let service, _):
      let base = try await service.streamDeltas(
        prompt: prompt,
        parameters: params,
        requestedModel: request.model
      )
      let baseBox = UncheckedSendableBox(value: base)
      return AsyncThrowingStream<String, Error> { continuation in
        let contBox = UncheckedSendableBox(value: continuation)
        Task {
          for await delta in baseBox.value {
            contBox.value.yield(delta)
          }
          contBox.value.finish()
        }
      }
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

    var services: [ModelService] = []
    services.append(FoundationModelService())

    let route = ModelServiceRouter.resolve(
      requestedModel: request.model,
      installedModels: [],
      services: services
    )

    let created = Int(Date().timeIntervalSince1970)
    let responseId = "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"

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


