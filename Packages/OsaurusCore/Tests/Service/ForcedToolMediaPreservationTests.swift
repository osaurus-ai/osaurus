import Foundation
import Testing

@testable import OsaurusCore

/// Explicit tool selection must not turn a multimodal request into text-only.
/// These fixtures use inert URLs; mapping them must not fetch remote resources.
@Suite(.serialized)
struct ForcedToolMediaPreservationTests {
    private static let model = "OsaurusAI/gemma-4-E2B-it-8bit"
    private static let firstImage = "https://first.invalid/image.png"
    private static let secondImage = "https://second.invalid/image.jpg"

    private static func choice(named: Bool) -> ToolChoiceOption {
        named
            ? .function(.init(type: "function", function: .init(name: "record_visual")))
            : .required
    }

    private static func directive(named: Bool) -> String {
        "The current assistant response MUST be a function call."
            + (named ? " Use the `record_visual` function." : "")
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    private static func richMessage() -> ChatMessage {
        ChatMessage(
            role: "user",
            content: "Compare these.",
            contentParts: [
                .text("Compare these."),
                .imageUrl(url: firstImage, detail: "high"),
                .audioInput(data: "AAAA", format: "wav"),
                .videoUrl(url: "https://video.invalid/clip.mp4"),
                .audioInput(data: "BBBB", format: "mp3"),
            ],
            localAudioSamples: [
                LocalAudioSamples(samples: [0.25, -0.5], sampleRate: 24_000), nil,
            ],
            tool_calls: [ToolCall(
                id: "prior-call", type: "function",
                function: .init(name: "read_visual", arguments: "{\"index\":1}"),
                geminiThoughtSignature: "opaque-test-signature"
            )],
            tool_call_id: "prior-result",
            reasoning_content: "retained reasoning",
            reasoning_item_id: "rs_test",
            reasoning_encrypted: "opaque-test-reasoning",
            responses_output_items: [.object(["type": .string("reasoning"), "id": .string("rs_test")])]
        )
    }

    @Test(arguments: [false, true])
    func orderedImagePartsAndWireTextSurvive(named: Bool) throws {
        let parts: [MessageContentPart] = [
            .text("Before."), .imageUrl(url: Self.firstImage, detail: "high"),
            .text("Between."), .imageUrl(url: Self.secondImage, detail: "low"),
            .imageUrl(url: Self.firstImage, detail: nil), .text("After."),
        ]
        let original = ChatMessage(role: "user", content: "Before.Between.After.", contentParts: parts)
        let result = try #require(ModelRuntime.applyForcedToolChoiceDirective(
            [original], toolChoice: Self.choice(named: named), modelName: Self.model
        ).first)
        let expectedText = "Before.Between.After.\n\n" + Self.directive(named: named)
        #expect(result.content == expectedText)
        #expect(result.imageUrls == [Self.firstImage, Self.secondImage, Self.firstImage])
        let actualParts = try #require(result.contentParts)
        #expect(try Self.encoded(Array(actualParts.prefix(parts.count))) == Self.encoded(parts))
        #expect(actualParts.count == parts.count + 1)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: Self.encoded(result))
        #expect(decoded.content == expectedText)
        #expect(decoded.imageUrls == result.imageUrls)
        #expect(original.content == "Before.Between.After.")
        #expect(try Self.encoded(original.contentParts) == Self.encoded(parts))
    }

    @Test(arguments: [false, true])
    func imageOnlyUserKeepsMedia(named: Bool) throws {
        let original = ChatMessage(role: "user", content: nil, contentParts: [
            .imageUrl(url: Self.firstImage, detail: nil),
        ])
        let result = ModelRuntime.applyForcedToolChoiceDirective(
            [original], toolChoice: Self.choice(named: named), modelName: Self.model
        )
        #expect(result.first?.content == Self.directive(named: named))
        #expect(result.first?.imageUrls == [Self.firstImage])
        let mapped = try ModelRuntime.mapOpenAIChatToMLX(result)
        #expect(mapped.first?.images.count == 1)
        #expect(mapped.first?.content == Self.directive(named: named))
    }

    @Test(arguments: [false, true])
    func nonTextAndOpaqueCarriersStayIntact(named: Bool) throws {
        let original = Self.richMessage()
        let result = try #require(ModelRuntime.applyForcedToolChoiceDirective(
            [original], toolChoice: Self.choice(named: named), modelName: Self.model
        ).first)
        #expect(result.imageUrls == original.imageUrls)
        #expect(result.videoUrls == original.videoUrls)
        #expect(result.audioInputs.map(\.data) == original.audioInputs.map(\.data))
        #expect(result.audioInputs.map(\.format) == original.audioInputs.map(\.format))
        #expect(result.localAudioSamples == original.localAudioSamples)
        #expect(result.audioInputsWithLocalSamples.map(\.localSamples) == original.localAudioSamples)
        #expect(try Self.encoded(result.tool_calls) == Self.encoded(original.tool_calls))
        #expect(result.tool_call_id == original.tool_call_id)
        #expect(result.reasoning_content == original.reasoning_content)
        #expect(result.reasoning_item_id == original.reasoning_item_id)
        #expect(result.reasoning_encrypted == original.reasoning_encrypted)
        #expect(result.responses_output_items == original.responses_output_items)
    }

    @Test(arguments: [false, true])
    func onlyLastUserChangesAndFollowingToolHistorySurvives(named: Bool) throws {
        let earlier = Self.richMessage()
        let messages = [
            ChatMessage(role: "system", content: "Context."),
            earlier,
            ChatMessage(role: "assistant", content: "First answer."),
            ChatMessage(role: "user", content: "Next image.", contentParts: [
                .text("Next image."), .imageUrl(url: Self.secondImage, detail: "high"),
            ]),
            ChatMessage(role: "assistant", content: nil, tool_calls: earlier.tool_calls, tool_call_id: nil),
            ChatMessage(role: "tool", content: "Observed result.", tool_calls: nil, tool_call_id: "prior-call"),
        ]
        let result = ModelRuntime.applyForcedToolChoiceDirective(
            messages, toolChoice: Self.choice(named: named), modelName: Self.model
        )
        #expect(result.count == messages.count)
        for index in [0, 1, 2, 4, 5] {
            #expect(try Self.encoded(result[index]) == Self.encoded(messages[index]))
        }
        #expect(result[1].localAudioSamples == earlier.localAudioSamples)
        #expect(result[1].responses_output_items == earlier.responses_output_items)
        #expect(result[3].imageUrls == [Self.secondImage])
        #expect(result[3].content == "Next image.\n\n" + Self.directive(named: named))
    }

    @Test func automaticAndNoToolChoiceRemainNoOps() throws {
        let message = Self.richMessage()
        let choices: [ToolChoiceOption?] = [nil, .auto, ToolChoiceOption.none]
        for choice in choices {
            let result = try #require(ModelRuntime.applyForcedToolChoiceDirective(
                [message], toolChoice: choice, modelName: Self.model
            ).first)
            #expect(try Self.encoded(result) == Self.encoded(message))
            #expect(result.localAudioSamples == message.localAudioSamples)
            #expect(result.responses_output_items == message.responses_output_items)
        }
    }

    @Test(arguments: [false, true])
    func nonGemmaAndUnknownModelsRemainNoOps(named: Bool) throws {
        let message = Self.richMessage()
        for model in [nil, "DeepSeek-V4-Flash", "Qwen3.5-27B"] as [String?] {
            let result = try #require(ModelRuntime.applyForcedToolChoiceDirective(
                [message], toolChoice: Self.choice(named: named), modelName: model
            ).first)
            #expect(try Self.encoded(result) == Self.encoded(message))
            #expect(result.localAudioSamples == message.localAudioSamples)
            #expect(result.responses_output_items == message.responses_output_items)
        }
    }

    @Test(arguments: [false, true])
    func textOnlyAndEmptyContentKeepExistingDirective(named: Bool) throws {
        for content in [nil, "", "Finish."] as [String?] {
            let original = ChatMessage(role: "user", content: content, tool_calls: nil, tool_call_id: nil)
            let result = try #require(ModelRuntime.applyForcedToolChoiceDirective(
                [original], toolChoice: Self.choice(named: named), modelName: Self.model
            ).first)
            let prefix = (content?.isEmpty == false) ? content! + "\n\n" : ""
            #expect(result.content == prefix + Self.directive(named: named))
            #expect(result.contentParts == nil)
        }
    }

    @Test(arguments: [false, true])
    func emptyPartsDoNotLoseDirectiveOnRoundTrip(named: Bool) throws {
        let original = ChatMessage(role: "user", content: nil, contentParts: [])
        let result = try #require(ModelRuntime.applyForcedToolChoiceDirective(
            [original], toolChoice: Self.choice(named: named), modelName: Self.model
        ).first)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: Self.encoded(result))
        #expect(decoded.content == Self.directive(named: named))
        #expect(result.imageUrls.isEmpty)
    }

    @Test(arguments: [false, true])
    func noUserKeepsExistingAppendBehavior(named: Bool) throws {
        let messages = [ChatMessage(role: "system", content: "System only.")]
        let result = ModelRuntime.applyForcedToolChoiceDirective(
            messages, toolChoice: Self.choice(named: named), modelName: Self.model
        )
        #expect(result.count == 2)
        #expect(try Self.encoded(result[0]) == Self.encoded(messages[0]))
        #expect(result[1].role == "user")
        #expect(result[1].content == Self.directive(named: named))
        #expect(result[1].contentParts == nil)
    }
}
