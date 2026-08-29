import Testing

@testable import OsaurusCore

@Suite("Model switch continuity warning")
@MainActor
struct ModelSwitchContinuityWarningTests {
    @Test("warns only for a real mid-conversation model change")
    func warningGate() {
        #expect(
            ChatSession.shouldWarnAboutModelSwitch(
                previousModel: "org/old", newModel: "org/new", hasConversation: true
            )
        )
        #expect(
            !ChatSession.shouldWarnAboutModelSwitch(
                previousModel: "org/old", newModel: "org/old", hasConversation: true
            )
        )
        #expect(
            !ChatSession.shouldWarnAboutModelSwitch(
                previousModel: "ORG/OLD", newModel: "org/old", hasConversation: true
            )
        )
        #expect(
            !ChatSession.shouldWarnAboutModelSwitch(
                previousModel: nil, newModel: "org/new", hasConversation: true
            )
        )
        #expect(
            !ChatSession.shouldWarnAboutModelSwitch(
                previousModel: "org/old", newModel: "org/new", hasConversation: false
            )
        )
    }

    @Test("session warns on a live model change and reset clears it")
    func sessionLifecycle() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()

            session.selectedModel = "org/old"
            #expect(session.modelSwitchContinuityWarning == nil)

            session.turns = [ChatTurn(role: .user, content: "hello")]
            session.selectedModel = "org/new"
            #expect(
                session.modelSwitchContinuityWarning
                    == ModelSwitchContinuityWarning(
                        previousModelId: "org/old",
                        newModelId: "org/new"
                    )
            )

            session.reset()
            #expect(session.modelSwitchContinuityWarning == nil)
        }
    }
}
