import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ChatTurnDeletionPolicyTests {
    @Test
    func deletingUserRemovesOnlyItsExchange() {
        let firstUser = ChatTurn(role: .user, content: "first")
        let firstAnswer = ChatTurn(role: .assistant, content: "answer")
        let secondUser = ChatTurn(role: .user, content: "second")
        let secondAnswer = ChatTurn(role: .assistant, content: "later answer")

        let remaining = ChatTurnDeletionPolicy.removingTurn(
            id: firstUser.id,
            from: [firstUser, firstAnswer, secondUser, secondAnswer]
        )

        #expect(remaining.map(\.id) == [secondUser.id, secondAnswer.id])
    }

    @Test
    func deletingToolCallingAssistantAlsoRemovesOnlyMatchingToolResults() {
        let user = ChatTurn(role: .user, content: "use tools")
        let toolCall = ToolCall(
            id: "call_read",
            type: "function",
            function: ToolCallFunction(name: "read_file", arguments: "{}")
        )
        let assistant = ChatTurn(role: .assistant, content: "")
        assistant.toolCalls = [toolCall]

        let matchingResult = ChatTurn(role: .tool, content: "file contents")
        matchingResult.toolCallId = "call_read"
        let unrelatedResult = ChatTurn(role: .tool, content: "keep this")
        unrelatedResult.toolCallId = "call_other"
        let finalAnswer = ChatTurn(role: .assistant, content: "done")
        let nextUser = ChatTurn(role: .user, content: "next")

        let remaining = ChatTurnDeletionPolicy.removingTurn(
            id: assistant.id,
            from: [user, assistant, matchingResult, unrelatedResult, finalAnswer, nextUser]
        )

        #expect(remaining.map(\.id) == [user.id, unrelatedResult.id, finalAnswer.id, nextUser.id])
    }

    @Test
    func deletingPlainAssistantLeavesLaterHistoryUntouched() {
        let user = ChatTurn(role: .user, content: "question")
        let answer = ChatTurn(role: .assistant, content: "answer")
        let laterUser = ChatTurn(role: .user, content: "follow-up")

        let remaining = ChatTurnDeletionPolicy.removingTurn(
            id: answer.id,
            from: [user, answer, laterUser]
        )

        #expect(remaining.map(\.id) == [user.id, laterUser.id])
    }
}
