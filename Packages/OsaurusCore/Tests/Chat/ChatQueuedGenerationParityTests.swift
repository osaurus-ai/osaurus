import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatQueuedGenerationParityTests {
    @Test(arguments: ["temperature", "topP", "topK", "minP", "repetition", "frequency", "presence",
        "seed", "stop", "outputCap", "thinking", "effort", "template", "speculation", "modelThinking", "modelEffort"])
    func changedGenerationDefaultsStayQueued(field: String) async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            var active = ChatTurnGenerationControls.capture(activeModelOptions: [:])
            active.agentDefaultsCaptured = true
            let user = ChatTurn(role: .user, content: "active task")
            user.generationControls = active
            session.turns = [user]
            var pending = active
            switch field {
            case "temperature": pending.temperature = 0
            case "topP": pending.topP = 0.8
            case "topK": pending.topK = 0
            case "minP": pending.agentSettings = .init(minP: 0)
            case "repetition": pending.agentSettings = .init(repetitionPenalty: 1.1)
            case "frequency": pending.agentSettings = .init(frequencyPenalty: 0)
            case "presence": pending.agentSettings = .init(presencePenalty: 0.2)
            case "seed": pending.agentSettings = .init(seed: 0)
            case "speculation": pending.agentSettings = .init(speculativeDecoding: false)
            case "stop": pending.agentSettings = .init(stop: [])
            case "outputCap": pending.maxOutputTokens = 128
            case "thinking": pending.agentSettings = .init(enableThinking: false)
            case "effort": pending.agentSettings = .init(reasoningEffort: "low")
            case "modelThinking":
                pending = .capture(activeModelOptions: ["disableThinking": .bool(true)])
                pending.agentDefaultsCaptured = true
            case "modelEffort":
                pending = .capture(activeModelOptions: ["reasoningEffort": .string("low")])
                pending.agentDefaultsCaptured = true
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

    @Test(arguments: [false, true])
    func steeredUserTurnRetainsActiveControlsForRetryAfterPersistence(remoteOnly: Bool) async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            var active = ChatTurnGenerationControls.capture(activeModelOptions: [:])
            active.hasResolvedReasoning = true
            active.temperature = 0
            active.agentSettings = .init(topP: 0.8, seed: 0, enableThinking: false)
            active.maxOutputTokens = 128
            active.agentDefaultsCaptured = true
            let user = ChatTurn(role: .user, content: "active task")
            user.generationControls = active
            session.turns = [user]
            if remoteOnly {
                session.remoteSteers = ["remote update"]
            } else {
                session.queuedSend = QueuedSend(text: "follow-up", attachments: [], generationControls: active)
            }
            #expect(session.injectQueuedSteerIfEligible())
            #expect(session.turns.last?.generationControls == active)
            session.save()
            let id = try #require(session.sessionId)
            let restored = try #require(ChatSessionStore.load(id: id))
            #expect(restored.turns.last?.generationControls == active)
        }
    }
}
