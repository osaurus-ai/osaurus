//
//  ModelRuntimeMappingTests.swift
//  osaurusTests
//

import Foundation
import CoreGraphics
import ImageIO
import MLXLMCommon
import Testing

@testable import OsaurusCore

struct ModelRuntimeMappingTests {
    @Test func richContentOrderSurvivesLocalRuntimeMapping() throws {
        let message = ChatMessage(role: "user", content: "beforeafter", contentParts: [
            .text("before"), .videoUrl(url: "file:///tmp/mimo-order-test.mp4"),
            .imageUrl(url: try validImageURL(), detail: nil), .text("after"),
        ])
        let mapped = try #require(ModelRuntime.mapOpenAIChatToMLX([message]).first)
        #expect(mapped.contentParts == [.text("before"), .video, .image, .text("after")])
        #expect(mapped.images.count == 1 && mapped.videos.count == 1)
    }

    private func imageMessage(_ urls: [String]) throws -> ChatMessage {
        var parts: [[String: Any]] = [["type": "text", "text": "Describe these images."]]
        parts += urls.map { ["type": "image_url", "image_url": ["url": $0]] }
        let data = try JSONSerialization.data(withJSONObject: [
            "role": "user",
            "content": parts,
        ])
        return try JSONDecoder().decode(ChatMessage.self, from: data)
    }

    private func validImageURL() throws -> String {
        let pixels = Data([255, 0, 0, 255])
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(
            width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return "data:image/png;base64," + (encoded as Data).base64EncodedString()
    }

    @Test(arguments: [
        "data:image/png;base64,%%%bad%%%",
        "data:image/png;base64,",
        "data:image/png;base64,bm90IGFuIGltYWdl",
        "data:image/png;base64",
        "data:text/plain;base64,bm90IGFuIGltYWdl",
        "not-an-image-url",
    ])
    func malformedImageFailsInsteadOfBecomingTextOnly(_ url: String) throws {
        let message = try imageMessage([url])
        #expect(throws: ModelRuntime.ImageInputError.self) {
            try ModelRuntime.mapOpenAIChatToMLX([message])
        }
    }

    @Test func mixedImagesCannotSilentlyLoseOneAttachment() throws {
        let message = try imageMessage([validImageURL(), "data:image/png;base64,bm90IGFuIGltYWdl"])
        do {
            _ = try ModelRuntime.mapOpenAIChatToMLX([message])
            Issue.record("corrupt second image was silently accepted")
        } catch let error as ModelRuntime.ImageInputError {
            #expect(error.imageIndex == 1)
            #expect(error.localizedDescription.contains("Image 2"))
            #expect(!error.localizedDescription.contains("bm90IGFu"))
        }
    }

    @Test func validImagesKeepTheirOrderAndDimensions() throws {
        let url = try validImageURL()
        let message = try imageMessage([url, "https://example.com/second.png", url])
        let mapped = try ModelRuntime.mapOpenAIChatToMLX([message])
        let images = try #require(mapped.first?.images)
        #expect(images.count == 3)
        guard case .ciImage(let first) = images[0],
            case .url(let second) = images[1], case .ciImage(let third) = images[2]
        else { Issue.record("image order or representation changed"); return }
        #expect(first.extent.width == 1 && first.extent.height == 1)
        #expect(second.absoluteString == "https://example.com/second.png")
        #expect(third.extent == first.extent)
        #expect(mapped.first?.content == "Describe these images.")
    }


    // MARK: - Multi-turn tool history fidelity
    //
    // `mapOpenAIChatToMLX` used to serialize assistant tool_calls into the
    // `content` string as Qwen-style `<tool_call>{...}</tool_call>` XML and
    // prefix tool results with `[tool: <name>]`. vmlx ≥ a99efeb added
    // structured `Chat.Message.toolCalls` / `toolCallId` fields and a
    // `DefaultMessageGenerator` that renders them into the Jinja dict under
    // `message.tool_calls`, so every template that reads
    // `message.tool_calls[i]` (MiniMax, Llama 3.1/3.2, Qwen 2.5, Mistral
    // Large, canonical OpenAI) now receives structured state instead of
    // string-embedded XML. These tests lock in the new structured flow.

    @Test func preservesAssistantToolCallTurns() throws {
        let toolCall = ToolCall(
            id: "call_1",
            type: "function",
            function: ToolCallFunction(
                name: "get_weather",
                arguments: "{\"city\":\"Tokyo\"}"
            )
        )
        let assistant = ChatMessage(
            role: "assistant",
            content: nil,
            tool_calls: [toolCall],
            tool_call_id: nil
        )
        let toolMsg = ChatMessage(
            role: "tool",
            content: "{\"temp\":72}",
            tool_calls: nil,
            tool_call_id: "call_1"
        )

        let mapped = try ModelRuntime.mapOpenAIChatToMLX([assistant, toolMsg])

        #expect(mapped.count == 2, "assistant tool_call turn must not be dropped")

        let asst = mapped[0]
        #expect(asst.role == .assistant)
        // Content no longer carries the XML; structured field does.
        #expect(asst.content == "")
        #expect(asst.toolCalls?.count == 1)
        #expect(asst.toolCalls?.first?.id == "call_1")
        #expect(asst.toolCalls?.first?.function.name == "get_weather")
        #expect(
            asst.toolCalls?.first?.function.rawArgumentsJSON
                == "{\"city\":\"Tokyo\"}"
        )
        if case .string(let city) = asst.toolCalls?.first?.function.arguments["city"] {
            #expect(city == "Tokyo")
        } else {
            Issue.record("expected arguments['city'] to decode as .string(\"Tokyo\")")
        }

        let tool = mapped[1]
        #expect(tool.role == .tool)
        // Tool content is now raw — no `[tool: name]` prefix; correlation
        // flows through `toolCallId` which the template binds to the
        // originating assistant call.
        #expect(tool.content == "{\"temp\":72}")
        #expect(tool.toolCallId == "call_1")
    }

    @Test func preservesMixedAssistantTurns() throws {
        let toolCall = ToolCall(
            id: "call_a",
            type: "function",
            function: ToolCallFunction(name: "search", arguments: "{\"q\":\"hi\"}")
        )
        let assistant = ChatMessage(
            role: "assistant",
            content: "Let me search for that.",
            tool_calls: [toolCall],
            tool_call_id: nil
        )

        let mapped = try ModelRuntime.mapOpenAIChatToMLX([assistant])
        #expect(mapped.count == 1)
        let asst = mapped[0]
        #expect(asst.role == .assistant)
        // Prose stays as content; tool call goes to structured field.
        #expect(asst.content == "Let me search for that.")
        #expect(asst.toolCalls?.count == 1)
        #expect(asst.toolCalls?.first?.function.name == "search")
    }

    @Test func multiTurnToolHistoryRoundTrip() throws {
        let user1 = ChatMessage(role: "user", content: "what's the weather and time?")
        let weather = ToolCall(
            id: "c1",
            type: "function",
            function: ToolCallFunction(name: "get_weather", arguments: "{}")
        )
        let asst1 = ChatMessage(role: "assistant", content: nil, tool_calls: [weather], tool_call_id: nil)
        let tool1 = ChatMessage(role: "tool", content: "{\"f\":72}", tool_calls: nil, tool_call_id: "c1")
        let time = ToolCall(
            id: "c2",
            type: "function",
            function: ToolCallFunction(name: "get_time", arguments: "{}")
        )
        let asst2 = ChatMessage(
            role: "assistant",
            content: "Now the time.",
            tool_calls: [time],
            tool_call_id: nil
        )
        let tool2 = ChatMessage(role: "tool", content: "12:34", tool_calls: nil, tool_call_id: "c2")
        let user2 = ChatMessage(role: "user", content: "thanks")

        let mapped = try ModelRuntime.mapOpenAIChatToMLX([user1, asst1, tool1, asst2, tool2, user2])
        #expect(mapped.count == 6)
        #expect(mapped[0].role == .user)
        #expect(mapped[1].role == .assistant)
        #expect(mapped[1].toolCalls?.first?.function.name == "get_weather")
        #expect(mapped[2].role == .tool)
        #expect(mapped[2].toolCallId == "c1")
        #expect(mapped[3].role == .assistant)
        #expect(mapped[3].content == "Now the time.")
        #expect(mapped[3].toolCalls?.first?.function.name == "get_time")
        #expect(mapped[4].role == .tool)
        #expect(mapped[4].toolCallId == "c2")
        #expect(mapped[5].role == .user)
    }

    @Test func flattensToolHistoryWhenStructuredToolsAreDisabled() throws {
        let call = ToolCall(
            id: "c1",
            type: "function",
            function: ToolCallFunction(
                name: "line_count",
                arguments: "{\"text\":\"red\\ngreen\\nblue\"}"
            )
        )
        let assistant = ChatMessage(
            role: "assistant",
            content: nil,
            tool_calls: [call],
            tool_call_id: nil
        )
        let tool = ChatMessage(
            role: "tool",
            content: "{\"lines\":3}",
            tool_calls: nil,
            tool_call_id: "c1"
        )
        let user = ChatMessage(role: "user", content: "How many lines?")

        let mapped = try ModelRuntime.mapOpenAIChatToMLX(
            [assistant, tool, user],
            preserveStructuredToolHistory: false
        )

        #expect(mapped.count == 2)
        #expect(mapped[0].role == .user)
        #expect(mapped[0].content == "Tool result: {\"lines\":3}")
        #expect(mapped[0].toolCalls == nil)
        #expect(mapped[0].toolCallId == nil)
        #expect(mapped[1].role == .user)
        #expect(mapped[1].content == "How many lines?")
    }

    /// Empty assistant turn (no content AND no tool_calls) must still be
    /// dropped so downstream templates don't see a stray empty message.
    @Test func skipsFullyEmptyAssistantTurns() throws {
        let empty = ChatMessage(role: "assistant", content: nil, tool_calls: nil, tool_call_id: nil)
        let whitespace = ChatMessage(role: "assistant", content: "   \n  ", tool_calls: nil, tool_call_id: nil)
        let valid = ChatMessage(role: "user", content: "hello")
        let mapped = try ModelRuntime.mapOpenAIChatToMLX([empty, whitespace, valid])
        #expect(mapped.count == 1)
        #expect(mapped[0].role == .user)
    }

    /// Local Jinja templates for ZAYA, Nemotron-H/Omni, MiniMax, and DSV4
    /// read `message.reasoning_content` on assistant history turns. Dropping
    /// it changes the rendered prompt across turns and can make thinking
    /// toggles or prefix-cache hits appear flaky.
    @Test func preservesAssistantReasoningContentTurns() throws {
        let assistant = ChatMessage(
            role: "assistant",
            content: "Final answer.",
            tool_calls: nil,
            tool_call_id: nil,
            reasoning_content: "Prior reasoning."
        )

        let mapped = try ModelRuntime.mapOpenAIChatToMLX([assistant])

        #expect(mapped.count == 1)
        #expect(mapped[0].role == .assistant)
        #expect(mapped[0].content == "Final answer.")
        #expect(mapped[0].reasoningContent == "Prior reasoning.")
    }

    @Test func preservesAssistantContentAndReasoningBytes() throws {
        let assistant = ChatMessage(
            role: "assistant",
            content: "  Final answer.\n",
            tool_calls: nil,
            tool_call_id: nil,
            reasoning_content: "\nPrior reasoning.  "
        )

        let mapped = try ModelRuntime.mapOpenAIChatToMLX([assistant])

        #expect(mapped.count == 1)
        #expect(mapped[0].role == .assistant)
        #expect(mapped[0].content == "  Final answer.\n")
        #expect(mapped[0].reasoningContent == "\nPrior reasoning.  ")
    }

    @Test func preservesReasoningOnlyAssistantTurns() throws {
        let assistant = ChatMessage(
            role: "assistant",
            content: nil,
            tool_calls: nil,
            tool_call_id: nil,
            reasoning_content: "Reasoning with no visible content yet."
        )

        let mapped = try ModelRuntime.mapOpenAIChatToMLX([assistant])

        #expect(mapped.count == 1)
        #expect(mapped[0].role == .assistant)
        #expect(mapped[0].content == "")
        #expect(mapped[0].reasoningContent == "Reasoning with no visible content yet.")
    }

    /// Malformed / non-object arguments must not crash the mapper — they
    /// decode to an empty dict and the tool call still emits.
    @Test func handlesMalformedArgumentsJson() throws {
        let toolCall = ToolCall(
            id: "c",
            type: "function",
            function: ToolCallFunction(name: "f", arguments: "not json")
        )
        let assistant = ChatMessage(
            role: "assistant",
            content: nil,
            tool_calls: [toolCall],
            tool_call_id: nil
        )
        let mapped = try ModelRuntime.mapOpenAIChatToMLX([assistant])
        #expect(mapped.count == 1)
        #expect(mapped[0].toolCalls?.count == 1)
        #expect(mapped[0].toolCalls?.first?.function.name == "f")
        #expect(mapped[0].toolCalls?.first?.function.arguments.isEmpty == true)
    }
}
