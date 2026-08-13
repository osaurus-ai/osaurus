import Foundation
import Testing

@testable import OsaurusCore

/// Issue #2327. Ornith-1.0-9B, offered tools and asked for the current time,
/// emits `<think>…"I have a tool called get_current_time… Let me call it."…
/// </think><|im_end|>` — blank content, non-blank thinking, natural `stop`, and
/// no tool call. Deterministic at both quants.
///
/// `requiresVisibleFinalResponse` is `hasStructuredToolWork || isRemoteAgentTarget`,
/// so on the FIRST turn — tools offered but none executed yet — it is false.
/// That makes `classifyTerminal` skip both reasoning guards and fall through to
/// `.finalResponse`: the run ends as a success with nothing the user can use.
@Suite("Reasoning-only turn classification")
struct ReasoningOnlyTurnClassificationTests {

    // `AgentLoopModelStep` carries associated values, so it is not Equatable.
    func isFinal(_ s: AgentLoopModelStep) -> Bool {
        if case .finalResponse = s { return true }
        return false
    }
    func isIncompleteReasoning(_ s: AgentLoopModelStep) -> Bool {
        if case .incompleteReasoning = s { return true }
        return false
    }
    func isEmpty(_ s: AgentLoopModelStep) -> Bool {
        if case .emptyResponse = s { return true }
        return false
    }

    @Test("a reasoning-only turn with tools offered is not a final response")
    func reasoningOnlyWithToolsIsNotFinal() {
        let terminal = AgentLoopModelStep.classifyTerminal(
            contentIsBlank: true,
            thinkingIsBlank: false,
            stopReason: "stop",
            unclosedReasoning: false,
            // First turn: tools are advertised, none has run yet.
            requiresVisibleFinalResponse: AgentLoopVisibleResponsePolicy
                .requiresVisibleFinalResponse(
                    hasStructuredToolWork: false, isRemoteAgentTarget: false),
            toolsWereOffered: true
        )
        #expect(!isFinal(terminal),
            "a turn that produced no content and no tool call was classified as a completed answer")
        #expect(isIncompleteReasoning(terminal),
            "expected the recoverable reasoning-only reason, got \(terminal)")
    }

    /// The existing policy is deliberate for plain chats: a reasoning-only
    /// bundle with no tools available may return on its reasoning rail, and
    /// this must keep working.
    @Test("a reasoning-only turn with no tools offered still completes")
    func reasoningOnlyWithoutToolsStillFinal() {
        let terminal = AgentLoopModelStep.classifyTerminal(
            contentIsBlank: true,
            thinkingIsBlank: false,
            stopReason: "stop",
            unclosedReasoning: false,
            requiresVisibleFinalResponse: false,
            toolsWereOffered: false
        )
        #expect(isFinal(terminal),
            "reasoning-only bundles with no tools must still be allowed to finish")
    }

    @Test("structured tool work still forces a visible answer") 
    func afterToolWorkStillRequiresAnswer() {
        let terminal = AgentLoopModelStep.classifyTerminal(
            contentIsBlank: true,
            thinkingIsBlank: false,
            stopReason: "stop",
            unclosedReasoning: false,
            requiresVisibleFinalResponse: AgentLoopVisibleResponsePolicy
                .requiresVisibleFinalResponse(
                    hasStructuredToolWork: true, isRemoteAgentTarget: false),
            toolsWereOffered: true
        )
        #expect(isIncompleteReasoning(terminal))
    }

    @Test("a fully empty turn is still emptyResponse")
    func fullyEmptyUnchanged() {
        let terminal = AgentLoopModelStep.classifyTerminal(
            contentIsBlank: true,
            thinkingIsBlank: true,
            stopReason: "stop",
            unclosedReasoning: false,
            requiresVisibleFinalResponse: false,
            toolsWereOffered: true
        )
        #expect(isEmpty(terminal))
    }

    @Test("a normal answer is unaffected")
    func normalAnswerUnaffected() {
        let terminal = AgentLoopModelStep.classifyTerminal(
            contentIsBlank: false,
            thinkingIsBlank: false,
            stopReason: "stop",
            unclosedReasoning: false,
            requiresVisibleFinalResponse: false,
            toolsWereOffered: true
        )
        #expect(isFinal(terminal))
    }
}
