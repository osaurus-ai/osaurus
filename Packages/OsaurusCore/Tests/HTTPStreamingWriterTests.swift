//
//  HTTPStreamingWriterTests.swift
//  osaurusTests
//

import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing

@testable import OsaurusCore

struct HTTPStreamingWriterTests {

    @Test func sse_writer_emits_done_and_headers() async throws {
        let channel = EmbeddedChannel()
        let writer = SSEResponseWriter()

        // Simulate writes
        let ctx = try channel.embeddedContext()
        writer.writeHeaders(ctx, extraHeaders: nil)
        writer.writeRole("assistant", model: "test-model", responseId: "id", created: 0, context: ctx)
        writer.writeContent("hi", model: "test-model", responseId: "id", created: 0, context: ctx)
        writer.writeFinish("test-model", responseId: "id", created: 0, context: ctx)
        writer.writeEnd(ctx)

        // Read head
        guard let headPart = try channel.readOutbound(as: HTTPServerResponsePart.self) else {
            #expect(Bool(false), "expected response head")
            return
        }
        if case .head(let head) = headPart {
            #expect(head.headers.contains(name: "Content-Type"))
            #expect((head.headers.first(name: "Content-Type") ?? "").contains("text/event-stream"))
        } else {
            #expect(Bool(false), "expected head part")
        }

        // Consume body parts until end; ensure [DONE] present
        var sawDone = false
        while let part = try channel.readOutbound(as: HTTPServerResponsePart.self) {
            switch part {
            case .body(let io):
                switch io {
                case .byteBuffer(var b):
                    if let s = b.readString(length: b.readableBytes) {
                        if s.contains("data: [DONE]") { sawDone = true }
                    }
                default:
                    break
                }
            case .end:
                break
            case .head:
                break
            }
        }
        #expect(sawDone)
    }

    @Test func ndjson_writer_emits_done_and_headers() async throws {
        let channel = EmbeddedChannel()
        let writer = NDJSONResponseWriter()

        let ctx = try channel.embeddedContext()
        writer.writeHeaders(ctx, extraHeaders: nil)
        writer.writeContent("hello", model: "test-model", responseId: "", created: 0, context: ctx)
        writer.writeFinish("test-model", responseId: "", created: 0, context: ctx)
        writer.writeEnd(ctx)

        guard let headPart = try channel.readOutbound(as: HTTPServerResponsePart.self) else {
            #expect(Bool(false), "expected response head")
            return
        }
        if case .head(let head) = headPart {
            #expect(head.headers.contains(name: "Content-Type"))
            #expect((head.headers.first(name: "Content-Type") ?? "").contains("application/x-ndjson"))
        } else {
            #expect(Bool(false), "expected head part")
        }

        var sawDone = false
        while let part = try channel.readOutbound(as: HTTPServerResponsePart.self) {
            switch part {
            case .body(let io):
                switch io {
                case .byteBuffer(var b):
                    if let s = b.readString(length: b.readableBytes) {
                        if s.contains("\"done\":true") || s.contains("\"done\": true") { sawDone = true }
                    }
                default:
                    break
                }
            case .end:
                break
            case .head:
                break
            }
        }
        #expect(sawDone)
    }
}

// Minimal helper to get a ChannelHandlerContext from EmbeddedChannel
extension EmbeddedChannel {
    @preconcurrency
    fileprivate func embeddedContext() throws -> ChannelHandlerContext {
        // EmbeddedChannel uses a single context for tests; the first handler context is sufficient
        return try self.pipeline.context(handlerType: NIOAsyncTestingHandler.self)
            .flatMapError { _ in
                // Install a dummy handler to obtain a context
                self.pipeline.addHandler(NIOAsyncTestingHandler()).flatMap {
                    self.pipeline.context(handlerType: NIOAsyncTestingHandler.self)
                }
            }
            .wait()
    }
}

// Dummy handler used only to fetch a context in tests
final class NIOAsyncTestingHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
}
