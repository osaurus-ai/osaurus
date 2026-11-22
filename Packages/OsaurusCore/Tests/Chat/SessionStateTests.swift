//
//  SessionStateTests.swift
//  OsaurusCoreTests
//
//  The Orchestrator's session state is the harness's: no tool writes it, a
//  finished turn keeps the previous object marked stale until extraction
//  replaces it, `in_flight` is always the harness's, and the block rides
//  with the user turn.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SessionStateTests {

    @Test
    func theOrchestratorIsNeverAskedToWriteState() {
        #expect(!ToolRegistry.orchestratorRoutingToolNames.contains("state"))
        #expect(!DefaultAgentSystemPromptBuilder.orchestratorRequiredToolNames.contains("state"))
        #expect(!OrchestratorTurnBlock.presentingTurnToolNames.contains("state"))
        #expect(!ToolRegistry.shared.isRegistered("state"))
        let block = OrchestratorTurnBlock.injectedBlock(state: SessionState(goal: "g").rendered(), dispatchedTool: nil)
        #expect(!block.contains("`state`"))
        for result in [
            HandoffResult.answer("a"), .applied("b"), .needsSetup("c"), .declined("d"),
            .awaitingUser(RunRef(runId: "r", workflow: "w", status: "awaiting_user"), question: "q"),
        ] {
            let envelope = result.envelope(tool: "configurator_handoff")
            #expect(!envelope.contains("call state"), "\(envelope)")
            #expect(!envelope.contains("Then call state"), "\(envelope)")
        }
    }

    @Test
    func aFinishedTurnKeepsThePreviousObjectMarkedStale() {
        let registry = SessionStateRegistry.shared
        let sid = "state-stale-\(UUID().uuidString)"
        let previous = SessionState(goal: "plan a trip", decisions: ["by train"])
        registry.seed(sessionId: sid, state: previous)

        let next = registry.finishTurn(sessionId: sid, inFlight: [])
        #expect(next.goal == "plan a trip")
        #expect(next.decisions == ["by train"])
        #expect(next.stale)
        #expect(next.rendered().contains("(stale: not updated last turn)"))

        let refreshed = registry.applyExtracted(sessionId: sid, state: SessionState(goal: "plan a trip"))
        #expect(refreshed?.stale == false)
        #expect(refreshed?.rendered().contains("stale") == false)
    }

    @Test
    func inFlightIsTheHarnessesWhateverExtractionWrites() {
        let registry = SessionStateRegistry.shared
        let sid = "state-inflight-\(UUID().uuidString)"
        let harness = [RunRef(runId: "r-1", workflow: "Weekly report", status: "running")]
        registry.finishTurn(sessionId: sid, inFlight: harness)
        let extracted = SessionStateExtraction.parse(
            #"{"goal":"g","in_flight":[{"run_id":"fake","workflow":"Invented","status":"running"}],"stale":true}"#)
        let next = registry.applyExtracted(sessionId: sid, state: extracted ?? .empty)
        #expect(next?.inFlight == harness)
        #expect(next?.stale == false)
        #expect(next?.rendered().contains("Weekly report (running, run r-1)") == true)
        #expect(next?.rendered().contains("Invented") == false)

        let quiet = registry.finishTurn(sessionId: sid, inFlight: [])
        #expect(quiet.inFlight.isEmpty, "a finished run leaves in_flight on the next turn")
    }

    @Test
    func extractedObjectsAreBounded() {
        let long = String(repeating: "a", count: SessionState.maxItemCharacters + 50)
        let items = (0..<20).map { "\"item \($0)\"" }.joined(separator: ",")
        let state = SessionState.fromModelArguments(#"{"goal":"\#(long)","facts":[\#(items)],"decisions":"one"}"#)
        #expect(state?.facts.count == SessionState.maxItemsPerList)
        #expect(state?.goal?.count == SessionState.maxItemCharacters + 1)
        #expect(state?.decisions == ["one"])
    }

    @Test
    func persistedStateRoundTripsOnTheSessionRecord() throws {
        let state = SessionState(
            goal: "g", decisions: ["d"], facts: ["f"], openItems: ["o"],
            inFlight: [RunRef(runId: "r", workflow: "w", status: "running")], stale: true)
        #expect(SessionState.decoded(state.encoded()) == state)

        var data = ChatSessionData(id: UUID(), title: "t")
        data.sessionState = state
        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(ChatSessionData.self, from: encoded)
        #expect(decoded.sessionState == state)
        #expect(SyncConversationMapper.sessionOwnedKeys.contains("sessionState"))
        let appData = try SyncConversationMapper.sessionAppData(for: data)
        let object = try #require(try JSONSerialization.jsonObject(with: appData) as? [String: Any])
        let synced = try #require(object["sessionState"] as? [String: Any])
        #expect(synced["goal"] as? String == "g")
    }

    /// The block rides the latest user message, after its frozen prefix and
    /// before the text, so the system prompt stays byte-stable while the
    /// state changes.
    @Test
    func stateRidesTheLatestUserMessageAfterItsFrozenPrefix() throws {
        let block = SessionState(goal: "ship it").rendered()
        let frozen = SystemPromptComposer.composeInjectedUserPrefix(memorySection: "remembered", screenContext: nil)
        let message = ChatSession.userMessage(
            ChatMessage(role: "user", content: "next step"), frozenPrefix: frozen, sessionState: block)
        let text = try #require(message.content)
        let memory = try #require(text.range(of: "[/Memory]"))
        let state = try #require(text.range(of: "[Session state]"))
        let request = try #require(text.range(of: "next step"))
        #expect(memory.upperBound <= state.lowerBound)
        #expect(state.upperBound <= request.lowerBound)
        #expect(text.contains("goal: ship it"))
    }

    /// The injected prefix alone carries no state; `userMessage` without a
    /// state block is the prefix plus the text.
    @Test
    func injectedPrefixAloneCarriesNoState() throws {
        let frozen = SystemPromptComposer.composeInjectedUserPrefix(memorySection: "remembered", screenContext: nil)
        #expect(frozen?.contains("[Session state]") == false)
        let older = ChatSession.userMessage(
            ChatMessage(role: "user", content: "earlier"), frozenPrefix: frozen, sessionState: nil)
        #expect(older.content?.contains("[Session state]") == false)
        #expect(older.content == (frozen ?? "") + "earlier")
    }

    /// The state block is frozen with the turn it was sent on. Freezing it
    /// leaves the sending request's bytes unchanged, and every later request
    /// replays those same bytes for that turn, so the conversation prefix
    /// through it stays reusable by the prefix cache. Before, a follow-up's
    /// copy of the previous user message lost its state block and the prompt
    /// diverged right after the system prompt on every follow-up.
    @Test
    func stateIsFrozenWithTheTurnItWasSentOn() throws {
        let injected = SystemPromptComposer.composeInjectedUserPrefix(memorySection: "remembered", screenContext: nil)
        let block = SessionState(goal: "ship it").rendered()
        let base = ChatMessage(role: "user", content: "next step")

        // What the latest turn used to be sent as: prefix + live state + text.
        let sentBefore = ChatSession.userMessage(base, frozenPrefix: injected, sessionState: block)
        // What it is sent as now: the frozen prefix already holds the state.
        let frozen = try #require(ChatSession.frozenUserPrefix(injected: injected, sessionState: block))
        let sentNow = ChatSession.userMessage(base, frozenPrefix: frozen, sessionState: nil)
        #expect(sentNow.content == sentBefore.content)

        // A later request replays the turn with no live state: same bytes.
        let replayed = ChatSession.userMessage(base, frozenPrefix: frozen, sessionState: nil)
        #expect(replayed.content == sentBefore.content)
        #expect(replayed.content?.contains("goal: ship it") == true)
    }

    @Test
    func frozenUserPrefixComposition() {
        #expect(ChatSession.frozenUserPrefix(injected: "P\n\n", sessionState: nil) == "P\n\n")
        #expect(ChatSession.frozenUserPrefix(injected: "P\n\n", sessionState: "  \n") == "P\n\n")
        #expect(ChatSession.frozenUserPrefix(injected: nil, sessionState: nil) == nil)
        #expect(ChatSession.frozenUserPrefix(injected: nil, sessionState: "S") == "S\n\n")
        #expect(ChatSession.frozenUserPrefix(injected: "P\n\n", sessionState: "S\n") == "P\n\nS\n\n")
    }

    // MARK: Extraction after each settled turn

    @Test
    func extractionRunsAfterEverySettledTurn() {
        #expect(SessionStateExtraction.applies(interrupted: false, lastStepEndedOn: .finalText))
        #expect(SessionStateExtraction.applies(interrupted: false, lastStepEndedOn: .iterationCap))
        #expect(!SessionStateExtraction.applies(interrupted: true, lastStepEndedOn: .finalText))
        #expect(!SessionStateExtraction.applies(interrupted: false, lastStepEndedOn: .clarify))
        #expect(!SessionStateExtraction.applies(interrupted: false, lastStepEndedOn: .awaitingUser))
        #expect(!SessionStateExtraction.applies(interrupted: false, lastStepEndedOn: nil))
    }

    @Test
    func anExtractedAnswerIsReadAsTheObjectAndAnEmptyOneIsNoWrite() {
        let fenced = "```json\n{\"goal\":\"ship it\",\"facts\":[\"port 1337\"],\"in_flight\":[{\"run_id\":\"x\"}]}\n```"
        let state = SessionStateExtraction.parse(fenced)
        #expect(state?.goal == "ship it")
        #expect(state?.facts == ["port 1337"])
        #expect(state?.inFlight == [])
        #expect(SessionStateExtraction.parse("{}") == nil)
        #expect(SessionStateExtraction.parse("The user wants to ship it.") == nil)
    }

    @Test
    func thePromptCarriesOnlyTheWritableFieldsAndKeepsTheUserLine() {
        let previous = SessionState(
            goal: "old", facts: ["f"], inFlight: [RunRef(runId: "r", workflow: "w", status: "running")], stale: true)
        let turn =
            [SessionStateExtraction.Line(speaker: "User", text: "first ask")]
            + (0..<40).map { SessionStateExtraction.Line(speaker: "Tool result", text: "line \($0)") }
        let prompt = SessionStateExtraction.prompt(previous: previous, turn: turn)
        #expect(prompt.contains(#""goal":"old""#))
        #expect(!prompt.contains("in_flight"))
        #expect(!prompt.contains("stale"))
        #expect(prompt.contains("User: first ask"))
        #expect(prompt.contains("line 39"))
        #expect(!prompt.contains("line 0\n"))
        #expect(SessionStateExtraction.clipped(turn).count == SessionStateExtraction.maxLines)
    }

    @Test
    func anExtractedObjectReplacesOnlyAStaleOneAndKeepsTheHarnessRuns() {
        let registry = SessionStateRegistry.shared
        let sid = "state-extract-\(UUID().uuidString)"
        let runs = [RunRef(runId: "r1", workflow: "Digest", status: "running")]
        registry.seed(sessionId: sid, state: SessionState(goal: "old"))
        let stale = registry.finishTurn(sessionId: sid, inFlight: runs)
        #expect(stale.stale)

        let applied = registry.applyExtracted(
            sessionId: sid, state: SessionState(goal: "new", inFlight: [], stale: true))
        #expect(applied?.goal == "new")
        #expect(applied?.stale == false)
        #expect(applied?.inFlight == runs)
        #expect(registry.state(for: sid).goal == "new")

        // An object that is no longer stale: a late extraction changes nothing.
        #expect(registry.applyExtracted(sessionId: sid, state: SessionState(goal: "late")) == nil)
        #expect(registry.state(for: sid).goal == "new")
    }
}
