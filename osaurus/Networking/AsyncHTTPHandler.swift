//
//  AsyncHTTPHandler.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Dispatch
import Foundation
import IkigaJSON
import NIOCore
import NIOHTTP1

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
      // Prepare model services (prefer Foundation for default, MLX for explicit local models)
      let services: [ModelService] = [FoundationModelService(), MLXService.shared]
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
        do {
          if request.stream ?? false {
            try await handleServiceStreamingResponse(
              service: service,
              prompt: prompt,
              effectiveModel: effectiveModel,
              parameters: GenerationParameters(temperature: temperature, maxTokens: maxTokens),
              stopSequences: effectiveStops,
              tools: request.tools,
              toolChoice: request.tool_choice,
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
              tools: request.tools,
              toolChoice: request.tool_choice,
              context: context,
              extraHeaders: extraHeaders
            )
          }
        }
        return
      case .none:
        let error = OpenAIError(
          error: OpenAIError.ErrorDetail(
            message: "No compatible model service available for this request.",
            type: "invalid_request_error",
            param: "model",
            code: nil
          )
        )
        try await sendJSONResponse(
          error, status: .notFound, context: context, extraHeaders: extraHeaders)
        return
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
    tools: [Tool]?,
    toolChoice: ToolChoiceOption?,
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

    // If the service is tool-capable and tools are provided (and not disabled),
    // delegate to the tool-aware streaming path to align with MLX tool handling.
    if let toolService = service as? ToolCapableService {
      let shouldUseTools: Bool = {
        guard let tools = tools, !tools.isEmpty else { return false }
        if let c = toolChoice { if case .none = c { return false } }
        return true
      }()
      if shouldUseTools {
        // Only SSE writer supports OpenAI-style tool_call deltas
        let isSSE = writer is SSEResponseWriter
        do {
          let stream = try await toolService.streamWithTools(
            prompt: prompt,
            parameters: parameters,
            stopSequences: stopSequences,
            tools: tools!,
            toolChoice: toolChoice,
            requestedModel: effectiveModel
          )
          var emittedAny = false
          for try await delta in stream {
            // Detect out-of-band error marker from Foundation service
            if delta.hasPrefix("__OS_ERROR__:") {
              let msg = String(delta.dropFirst("__OS_ERROR__:".count))
              executeOnLoop(loop) {
                writerBox.value.writeError(msg, context: ctxBox.value)
                writerBox.value.writeEnd(ctxBox.value)
              }
              return
            }
            executeOnLoop(loop) {
              writerBox.value.writeContent(
                delta, model: effectiveModel, responseId: responseId, created: created,
                context: ctxBox.value)
            }
            emittedAny = true
          }
          if emittedAny {
            executeOnLoop(loop) {
              writerBox.value.writeFinish(
                effectiveModel, responseId: responseId, created: created, context: ctxBox.value)
              writerBox.value.writeEnd(ctxBox.value)
            }
          } else {
            executeOnLoop(loop) {
              writerBox.value.writeError("Generation produced no content.", context: ctxBox.value)
              writerBox.value.writeEnd(ctxBox.value)
            }
          }
        } catch let inv as ServiceToolInvocation {
          if isSSE {
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
          } else {
            executeOnLoop(loop) {
              writerBox.value.writeFinish(
                effectiveModel, responseId: responseId, created: created, context: ctxBox.value)
              writerBox.value.writeEnd(ctxBox.value)
            }
          }
        } catch {
          // Stream failed; emit error over the chosen streaming format
          executeOnLoop(loop) {
            writerBox.value.writeError(error.localizedDescription, context: ctxBox.value)
            writerBox.value.writeEnd(ctxBox.value)
          }
        }
        return
      }
    }

    // Use the service stream
    let stream: AsyncStream<String>
    do {
      stream = try await service.streamDeltas(
        prompt: prompt,
        parameters: parameters,
        requestedModel: effectiveModel)
    } catch {
      // If obtaining the stream fails after headers have been sent, emit an error chunk
      executeOnLoop(loop) {
        writerBox.value.writeError(error.localizedDescription, context: ctxBox.value)
        writerBox.value.writeEnd(ctxBox.value)
      }
      return
    }

    // Stop sequence handling across chunk boundaries
    var accumulated: String = ""
    var alreadyEmitted: Int = 0
    let shouldCheckStop = !stopSequences.isEmpty

    var emittedAnyContent = false
    for await delta in stream {
      // Detect out-of-band error marker from Foundation service
      if delta.hasPrefix("__OS_ERROR__:") {
        let msg = String(delta.dropFirst("__OS_ERROR__:".count))
        executeOnLoop(loop) {
          writerBox.value.writeError(msg, context: ctxBox.value)
          writerBox.value.writeEnd(ctxBox.value)
        }
        return
      }
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
            emittedAnyContent = true
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
        emittedAnyContent = true
      }
    }

    // Finish or emit error and end
    if emittedAnyContent {
      executeOnLoop(loop) {
        writerBox.value.writeFinish(
          effectiveModel, responseId: responseId, created: created, context: ctxBox.value)
        writerBox.value.writeEnd(ctxBox.value)
      }
    } else {
      executeOnLoop(loop) {
        writerBox.value.writeError("Generation produced no content.", context: ctxBox.value)
        writerBox.value.writeEnd(ctxBox.value)
      }
    }
  }

  private func handleServiceNonStreamingResponse(
    service: ModelService,
    prompt: String,
    effectiveModel: String,
    parameters: GenerationParameters,
    stopSequences: [String],
    tools: [Tool]?,
    toolChoice: ToolChoiceOption?,
    context: ChannelHandlerContext,
    extraHeaders: [(String, String)]? = nil
  ) async throws {
    // If the service is tool-capable and tools are provided (and not disabled), delegate
    if let toolService = service as? ToolCapableService {
      let shouldUseTools: Bool = {
        guard let tools = tools, !tools.isEmpty else { return false }
        if let c = toolChoice { if case .none = c { return false } }
        return true
      }()
      if shouldUseTools {
        do {
          let reply = try await toolService.respondWithTools(
            prompt: prompt,
            parameters: parameters,
            stopSequences: stopSequences,
            tools: tools!,
            toolChoice: toolChoice,
            requestedModel: effectiveModel
          )
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
          return
        } catch let inv as ServiceToolInvocation {
          // Map tool invocation to OpenAI-compatible tool_calls and return
          let tc = ToolCall(
            id: "call_\(UUID().uuidString.prefix(8))",
            type: "function",
            function: ToolCallFunction(name: inv.toolName, arguments: inv.jsonArguments)
          )
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
      }
    }

    var reply = try await service.generateOneShot(
      prompt: prompt,
      parameters: parameters,
      requestedModel: effectiveModel
    )

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
