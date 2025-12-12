//
//  ResponseWriters.swift
//  osaurus
//
//  Created by Robin on 8/29/25.
//

import Foundation
import IkigaJSON
import NIOCore
import NIOHTTP1

protocol ResponseWriter {
    func writeHeaders(_ context: ChannelHandlerContext, extraHeaders: [(String, String)]?)
    func writeRole(
        _ role: String,
        model: String,
        responseId: String,
        created: Int,
        context: ChannelHandlerContext
    )
    func writeContent(
        _ content: String,
        model: String,
        responseId: String,
        created: Int,
        context: ChannelHandlerContext
    )
    func writeFinish(
        _ model: String,
        responseId: String,
        created: Int,
        context: ChannelHandlerContext
    )
    /// Emit an error payload over the current streaming format and flush
    func writeError(_ message: String, context: ChannelHandlerContext)
    func writeEnd(_ context: ChannelHandlerContext)
}

final class SSEResponseWriter: ResponseWriter {

    func writeHeaders(_ context: ChannelHandlerContext, extraHeaders: [(String, String)]? = nil) {
        var head = HTTPResponseHead(version: .http1_1, status: .ok)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache, no-transform")
        headers.add(name: "Connection", value: "keep-alive")
        headers.add(name: "X-Accel-Buffering", value: "no")
        headers.add(name: "Transfer-Encoding", value: "chunked")
        if let extraHeaders {
            for (n, v) in extraHeaders { headers.add(name: n, value: v) }
        }
        head.headers = headers
        context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        context.flush()
    }

    @inline(__always)
    func writeRole(
        _ role: String,
        model: String,
        responseId: String,
        created: Int,
        context: ChannelHandlerContext
    ) {
        let chunk = ChatCompletionChunk(
            id: responseId,
            created: created,
            model: model,
            choices: [
                StreamChoice(
                    index: 0,
                    delta: DeltaContent(role: role, content: ""),
                    finish_reason: nil
                )
            ],
            system_fingerprint: nil
        )
        writeSSEChunk(chunk, context: context)
    }

    @inline(__always)
    func writeContent(
        _ content: String,
        model: String,
        responseId: String,
        created: Int,
        context: ChannelHandlerContext
    ) {
        guard !content.isEmpty else { return }
        let chunk = ChatCompletionChunk(
            id: responseId,
            created: created,
            model: model,
            choices: [
                StreamChoice(
                    index: 0,
                    delta: DeltaContent(content: content),
                    finish_reason: nil
                )
            ],
            system_fingerprint: nil
        )
        writeSSEChunk(chunk, context: context)
    }

    @inline(__always)
    func writeFinish(
        _ model: String,
        responseId: String,
        created: Int,
        context: ChannelHandlerContext
    ) {
        let chunk = ChatCompletionChunk(
            id: responseId,
            created: created,
            model: model,
            choices: [
                StreamChoice(
                    index: 0,
                    delta: DeltaContent(),
                    finish_reason: "stop"
                )
            ],
            system_fingerprint: nil
        )
        writeSSEChunk(chunk, context: context)
    }

    // MARK: - Tool calling (OpenAI-style streaming deltas)

    @inline(__always)
    func writeToolCallStart(
        callId: String,
        functionName: String,
        index: Int = 0,
        model: String,
        responseId: String,
        created: Int,
        context: ChannelHandlerContext
    ) {
        let delta = DeltaContent(
            role: nil,
            content: nil,
            refusal: nil,
            tool_calls: [
                DeltaToolCall(
                    index: index,
                    id: callId,
                    type: "function",
                    function: DeltaToolCallFunction(name: functionName, arguments: nil)
                )
            ]
        )
        let chunk = ChatCompletionChunk(
            id: responseId,
            created: created,
            model: model,
            choices: [StreamChoice(index: 0, delta: delta, finish_reason: nil)],
            system_fingerprint: nil
        )
        writeSSEChunk(chunk, context: context)
    }

    @inline(__always)
    func writeToolCallArgumentsDelta(
        callId: String,
        index: Int,
        argumentsChunk: String,
        model: String,
        responseId: String,
        created: Int,
        context: ChannelHandlerContext
    ) {
        guard !argumentsChunk.isEmpty else { return }
        let delta = DeltaContent(
            role: nil,
            content: nil,
            refusal: nil,
            tool_calls: [
                DeltaToolCall(
                    index: index,
                    id: nil,
                    type: nil,
                    function: DeltaToolCallFunction(name: nil, arguments: argumentsChunk)
                )
            ]
        )
        let chunk = ChatCompletionChunk(
            id: responseId,
            created: created,
            model: model,
            choices: [StreamChoice(index: 0, delta: delta, finish_reason: nil)],
            system_fingerprint: nil
        )
        writeSSEChunk(chunk, context: context)
    }

    @inline(__always)
    func writeFinishWithReason(
        _ reason: String,
        model: String,
        responseId: String,
        created: Int,
        context: ChannelHandlerContext
    ) {
        let chunk = ChatCompletionChunk(
            id: responseId,
            created: created,
            model: model,
            choices: [
                StreamChoice(index: 0, delta: DeltaContent(), finish_reason: reason)
            ],
            system_fingerprint: nil
        )
        writeSSEChunk(chunk, context: context)
    }

    @inline(__always)
    private func writeSSEChunk(_ chunk: ChatCompletionChunk, context: ChannelHandlerContext) {
        let encoder = IkigaJSONEncoder()  // Create encoder per write for thread safety
        var buffer = context.channel.allocator.buffer(capacity: 256)
        buffer.writeString("data: ")
        do {
            try encoder.encodeAndWrite(chunk, into: &buffer)
            buffer.writeString("\n\n")
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            context.flush()
        } catch {
            // Log encoding error and close connection gracefully
            print("Error encoding SSE chunk: \(error)")
            context.close(promise: nil)
        }
    }

    func writeError(_ message: String, context: ChannelHandlerContext) {
        let encoder = IkigaJSONEncoder()
        var buffer = context.channel.allocator.buffer(capacity: 256)
        buffer.writeString("data: ")
        do {
            let err = OpenAIError(
                error: OpenAIError.ErrorDetail(
                    message: message,
                    type: "internal_error",
                    param: nil,
                    code: nil
                )
            )
            try encoder.encodeAndWrite(err, into: &buffer)
            buffer.writeString("\n\n")
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            context.flush()
        } catch {
            // As a last resort, send a minimal JSON error payload
            buffer.clear()
            buffer.writeString("data: {\"error\":{\"message\":\"")
            buffer.writeString(message)
            buffer.writeString("\",\"type\":\"internal_error\"}}\n\n")
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            context.flush()
        }
    }

    func writeEnd(_ context: ChannelHandlerContext) {
        var tail = context.channel.allocator.buffer(capacity: 16)
        tail.writeString("data: [DONE]\n\n")
        context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(tail))), promise: nil)
        let ctx = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete {
            _ in
            ctx.value.close(promise: nil)
        }
    }
}

final class NDJSONResponseWriter: ResponseWriter {
    func writeHeaders(_ context: ChannelHandlerContext, extraHeaders: [(String, String)]? = nil) {
        var head = HTTPResponseHead(version: .http1_1, status: .ok)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/x-ndjson")
        headers.add(name: "Cache-Control", value: "no-cache, no-transform")
        headers.add(name: "Connection", value: "keep-alive")
        headers.add(name: "Transfer-Encoding", value: "chunked")
        if let extraHeaders {
            for (n, v) in extraHeaders { headers.add(name: n, value: v) }
        }
        head.headers = headers
        context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        context.flush()
    }

    func writeRole(
        _ role: String,
        model: String,
        responseId: String,
        created: Int,
        context: ChannelHandlerContext
    ) {
        // NDJSON doesn't send separate role chunks - they're combined with content
    }

    @inline(__always)
    func writeContent(
        _ content: String,
        model: String,
        responseId: String,
        created: Int,
        context: ChannelHandlerContext
    ) {
        guard !content.isEmpty else { return }
        writeNDJSONMessage(content, model: model, done: false, context: context)
    }

    @inline(__always)
    func writeFinish(
        _ model: String,
        responseId: String,
        created: Int,
        context: ChannelHandlerContext
    ) {
        writeNDJSONMessage("", model: model, done: true, context: context)
    }

    @inline(__always)
    private func writeNDJSONMessage(
        _ content: String,
        model: String,
        done: Bool,
        context: ChannelHandlerContext
    ) {
        let response: [String: Any] = [
            "model": model,
            "created_at": Date().ISO8601Format(),
            "message": [
                "role": "assistant",
                "content": content,
            ],
            "done": done,
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: response) {
            var buffer = context.channel.allocator.buffer(capacity: 256)
            buffer.writeBytes(jsonData)
            buffer.writeString("\n")
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            context.flush()
        }
    }

    func writeError(_ message: String, context: ChannelHandlerContext) {
        let response: [String: Any] = [
            "error": [
                "message": message,
                "type": "internal_error",
            ],
            "done": true,
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: response) {
            var buffer = context.channel.allocator.buffer(capacity: 256)
            buffer.writeBytes(jsonData)
            buffer.writeString("\n")
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            context.flush()
        }
    }

    func writeEnd(_ context: ChannelHandlerContext) {
        let ctx = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete {
            _ in
            ctx.value.close(promise: nil)
        }
    }
}

// MARK: - Anthropic SSE Response Writer

/// SSE Response Writer for Anthropic Messages API format
/// Emits events: message_start, content_block_start, content_block_delta, content_block_stop, message_delta, message_stop
final class AnthropicSSEResponseWriter {
    private var messageId: String = ""
    private var model: String = ""
    private var inputTokens: Int = 0
    private var outputTokens: Int = 0
    private var currentBlockIndex: Int = 0
    private var hasStartedTextBlock: Bool = false

    func writeHeaders(_ context: ChannelHandlerContext, extraHeaders: [(String, String)]? = nil) {
        var head = HTTPResponseHead(version: .http1_1, status: .ok)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache, no-transform")
        headers.add(name: "Connection", value: "keep-alive")
        headers.add(name: "X-Accel-Buffering", value: "no")
        headers.add(name: "Transfer-Encoding", value: "chunked")
        if let extraHeaders {
            for (n, v) in extraHeaders { headers.add(name: n, value: v) }
        }
        head.headers = headers
        context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        context.flush()
    }

    /// Write message_start event
    func writeMessageStart(
        messageId: String,
        model: String,
        inputTokens: Int,
        context: ChannelHandlerContext
    ) {
        self.messageId = messageId
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = 0
        self.currentBlockIndex = 0
        self.hasStartedTextBlock = false

        let event = MessageStartEvent(id: messageId, model: model, inputTokens: inputTokens)
        writeSSEEvent("message_start", payload: event, context: context)
    }

    /// Write content_block_start for a text block
    func writeTextBlockStart(context: ChannelHandlerContext) {
        guard !hasStartedTextBlock else { return }
        hasStartedTextBlock = true

        let event = ContentBlockStartEvent(index: currentBlockIndex, textBlock: true)
        writeSSEEvent("content_block_start", payload: event, context: context)
    }

    /// Write content_block_delta with text
    @inline(__always)
    func writeTextDelta(_ text: String, context: ChannelHandlerContext) {
        guard !text.isEmpty else { return }

        // Start text block if not already started
        if !hasStartedTextBlock {
            writeTextBlockStart(context: context)
        }

        // Estimate output tokens (rough: 1 token per 4 chars)
        outputTokens += max(1, text.count / 4)

        let event = ContentBlockDeltaEvent(index: currentBlockIndex, text: text)
        writeSSEEvent("content_block_delta", payload: event, context: context)
    }

    /// Write content_block_stop for current block
    func writeBlockStop(context: ChannelHandlerContext) {
        let event = ContentBlockStopEvent(index: currentBlockIndex)
        writeSSEEvent("content_block_stop", payload: event, context: context)
        currentBlockIndex += 1
        hasStartedTextBlock = false
    }

    /// Write tool_use block start
    func writeToolUseBlockStart(
        toolId: String,
        toolName: String,
        context: ChannelHandlerContext
    ) {
        // Close text block if open
        if hasStartedTextBlock {
            writeBlockStop(context: context)
        }

        let event = ContentBlockStartEvent(index: currentBlockIndex, toolId: toolId, toolName: toolName)
        writeSSEEvent("content_block_start", payload: event, context: context)
    }

    /// Write tool_use input_json_delta
    @inline(__always)
    func writeToolInputDelta(_ partialJson: String, context: ChannelHandlerContext) {
        guard !partialJson.isEmpty else { return }

        let event = ContentBlockDeltaEvent(index: currentBlockIndex, partialJson: partialJson)
        writeSSEEvent("content_block_delta", payload: event, context: context)
    }

    /// Write message_delta with stop_reason
    func writeMessageDelta(stopReason: String, context: ChannelHandlerContext) {
        let event = MessageDeltaEvent(stopReason: stopReason, outputTokens: outputTokens)
        writeSSEEvent("message_delta", payload: event, context: context)
    }

    /// Write message_stop event
    func writeMessageStop(context: ChannelHandlerContext) {
        let event = MessageStopEvent()
        writeSSEEvent("message_stop", payload: event, context: context)
    }

    /// Write error event
    func writeError(_ message: String, context: ChannelHandlerContext) {
        let error = AnthropicError(message: message, errorType: "api_error")
        let encoder = IkigaJSONEncoder()
        var buffer = context.channel.allocator.buffer(capacity: 256)
        buffer.writeString("event: error\ndata: ")
        do {
            try encoder.encodeAndWrite(error, into: &buffer)
            buffer.writeString("\n\n")
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            context.flush()
        } catch {
            buffer.clear()
            buffer.writeString(
                "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\""
            )
            buffer.writeString(message)
            buffer.writeString("\"}}\n\n")
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            context.flush()
        }
    }

    /// Complete the stream with stop reason and close connection
    func writeFinish(stopReason: String, context: ChannelHandlerContext) {
        // Close any open text block
        if hasStartedTextBlock {
            writeBlockStop(context: context)
        }

        // Write message_delta with stop reason
        writeMessageDelta(stopReason: stopReason, context: context)

        // Write message_stop
        writeMessageStop(context: context)
    }

    /// Close the connection
    func writeEnd(_ context: ChannelHandlerContext) {
        let ctx = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete {
            _ in
            ctx.value.close(promise: nil)
        }
    }

    // MARK: - Private Helpers

    @inline(__always)
    private func writeSSEEvent<T: Encodable>(_ eventType: String, payload: T, context: ChannelHandlerContext) {
        let encoder = IkigaJSONEncoder()
        var buffer = context.channel.allocator.buffer(capacity: 256)
        buffer.writeString("event: ")
        buffer.writeString(eventType)
        buffer.writeString("\ndata: ")
        do {
            try encoder.encodeAndWrite(payload, into: &buffer)
            buffer.writeString("\n\n")
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            context.flush()
        } catch {
            print("Error encoding Anthropic SSE event: \(error)")
            context.close(promise: nil)
        }
    }
}
