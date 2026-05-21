//
//  HTTPStreamingWriterTests.swift
//  osaurusTests
//

import Foundation
@preconcurrency import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing

@testable import OsaurusCore

struct HTTPStreamingWriterTests {

    @Test func stream_delta_coalescer_respects_runtime_interval_and_flushes_tail() {
        var coalescer = HTTPHandler.StreamDeltaCoalescer(interval: 3)

        #expect(coalescer.append("a") == nil)
        #expect(coalescer.append("b") == nil)
        #expect(coalescer.append("c") == "abc")
        #expect(coalescer.append("d") == nil)
        #expect(coalescer.flush() == "d")
        #expect(coalescer.flush() == nil)
    }

    @Test func stream_delta_coalescer_preserves_legacy_per_delta_streaming_for_interval_one() {
        var coalescer = HTTPHandler.StreamDeltaCoalescer(interval: 1)

        #expect(coalescer.append("a") == "a")
        #expect(coalescer.append("b") == "b")
        #expect(coalescer.flush() == nil)
    }

    @Test func sse_writer_emits_done_and_headers() async throws {
        let channel = EmbeddedChannel()
        let writer = SSEResponseWriter()

        // Simulate writes
        let ctx = try channel.embeddedContext()
        writer.writeHeaders(ctx, extraHeaders: nil)
        writer.writeRole("assistant", model: "test-model", responseId: "id", created: 0, prefixHash: nil, context: ctx)
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
private struct CtxBox: @unchecked Sendable {
    let ctx: ChannelHandlerContext
}

extension EmbeddedChannel {
    fileprivate func embeddedContext() throws -> ChannelHandlerContext {
        do {
            return try self.pipeline.context(handlerType: NIOAsyncTestingHandler.self).map { CtxBox(ctx: $0) }.wait()
                .ctx
        } catch {
            try self.pipeline.addHandler(NIOAsyncTestingHandler()).wait()
            return try self.pipeline.context(handlerType: NIOAsyncTestingHandler.self).map { CtxBox(ctx: $0) }.wait()
                .ctx
        }
    }
}

// Dummy handler used only to fetch a context in tests
final class NIOAsyncTestingHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
}
