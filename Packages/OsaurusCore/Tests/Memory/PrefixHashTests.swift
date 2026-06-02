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
        // Mark the embedded channel active so writers that (correctly) skip
        // writes on an inactive channel — e.g. `SSEResponseWriter`'s
        // backpressure-aware path guards on `channel.isActive` — actually
        // emit outbound parts under test. `connect` on an `EmbeddedChannel`
        // just flips it active without any real networking.
        if !self.isActive {
            try? self.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
        }
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

    private func fixtureTool(
        description: String,
        parameterDescription: String? = nil
    ) -> Tool {
        var pathSchema: [String: JSONValue] = ["type": .string("string")]
        if let parameterDescription {
            pathSchema["description"] = .string(parameterDescription)
        }
        return Tool(
            type: "function",
            function: ToolFunction(
                name: "mutable_context",
                description: description,
                parameters: .object([
                    "type": .string("object"),
                    "required": .array([.string("path")]),
                    "properties": .object([
                        "path": .object(pathSchema)
                    ]),
                ])
            )
        )
    }

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

    @Test func toolSchemaChangeProducesDifferentHashForSameToolName() {
        let compact = fixtureTool(description: "Mutates context.")
        let full = fixtureTool(
            description: "Mutates context after validating the target path and replacement body.",
            parameterDescription: "Repository-relative path to mutate."
        )

        let legacyCompact = ModelRuntime.computePrefixHash(
            systemContent: "sys",
            toolNames: [compact.function.name]
        )
        let legacyFull = ModelRuntime.computePrefixHash(
            systemContent: "sys",
            toolNames: [full.function.name]
        )
        #expect(legacyCompact == legacyFull)

        let payloadCompact = ModelRuntime.computePrefixHash(systemContent: "sys", tools: [compact])
        let payloadFull = ModelRuntime.computePrefixHash(systemContent: "sys", tools: [full])
        #expect(payloadCompact != payloadFull)
    }

    @Test func staticPrefixCacheHintIncludesToolSchemaPayload() {
        let manifest = PromptManifest(sections: [
            .static(id: "platform", label: "Platform", content: "You are Osaurus.")
        ])
        let compact = fixtureTool(description: "Mutates context.")
        let full = fixtureTool(
            description: "Mutates context after validating the target path and replacement body.",
            parameterDescription: "Repository-relative path to mutate."
        )

        #expect(
            manifest.staticPrefixHash(tools: [compact])
                != manifest.staticPrefixHash(tools: [full])
        )
    }

    @Test func toolSchemaHashCanonicalizesNestedPropertyOrder() {
        let a = Tool(
            type: "function",
            function: ToolFunction(
                name: "stable_context",
                description: "Stable schema.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "z": .object(["type": .string("string")]),
                        "a": .object(["type": .string("number")]),
                    ]),
                ])
            )
        )
        let b = Tool(
            type: "function",
            function: ToolFunction(
                name: "stable_context",
                description: "Stable schema.",
                parameters: .object([
                    "properties": .object([
                        "a": .object(["type": .string("number")]),
                        "z": .object(["type": .string("string")]),
                    ]),
                    "type": .string("object"),
                ])
            )
        )

        #expect(
            ModelRuntime.computePrefixHash(systemContent: "sys", tools: [a])
                == ModelRuntime.computePrefixHash(systemContent: "sys", tools: [b])
        )
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
