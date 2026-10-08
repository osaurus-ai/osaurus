import Foundation
import Testing

@testable import OsaurusCore

/// Actual ChatSession Stop and save behavior, without a model or GPU producer.
/// The same begin/finish presentation seam is used by native generate and edit.
@Suite(.serialized)
@MainActor
struct ChatSessionImageCancellationTests {
    private func sessionWithAssistant(_ text: String) -> (ChatSession, ChatTurn) {
        let session = ChatSession()
        let turn = ChatTurn(role: .assistant, content: text)
        session.turns = [ChatTurn(role: .user, content: "Make a teapot."), turn]
        session.isStreaming = true
        return (session, turn)
    }

    @Test(arguments: ["Generating image…", "Loading image model…", "Generating image… 8/40"])
    func stopReplacesPendingNativeImageProgressBeforeSaving(_ progress: String) async throws {
        try await ChatHistoryTestStorage.run {
            let (session, turn) = sessionWithAssistant("")
            session.beginNativeImagePresentation(on: turn)
            turn.content = progress

            session.stop()

            #expect(turn.content == L("Image generation cancelled."))
            #expect(!session.isStreaming)
            let id = try #require(session.sessionId)
            // saveAsync publishes this persistence snapshot synchronously;
            // no sleep or disk-poll race is needed to observe the saved content.
            let saved = try #require(ChatSessionsManager.shared.session(for: id))
            #expect(saved.turns.last?.content == L("Image generation cancelled."))
        }
    }

    @Test(arguments: [
        "![teapot](file:///tmp/completed-teapot.png)",
        "Image generation failed: bad request",
        "Image generation cancelled.",
    ])
    func stopPreservesTerminalNativeImageContent(_ terminalContent: String) async throws {
        try await ChatHistoryTestStorage.run {
            let (session, turn) = sessionWithAssistant("")
            session.beginNativeImagePresentation(on: turn)
            session.finishNativeImagePresentation(on: turn)
            turn.content = terminalContent

            session.stop()

            #expect(turn.content == terminalContent)
        }
    }

    @Test
    func stopPreservesPartialTextAssistantContent() async throws {
        try await ChatHistoryTestStorage.run {
            let (session, turn) = sessionWithAssistant("A partial text answer.")

            session.stop()

            #expect(turn.content == "A partial text answer.")
        }
    }

    @Test
    func lifecycleStopKeepsExistingNoCancelledMarkerContract() async throws {
        try await ChatHistoryTestStorage.run {
            let (session, turn) = sessionWithAssistant("")
            session.beginNativeImagePresentation(on: turn)
            turn.content = "Generating image… 8/40"

            session.stop(preservesCancelledMarker: false)

            #expect(turn.content == "Generating image… 8/40")
        }
    }

    @Test
    func pendingOwnerCannotRewriteAReplacementConversation() async throws {
        try await ChatHistoryTestStorage.run {
            let (session, oldTurn) = sessionWithAssistant("")
            session.beginNativeImagePresentation(on: oldTurn)
            let replacement = ChatTurn(role: .assistant, content: "A different conversation.")
            session.turns = [replacement]

            session.stop()

            #expect(replacement.content == "A different conversation.")
        }
    }

    @Test
    func oldProducerFinishCannotClearNewImagePresentationOwner() async throws {
        try await ChatHistoryTestStorage.run {
            let (session, oldTurn) = sessionWithAssistant("")
            session.beginNativeImagePresentation(on: oldTurn)
            let newTurn = ChatTurn(role: .assistant, content: "")
            session.turns.append(newTurn)
            session.beginNativeImagePresentation(on: newTurn)
            newTurn.content = "Generating image… 2/40"

            session.finishNativeImagePresentation(on: oldTurn)
            session.stop()

            #expect(newTurn.content == L("Image generation cancelled."))
        }
    }
}
