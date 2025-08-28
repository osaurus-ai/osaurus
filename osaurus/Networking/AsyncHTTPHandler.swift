//
//  AsyncHTTPHandler.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation
import Dispatch
import NIOCore
import NIOHTTP1
import IkigaJSON
import MLXLMCommon

private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

/// Handles async operations for HTTP endpoints
class AsyncHTTPHandler {
    static let shared = AsyncHTTPHandler()
    
    // JSON encoder is created per write to avoid cross-request contention
    
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
            
            // Honor only request-provided stop sequences; otherwise rely on library EOS handling
            let effectiveStops: [String] = request.stop ?? []

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
                    sessionId: request.session_id,
                    stopSequences: effectiveStops,
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
        sessionId: String?,
        stopSequences: [String],
        context: ChannelHandlerContext
    ) async throws {
        let loop = context.eventLoop
        let ctxBox = UncheckedSendableBox(value: context)
        
        // Use pre-built SSE headers for better performance
        var responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        var nioHeaders = HTTPHeaders()
        nioHeaders.add(name: "Content-Type", value: "text/event-stream")
        nioHeaders.add(name: "Cache-Control", value: "no-cache, no-transform")
        nioHeaders.add(name: "Connection", value: "keep-alive")
        nioHeaders.add(name: "X-Accel-Buffering", value: "no")
        nioHeaders.add(name: "Transfer-Encoding", value: "chunked")
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
            let roleChunk = ChatCompletionChunk(
                id: responseId,
                created: created,
                model: requestModel,
                choices: [StreamChoice(index: 0, delta: DeltaContent(role: "assistant", content: nil, tool_calls: nil), finish_reason: nil)],
                system_fingerprint: nil
            )
            @inline(__always)
            func writeSSE<T: Encodable>(_ value: T, flush: Bool = true) {
                loop.execute {
                    let context = ctxBox.value
                    guard context.channel.isActive else { return }
                    let encoder = IkigaJSONEncoder()
                    var buffer = context.channel.allocator.buffer(capacity: 256)
                    buffer.writeString("data: ")
                    do { try encoder.encodeAndWrite(value, into: &buffer) } catch {}
                    buffer.writeString("\n\n")
                    context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                    if flush { context.flush() }
                }
            }
            @inline(__always)
            func writeSSEString(_ s: String, flush: Bool = true) {
                loop.execute {
                    let context = ctxBox.value
                    guard context.channel.isActive else { return }
                    var buffer = context.channel.allocator.buffer(capacity: s.utf8.count)
                    buffer.writeString(s)
                    context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                    if flush { context.flush() }
                }
            }
            writeSSE(roleChunk)
            
            // Stream tokens while collecting them for tool detection (bounded window)
            // Detection window: cap accumulation to reduce joins and scans
            let detectWindowBytesLimit: Int = {
                let env = ProcessInfo.processInfo.environment
                return Int(env["OSU_TOOL_DETECT_WINDOW_BYTES"] ?? "") ?? 4096
            }()
            var accumulatedBytes: Int = 0
            // MLX stream already separates tool calls; emit text chunks immediately and buffer for summary
            for await event in eventStream {
                if let chunk = event.chunk {
                    responseBuffer.append(chunk)
                    accumulatedBytes += chunk.utf8.count
                    tokenCount += 1
                    if !chunk.isEmpty {
                        let contentChunk = ChatCompletionChunk(
                            id: responseId,
                            created: created,
                            model: requestModel,
                            choices: [StreamChoice(index: 0, delta: DeltaContent(role: nil, content: chunk, tool_calls: nil), finish_reason: nil)],
                            system_fingerprint: nil
                        )
                        writeSSE(contentChunk)
                    }
                }
                if let toolCall = event.toolCall {
                    // Emit OpenAI-style tool_call deltas based on MLX ToolCall
                    // Here we emit a single tool call per event (index 0)
                    let mlxName = toolCall.function.name
                    let argsObject = toolCall.function.arguments
                    // Encode arguments dictionary back to JSON string per OpenAI spec
                    let argsData = try? JSONSerialization.data(withJSONObject: argsObject.mapValues { $0.anyValue })
                    let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

                    // Construct a synthetic id to satisfy OpenAI delta contract
                    let callId = "call_\(UUID().uuidString.prefix(8))"

                    // id/type
                    writeSSE(ChatCompletionChunk(
                        id: responseId,
                        created: created,
                        model: requestModel,
                        choices: [StreamChoice(index: 0, delta: DeltaContent(role: nil, content: nil, tool_calls: [
                            DeltaToolCall(index: 0, id: callId, type: "function", function: nil)
                        ]), finish_reason: nil)],
                        system_fingerprint: nil
                    ))
                    // name
                    writeSSE(ChatCompletionChunk(
                        id: responseId,
                        created: created,
                        model: requestModel,
                        choices: [StreamChoice(index: 0, delta: DeltaContent(role: nil, content: nil, tool_calls: [
                            DeltaToolCall(index: 0, id: nil, type: nil, function: DeltaToolCallFunction(name: mlxName, arguments: nil))
                        ]), finish_reason: nil)],
                        system_fingerprint: nil
                    ))
                    // args
                    let argChunkSize = 500
                    var start = argsString.startIndex
                    while start < argsString.endIndex {
                        let end = argsString.index(start, offsetBy: argChunkSize, limitedBy: argsString.endIndex) ?? argsString.endIndex
                        let slice = String(argsString[start..<end])
                        writeSSE(ChatCompletionChunk(
                            id: responseId,
                            created: created,
                            model: requestModel,
                            choices: [StreamChoice(index: 0, delta: DeltaContent(role: nil, content: nil, tool_calls: [
                                DeltaToolCall(index: 0, id: nil, type: nil, function: DeltaToolCallFunction(name: nil, arguments: slice))
                            ]), finish_reason: nil)],
                            system_fingerprint: nil
                        ))
                        start = end
                    }

                    // Terminate tool_calls stream and close
                    writeSSE(ChatCompletionChunk(
                        id: responseId,
                        created: created,
                        model: requestModel,
                        choices: [StreamChoice(index: 0, delta: DeltaContent(role: nil, content: nil, tool_calls: nil), finish_reason: "tool_calls")],
                        system_fingerprint: nil
                    ))
                    writeSSEString("data: [DONE]\n\n")
                    loop.execute {
                        let context = ctxBox.value
                        guard context.channel.isActive else { return }
                        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
                            let context = ctxBox.value
                            context.close(promise: nil)
                        }
                    }
                    return
                }
            }
            
            fullResponse = responseBuffer.joined()
        } else {
            // Stream tokens as JSON-encoded SSE chunks with batching and stop detection
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

            // Batching state
            var firstTokenSent = false
            var pendingContent = ""
            var lastFlushNs: UInt64 = DispatchTime.now().uptimeNanoseconds

            // Queue writes on the event loop at a fixed cadence to reduce cross-thread hops
            var scheduledFlush: Bool = false
            @inline(__always)
            func scheduleFlushIfNeeded() {
                if scheduledFlush { return }
                scheduledFlush = true
                let deadline = NIODeadline.now() + .milliseconds(Int64(batchIntervalMs))
                loop.scheduleTask(deadline: deadline) {
                    scheduledFlush = false
                    guard !pendingContent.isEmpty else { return }
                    sendContentDelta(pendingContent, flushNow: true)
                    pendingContent.removeAll(keepingCapacity: true)
                    lastFlushNs = DispatchTime.now().uptimeNanoseconds
                }
            }

            @inline(__always)
            func sendChunk(_ delta: DeltaContent, finishReason: String? = nil, flushNow: Bool) {
                let chunk = ChatCompletionChunk(
                    id: responseId,
                    created: created,
                    model: requestModel,
                    choices: [StreamChoice(index: 0, delta: delta, finish_reason: finishReason)],
                    system_fingerprint: nil
                )
                let encoder = IkigaJSONEncoder()
                loop.execute {
                    let context = ctxBox.value
                    guard context.channel.isActive else { return }
                    var buffer = context.channel.allocator.buffer(capacity: 256)
                    buffer.writeString("data: ")
                    do { try encoder.encodeAndWrite(chunk, into: &buffer) } catch {}
                    buffer.writeString("\n\n")
                    context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                    if flushNow { context.flush() }
                }
            }

            // Send role prelude as soon as headers are written to decrease TTFT
            @inline(__always)
            func sendRolePrelude() {
                sendChunk(DeltaContent(role: "assistant", content: nil, tool_calls: nil), flushNow: true)
            }

            @inline(__always)
            func sendContentDelta(_ content: String, flushNow: Bool) {
                guard !content.isEmpty else { return }
                sendChunk(DeltaContent(role: nil, content: content, tool_calls: nil), flushNow: flushNow)
            }

            // Immediately send role prelude before first model token (helps TTFT)
            sendRolePrelude()
            for await event in eventStream {
                guard let token = event.chunk else { continue }
                if shouldCheckStop {
                    stopTail += token
                    if stopTail.count > maxStopLen {
                        let overflow = stopTail.count - maxStopLen
                        stopTail.removeFirst(overflow)
                    }
                    if stopSequences.first(where: { stopTail.contains($0) }) != nil {
                        if !pendingContent.isEmpty {
                            sendContentDelta(pendingContent, flushNow: true)
                            pendingContent.removeAll(keepingCapacity: true)
                        }
                        break
                    }
                }

                if !firstTokenSent {
                    sendContentDelta(token, flushNow: true)
                    firstTokenSent = true
                    lastFlushNs = DispatchTime.now().uptimeNanoseconds
                    continue
                }

                pendingContent += token
                let nowNs = DispatchTime.now().uptimeNanoseconds
                if pendingContent.count >= batchCharThreshold || nowNs - lastFlushNs >= flushIntervalNs {
                    sendContentDelta(pendingContent, flushNow: true)
                    pendingContent.removeAll(keepingCapacity: true)
                    lastFlushNs = nowNs
                } else {
                    scheduleFlushIfNeeded()
                }
            }

            if !pendingContent.isEmpty {
                sendContentDelta(pendingContent, flushNow: true)
                pendingContent.removeAll(keepingCapacity: true)
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
        
        @inline(__always)
        func writeSSEFinal<T: Encodable>(_ value: T) {
            loop.execute {
                let context = ctxBox.value
                guard context.channel.isActive else { return }
                let encoder = IkigaJSONEncoder()
                var buffer = context.channel.allocator.buffer(capacity: 256)
                buffer.writeString("data: ")
                do { try encoder.encodeAndWrite(value, into: &buffer) } catch {}
                buffer.writeString("\n\n")
                context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                var tail = context.channel.allocator.buffer(capacity: 16)
                tail.writeString("data: [DONE]\n\n")
                context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(tail))), promise: nil)
                context.flush()
                context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
                    let context = ctxBox.value
                    context.close(promise: nil)
                }
            }
        }
        writeSSEFinal(finalChunk)
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
        context: ChannelHandlerContext
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
                let argsData = try? JSONSerialization.data(withJSONObject: toolCall.function.arguments.mapValues { $0.anyValue })
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
                            message: ChatMessage(role: "assistant", content: "", tool_calls: [tc], tool_call_id: nil),
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
                try await sendJSONResponse(response, status: .ok, context: context)
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
        // Since we route tool calls immediately above, remaining path is normal text completion
        let toolCalls: [ToolCall]? = nil
        let finishReason = "stop"

        // Create response
        let response = ChatCompletionResponse(
            id: "chatcmpl-\(UUID().uuidString.prefix(8))",
            created: Int(Date().timeIntervalSince1970),
            model: requestModel,
            choices: [
                ChatChoice(
                    index: 0,
                    message: ChatMessage(role: "assistant", content: fullResponse, tool_calls: nil, tool_call_id: nil),
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
            responseHead.headers = headers
            context.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
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
