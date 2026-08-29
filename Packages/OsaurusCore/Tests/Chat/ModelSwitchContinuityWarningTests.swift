import Testing

@testable import OsaurusCore

@Suite("Model switch continuity warning")
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
}
