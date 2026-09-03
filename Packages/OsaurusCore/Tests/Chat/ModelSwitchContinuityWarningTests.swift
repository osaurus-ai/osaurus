import Foundation
import Testing

@testable import OsaurusCore

@Suite("Model switch continuity warning")
@MainActor
struct ModelSwitchContinuityWarningTests {

    @Test("model-switch advisory never suppresses RAM or swap safety rows")
    func safetyRowsRemainVisible() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent("Views/Chat/FloatingInputCard.swift"),
            encoding: .utf8
        )
        let anchor = try #require(source.range(of: "if !showVoiceOverlay"))
        let tail = String(source[anchor.lowerBound...])
        let end = try #require(tail.range(of: "// Read-only screen-context indicator"))
        let rows = String(tail[..<end.lowerBound])

        #expect(rows.contains("ramPressureRow"))
        #expect(rows.contains("swapPressureRow"))
        #expect(rows.contains("modelSwitchContinuityRow"))
        #expect(!rows.contains("if modelSwitchContinuityWarning != nil"))
    }

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
