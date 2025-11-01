//
//  HTTPStreamingWriterTests.swift
//  osaurusTests
//

import Foundation
import NIOCore
import NIOHTTP1
import Testing

@testable import osaurus

struct HTTPStreamingWriterTests {

  @Test func sse_writer_emits_done_and_headers() async throws {
    let channel = EmbeddedChannel()
    let writer = SSEResponseWriter()

    // Simulate writes
    writer.writeHeaders(channel.embeddedContext(), extraHeaders: nil)
    writer.writeRole("assistant", model: "test-model", responseId: "id", created: 0, context: channel.embeddedContext())
    writer.writeContent("hi", model: "test-model", responseId: "id", created: 0, context: channel.embeddedContext())
    writer.writeFinish("test-model", responseId: "id", created: 0, context: channel.embeddedContext())
    writer.writeEnd(channel.embeddedContext())

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
      case .body(let buf):
        var b = buf
        if let s = b.readString(length: b.readableBytes) {
          if s.contains("data: [DONE]") { sawDone = true }
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

    writer.writeHeaders(channel.embeddedContext(), extraHeaders: nil)
    writer.writeContent("hello", model: "test-model", responseId: "", created: 0, context: channel.embeddedContext())
    writer.writeFinish("test-model", responseId: "", created: 0, context: channel.embeddedContext())
    writer.writeEnd(channel.embeddedContext())

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
      case .body(let buf):
        var b = buf
        if let s = b.readString(length: b.readableBytes) {
          if s.contains("\"done\": true") { sawDone = true }
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
private extension EmbeddedChannel {
  func embeddedContext() -> ChannelHandlerContext {
    // EmbeddedChannel uses a single context for tests; the first handler context is sufficient
    return self.pipeline.context(handlerType: NIOAsyncTestingHandler.self)
      .recover { _ in
        // Install a dummy handler to obtain a context
        self.pipeline.addHandler(NIOAsyncTestingHandler()).flatMap {
          self.pipeline.context(handlerType: NIOAsyncTestingHandler.self)
        }
      }
      .map { $0 }
      .wait()
  }
}

// Dummy handler used only to fetch a context in tests
final class NIOAsyncTestingHandler: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
}


