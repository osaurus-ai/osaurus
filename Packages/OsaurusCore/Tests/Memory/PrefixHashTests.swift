//
//  PrefixHashTests.swift
//  osaurusTests
//

import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing

@testable import OsaurusCore

private struct CtxBox: @unchecked Sendable {
    let ctx: ChannelHandlerContext
}

private extension EmbeddedChannel {
    func testContext() throws -> ChannelHandlerContext {
        do {
            return try self.pipeline.context(handlerType: TestContextHandler.self).map { CtxBox(ctx: $0) }.wait().ctx
        } catch {
            try self.pipeline.addHandler(TestContextHandler()).wait()
            return try self.pipeline.context(handlerType: TestContextHandler.self).map { CtxBox(ctx: $0) }.wait().ctx
        }
    }
}

private final class TestContextHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
}

struct PrefixHashTests {

    // MARK: - computePrefixHash

    @Test func hashIsDeterministic() {
        let h1 = ModelRuntime.computePrefixHash(systemContent: "You are helpful.", toolNames: ["search"])
        let h2 = ModelRuntime.computePrefixHash(systemContent: "You are helpful.", toolNames: ["search"])
        #expect(h1 == h2)
    }

    @Test func toolOrderDoesNotMatter() {
        let h1 = ModelRuntime.computePrefixHash(systemContent: "sys", toolNames: ["alpha", "beta", "gamma"])
        let h2 = ModelRuntime.computePrefixHash(systemContent: "sys", toolNames: ["gamma", "alpha", "beta"])
        #expect(h1 == h2)
    }

    @Test func differentContentProducesDifferentHash() {
        let h1 = ModelRuntime.computePrefixHash(systemContent: "You are helpful.", toolNames: [])
        let h2 = ModelRuntime.computePrefixHash(systemContent: "You are a pirate.", toolNames: [])
        #expect(h1 != h2)
    }

    @Test func differentToolsProduceDifferentHash() {
        let h1 = ModelRuntime.computePrefixHash(systemContent: "sys", toolNames: ["search"])
        let h2 = ModelRuntime.computePrefixHash(systemContent: "sys", toolNames: ["calculate"])
        #expect(h1 != h2)
    }

    @Test func addingToolChangesHash() {
        let h1 = ModelRuntime.computePrefixHash(systemContent: "sys", toolNames: ["search"])
        let h2 = ModelRuntime.computePrefixHash(systemContent: "sys", toolNames: ["search", "browse"])
        #expect(h1 != h2)
    }

    @Test func hashFormatIs32HexChars() {
        let hash = ModelRuntime.computePrefixHash(systemContent: "test", toolNames: ["a", "b"])
        #expect(hash.count == 32)
        let hexCharSet = CharacterSet(charactersIn: "0123456789abcdef")
        for char in hash.unicodeScalars {
            #expect(hexCharSet.contains(char), "Non-hex character found: \(char)")
        }
    }

    @Test func emptyInputsProduceValidHash() {
        let hash = ModelRuntime.computePrefixHash(systemContent: "", toolNames: [])
        #expect(hash.count == 32)
        let hexCharSet = CharacterSet(charactersIn: "0123456789abcdef")
        for char in hash.unicodeScalars {
            #expect(hexCharSet.contains(char))
        }
    }

    @Test func emptyToolsVsNoToolsAreSame() {
        let h1 = ModelRuntime.computePrefixHash(systemContent: "sys", toolNames: [])
        let h2 = ModelRuntime.computePrefixHash(systemContent: "sys", toolNames: [])
        #expect(h1 == h2)
    }

    @Test func toolNameWithDelimiterDoesNotCollide() {
        // Ensure that a tool name containing the old delimiter doesn't collide
        let h1 = ModelRuntime.computePrefixHash(systemContent: "sys", toolNames: ["a,b"])
        let h2 = ModelRuntime.computePrefixHash(systemContent: "sys", toolNames: ["a", "b"])
        #expect(h1 != h2)
    }

    @Test func systemContentWithDelimiterDoesNotCollide() {
        let h1 = ModelRuntime.computePrefixHash(systemContent: "a|b", toolNames: [])
        let h2 = ModelRuntime.computePrefixHash(systemContent: "a", toolNames: ["b"])
        #expect(h1 != h2)
    }

    // MARK: - SSE writeRole prefix_hash

    @Test func sseWriteRoleIncludesPrefixHash() async throws {
        let channel = EmbeddedChannel()
        let writer = SSEResponseWriter()
        let ctx = try channel.testContext()

        writer.writeHeaders(ctx, extraHeaders: nil)
        writer.writeRole(
            "assistant",
            model: "test-model",
            responseId: "resp-1",
            created: 0,
            prefixHash: "abc123deadbeef00",
            context: ctx
        )

        // Skip the head part
        _ = try channel.readOutbound(as: HTTPServerResponsePart.self)

        // Read the role chunk body
        guard let bodyPart = try channel.readOutbound(as: HTTPServerResponsePart.self) else {
            #expect(Bool(false), "expected body part for role chunk")
            return
        }
        if case .body(let ioData) = bodyPart {
            switch ioData {
            case .byteBuffer(var buffer):
                let text = buffer.readString(length: buffer.readableBytes) ?? ""
                #expect(text.contains("\"prefix_hash\""))
                #expect(text.contains("abc123deadbeef00"))
            default:
                #expect(Bool(false), "expected byteBuffer")
            }
        } else {
            #expect(Bool(false), "expected body part")
        }
    }

    @Test func sseWriteRoleOmitsPrefixHashWhenNil() async throws {
        let channel = EmbeddedChannel()
        let writer = SSEResponseWriter()
        let ctx = try channel.testContext()

        writer.writeHeaders(ctx, extraHeaders: nil)
        writer.writeRole(
            "assistant",
            model: "test-model",
            responseId: "resp-2",
            created: 0,
            prefixHash: nil,
            context: ctx
        )

        _ = try channel.readOutbound(as: HTTPServerResponsePart.self)

        guard let bodyPart = try channel.readOutbound(as: HTTPServerResponsePart.self) else {
            #expect(Bool(false), "expected body part for role chunk")
            return
        }
        if case .body(let ioData) = bodyPart {
            switch ioData {
            case .byteBuffer(var buffer):
                let text = buffer.readString(length: buffer.readableBytes) ?? ""
                // When nil, prefix_hash should either be absent or encoded as null
                let hasNonNullHash = text.contains("\"prefix_hash\"") && !text.contains("\"prefix_hash\":null")
                #expect(!hasNonNullHash, "prefix_hash should be absent or null when nil")
            default:
                #expect(Bool(false), "expected byteBuffer")
            }
        } else {
            #expect(Bool(false), "expected body part")
        }
    }

    @Test func sseContentChunkDoesNotIncludePrefixHash() async throws {
        let channel = EmbeddedChannel()
        let writer = SSEResponseWriter()
        let ctx = try channel.testContext()

        writer.writeHeaders(ctx, extraHeaders: nil)
        writer.writeContent(
            "Hello",
            model: "test-model",
            responseId: "resp-3",
            created: 0,
            context: ctx
        )

        _ = try channel.readOutbound(as: HTTPServerResponsePart.self)

        guard let bodyPart = try channel.readOutbound(as: HTTPServerResponsePart.self) else {
            #expect(Bool(false), "expected body part for content chunk")
            return
        }
        if case .body(let ioData) = bodyPart {
            switch ioData {
            case .byteBuffer(var buffer):
                let text = buffer.readString(length: buffer.readableBytes) ?? ""
                // Content chunks should not have a non-null prefix_hash
                let hasNonNullHash = text.contains("\"prefix_hash\"") && !text.contains("\"prefix_hash\":null")
                #expect(!hasNonNullHash)
            default:
                #expect(Bool(false), "expected byteBuffer")
            }
        } else {
            #expect(Bool(false), "expected body part")
        }
    }
}
