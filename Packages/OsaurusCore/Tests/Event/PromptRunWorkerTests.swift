//
//  PromptRunWorkerTests.swift
//  OsaurusCoreTests
//
//  The "Ask a Model" action: one tool-less generation with no agent, the
//  trigger's content wrapped as untrusted, saved as an automation chat
//  keyed by the event.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct PromptRunWorkerTests {
    private final class Captured: @unchecked Sendable {
        var model: String?
        var messages: [ChatMessage] = []
        var source: RequestSource?
    }

    private static func event(model: String? = "probe-model") -> OsaurusEvent {
        OsaurusEvent(
            name: "Issue note \(UUID().uuidString.prefix(6))",
            source: .webhook(WebhookSourceConfig()),
            action: .prompt(PromptEventAction(instructions: "Summarize {{webhook.body.title}}.", model: model)))
    }

    private static func input(_ event: OsaurusEvent) -> AutomationWorkInput {
        AutomationWorkInput(
            event: event,
            occurrence: EventOccurrence(
                eventId: event.id,
                payload: .object(["webhook": .object(["body": .object(["title": .string("Crash on launch")])])])))
    }

    @Test func oneToolLessAnswerIsSavedAsAnAutomationChat() async throws {
        let event = Self.event()
        let captured = Captured()
        var started: UUID?
        let taskId = UUID()
        let outcome = await PromptRunWorker.run(
            taskId: taskId, input: Self.input(event), onStarted: { session, run in
                started = session
                #expect(run == nil)
            },
            generate: { model, messages, source in
                captured.model = model
                captured.messages = messages
                captured.source = source
                return .init(content: "A crash at launch.", reasoning: "The title names the crash.")
            })
        let sessionId = try #require(outcome.sessionId)
        defer { ChatSessionStore.delete(id: sessionId) }

        #expect(outcome.status == .succeeded)
        #expect(outcome.summary["model"] == "probe-model")
        #expect(started == sessionId)
        #expect(captured.model == "probe-model")
        #expect(captured.source == event.sourceKind.descriptor.requestSource)
        #expect(captured.messages.count == 1)
        let prompt = try #require(captured.messages.first?.content)
        #expect(prompt.hasPrefix("Summarize Crash on launch."))
        #expect(prompt.contains(ChannelRemoteSafetyGate.untrustedEnvelopeOpen))

        let session = try #require(ChatSessionStore.load(id: sessionId))
        #expect(session.source == .automation)
        #expect(session.automationKind == .webhook)
        #expect(session.externalSessionKey == event.id.uuidString)
        #expect(session.dispatchTaskId == taskId)
        #expect(session.agentId == nil)
        #expect(session.turns.map(\.role) == [.user, .assistant])
        #expect(session.turns.last?.content == "A crash at launch.")
        #expect(session.turns.last?.thinking == "The title names the crash.")
    }

    @Test func aFailedGenerationKeepsTheQuestionAndReportsTheError() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "model went away" } }
        let outcome = await PromptRunWorker.run(
            taskId: UUID(), input: Self.input(Self.event()), onStarted: { _, _ in },
            generate: { _, _, _ in throw Boom() })
        let sessionId = try #require(outcome.sessionId)
        defer { ChatSessionStore.delete(id: sessionId) }
        #expect(outcome.status == .failed)
        #expect(outcome.error == "model went away")
        #expect(ChatSessionStore.load(id: sessionId)?.turns.map(\.role) == [.user])
    }

    @Test func nonPromptActionsAreNotItsJob() async {
        let event = OsaurusEvent(
            name: "Agent", source: .webhook(WebhookSourceConfig()),
            action: .agent(AgentEventAction(target: .local(UUID()), instructions: "x")))
        let outcome = await PromptRunWorker.run(
            taskId: UUID(), input: Self.input(event), onStarted: { _, _ in Issue.record("must not start") },
            generate: { _, _, _ in
                Issue.record("must not generate")
                return .init(content: "")
            })
        #expect(outcome.status == .suppressed)
    }

    @Test func theActionModelWinsOverTheDefaults() {
        #expect(PromptRunWorker.resolvedModel(PromptEventAction(instructions: "x", model: " chosen ")) == "chosen")
        #expect(
            PromptRunWorker.resolvedModel(PromptEventAction(instructions: "x", model: nil))
                == (ChatConfigurationStore.load().defaultModel ?? DefaultAgentConfigurationStore.load().defaultModel))
    }
}
