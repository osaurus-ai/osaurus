//
//  AsyncHTTPHandler.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Dispatch
import Foundation
import IkigaJSON
import MLXLMCommon
import NIOCore
import NIOHTTP1

#if canImport(FoundationModels)
  import FoundationModels
#endif

private struct UncheckedSendableBox<T>: @unchecked Sendable {
  let value: T
}

/// Handles async operations for HTTP endpoints
class AsyncHTTPHandler {
  static let shared = AsyncHTTPHandler()

  private init() {}

  @inline(__always)
  private func executeOnLoop(_ loop: EventLoop, _ block: @escaping () -> Void) {
    if loop.inEventLoop {
      block()
    } else {
      loop.execute {
        block()
      }
    }
  }

  /// Handle chat completions with streaming support (OpenAI-compatible SSE)
  func handleChatCompletion(
    request: ChatCompletionRequest,
    context: ChannelHandlerContext,
    extraHeaders: [(String, String)]? = nil
  ) async {
    await handleChat(
      request: request,
      context: context,
      writer: SSEResponseWriter(),
      extraHeaders: extraHeaders
    )
  }

  /// Handle chat endpoint with NDJSON streaming
  func handleChat(
    request: ChatCompletionRequest,
    context: ChannelHandlerContext,
    extraHeaders: [(String, String)]? = nil
  ) async {
    await handleChat(
      request: request,
      context: context,
      writer: NDJSONResponseWriter(),
      extraHeaders: extraHeaders
    )
  }

  /// Unified chat handler with pluggable response writer
  private func handleChat(
    request: ChatCompletionRequest,
    context: ChannelHandlerContext,
    writer: ResponseWriter,
    extraHeaders: [(String, String)]? = nil
  ) async {
    // Signal generation activity for status UI
    ServerController.signalGenerationStart()
    defer { ServerController.signalGenerationEnd() }
    do {
      // Determine if we should use FoundationModels default session
      let noModelsInstalled = MLXService.getAvailableModels().isEmpty
      // Prepare model services
      let services: [ModelService] = [FoundationModelService()]
      let route = ModelServiceRouter.resolve(
        requestedModel: request.model,
        installedModels: MLXService.getAvailableModels(),
        services: services
      )

      // Convert messages
      let messages = request.toInternalMessages()

      // Get generation parameters
      let temperature = request.temperature ?? 0.7
      let maxTokens = request.max_tokens ?? 2048

      // Honor only request-provided stop sequences; otherwise rely on library EOS handling
      let effectiveStops: [String] = request.stop ?? []

      switch route {
      case .service(let service, let effectiveModel):
        // Build a generic chat-style prompt for services
        let prompt = PromptBuilder.buildPrompt(from: messages)
        // If OpenAI-style tools are present and allowed, use FoundationModels tool-calling bridge
        #if canImport(FoundationModels)
          if let tools = request.tools, !tools.isEmpty,
            request.tool_choice == nil
              || {
                if let c = request.tool_choice { if case .none = c { return false } }
                return true
              }()
          {
            if #available(macOS 26.0, *) {
              if request.stream ?? false {
                try await handleFoundationStreamingWithTools(
                  prompt: prompt,
                  effectiveModel: effectiveModel,
                  parameters: GenerationParameters(temperature: temperature, maxTokens: maxTokens),
                  stopSequences: effectiveStops,
                  tools: tools,
                  toolChoice: request.tool_choice,
                  context: context,
                  writer: writer,
                  extraHeaders: extraHeaders
                )
              } else {
                try await handleFoundationNonStreamingWithTools(
                  prompt: prompt,
                  effectiveModel: effectiveModel,
                  parameters: GenerationParameters(temperature: temperature, maxTokens: maxTokens),
                  stopSequences: effectiveStops,
                  tools: tools,
                  toolChoice: request.tool_choice,
                  context: context,
                  extraHeaders: extraHeaders
                )
              }
              return
            }
          }
        #endif
        do {
          if request.stream ?? false {
            try await handleServiceStreamingResponse(
              service: service,
              prompt: prompt,
              effectiveModel: effectiveModel,
              parameters: GenerationParameters(temperature: temperature, maxTokens: maxTokens),
              stopSequences: effectiveStops,
              context: context,
              writer: writer,
              extraHeaders: extraHeaders
            )
          } else {
            try await handleServiceNonStreamingResponse(
              service: service,
              prompt: prompt,
              effectiveModel: effectiveModel,
              parameters: GenerationParameters(temperature: temperature, maxTokens: maxTokens),
              stopSequences: effectiveStops,
              context: context,
              extraHeaders: extraHeaders
            )
          }
        }
        return
      case .none:
        break
      }

      // Find MLX model using nonisolated static accessor
      guard let model = MLXService.findModel(named: request.model) else {
        // If no models installed but FoundationModels not available, return a helpful error
        if noModelsInstalled {
          let error = OpenAIError(
            error: OpenAIError.ErrorDetail(
              message:
                "No local models found and no compatible model service is available.",
              type: "invalid_request_error",
              param: "model",
              code: nil
            )
          )
          try await sendJSONResponse(
            error, status: .notFound, context: context, extraHeaders: extraHeaders)
          return
        }
        let error = OpenAIError(
          error: OpenAIError.ErrorDetail(
            message: "Model not found: \(request.model)",
            type: "invalid_request_error",
            param: "model",
            code: nil
          )
        )
        try await sendJSONResponse(
          error, status: .notFound, context: context, extraHeaders: extraHeaders)
        return
      }

      // Check if streaming is requested
      if request.stream ?? false {
        try await handleStreamingResponse(
          messages: messages,
          model: model,
          temperature: temperature,
          maxTokens: maxTokens,
          requestModel: request.model,
          tools: request.tools,
          toolChoice: request.tool_choice,
          sessionId: request.session_id,
          stopSequences: effectiveStops,
          context: context,
          writer: writer,
          extraHeaders: extraHeaders
        )
      } else {
        try await handleNonStreamingResponse(
          messages: messages,
          model: model,
          temperature: temperature,
          maxTokens: maxTokens,
          requestModel: request.model,
          tools: request.tools,
          toolChoice: request.tool_choice,
          sessionId: request.session_id,
          stopSequences: effectiveStops,
          context: context,
          extraHeaders: extraHeaders
        )
      }
    } catch {
      let errorResponse = OpenAIError(
        error: OpenAIError.ErrorDetail(
          message: error.localizedDescription,
          type: "internal_error",
          param: nil,
          code: nil
        )
      )
      try? await sendJSONResponse(
        errorResponse, status: .internalServerError, context: context, extraHeaders: extraHeaders)
    }
  }

  // MARK: - Generic ModelService handlers

  private func handleServiceStreamingResponse(
    service: ModelService,
    prompt: String,
    effectiveModel: String,
    parameters: GenerationParameters,
    stopSequences: [String],
    context: ChannelHandlerContext,
    writer: ResponseWriter,
    extraHeaders: [(String, String)]? = nil
  ) async throws {
    let loop = context.eventLoop
    let ctxBox = UncheckedSendableBox(value: context)
    let writerBox = UncheckedSendableBox(value: writer)

    // Write headers
    executeOnLoop(loop) {
      writerBox.value.writeHeaders(ctxBox.value, extraHeaders: extraHeaders)
    }

    let responseId = "chatcmpl-\(UUID().uuidString.prefix(8))"
    let created = Int(Date().timeIntervalSince1970)

    // Send role prelude (SSE will emit; NDJSON writer ignores)
    executeOnLoop(loop) {
      writerBox.value.writeRole(
        "assistant", model: effectiveModel, responseId: responseId, created: created,
        context: ctxBox.value)
    }

    // Use the service stream
    let stream = try await service.streamDeltas(
      prompt: prompt, parameters: parameters)

    // Stop sequence handling across chunk boundaries
    var accumulated: String = ""
    var alreadyEmitted: Int = 0
    let shouldCheckStop = !stopSequences.isEmpty

    for await delta in stream {
      guard !delta.isEmpty else { continue }
      accumulated += delta

      // New content since last emission
      let newSlice = String(accumulated.dropFirst(alreadyEmitted))

      if shouldCheckStop && !newSlice.isEmpty {
        if let stopIndex = stopSequences.compactMap({ s in accumulated.range(of: s)?.lowerBound })
          .first
        {
          let endIdx = stopIndex
          let finalRange =
            accumulated.index(accumulated.startIndex, offsetBy: alreadyEmitted)..<endIdx
          let finalContent = String(accumulated[finalRange])
          if !finalContent.isEmpty {
            executeOnLoop(loop) {
              writerBox.value.writeContent(
                finalContent, model: effectiveModel, responseId: responseId, created: created,
                context: ctxBox.value)
            }
            alreadyEmitted += finalContent.count
          }
          break
        }
      }

      if !newSlice.isEmpty {
        executeOnLoop(loop) {
          writerBox.value.writeContent(
            newSlice, model: effectiveModel, responseId: responseId, created: created,
            context: ctxBox.value)
        }
        alreadyEmitted += newSlice.count
      }
    }

    // Finish and end
    executeOnLoop(loop) {
      writerBox.value.writeFinish(
        effectiveModel, responseId: responseId, created: created, context: ctxBox.value)
      writerBox.value.writeEnd(ctxBox.value)
    }
  }

  private func handleServiceNonStreamingResponse(
    service: ModelService,
    prompt: String,
    effectiveModel: String,
    parameters: GenerationParameters,
    stopSequences: [String],
    context: ChannelHandlerContext,
    extraHeaders: [(String, String)]? = nil
  ) async throws {
    var reply = try await service.generateOneShot(prompt: prompt, parameters: parameters)

    if !stopSequences.isEmpty {
      for s in stopSequences {
        if let r = reply.range(of: s) {
          reply = String(reply[..<r.lowerBound])
          break
        }
      }
    }

    let tokenCount = max(1, reply.count / 4)
    let response = ChatCompletionResponse(
      id: "chatcmpl-\(UUID().uuidString.prefix(8))",
      created: Int(Date().timeIntervalSince1970),
      model: effectiveModel,
      choices: [
        ChatChoice(
          index: 0,
          message: ChatMessage(
            role: "assistant", content: reply, tool_calls: nil, tool_call_id: nil),
          finish_reason: "stop"
        )
      ],
      usage: Usage(
        prompt_tokens: prompt.count / 4,
        completion_tokens: tokenCount,
        total_tokens: prompt.count / 4 + tokenCount
      ),
      system_fingerprint: nil
    )

    try await sendJSONResponse(response, status: .ok, context: context, extraHeaders: extraHeaders)
  }

  // MARK: - FoundationModels tool-calling bridge (OpenAI-compatible)

  #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private struct ToolInvocationError: Error {
      let toolName: String
      let jsonArguments: String
    }

    @available(macOS 26.0, *)
    private struct OpenAIToolAdapter: FoundationModels.Tool {
      typealias Output = String
      typealias Arguments = GeneratedContent

      let name: String
      let description: String
      let parameters: GenerationSchema
      var includesSchemaInInstructions: Bool { true }

      func call(arguments: GeneratedContent) async throws -> String {
        // Serialize arguments as JSON and throw to signal a tool call back to the server
        let json = arguments.jsonString
        throw ToolInvocationError(toolName: name, jsonArguments: json)
      }
    }

    @available(macOS 26.0, *)
    private func toAppleTool(_ tool: Tool) -> any FoundationModels.Tool {
      let desc = tool.function.description ?? ""
      let schema: GenerationSchema = makeGenerationSchema(
        from: tool.function.parameters, toolName: tool.function.name, description: desc)
      return OpenAIToolAdapter(name: tool.function.name, description: desc, parameters: schema)
    }

    // Convert OpenAI JSON Schema (as JSONValue) to FoundationModels GenerationSchema
    @available(macOS 26.0, *)
    private func makeGenerationSchema(
      from parameters: JSONValue?,
      toolName: String,
      description: String?
    ) -> GenerationSchema {
      guard let parameters else {
        return GenerationSchema(
          type: GeneratedContent.self, description: description, properties: [])
      }
      if let root = dynamicSchema(from: parameters, name: toolName) {
        if let schema = try? GenerationSchema(root: root, dependencies: []) {
          return schema
        }
      }
      return GenerationSchema(type: GeneratedContent.self, description: description, properties: [])
    }

    // Build a DynamicGenerationSchema recursively from a minimal subset of JSON Schema
    @available(macOS 26.0, *)
    private func dynamicSchema(from json: JSONValue, name: String) -> DynamicGenerationSchema? {
      switch json {
      case .object(let dict):
        // enum of strings
        if case let .array(enumVals)? = dict["enum"],
          case .string = enumVals.first
        {
          let choices: [String] = enumVals.compactMap { v in
            if case let .string(s) = v { return s } else { return nil }
          }
          return DynamicGenerationSchema(
            name: name, description: jsonStringOrNil(dict["description"]), anyOf: choices)
        }

        // type can be string or array
        var typeString: String? = nil
        if let t = dict["type"] {
          switch t {
          case .string(let s): typeString = s
          case .array(let arr):
            // Prefer first non-null type
            typeString =
              arr.compactMap { v in
                if case let .string(s) = v, s != "null" { return s } else { return nil }
              }.first
          default: break
          }
        }

        let desc = jsonStringOrNil(dict["description"])

        switch typeString ?? "object" {
        case "string":
          return DynamicGenerationSchema(type: String.self)
        case "integer":
          return DynamicGenerationSchema(type: Int.self)
        case "number":
          return DynamicGenerationSchema(type: Double.self)
        case "boolean":
          return DynamicGenerationSchema(type: Bool.self)
        case "array":
          if let items = dict["items"],
            let itemSchema = dynamicSchema(from: items, name: name + "Item")
          {
            let minItems = jsonIntOrNil(dict["minItems"])
            let maxItems = jsonIntOrNil(dict["maxItems"])
            return DynamicGenerationSchema(
              arrayOf: itemSchema, minimumElements: minItems, maximumElements: maxItems)
          }
          // Fallback to array of strings
          return DynamicGenerationSchema(
            arrayOf: DynamicGenerationSchema(type: String.self), minimumElements: nil,
            maximumElements: nil)
        case "object": fallthrough
        default:
          // Build object properties
          var required: Set<String> = []
          if case .array(let reqArr)? = dict["required"] {
            required = Set(
              reqArr.compactMap { v in if case let .string(s) = v { return s } else { return nil } }
            )
          }
          var properties: [DynamicGenerationSchema.Property] = []
          if case .object(let propsDict)? = dict["properties"] {
            for (propName, propSchemaJSON) in propsDict {
              let propSchema =
                dynamicSchema(from: propSchemaJSON, name: name + "." + propName)
                ?? DynamicGenerationSchema(type: String.self)
              let isOptional = !required.contains(propName)
              let prop = DynamicGenerationSchema.Property(
                name: propName,
                description: nil,
                schema: propSchema,
                isOptional: isOptional
              )
              properties.append(prop)
            }
          }
          return DynamicGenerationSchema(name: name, description: desc, properties: properties)
        }

      case .string:
        return DynamicGenerationSchema(type: String.self)
      case .number:
        return DynamicGenerationSchema(type: Double.self)
      case .bool:
        return DynamicGenerationSchema(type: Bool.self)
      case .array(let arr):
        // Attempt array of first element type
        if let first = arr.first, let item = dynamicSchema(from: first, name: name + "Item") {
          return DynamicGenerationSchema(arrayOf: item, minimumElements: nil, maximumElements: nil)
        }
        return DynamicGenerationSchema(
          arrayOf: DynamicGenerationSchema(type: String.self), minimumElements: nil,
          maximumElements: nil)
      case .null:
        // Default to string when null only
        return DynamicGenerationSchema(type: String.self)
      }
    }

    @available(macOS 26.0, *)
    private func buildOpenAIToolCall(toolName: String, jsonArguments: String) -> ToolCall {
      return ToolCall(
        id: "call_\(UUID().uuidString.prefix(8))",
        type: "function",
        function: ToolCallFunction(name: toolName, arguments: jsonArguments)
      )
    }

    // Helpers to extract primitive values from JSONValue
    private func jsonStringOrNil(_ value: JSONValue?) -> String? {
      guard let value else { return nil }
      if case let .string(s) = value { return s }
      return nil
    }
    private func jsonIntOrNil(_ value: JSONValue?) -> Int? {
      guard let value else { return nil }
      switch value {
      case let .number(d): return Int(d)
      case let .string(s): return Int(s)
      default: return nil
      }
    }

    @available(macOS 26.0, *)
    private func shouldEnableTool(_ tool: Tool, choice: ToolChoiceOption?) -> Bool {
      guard let choice else { return true }
      switch choice {
      case .auto: return true
      case .none: return false
      case .function(let n):
        return n.function.name == tool.function.name
      }
    }

    @available(macOS 26.0, *)
    private func handleFoundationNonStreamingWithTools(
      prompt: String,
      effectiveModel: String,
      parameters: GenerationParameters,
      stopSequences: [String],
      tools: [Tool],
      toolChoice: ToolChoiceOption?,
      context: ChannelHandlerContext,
      extraHeaders: [(String, String)]? = nil
    ) async throws {
      // Build Apple tools from OpenAI definitions honoring tool_choice
      let appleTools: [any FoundationModels.Tool] = tools.filter {
        shouldEnableTool($0, choice: toolChoice)
      }
      .map { toAppleTool($0) }

      let options = GenerationOptions(
        sampling: nil,
        temperature: Double(parameters.temperature),
        maximumResponseTokens: parameters.maxTokens
      )

      do {
        let session = LanguageModelSession(model: .default, tools: appleTools, instructions: nil)
        let response = try await session.respond(to: prompt, options: options)
        var reply = response.content
        if !stopSequences.isEmpty {
          for s in stopSequences {
            if let r = reply.range(of: s) {
              reply = String(reply[..<r.lowerBound])
              break
            }
          }
        }
        let tokenCount = max(1, reply.count / 4)
        let res = ChatCompletionResponse(
          id: "chatcmpl-\(UUID().uuidString.prefix(8))",
          created: Int(Date().timeIntervalSince1970),
          model: effectiveModel,
          choices: [
            ChatChoice(
              index: 0,
              message: ChatMessage(
                role: "assistant", content: reply, tool_calls: nil, tool_call_id: nil),
              finish_reason: "stop")
          ],
          usage: Usage(
            prompt_tokens: prompt.count / 4,
            completion_tokens: tokenCount,
            total_tokens: prompt.count / 4 + tokenCount
          ),
          system_fingerprint: nil
        )
        try await sendJSONResponse(res, status: .ok, context: context, extraHeaders: extraHeaders)
      } catch let error as LanguageModelSession.ToolCallError {
        // Map tool invocation to OpenAI-compatible tool_calls and return immediately
        if let inv = error.underlyingError as? ToolInvocationError {
          let tc = buildOpenAIToolCall(toolName: inv.toolName, jsonArguments: inv.jsonArguments)
          let res = ChatCompletionResponse(
            id: "chatcmpl-\(UUID().uuidString.prefix(8))",
            created: Int(Date().timeIntervalSince1970),
            model: effectiveModel,
            choices: [
              ChatChoice(
                index: 0,
                message: ChatMessage(
                  role: "assistant", content: nil, tool_calls: [tc], tool_call_id: nil),
                finish_reason: "tool_calls")
            ],
            usage: Usage(
              prompt_tokens: prompt.count / 4,
              completion_tokens: 0,
              total_tokens: prompt.count / 4
            ),
            system_fingerprint: nil
          )
          try await sendJSONResponse(res, status: .ok, context: context, extraHeaders: extraHeaders)
          return
        }
        throw error
      }
    }

    @available(macOS 26.0, *)
    private func handleFoundationStreamingWithTools(
      prompt: String,
      effectiveModel: String,
      parameters: GenerationParameters,
      stopSequences: [String],
      tools: [Tool],
      toolChoice: ToolChoiceOption?,
      context: ChannelHandlerContext,
      writer: ResponseWriter,
      extraHeaders: [(String, String)]? = nil
    ) async throws {
      let loop = context.eventLoop
      let ctxBox = UncheckedSendableBox(value: context)
      let writerBox = UncheckedSendableBox(value: writer)

      // Only SSE writer supports OpenAI-style tool_call deltas
      let isSSE = writer is SSEResponseWriter

      executeOnLoop(loop) {
        writerBox.value.writeHeaders(ctxBox.value, extraHeaders: extraHeaders)
      }

      let responseId = "chatcmpl-\(UUID().uuidString.prefix(8))"
      let created = Int(Date().timeIntervalSince1970)

      // Send role prelude
      executeOnLoop(loop) {
        writerBox.value.writeRole(
          "assistant", model: effectiveModel, responseId: responseId, created: created,
          context: ctxBox.value)
      }

      let appleTools: [any FoundationModels.Tool] = tools.filter {
        shouldEnableTool($0, choice: toolChoice)
      }
      .map { toAppleTool($0) }

      let options = GenerationOptions(
        sampling: nil,
        temperature: Double(parameters.temperature),
        maximumResponseTokens: parameters.maxTokens
      )

      let session = LanguageModelSession(model: .default, tools: appleTools, instructions: nil)
      let stream = session.streamResponse(to: prompt, options: options)

      var previous = ""

      do {
        var iterator = stream.makeAsyncIterator()
        while let snapshot = try await iterator.next() {
          var current = snapshot.content
          if !stopSequences.isEmpty,
            let r = stopSequences.compactMap({ current.range(of: $0)?.lowerBound }).first
          {
            current = String(current[..<r])
          }
          let delta: String
          if current.hasPrefix(previous) {
            delta = String(current.dropFirst(previous.count))
          } else {
            delta = current
          }
          if !delta.isEmpty {
            executeOnLoop(loop) {
              writerBox.value.writeContent(
                delta, model: effectiveModel, responseId: responseId, created: created,
                context: ctxBox.value)
            }
          }
          previous = current
        }

        // Finish
        executeOnLoop(loop) {
          writerBox.value.writeFinish(
            effectiveModel, responseId: responseId, created: created, context: ctxBox.value)
          writerBox.value.writeEnd(ctxBox.value)
        }
      } catch let error as LanguageModelSession.ToolCallError {
        // Flush any streamed content and emit tool_calls if SSE
        if isSSE, let inv = error.underlyingError as? ToolInvocationError {
          let callId = "call_\(UUID().uuidString.prefix(8))"
          let idTypeChunk = ChatCompletionChunk(
            id: responseId,
            created: created,
            model: effectiveModel,
            choices: [
              StreamChoice(
                index: 0,
                delta: DeltaContent(tool_calls: [
                  DeltaToolCall(index: 0, id: callId, type: "function", function: nil)
                ]), finish_reason: nil)
            ],
            system_fingerprint: nil
          )
          let nameChunk = ChatCompletionChunk(
            id: responseId,
            created: created,
            model: effectiveModel,
            choices: [
              StreamChoice(
                index: 0,
                delta: DeltaContent(tool_calls: [
                  DeltaToolCall(
                    index: 0, id: callId, type: nil,
                    function: DeltaToolCallFunction(name: inv.toolName, arguments: nil))
                ]), finish_reason: nil)
            ],
            system_fingerprint: nil
          )
          let argsChunk = ChatCompletionChunk(
            id: responseId,
            created: created,
            model: effectiveModel,
            choices: [
              StreamChoice(
                index: 0,
                delta: DeltaContent(tool_calls: [
                  DeltaToolCall(
                    index: 0, id: callId, type: nil,
                    function: DeltaToolCallFunction(name: nil, arguments: inv.jsonArguments))
                ]), finish_reason: nil)
            ],
            system_fingerprint: nil
          )

          executeOnLoop(loop) {
            let context = ctxBox.value
            guard context.channel.isActive else { return }
            let encoder = IkigaJSONEncoder()
            var buffer = context.channel.allocator.buffer(capacity: 1024)
            func writeData<T: Encodable>(_ v: T) {
              buffer.writeString("data: ")
              do { try encoder.encodeAndWrite(v, into: &buffer) } catch {}
              buffer.writeString("\n\n")
            }
            writeData(idTypeChunk)
            writeData(nameChunk)
            writeData(argsChunk)
            let finishChunk = ChatCompletionChunk(
              id: responseId,
              created: created,
              model: effectiveModel,
              choices: [StreamChoice(index: 0, delta: DeltaContent(), finish_reason: "tool_calls")],
              system_fingerprint: nil
            )
            writeData(finishChunk)
            buffer.writeString("data: [DONE]\n\n")
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            context.flush()
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?)))
              .whenComplete { _ in
                let context = ctxBox.value
                context.close(promise: nil)
              }
          }
          return
        } else {
          // Fallback: end normally
          executeOnLoop(loop) {
            writerBox.value.writeFinish(
              effectiveModel, responseId: responseId, created: created, context: ctxBox.value)
            writerBox.value.writeEnd(ctxBox.value)
          }
        }
      }
    }
  #endif

  private func handleStreamingResponse(
    messages: [Message],
    model: LMModel,
    temperature: Float,
    maxTokens: Int,
    requestModel: String,
    tools: [Tool]?,
    toolChoice: ToolChoiceOption?,
    sessionId: String?,
    stopSequences: [String],
    context: ChannelHandlerContext,
    writer: ResponseWriter,
    extraHeaders: [(String, String)]? = nil
  ) async throws {
    let loop = context.eventLoop
    let ctxBox = UncheckedSendableBox(value: context)
    let writerBox = UncheckedSendableBox(value: writer)

    // Write headers using the response writer
    executeOnLoop(loop) {
      writerBox.value.writeHeaders(ctxBox.value, extraHeaders: extraHeaders)
    }

    // Generate response ID
    let responseId = "chatcmpl-\(UUID().uuidString.prefix(8))"
    let created = Int(Date().timeIntervalSince1970)

    // Generate MLX event stream (chunks + tool calls)
    let eventStream = try await MLXService.shared.generateEvents(
      messages: messages,
      model: model,
      temperature: temperature,
      maxTokens: maxTokens,
      tools: tools,
      toolChoice: toolChoice,
      sessionId: sessionId
    )

    var fullResponse = ""
    var tokenCount = 0

    // If tools are provided (and tool_choice is not "none"), we need to check for tool calls
    // However, we'll stream content immediately for better performance
    let shouldCheckForTools: Bool = {
      guard tools?.isEmpty == false else { return false }
      if let toolChoice, case .none = toolChoice { return false }
      return true
    }()

    // For final content summary (non-tool path), collect chunks
    var responseBuffer: [String] = []
    responseBuffer.reserveCapacity(1024)

    if shouldCheckForTools {
      // Send initial role chunk
      executeOnLoop(loop) {
        writerBox.value.writeRole(
          "assistant", model: requestModel, responseId: responseId, created: created,
          context: ctxBox.value)
      }

      // Probe thresholds (env tunable)
      let probeTokenThreshold: Int = {
        let env = ProcessInfo.processInfo.environment
        return Int(env["OSU_TOOL_PROBE_TOKENS"] ?? "") ?? 12
      }()
      let probeByteThreshold: Int = {
        let env = ProcessInfo.processInfo.environment
        return Int(env["OSU_TOOL_PROBE_BYTES"] ?? "") ?? 2048
      }()

      // Reuse streaming batch tunables
      let batchCharThreshold: Int = {
        let env = ProcessInfo.processInfo.environment
        return Int(env["OSU_STREAM_BATCH_CHARS"] ?? "") ?? 256
      }()
      let batchIntervalMs: Int = {
        let env = ProcessInfo.processInfo.environment
        return Int(env["OSU_STREAM_BATCH_MS"] ?? "") ?? 16
      }()
      let flushIntervalNs: UInt64 = UInt64(batchIntervalMs) * 1_000_000

      var accumulatedBytes: Int = 0
      var didSwitchToStreaming: Bool = false

      // Stop sequence rolling window (used after switching to streaming)
      let shouldCheckStop = !(stopSequences.isEmpty)
      let maxStopLen: Int = shouldCheckStop ? (stopSequences.map { $0.count }.max() ?? 0) : 0
      var stopTail = ""

      // Batching state (event-loop confined) for post-probe streaming
      var firstTokenSent = false
      let initialCapacity = max(1024, batchCharThreshold)
      var pendingBuffer = ByteBufferAllocator().buffer(capacity: initialCapacity)
      var pendingCharCount: Int = 0
      var lastFlushNs: UInt64 = DispatchTime.now().uptimeNanoseconds
      var scheduledFlush: Bool = false

      @inline(__always)
      func scheduleFlushOnLoopIfNeeded() {
        if scheduledFlush { return }
        scheduledFlush = true
        let deadline = NIODeadline.now() + .milliseconds(Int64(batchIntervalMs))
        loop.scheduleTask(deadline: deadline) {
          scheduledFlush = false
          if pendingBuffer.readableBytes > 0 {
            let content = pendingBuffer.readString(length: pendingBuffer.readableBytes) ?? ""
            writerBox.value.writeContent(
              content, model: requestModel, responseId: responseId, created: created,
              context: ctxBox.value)
            pendingCharCount = 0
            lastFlushNs = DispatchTime.now().uptimeNanoseconds
          }
        }
      }

      @inline(__always)
      func processTokenOnLoop(_ token: String) {
        if !firstTokenSent {
          writerBox.value.writeContent(
            token, model: requestModel, responseId: responseId, created: created,
            context: ctxBox.value)
          firstTokenSent = true
          lastFlushNs = DispatchTime.now().uptimeNanoseconds
          return
        }
        pendingBuffer.writeString(token)
        pendingCharCount &+= token.count
        let nowNs = DispatchTime.now().uptimeNanoseconds
        if pendingCharCount >= batchCharThreshold || nowNs - lastFlushNs >= flushIntervalNs {
          if pendingBuffer.readableBytes > 0 {
            let content = pendingBuffer.readString(length: pendingBuffer.readableBytes) ?? ""
            writerBox.value.writeContent(
              content, model: requestModel, responseId: responseId, created: created,
              context: ctxBox.value)
            pendingCharCount = 0
            lastFlushNs = nowNs
          }
        } else {
          scheduleFlushOnLoopIfNeeded()
        }
      }

      // When tools are enabled, start with a brief probe. If a tool call happens, we discard the
      // buffered content. If no tool call happens after the probe, switch to micro-batched streaming.
      for await event in eventStream {
        if let chunk = event.chunk {
          if !didSwitchToStreaming {
            responseBuffer.append(chunk)
            accumulatedBytes &+= chunk.utf8.count
            tokenCount &+= 1

            // Check if we should switch to streaming due to probe threshold
            if tokenCount >= probeTokenThreshold || accumulatedBytes >= probeByteThreshold {
              // Join buffered content and trim stops locally if present
              var buffered = responseBuffer.joined()
              if shouldCheckStop && !stopSequences.isEmpty {
                for s in stopSequences {
                  if let range = buffered.range(of: s) {
                    buffered = String(buffered[..<range.lowerBound])
                    break
                  }
                }
              }
              if !buffered.isEmpty {
                // Prime stopTail for subsequent detection
                if shouldCheckStop {
                  if buffered.count > maxStopLen {
                    stopTail = String(buffered.suffix(maxStopLen))
                  } else {
                    stopTail = buffered
                  }
                }
                let contentToSend = buffered
                executeOnLoop(loop) {
                  writerBox.value.writeContent(
                    contentToSend, model: requestModel, responseId: responseId, created: created,
                    context: ctxBox.value)
                }
                firstTokenSent = true
              }
              // Clear probe buffer and switch to streaming
              responseBuffer.removeAll(keepingCapacity: true)
              accumulatedBytes = 0
              didSwitchToStreaming = true
              continue
            }
          } else {
            // Already in streaming mode: apply stop detection and micro-batching
            if shouldCheckStop {
              stopTail += chunk
              if stopTail.count > maxStopLen {
                let overflow = stopTail.count - maxStopLen
                stopTail.removeFirst(overflow)
              }
              if stopSequences.first(where: { stopTail.contains($0) }) != nil {
                // Flush any pending content and break
                executeOnLoop(loop) {
                  if pendingBuffer.readableBytes > 0 {
                    let content =
                      pendingBuffer.readString(length: pendingBuffer.readableBytes) ?? ""
                    writerBox.value.writeContent(
                      content, model: requestModel, responseId: responseId, created: created,
                      context: ctxBox.value)
                    pendingCharCount = 0
                    lastFlushNs = DispatchTime.now().uptimeNanoseconds
                  }
                }
                break
              }
            }
            executeOnLoop(loop) {
              processTokenOnLoop(chunk)
            }
          }
        }

        if let toolCall = event.toolCall {
          // If we already switched to streaming, flush pending buffer before emitting tool call deltas
          if didSwitchToStreaming {
            executeOnLoop(loop) {
              if pendingBuffer.readableBytes > 0 {
                let content = pendingBuffer.readString(length: pendingBuffer.readableBytes) ?? ""
                writerBox.value.writeContent(
                  content, model: requestModel, responseId: responseId, created: created,
                  context: ctxBox.value)
                pendingCharCount = 0
                lastFlushNs = DispatchTime.now().uptimeNanoseconds
              }
            }
          }

          // For SSE writer, we need to handle tool calls specially
          // NDJSON writer doesn't support tool calls in the same way
          if writer is SSEResponseWriter {
            // Emit OpenAI-style tool_call deltas based on MLX ToolCall
            let mlxName = toolCall.function.name
            let argsObject = toolCall.function.arguments
            let argsData = try? JSONSerialization.data(
              withJSONObject: argsObject.mapValues { $0.anyValue })
            let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let callId = "call_\(UUID().uuidString.prefix(8))"

            // Batch tool_call deltas
            let idTypeChunk = ChatCompletionChunk(
              id: responseId,
              created: created,
              model: requestModel,
              choices: [
                StreamChoice(
                  index: 0,
                  delta: DeltaContent(tool_calls: [
                    DeltaToolCall(index: 0, id: callId, type: "function", function: nil)
                  ]), finish_reason: nil)
              ],
              system_fingerprint: nil
            )
            let nameChunk = ChatCompletionChunk(
              id: responseId,
              created: created,
              model: requestModel,
              choices: [
                StreamChoice(
                  index: 0,
                  delta: DeltaContent(tool_calls: [
                    DeltaToolCall(
                      index: 0, id: callId, type: nil,
                      function: DeltaToolCallFunction(name: mlxName, arguments: nil))
                  ]), finish_reason: nil)
              ],
              system_fingerprint: nil
            )
            let argsChunk = ChatCompletionChunk(
              id: responseId,
              created: created,
              model: requestModel,
              choices: [
                StreamChoice(
                  index: 0,
                  delta: DeltaContent(tool_calls: [
                    DeltaToolCall(
                      index: 0, id: callId, type: nil,
                      function: DeltaToolCallFunction(name: nil, arguments: argsString))
                  ]), finish_reason: nil)
              ],
              system_fingerprint: nil
            )
            executeOnLoop(loop) {
              let context = ctxBox.value
              guard context.channel.isActive else { return }
              let encoder = IkigaJSONEncoder()
              var buffer = context.channel.allocator.buffer(capacity: 1024)
              func writeData<T: Encodable>(_ v: T) {
                buffer.writeString("data: ")
                do { try encoder.encodeAndWrite(v, into: &buffer) } catch {}
                buffer.writeString("\n\n")
              }
              writeData(idTypeChunk)
              writeData(nameChunk)
              writeData(argsChunk)
              // Write finish with tool_calls reason
              let finishChunk = ChatCompletionChunk(
                id: responseId,
                created: created,
                model: requestModel,
                choices: [
                  StreamChoice(index: 0, delta: DeltaContent(), finish_reason: "tool_calls")
                ],
                system_fingerprint: nil
              )
              writeData(finishChunk)
              buffer.writeString("data: [DONE]\n\n")
              context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
              context.flush()
              context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?)))
                .whenComplete { _ in
                  let context = ctxBox.value
                  context.close(promise: nil)
                }
            }
          }
          return
        }
      }

      if didSwitchToStreaming {
        // Flush any remaining pending buffer after event stream completion
        executeOnLoop(loop) {
          if pendingBuffer.readableBytes > 0 {
            let content = pendingBuffer.readString(length: pendingBuffer.readableBytes) ?? ""
            writerBox.value.writeContent(
              content, model: requestModel, responseId: responseId, created: created,
              context: ctxBox.value)
          }
        }
      } else {
        // Join buffered content and trim stops locally; emit once if no tool call occurred
        fullResponse = responseBuffer.joined()
        if !stopSequences.isEmpty {
          for s in stopSequences {
            if let range = fullResponse.range(of: s) {
              fullResponse = String(fullResponse[..<range.lowerBound])
              break
            }
          }
        }
        if !fullResponse.isEmpty {
          executeOnLoop(loop) {
            writerBox.value.writeContent(
              fullResponse, model: requestModel, responseId: responseId, created: created,
              context: ctxBox.value)
          }
        }
      }
    } else {
      // Stream tokens with batching and stop detection
      // Cache env thresholds once per process to avoid per-request overhead
      struct StreamTuning {
        static let batchChars: Int = {
          let env = ProcessInfo.processInfo.environment
          return Int(env["OSU_STREAM_BATCH_CHARS"] ?? "") ?? 256
        }()
        static let batchMs: Int = {
          let env = ProcessInfo.processInfo.environment
          return Int(env["OSU_STREAM_BATCH_MS"] ?? "") ?? 16
        }()
      }
      let batchCharThreshold: Int = StreamTuning.batchChars
      let batchIntervalMs: Int = StreamTuning.batchMs
      let flushIntervalNs: UInt64 = UInt64(batchIntervalMs) * 1_000_000

      // Stop sequence rolling window
      let shouldCheckStop = !(stopSequences.isEmpty)
      let maxStopLen: Int = shouldCheckStop ? (stopSequences.map { $0.count }.max() ?? 0) : 0
      var stopTail = ""

      // Batching state (event-loop confined)
      var firstTokenSent = false
      let initialCapacity = max(1024, batchCharThreshold)
      var pendingBuffer = ByteBufferAllocator().buffer(capacity: initialCapacity)
      var pendingCharCount: Int = 0
      var lastFlushNs: UInt64 = DispatchTime.now().uptimeNanoseconds
      var scheduledFlush: Bool = false

      @inline(__always)
      func scheduleFlushOnLoopIfNeeded() {
        if scheduledFlush { return }
        scheduledFlush = true
        let deadline = NIODeadline.now() + .milliseconds(Int64(batchIntervalMs))
        loop.scheduleTask(deadline: deadline) {
          scheduledFlush = false
          if pendingBuffer.readableBytes > 0 {
            let content = pendingBuffer.readString(length: pendingBuffer.readableBytes) ?? ""
            writerBox.value.writeContent(
              content, model: requestModel, responseId: responseId, created: created,
              context: ctxBox.value)
            pendingCharCount = 0
            lastFlushNs = DispatchTime.now().uptimeNanoseconds
          }
        }
      }

      @inline(__always)
      func processTokenOnLoop(_ token: String) {
        if !firstTokenSent {
          writerBox.value.writeContent(
            token, model: requestModel, responseId: responseId, created: created,
            context: ctxBox.value)
          firstTokenSent = true
          lastFlushNs = DispatchTime.now().uptimeNanoseconds
          return
        }
        pendingBuffer.writeString(token)
        pendingCharCount &+= token.count
        let nowNs = DispatchTime.now().uptimeNanoseconds
        if pendingCharCount >= batchCharThreshold || nowNs - lastFlushNs >= flushIntervalNs {
          if pendingBuffer.readableBytes > 0 {
            let content = pendingBuffer.readString(length: pendingBuffer.readableBytes) ?? ""
            writerBox.value.writeContent(
              content, model: requestModel, responseId: responseId, created: created,
              context: ctxBox.value)
            pendingCharCount = 0
            lastFlushNs = nowNs
          }
        } else {
          scheduleFlushOnLoopIfNeeded()
        }
      }

      // Immediately send role prelude before first model token (helps TTFT)
      executeOnLoop(loop) {
        writerBox.value.writeRole(
          "assistant", model: requestModel, responseId: responseId, created: created,
          context: ctxBox.value)
      }

      for await event in eventStream {
        guard let token = event.chunk else { continue }
        if shouldCheckStop {
          stopTail += token
          if stopTail.count > maxStopLen {
            let overflow = stopTail.count - maxStopLen
            stopTail.removeFirst(overflow)
          }
          if stopSequences.first(where: { stopTail.contains($0) }) != nil {
            executeOnLoop(loop) {
              if pendingBuffer.readableBytes > 0 {
                let content = pendingBuffer.readString(length: pendingBuffer.readableBytes) ?? ""
                writerBox.value.writeContent(
                  content, model: requestModel, responseId: responseId, created: created,
                  context: ctxBox.value)
                pendingCharCount = 0
                lastFlushNs = DispatchTime.now().uptimeNanoseconds
              }
            }
            break
          }
        }

        executeOnLoop(loop) {
          processTokenOnLoop(token)
        }
      }

      executeOnLoop(loop) {
        if pendingBuffer.readableBytes > 0 {
          let content = pendingBuffer.readString(length: pendingBuffer.readableBytes) ?? ""
          writerBox.value.writeContent(
            content, model: requestModel, responseId: responseId, created: created,
            context: ctxBox.value)
          pendingCharCount = 0
          lastFlushNs = DispatchTime.now().uptimeNanoseconds
        }
      }
    }

    // Send final chunk (non-tool path). For tool_calls path we already returned above
    // Trim to first stop sequence if present (non-tool path)
    if !stopSequences.isEmpty {
      for s in stopSequences {
        if let range = fullResponse.range(of: s) {
          fullResponse = String(fullResponse[..<range.lowerBound])
          break
        }
      }
    }

    // Send finish and end
    executeOnLoop(loop) {
      writerBox.value.writeFinish(
        requestModel, responseId: responseId, created: created, context: ctxBox.value)
      writerBox.value.writeEnd(ctxBox.value)
    }
  }

  private func handleNonStreamingResponse(
    messages: [Message],
    model: LMModel,
    temperature: Float,
    maxTokens: Int,
    requestModel: String,
    tools: [Tool]?,
    toolChoice: ToolChoiceOption?,
    sessionId: String?,
    stopSequences: [String],
    context: ChannelHandlerContext,
    extraHeaders: [(String, String)]? = nil
  ) async throws {
    // Generate complete response
    let eventStream = try await MLXService.shared.generateEvents(
      messages: messages,
      model: model,
      temperature: temperature,
      maxTokens: maxTokens,
      tools: tools,
      toolChoice: toolChoice,
      sessionId: sessionId
    )

    var fullResponse = ""
    var tokenCount = 0
    var segments: [String] = []
    segments.reserveCapacity(512)

    let stopSequences: [String] = stopSequences
    let shouldCheckStop = !stopSequences.isEmpty
    let maxStopLen: Int = shouldCheckStop ? (stopSequences.map { $0.count }.max() ?? 0) : 0
    var stopTail = ""
    for await event in eventStream {
      if let toolCall = event.toolCall {
        // Build OpenAI-compatible tool_calls in non-streaming response
        let argsData = try? JSONSerialization.data(
          withJSONObject: toolCall.function.arguments.mapValues { $0.anyValue })
        let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let tc = ToolCall(
          id: "call_\(UUID().uuidString.prefix(8))",
          type: "function",
          function: ToolCallFunction(name: toolCall.function.name, arguments: argsString)
        )
        // Construct response with tool call and return immediately
        let response = ChatCompletionResponse(
          id: "chatcmpl-\(UUID().uuidString.prefix(8))",
          created: Int(Date().timeIntervalSince1970),
          model: requestModel,
          choices: [
            ChatChoice(
              index: 0,
              message: ChatMessage(
                role: "assistant", content: nil, tool_calls: [tc], tool_call_id: nil),
              finish_reason: "tool_calls"
            )
          ],
          usage: Usage(
            prompt_tokens: messages.reduce(0) { $0 + $1.content.count / 4 },
            completion_tokens: 0,
            total_tokens: messages.reduce(0) { $0 + $1.content.count / 4 }
          ),
          system_fingerprint: nil
        )
        try await sendJSONResponse(
          response, status: .ok, context: context, extraHeaders: extraHeaders)
        return
      }
      guard let token = event.chunk else { continue }
      if shouldCheckStop {
        stopTail += token
        if stopTail.count > maxStopLen {
          let overflow = stopTail.count - maxStopLen
          stopTail.removeFirst(overflow)
        }
        if stopSequences.first(where: { stopTail.contains($0) }) != nil {
          break
        }
      }
      segments.append(token)
      tokenCount += 1
    }
    fullResponse = segments.joined()

    // Trim at stop if present
    if !stopSequences.isEmpty {
      for s in stopSequences {
        if let range = fullResponse.range(of: s) {
          fullResponse = String(fullResponse[..<range.lowerBound])
          break
        }
      }
    }
    let finishReason = "stop"

    // Create response
    let response = ChatCompletionResponse(
      id: "chatcmpl-\(UUID().uuidString.prefix(8))",
      created: Int(Date().timeIntervalSince1970),
      model: requestModel,
      choices: [
        ChatChoice(
          index: 0,
          message: ChatMessage(
            role: "assistant", content: fullResponse, tool_calls: nil, tool_call_id: nil),
          finish_reason: finishReason
        )
      ],
      usage: Usage(
        prompt_tokens: messages.reduce(0) { $0 + $1.content.count / 4 },
        completion_tokens: tokenCount,
        total_tokens: messages.reduce(0) { $0 + $1.content.count / 4 } + tokenCount
      ),
      system_fingerprint: nil
    )

    try await sendJSONResponse(response, status: .ok, context: context, extraHeaders: extraHeaders)
  }

  // Tool Call Parsing moved to ToolCallParser

  private func sendJSONResponse<T: Encodable>(
    _ response: T,
    status: HTTPResponseStatus,
    context: ChannelHandlerContext,
    extraHeaders: [(String, String)]? = nil
  ) async throws {
    let loop = context.eventLoop
    let ctxBox = UncheckedSendableBox(value: context)
    // Send response on the event loop
    loop.execute {
      let context = ctxBox.value
      guard context.channel.isActive else { return }
      let encoder = IkigaJSONEncoder()
      var responseHead = HTTPResponseHead(version: .http1_1, status: status)
      var buffer = context.channel.allocator.buffer(capacity: 1024)
      do { try encoder.encodeAndWrite(response, into: &buffer) } catch {
        buffer.clear()
        buffer.writeString("{}")
      }
      var headers = HTTPHeaders()
      headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
      headers.add(name: "Content-Length", value: String(buffer.readableBytes))
      headers.add(name: "Connection", value: "close")
      if let extraHeaders {
        for (n, v) in extraHeaders { headers.add(name: n, value: v) }
      }
      responseHead.headers = headers
      context.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
      context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
      context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete {
        _ in
        let context = ctxBox.value
        context.close(promise: nil)
      }
    }
  }

  // MARK: - Helpers
  private func encodeJSONString<T: Encodable>(_ value: T) -> String? {
    let encoder = IkigaJSONEncoder()
    var buffer = ByteBufferAllocator().buffer(capacity: 1024)
    do {
      try encoder.encodeAndWrite(value, into: &buffer)
      return buffer.readString(length: buffer.readableBytes)
    } catch {
      return nil
    }
  }
}
