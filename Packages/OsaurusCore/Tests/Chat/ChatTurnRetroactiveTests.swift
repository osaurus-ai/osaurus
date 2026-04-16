import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ChatTurnRetroactiveTests {
    @Test
    func moveContentToThinking_movesPriorContentPlusTail() {
        let turn = ChatTurn(role: .assistant, content: "")
        turn.appendContent("hello")
        turn.appendContent(" world")

        let moved = turn.moveContentToThinking(tail: " before tag")
        #expect(moved == "hello world before tag".count)
        #expect(turn.content == "")
        #expect(turn.contentIsEmpty)
        #expect(turn.contentLength == 0)
        #expect(turn.thinking == "hello world before tag")
        #expect(turn.thinkingLength == "hello world before tag".count)
    }

    @Test
    func moveContentToThinking_noopOnEmpty() {
        let turn = ChatTurn(role: .assistant, content: "")
        let moved = turn.moveContentToThinking(tail: "")
        #expect(moved == 0)
        #expect(turn.thinking == "")
        #expect(turn.content == "")
    }

    @Test
    func moveContentToThinking_appendsToExistingThinking() {
        let turn = ChatTurn(role: .assistant, content: "")
        turn.appendThinking("prior thinking. ")
        turn.appendContent("accidental reasoning ")

        turn.moveContentToThinking(tail: "tail")
        #expect(turn.thinking == "prior thinking. accidental reasoning tail")
        #expect(turn.content == "")
    }

    @Test
    func moveContentToThinking_tailOnlyWhenContentEmpty() {
        let turn = ChatTurn(role: .assistant, content: "")
        let moved = turn.moveContentToThinking(tail: "some reasoning")
        #expect(moved == "some reasoning".count)
        #expect(turn.thinking == "some reasoning")
        #expect(turn.content == "")
    }
}
