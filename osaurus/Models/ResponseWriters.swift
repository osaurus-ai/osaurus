//
//  ResponseWriters.swift  
//  osaurus
//
//  Created by Robin on 8/29/25.
//

import Foundation
import NIOCore
import NIOHTTP1
import IkigaJSON

protocol ResponseWriter {
    func writeHeaders(_ context: ChannelHandlerContext)
    func writeRole(_ role: String, model: String, responseId: String, created: Int, context: ChannelHandlerContext)
    func writeContent(_ content: String, model: String, responseId: String, created: Int, context: ChannelHandlerContext) 
    func writeFinish(_ model: String, responseId: String, created: Int, context: ChannelHandlerContext)
    func writeEnd(_ context: ChannelHandlerContext)
}

final class SSEResponseWriter: ResponseWriter {
    
    func writeHeaders(_ context: ChannelHandlerContext) {
        var head = HTTPResponseHead(version: .http1_1, status: .ok)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache, no-transform")  
        headers.add(name: "Connection", value: "keep-alive")
        headers.add(name: "X-Accel-Buffering", value: "no")
        headers.add(name: "Transfer-Encoding", value: "chunked")
        head.headers = headers
        context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        context.flush()
    }
    
    @inline(__always)
    func writeRole(_ role: String, model: String, responseId: String, created: Int, context: ChannelHandlerContext) {
        let chunk = ChatCompletionChunk(
            id: responseId,
            created: created,
            model: model,
            choices: [StreamChoice(
                index: 0, 
                delta: DeltaContent(role: role, content: ""),   
                finish_reason: nil
            )],
            system_fingerprint: nil
        )
        writeSSEChunk(chunk, context: context)
    }
    
    @inline(__always)
    func writeContent(_ content: String, model: String, responseId: String, created: Int, context: ChannelHandlerContext) {
        guard !content.isEmpty else { return }
        let chunk = ChatCompletionChunk(
            id: responseId,
            created: created,
            model: model,
            choices: [StreamChoice(
                index: 0, 
                delta: DeltaContent(content: content), 
                finish_reason: nil
            )],
            system_fingerprint: nil
        )
        writeSSEChunk(chunk, context: context)
    }
    
    @inline(__always)
    func writeFinish(_ model: String, responseId: String, created: Int, context: ChannelHandlerContext) {
        let chunk = ChatCompletionChunk(
            id: responseId,
            created: created,
            model: model,
            choices: [StreamChoice(
                index: 0, 
                delta: DeltaContent(), 
                finish_reason: "stop"
            )],
            system_fingerprint: nil
        )
        writeSSEChunk(chunk, context: context)
    }
    
    @inline(__always)
    private func writeSSEChunk(_ chunk: ChatCompletionChunk, context: ChannelHandlerContext) {
        let encoder = IkigaJSONEncoder() // Create encoder per write for thread safety
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
    
    func writeEnd(_ context: ChannelHandlerContext) {
        var tail = context.channel.allocator.buffer(capacity: 16)
        tail.writeString("data: [DONE]\n\n")
        context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(tail))), promise: nil)
        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}

final class NDJSONResponseWriter: ResponseWriter {
    func writeHeaders(_ context: ChannelHandlerContext) {
        var head = HTTPResponseHead(version: .http1_1, status: .ok)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/x-ndjson")
        headers.add(name: "Cache-Control", value: "no-cache, no-transform")
        headers.add(name: "Connection", value: "keep-alive")
        headers.add(name: "Transfer-Encoding", value: "chunked")
        head.headers = headers
        context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        context.flush()
    }
    
    func writeRole(_ role: String, model: String, responseId: String, created: Int, context: ChannelHandlerContext) {
        // NDJSON doesn't send separate role chunks - they're combined with content
    }
    
    @inline(__always)
    func writeContent(_ content: String, model: String, responseId: String, created: Int, context: ChannelHandlerContext) {
        guard !content.isEmpty else { return }
        writeNDJSONMessage(content, model: model, done: false, context: context)
    }
    
    @inline(__always) 
    func writeFinish(_ model: String, responseId: String, created: Int, context: ChannelHandlerContext) {
        writeNDJSONMessage("", model: model, done: true, context: context)
    }
    
    @inline(__always)
    private func writeNDJSONMessage(_ content: String, model: String, done: Bool, context: ChannelHandlerContext) {
        let response: [String: Any] = [
            "model": model,
            "created_at": Date().ISO8601Format(),
            "message": [
                "role": "assistant",
                "content": content
            ],
            "done": done
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
        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}
