import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatQueuedGenerationParityTests {
    @Test(arguments: ["temperature", "topP", "topK", "agent", "outputCap", "thinking", "effort", "template"])
    func changedGenerationDefaultsStayQueued(field: String) async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let active = ChatTurnGenerationControls.capture(activeModelOptions: [:])
            let user = ChatTurn(role: .user, content: "active task")
            user.generationControls = active
            session.turns = [user]
            var pending = active
            switch field {
            case "temperature": pending.temperature = 0
            case "topP": pending.topP = 0.8
            case "topK": pending.topK = 0
            case "agent": pending.agentSettings = .init(minP: 0, repetitionPenalty: 1.1,
                frequencyPenalty: 0, presencePenalty: 0.2, seed: 0, stop: ["END"])
            case "outputCap": pending.maxOutputTokens = 128; pending.agentDefaultsCaptured = true
            case "thinking": pending.agentSettings = .init(enableThinking: false)
            case "effort": pending.agentSettings = .init(reasoningEffort: "low")
            default: pending.agentSettings = .init(templateKwargs: ["format": .string("record")])
            }
            session.queuedSend = QueuedSend(text: "follow-up", attachments: [], generationControls: pending)

            #expect(!session.injectQueuedSteerIfEligible())
            #expect(session.queuedSend?.generationControls == pending)
            #expect(session.turns.map(\.content) == ["active task"])
        }
    }

    @Test func unchangedDefaultsStillSteerAfterReasoningResolution() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            var active = ChatTurnGenerationControls.capture(activeModelOptions: [:])
            active.agentSettings = .init(topK: 0, seed: 0, enableThinking: false)
            active.maxOutputTokens = 128
            active.agentDefaultsCaptured = true
            var pending = active
            active.hasResolvedReasoning = true
            pending.hasResolvedReasoning = false
            let user = ChatTurn(role: .user, content: "active task")
            user.generationControls = active
            // An earlier steer carries no new settings. It must not hide the
            // original turn's frozen controls at the next tool boundary.
            session.turns = [user, ChatTurn(role: .user, content: "earlier steer")]
            session.queuedSend = QueuedSend(text: "follow-up", attachments: [], generationControls: pending)

            #expect(session.injectQueuedSteerIfEligible())
            #expect(session.queuedSend == nil)
            #expect(session.turns.last?.content == "follow-up")
        }
    }

    @Test func changedDefaultsDoNotConsumeComposerWhenRemoteSteerArrives() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let active = ChatTurnGenerationControls.capture(activeModelOptions: [:])
            let user = ChatTurn(role: .user, content: "active task")
            user.generationControls = active
            session.turns = [user]
            var pending = active
            pending.agentSettings = .init(seed: 0)
            session.queuedSend = QueuedSend(text: "follow-up", attachments: [], generationControls: pending)
            session.remoteSteers = ["remote update"]

            #expect(session.injectQueuedSteerIfEligible())
            #expect(session.turns.last?.content == "remote update")
            #expect(session.queuedSend?.text == "follow-up")
            #expect(session.remoteSteers.isEmpty)
        }
    }

    @Test func emptyTemplateOverrideIsExplicitAndCannotSteerOrDisappearOnWorkspace() async throws {
        let overrides = ChatTurnOverrides(templateKwargs: [:])
        #expect(!overrides.isEmpty)
        #expect(throws: (any Error).self) { try overrides.validate(forWorkspaceAgent: true) }
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            var pending = ChatTurnGenerationControls.capture(activeModelOptions: [:])
            pending.overrides = overrides
            session.queuedSend = QueuedSend(text: "clear inherited template parameters", attachments: [],
                generationControls: pending)
            #expect(!session.injectQueuedSteerIfEligible())
            #expect(session.queuedSend?.generationControls?.overrides.templateKwargs == [:])
            #expect(session.turns.isEmpty)
        }
    }

    @Test func canonicallyEquivalentTemplateTextStillRequiresItsOwnRequest() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            var active = ChatTurnGenerationControls.capture(activeModelOptions: [:])
            active.agentSettings = .init(templateKwargs: ["label": .string("\u{e9}")])
            let user = ChatTurn(role: .user, content: "active task")
            user.generationControls = active
            session.turns = [user]
            var pending = active
            pending.agentSettings = .init(templateKwargs: ["label": .string("e\u{301}")])
            session.queuedSend = QueuedSend(text: "follow-up", attachments: [], generationControls: pending)
            #expect(!session.injectQueuedSteerIfEligible())
            #expect(session.queuedSend != nil)
        }
    }
}
