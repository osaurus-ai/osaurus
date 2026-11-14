//
//  StateToolTests.swift
//  OsaurusCoreTests
//
//  The Orchestrator's session state: a `state` call replaces the whole
//  object (last call in a turn wins), a turn without one keeps the previous
//  object marked stale, `in_flight` is always the harness's, and the block
//  rides with the user turn.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct StateToolTests {

    private static func callState(_ json: String, sessionId: String, agentId: UUID = Agent.defaultId) async -> String {
        await ChatExecutionContext.$currentAgentId.withValue(agentId) {
            await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
                (try? await StateTool().execute(argumentsJSON: json)) ?? ""
            }
        }
    }

    @Test
    func aStateCallReplacesTheWholeObject() async {
        let registry = SessionStateRegistry.shared
        let sid = "state-replace-\(UUID().uuidString)"
        registry.seed(
            sessionId: sid,
            state: SessionState(goal: "old goal", decisions: ["keep A"], facts: ["fact 1"], openItems: ["todo 1"]))

        let result = await Self.callState(#"{"goal":"new goal","facts":["fact 2"]}"#, sessionId: sid)
        #expect(ToolEnvelope.isSuccess(result))
        let next = registry.finishTurn(sessionId: sid, inFlight: [])
        #expect(next.goal == "new goal")
        #expect(next.facts == ["fact 2"])
        #expect(next.decisions.isEmpty, "a field left out is dropped, never merged")
        #expect(next.openItems.isEmpty)
        #expect(!next.stale)
    }

    @Test
    func theLastCallInATurnWins() async {
        let registry = SessionStateRegistry.shared
        let sid = "state-last-wins-\(UUID().uuidString)"
        _ = await Self.callState(#"{"goal":"first"}"#, sessionId: sid)
        _ = await Self.callState(#"{"goal":"second","open_items":["x"]}"#, sessionId: sid)
        let next = registry.finishTurn(sessionId: sid, inFlight: [])
        #expect(next.goal == "second")
        #expect(next.openItems == ["x"])
    }

    @Test
    func aTurnWithoutAStateCallKeepsThePreviousObjectMarkedStale() {
        let registry = SessionStateRegistry.shared
        let sid = "state-stale-\(UUID().uuidString)"
        let previous = SessionState(goal: "plan a trip", decisions: ["by train"])
        registry.seed(sessionId: sid, state: previous)

        let next = registry.finishTurn(sessionId: sid, inFlight: [])
        #expect(next.goal == "plan a trip")
        #expect(next.decisions == ["by train"])
        #expect(next.stale)
        #expect(next.rendered().contains("(stale: not updated last turn)"))

        registry.recordModelWrite(sessionId: sid, state: SessionState(goal: "plan a trip"))
        let refreshed = registry.finishTurn(sessionId: sid, inFlight: [])
        #expect(!refreshed.stale)
        #expect(!refreshed.rendered().contains("stale"))
    }

    @Test
    func inFlightIsTheHarnessesWhateverTheModelWrites() async {
        let registry = SessionStateRegistry.shared
        let sid = "state-inflight-\(UUID().uuidString)"
        _ = await Self.callState(
            #"{"goal":"g","in_flight":[{"run_id":"fake","workflow":"Invented","status":"running"}],"stale":true}"#,
            sessionId: sid)
        let harness = [RunRef(runId: "r-1", workflow: "Weekly report", status: "running")]
        let next = registry.finishTurn(sessionId: sid, inFlight: harness)
        #expect(next.inFlight == harness)
        #expect(!next.stale)
        #expect(next.rendered().contains("Weekly report (running, run r-1)"))
        #expect(!next.rendered().contains("Invented"))

        let quiet = registry.finishTurn(sessionId: sid, inFlight: [])
        #expect(quiet.inFlight.isEmpty, "a finished run leaves in_flight on the next turn")
    }

    @Test
    func aDiscardedTurnCommitsNothing() async {
        let registry = SessionStateRegistry.shared
        let sid = "state-discard-\(UUID().uuidString)"
        registry.seed(sessionId: sid, state: SessionState(goal: "kept"))
        _ = await Self.callState(#"{"goal":"cancelled turn"}"#, sessionId: sid)
        #expect(registry.hasPendingWrite(sessionId: sid))
        registry.discardPending(sessionId: sid)
        #expect(!registry.hasPendingWrite(sessionId: sid))
        #expect(registry.state(for: sid).goal == "kept")
    }

    @Test
    func onlyTheOrchestratorInAChatMayWriteState() async {
        let custom = await Self.callState(#"{"goal":"g"}"#, sessionId: "s", agentId: UUID())
        #expect(ToolEnvelope.isError(custom))
        let noSession = await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            (try? await StateTool().execute(argumentsJSON: #"{"goal":"g"}"#)) ?? ""
        }
        #expect(ToolEnvelope.isError(noSession))
        let sid = "state-bad-args-\(UUID().uuidString)"
        #expect(ToolEnvelope.isError(await Self.callState("[1,2]", sessionId: sid)))
    }

    @Test
    func modelWritesAreBounded() {
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

    /// State is never frozen with a turn: an older user message replays only
    /// its frozen prefix, so the prompt never holds a stale snapshot.
    @Test
    func olderUserMessagesCarryNoState() throws {
        let frozen = SystemPromptComposer.composeInjectedUserPrefix(memorySection: "remembered", screenContext: nil)
        #expect(frozen?.contains("[Session state]") == false)
        let older = ChatSession.userMessage(
            ChatMessage(role: "user", content: "earlier"), frozenPrefix: frozen, sessionState: nil)
        #expect(older.content?.contains("[Session state]") == false)
        #expect(older.content == (frozen ?? "") + "earlier")
    }

    // MARK: Extraction after a turn without `state`

    @Test
    func extractionRunsOnlyWhereTheForcedStepWould() {
        #expect(SessionStateExtraction.applies(interrupted: false, lastStepEndedOn: .finalText, stateWritten: false))
        #expect(SessionStateExtraction.applies(interrupted: false, lastStepEndedOn: .iterationCap, stateWritten: false))
        #expect(!SessionStateExtraction.applies(interrupted: true, lastStepEndedOn: .finalText, stateWritten: false))
        #expect(!SessionStateExtraction.applies(interrupted: false, lastStepEndedOn: .finalText, stateWritten: true))
        #expect(!SessionStateExtraction.applies(interrupted: false, lastStepEndedOn: .clarify, stateWritten: false))
        #expect(!SessionStateExtraction.applies(interrupted: false, lastStepEndedOn: .awaitingUser, stateWritten: false))
        #expect(!SessionStateExtraction.applies(interrupted: false, lastStepEndedOn: nil, stateWritten: false))
    }

    @Test
    func anExtractedAnswerIsReadLikeAStateCallAndAnEmptyOneIsNoWrite() {
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

        // A later write already landed: the extraction changes nothing.
        #expect(registry.applyExtracted(sessionId: sid, state: SessionState(goal: "late")) == nil)
        #expect(registry.state(for: sid).goal == "new")
    }
}
