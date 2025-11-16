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
