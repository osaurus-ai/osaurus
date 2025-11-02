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
    let repPenalty: Float? = {
      // Map OpenAI penalties (presence/frequency) to a simple repetition penalty if provided
      if let fp = request.frequency_penalty, fp > 0 { return 1.0 + fp }
      if let pp = request.presence_penalty, pp > 0 { return 1.0 + pp }
      return nil
    }()
    let params = GenerationParameters(
      temperature: temperature,
      maxTokens: maxTokens,
      topPOverride: request.top_p,
      repetitionPenalty: repPenalty
    )

    // Candidate services and installed models (injected for testability)
    let services = self.services
    let route = ModelServiceRouter.resolve(
      requestedModel: request.model,
      services: services
    )

    switch route {
    case .service(let service, _):
      // If tools were provided and supported, use tool-capable streaming
      if let tools = request.tools, !tools.isEmpty, let toolSvc = service as? ToolCapableService {
        let stopSequences = request.stop ?? []
        return try await toolSvc.streamWithTools(
          prompt: prompt,
          parameters: params,
          stopSequences: stopSequences,
          tools: tools,
          toolChoice: request.tool_choice,
          requestedModel: request.model
        )
      }
      // Fallback to plain streaming
      guard let throwingService = service as? ThrowingStreamingService else {
        throw EngineError()
      }
      return try await throwingService.streamDeltasThrowing(
        prompt: prompt,
        parameters: params,
        requestedModel: request.model,
        stopSequences: request.stop ?? []
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
    let repPenalty2: Float? = {
      if let fp = request.frequency_penalty, fp > 0 { return 1.0 + fp }
      if let pp = request.presence_penalty, pp > 0 { return 1.0 + pp }
      return nil
    }()
    let params = GenerationParameters(
      temperature: temperature,
      maxTokens: maxTokens,
      topPOverride: request.top_p,
      repetitionPenalty: repPenalty2
    )

    let services = self.services
    let route = ModelServiceRouter.resolve(
      requestedModel: request.model,
      services: services
    )

    let created = Int(Date().timeIntervalSince1970)
    let responseId =
      "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"

    switch route {
    case .service(let service, let effectiveModel):
      // If tools were provided and the service supports them, use the tool-capable API
      if let tools = request.tools, !tools.isEmpty, let toolSvc = service as? ToolCapableService {
        let stopSequences = request.stop ?? []
        do {
          let text = try await toolSvc.respondWithTools(
            prompt: prompt,
            parameters: params,
            stopSequences: stopSequences,
            tools: tools,
            toolChoice: request.tool_choice,
            requestedModel: request.model
          )
          let choice = ChatChoice(
            index: 0,
            message: ChatMessage(
              role: "assistant", content: text, tool_calls: nil, tool_call_id: nil
            ),
            finish_reason: "stop"
          )
          let usage = Usage(prompt_tokens: 0, completion_tokens: 0, total_tokens: 0)
          return ChatCompletionResponse(
            id: responseId,
            created: created,
            model: effectiveModel,
            choices: [choice],
            usage: usage,
            system_fingerprint: nil
          )
        } catch let inv as ServiceToolInvocation {
          // Convert tool invocation to OpenAI-style non-stream response
          let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
          let callId = "call_" + String(raw.prefix(24))
          let toolCall = ToolCall(
            id: callId,
            type: "function",
            function: ToolCallFunction(name: inv.toolName, arguments: inv.jsonArguments)
          )
          let assistant = ChatMessage(
            role: "assistant",
            content: nil,
            tool_calls: [toolCall],
            tool_call_id: nil
          )
          let choice = ChatChoice(index: 0, message: assistant, finish_reason: "tool_calls")
          let usage = Usage(prompt_tokens: 0, completion_tokens: 0, total_tokens: 0)
          return ChatCompletionResponse(
            id: responseId,
            created: created,
            model: effectiveModel,
            choices: [choice],
            usage: usage,
            system_fingerprint: nil
          )
        }
      }

      // Fallback to plain generation (no tools)
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
