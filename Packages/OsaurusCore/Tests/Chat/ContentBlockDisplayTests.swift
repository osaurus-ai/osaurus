import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ContentBlockDisplayTests {
    @Test
    func assistantVisibleContent_hidesGeminiMetadata() {
        let assistant = ChatTurn(
            role: .assistant,
            content: "\u{200B}ts:CiQabcDEF123+/=_\u{200B}Dependencies installed."
        )

        #expect(assistant.visibleContent == "Dependencies installed.")
    }

    @Test
    func assistantParagraphs_useVisibleContent() {
        let assistant = ChatTurn(
            role: .assistant,
            content: "\u{200B}ts:CiQabcDEF123+/=_\u{200B}Dependencies installed."
        )

        let blocks = ContentBlock.generateBlocks(
            from: [assistant],
            streamingTurnId: nil,
            agentName: "Assistant"
        )

        let paragraphText = blocks.compactMap { block -> String? in
            guard case let .paragraph(_, text, _, _) = block.kind else { return nil }
            return text
        }.first

        #expect(paragraphText == "Dependencies installed.")
    }

    @Test
    func assistantWhitespaceOnlyCompletion_rendersFallbackInsteadOfBlankParagraph() {
        let assistant = ChatTurn(role: .assistant, content: "\n\n\n")
        assistant.generationTokenCount = 32
        assistant.generationTokensPerSecond = 19.5

        let blocks = ContentBlock.generateBlocks(
            from: [assistant],
            streamingTurnId: nil,
            agentName: "Assistant"
        )

        let paragraphTexts = blocks.compactMap { block -> String? in
            guard case let .paragraph(_, text, _, _) = block.kind else { return nil }
            return text
        }

        #expect(paragraphTexts == ["No visible text was produced."])
    }

    @Test
    func assistantReasoningOnlyCompletion_rendersThinkingNotBlankFallback() {
        let assistant = ChatTurn(role: .assistant, content: "\n\n")
        assistant.thinking = "The user greeted us."
        assistant.generationTokenCount = 12

        let blocks = ContentBlock.generateBlocks(
            from: [assistant],
            streamingTurnId: nil,
            agentName: "Assistant"
        )

        let thinkingText = blocks.compactMap { block -> String? in
            guard case let .thinking(_, text, _, _) = block.kind else { return nil }
            return text
        }.first
        let paragraphTexts = blocks.compactMap { block -> String? in
            guard case let .paragraph(_, text, _, _) = block.kind else { return nil }
            return text
        }

        #expect(thinkingText == "The user greeted us.")
        #expect(paragraphTexts.isEmpty)
    }

    @Test
    func assistantReasoningOnlyCompletion_keepsAssistantActionsAvailable() {
        let assistant = ChatTurn(role: .assistant, content: "\n")
        assistant.thinking = "Reasoning transcript"
        assistant.generationTokenCount = 8

        let blocks = ContentBlock.generateBlocks(
            from: [assistant],
            streamingTurnId: nil,
            agentName: "Assistant"
        )

        let hasActions = blocks.contains { block in
            if case .assistantActions = block.kind { return true }
            return false
        }

        #expect(hasActions)
    }

    @Test
    func billedBlankCompletion_rendersEmptyResponseNoticeInsteadOfFallback() {
        let assistant = ChatTurn(role: .assistant, content: "\n\n")
        assistant.generationTokenCount = 3
        assistant.routerBilling = RouterBillingSummary(
            costMicro: "1234",
            status: "completed",
            tokenSource: "provider",
            inputTokens: 11,
            outputTokens: 3
        )

        let blocks = ContentBlock.generateBlocks(
            from: [assistant],
            streamingTurnId: nil,
            agentName: "Assistant"
        )

        let notice = blocks.compactMap { block -> (Int, String, String)? in
            guard case let .emptyResponseNotice(_, tokens, cost, status) = block.kind else { return nil }
            return (tokens, cost, status)
        }.first
        let paragraphTexts = blocks.compactMap { block -> String? in
            guard case let .paragraph(_, text, _, _) = block.kind else { return nil }
            return text
        }

        #expect(notice?.0 == 3)
        #expect(notice?.1 == "1234")
        #expect(notice?.2 == "completed")
        // The notice replaces the generic "No visible text was produced." line.
        #expect(paragraphTexts.isEmpty)
    }

    @Test
    func billedTurnWithVisibleContent_rendersContentNotNotice() {
        let assistant = ChatTurn(role: .assistant, content: "Here is your answer.")
        assistant.routerBilling = RouterBillingSummary(
            costMicro: "500",
            status: "completed",
            tokenSource: "provider",
            inputTokens: 8,
            outputTokens: 5
        )

        let blocks = ContentBlock.generateBlocks(
            from: [assistant],
            streamingTurnId: nil,
            agentName: "Assistant"
        )

        let hasNotice = blocks.contains { if case .emptyResponseNotice = $0.kind { return true } else { return false } }
        let paragraphText = blocks.compactMap { block -> String? in
            guard case let .paragraph(_, text, _, _) = block.kind else { return nil }
            return text
        }.first

        #expect(!hasNotice)
        #expect(paragraphText == "Here is your answer.")
    }

    @Test
    func userVisibleContent_preservesOriginalText() {
        let user = ChatTurn(role: .user, content: "ts:debug-token should stay visible for user content")

        #expect(user.visibleContent == "ts:debug-token should stay visible for user content")
    }

    @Test
    func userParagraphs_preserveOriginalText() {
        let user = ChatTurn(role: .user, content: "ts:debug-token should stay visible for user content")

        let blocks = ContentBlock.generateBlocks(
            from: [user],
            streamingTurnId: nil,
            agentName: "Assistant"
        )

        let userText = blocks.compactMap { block -> String? in
            guard case let .userMessage(text, _, _, _) = block.kind else { return nil }
            return text
        }.first

        #expect(userText == "ts:debug-token should stay visible for user content")
    }

    @Test
    func imageGenerateToolResult_rendersSharedArtifactCard() throws {
        let assistant = ChatTurn(role: .assistant, content: "")
        let call = ToolCall(
            id: "call_image_1",
            type: "function",
            function: ToolCallFunction(name: "image", arguments: #"{"prompt":"green apple"}"#)
        )
        assistant.toolCalls = [call]
        assistant.toolResults[call.id] = ToolEnvelope.success(
            tool: "image",
            text: try Self.enrichedArtifactMarker(
                filename: "green-apple.png",
                mimeType: "image/png",
                hostPath: "/tmp/green-apple.png",
                contextId: "chat-context"
            )
        )

        let blocks = ContentBlock.generateBlocks(
            from: [assistant],
            streamingTurnId: nil,
            agentName: "Assistant"
        )

        let artifact = blocks.compactMap { block -> SharedArtifact? in
            guard case let .sharedArtifact(artifact) = block.kind else { return nil }
            return artifact
        }.first

        #expect(artifact?.filename == "green-apple.png")
        #expect(artifact?.mimeType == "image/png")
        #expect(artifact?.hostPath == "/tmp/green-apple.png")
    }

    @Test
    func rollupActivity_groupsConsecutiveThinkingAndToolRuns() {
        let turn1 = UUID()
        let turn2 = UUID()
        let thinking = ContentBlock.thinking(
            turnId: turn1, index: 0, text: "reasoning", isStreaming: false,
            duration: 1.2, position: .middle
        )
        let tools = ContentBlock.toolCallGroup(
            turnId: turn2, calls: [Self.toolCallItem(id: "call-1")], position: .middle
        )
        let answer = ContentBlock.paragraph(
            turnId: turn2, index: 0, text: "answer", isStreaming: false,
            role: .assistant, position: .last
        )

        let rolled = ContentBlock.rollupActivityBlocks([thinking, tools, answer])

        #expect(rolled.count == 2)
        guard case let .activityGroup(children) = rolled[0].kind else {
            Issue.record("expected leading activityGroup, got \(rolled[0].kind)")
            return
        }
        #expect(children.map(\.id) == [thinking.id, tools.id])
        #expect(rolled[0].id == ContentBlock.activityGroupId(firstChildId: thinking.id))
        #expect(rolled[0].turnId == turn1)
        #expect(rolled[1].id == answer.id)
        #expect(
            ContentBlock.enclosingActivityGroupId(forChildId: thinking.id, in: rolled)
                == rolled[0].id
        )
    }

    @Test
    func rollupActivity_leavesSingleBlocksAndOtherKindsBare() {
        let turnId = UUID()
        let thinking = ContentBlock.thinking(
            turnId: turnId, index: 0, text: "reasoning", isStreaming: true,
            duration: nil, position: .middle
        )
        let answer = ContentBlock.paragraph(
            turnId: turnId, index: 0, text: "answer", isStreaming: false,
            role: .assistant, position: .last
        )

        let rolled = ContentBlock.rollupActivityBlocks([thinking, answer])

        #expect(rolled.map(\.id) == [thinking.id, answer.id])
        #expect(ContentBlock.enclosingActivityGroupId(forChildId: thinking.id, in: rolled) == nil)
    }

    @Test
    func rollupActivity_groupsLoneToolGroupByStepCount() {
        // Loaded chats coalesce a whole tool run into one block; the rollup
        // threshold counts steps, so a lone multi-call group still rolls up
        // while a lone single-call group stays bare.
        let turnId = UUID()
        let multi = ContentBlock.toolCallGroup(
            turnId: turnId,
            calls: [Self.toolCallItem(id: "call-1"), Self.toolCallItem(id: "call-2")],
            position: .middle
        )
        let single = ContentBlock.toolCallGroup(
            turnId: turnId, calls: [Self.toolCallItem(id: "call-3")], position: .middle
        )
        let answer = ContentBlock.paragraph(
            turnId: turnId, index: 0, text: "answer", isStreaming: false,
            role: .assistant, position: .last
        )

        let rolledMulti = ContentBlock.rollupActivityBlocks([multi, answer])
        guard case .activityGroup = rolledMulti[0].kind else {
            Issue.record("expected multi-call group to roll up, got \(rolledMulti[0].kind)")
            return
        }

        let rolledSingle = ContentBlock.rollupActivityBlocks([single, answer])
        #expect(rolledSingle.map(\.id) == [single.id, answer.id])
    }

    private static func toolCallItem(id: String) -> ToolCallItem {
        ToolCallItem(
            call: ToolCall(
                id: id,
                type: "function",
                function: ToolCallFunction(name: "web_search", arguments: "{}")
            ),
            result: "{}",
            duration: 0.2
        )
    }

    private static func enrichedArtifactMarker(
        filename: String,
        mimeType: String,
        hostPath: String,
        contextId: String
    ) throws -> String {
        let metadata: [String: Any] = [
            "filename": filename,
            "mime_type": mimeType,
            "has_content": false,
            "host_path": hostPath,
            "context_id": contextId,
            "context_type": ArtifactContextType.chat.rawValue,
            "file_size": 128,
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: .osaurusCanonical)
        let jsonLine = String(decoding: data, as: UTF8.self)
        return SharedArtifact.startMarker + jsonLine + SharedArtifact.endMarker
    }
}
