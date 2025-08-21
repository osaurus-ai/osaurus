//
//  AsyncHTTPHandler.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1

private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

/// Handles async operations for HTTP endpoints
class AsyncHTTPHandler {
    static let shared = AsyncHTTPHandler()
    
    private init() {}
    
    /// Handle chat completions with streaming support
    func handleChatCompletion(
        request: ChatCompletionRequest,
        context: ChannelHandlerContext
    ) async {
        do {
            // Find the model using nonisolated static accessor
            guard let model = MLXService.findModel(named: request.model) else {
                let error = OpenAIError(
                    error: OpenAIError.ErrorDetail(
                        message: "Model not found: \(request.model)",
                        type: "invalid_request_error",
                        param: "model",
                        code: nil
                    )
                )
                try await sendJSONResponse(error, status: .notFound, context: context)
                return
            }
            
            // Convert messages
            let messages = request.toInternalMessages()
            
            // Get generation parameters
            let temperature = request.temperature ?? 0.7
            let maxTokens = request.max_tokens ?? 2048
            
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
                    context: context
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
                    context: context
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
            try? await sendJSONResponse(errorResponse, status: .internalServerError, context: context)
        }
    }
    
    private func handleStreamingResponse(
        messages: [Message],
        model: LMModel,
        temperature: Float,
        maxTokens: Int,
        requestModel: String,
        tools: [Tool]?,
        toolChoice: ToolChoiceOption?,
        context: ChannelHandlerContext
    ) async throws {
        let loop = context.eventLoop
        let ctxBox = UncheckedSendableBox(value: context)
        // Send SSE headers
        let headers: [(String, String)] = [
            ("Content-Type", "text/event-stream"),
            ("Cache-Control", "no-cache"),
            ("Connection", "keep-alive")
        ]
        
        // Prepare response headers
        var responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        var nioHeaders = HTTPHeaders()
        for (name, value) in headers {
            nioHeaders.add(name: name, value: value)
        }
        responseHead.headers = nioHeaders
        
        // Ensure header write happens on the channel's event loop
        loop.execute {
            let context = ctxBox.value
            guard context.channel.isActive else { return }
            context.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
            context.flush()
        }
        
        // Generate response ID
        let responseId = "chatcmpl-\(UUID().uuidString.prefix(8))"
        let created = Int(Date().timeIntervalSince1970)
        
        // Generate
        let stream = try await MLXService.shared.generate(
            messages: messages,
            model: model,
            temperature: temperature,
            maxTokens: maxTokens,
            tools: tools,
            toolChoice: toolChoice
        )
        
        var fullResponse = ""
        var tokenCount = 0
        
        // If tools are provided (and tool_choice is not "none"), buffer the stream to detect tool_calls and then emit appropriate deltas
        let shouldBufferForTools: Bool = {
            guard tools?.isEmpty == false else { return false }
            if let toolChoice, case .none = toolChoice { return false }
            return true
        }()
        if shouldBufferForTools {
            for await token in stream {
                fullResponse += token
                tokenCount += 1
            }
            if let toolCalls = ToolCallParser.parse(from: fullResponse) {
                // Emit OpenAI-style incremental tool_call deltas
                func sendChunk(_ chunk: ChatCompletionChunk) {
                    if let jsonData = try? JSONEncoder().encode(chunk), let jsonString = String(data: jsonData, encoding: .utf8) {
                        let sseData = "data: \(jsonString)\n\n"
                        loop.execute {
                            let context = ctxBox.value
                            guard context.channel.isActive else { return }
                            var buffer = context.channel.allocator.buffer(capacity: sseData.utf8.count)
                            buffer.writeString(sseData)
                            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                            context.flush()
                        }
                    }
                }

                // Initial role chunk
                sendChunk(ChatCompletionChunk(
                    id: responseId,
                    created: created,
                    model: requestModel,
                    choices: [StreamChoice(index: 0, delta: DeltaContent(role: "assistant", content: nil, tool_calls: nil), finish_reason: nil)],
                    system_fingerprint: nil
                ))

                let argChunkSize = 500
                for (idx, call) in toolCalls.enumerated() {
                    // Emit id/type for this tool call
                    sendChunk(ChatCompletionChunk(
                        id: responseId,
                        created: created,
                        model: requestModel,
                        choices: [StreamChoice(index: 0, delta: DeltaContent(role: nil, content: nil, tool_calls: [
                            DeltaToolCall(index: idx, id: call.id, type: call.type, function: nil)
                        ]), finish_reason: nil)],
                        system_fingerprint: nil
                    ))

                    // Emit function name
                    sendChunk(ChatCompletionChunk(
                        id: responseId,
                        created: created,
                        model: requestModel,
                        choices: [StreamChoice(index: 0, delta: DeltaContent(role: nil, content: nil, tool_calls: [
                            DeltaToolCall(index: idx, id: nil, type: nil, function: DeltaToolCallFunction(name: call.function.name, arguments: nil))
                        ]), finish_reason: nil)],
                        system_fingerprint: nil
                    ))

                    // Emit arguments in chunks
                    let args = call.function.arguments
                    var start = args.startIndex
                    while start < args.endIndex {
                        let end = args.index(start, offsetBy: argChunkSize, limitedBy: args.endIndex) ?? args.endIndex
                        let slice = String(args[start..<end])
                        sendChunk(ChatCompletionChunk(
                            id: responseId,
                            created: created,
                            model: requestModel,
                            choices: [StreamChoice(index: 0, delta: DeltaContent(role: nil, content: nil, tool_calls: [
                                DeltaToolCall(index: idx, id: nil, type: nil, function: DeltaToolCallFunction(name: nil, arguments: slice))
                            ]), finish_reason: nil)],
                            system_fingerprint: nil
                        ))
                        start = end
                    }
                }

                // Final chunk indicating end of tool_calls
                sendChunk(ChatCompletionChunk(
                    id: responseId,
                    created: created,
                    model: requestModel,
                    choices: [StreamChoice(index: 0, delta: DeltaContent(role: nil, content: nil, tool_calls: nil), finish_reason: "tool_calls")],
                    system_fingerprint: nil
                ))

                // Send [DONE] and close
                let done = "data: [DONE]\n\n"
                loop.execute {
                    let context = ctxBox.value
                    guard context.channel.isActive else { return }
                    var buffer = context.channel.allocator.buffer(capacity: done.utf8.count)
                    buffer.writeString(done)
                    context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                    context.flush()
                    context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
                        let context = ctxBox.value
                        context.close(promise: nil)
                    }
                }
                return
            } else {
                // Fallback: emit full content in one delta
                let chunk = ChatCompletionChunk(
                    id: responseId,
                    created: created,
                    model: requestModel,
                    choices: [StreamChoice(index: 0, delta: DeltaContent(role: "assistant", content: fullResponse, tool_calls: nil), finish_reason: nil)],
                    system_fingerprint: nil
                )
                if let jsonData = try? JSONEncoder().encode(chunk), let jsonString = String(data: jsonData, encoding: .utf8) {
                    let sseData = "data: \(jsonString)\n\n"
                    loop.execute {
                        let context = ctxBox.value
                        guard context.channel.isActive else { return }
                        var buffer = context.channel.allocator.buffer(capacity: sseData.utf8.count)
                        buffer.writeString(sseData)
                        context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                        context.flush()
                    }
                }
            }
        } else {
            // Stream tokens as content
            for await token in stream {
                fullResponse += token
                tokenCount += 1
                let chunk = ChatCompletionChunk(
                    id: responseId,
                    created: created,
                    model: requestModel,
                    choices: [
                        StreamChoice(
                            index: 0,
                            delta: DeltaContent(role: nil, content: token, tool_calls: nil),
                            finish_reason: nil
                        )
                    ],
                    system_fingerprint: nil
                )
                if let jsonData = try? JSONEncoder().encode(chunk),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    let sseData = "data: \(jsonString)\n\n"
                    loop.execute {
                        let context = ctxBox.value
                        guard context.channel.isActive else { return }
                        var buffer = context.channel.allocator.buffer(capacity: sseData.utf8.count)
                        buffer.writeString(sseData)
                        context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                        context.flush()
                    }
                }
            }
        }
        
        // Send final chunk (non-tool path). For tool_calls path we already returned above
        let finalChunk = ChatCompletionChunk(
            id: responseId,
            created: created,
            model: requestModel,
            choices: [
                StreamChoice(
                    index: 0,
                    delta: DeltaContent(role: nil, content: nil, tool_calls: nil),
                    finish_reason: "stop"
                )
            ],
            system_fingerprint: nil
        )
        
        if let jsonData = try? JSONEncoder().encode(finalChunk),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            let sseData = "data: \(jsonString)\n\n\ndata: [DONE]\n\n"
            loop.execute {
                let context = ctxBox.value
                guard context.channel.isActive else { return }
                var buffer = context.channel.allocator.buffer(capacity: sseData.utf8.count)
                buffer.writeString(sseData)
                context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                context.flush()
                context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
                    let context = ctxBox.value
                    context.close(promise: nil)
                }
            }
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
        context: ChannelHandlerContext
    ) async throws {
        // Generate complete response
        let stream = try await MLXService.shared.generate(
            messages: messages,
            model: model,
            temperature: temperature,
            maxTokens: maxTokens,
            tools: tools,
            toolChoice: toolChoice
        )
        
        var fullResponse = ""
        var tokenCount = 0
        
        for await token in stream {
            fullResponse += token
            tokenCount += 1
        }
        
        // Detect tool calls in model output
        let toolCalls = ToolCallParser.parse(from: fullResponse)
        let finishReason = (toolCalls != nil) ? "tool_calls" : "stop"

        // Create response
        let response = ChatCompletionResponse(
            id: "chatcmpl-\(UUID().uuidString.prefix(8))",
            created: Int(Date().timeIntervalSince1970),
            model: requestModel,
            choices: [
                ChatChoice(
                    index: 0,
                    message: ChatMessage(role: "assistant", content: toolCalls == nil ? fullResponse : "", tool_calls: toolCalls, tool_call_id: nil),
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
        
        try await sendJSONResponse(response, status: .ok, context: context)
    }

    // Tool Call Parsing moved to ToolCallParser
    
    private func sendJSONResponse<T: Encodable>(
        _ response: T,
        status: HTTPResponseStatus,
        context: ChannelHandlerContext
    ) async throws {
        let loop = context.eventLoop
        let ctxBox = UncheckedSendableBox(value: context)
        let jsonData = try JSONEncoder().encode(response)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
        
        // Send response on the event loop
        loop.execute {
            let context = ctxBox.value
            guard context.channel.isActive else { return }
            var responseHead = HTTPResponseHead(version: .http1_1, status: status)
            var buffer = context.channel.allocator.buffer(capacity: jsonString.utf8.count)
            buffer.writeString(jsonString)
            
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
            headers.add(name: "Content-Length", value: String(buffer.readableBytes))
            headers.add(name: "Connection", value: "close")
            responseHead.headers = headers
            
            context.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
                let context = ctxBox.value
                context.close(promise: nil)
            }
        }
    }
}
