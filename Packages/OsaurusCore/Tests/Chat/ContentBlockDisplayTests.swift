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
            guard case let .thinking(_, text, _) = block.kind else { return nil }
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
            guard case let .userMessage(text, _) = block.kind else { return nil }
            return text
        }.first

        #expect(userText == "ts:debug-token should stay visible for user content")
    }
}
