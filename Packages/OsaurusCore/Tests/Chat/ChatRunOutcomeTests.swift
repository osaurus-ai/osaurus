//
//  ChatRunOutcomeTests.swift
//  osaurus
//
//  How a chat run that ended without an answer is classified, persisted
//  and rendered: from envelope fields, thrown error types and loop exits.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ChatRunOutcomeTests {
    private static let gib: UInt64 = 1 << 30

    private static func stableRefusal(pressure: String = "warning") -> String {
        ToolEnvelope.failure(
            kind: .rejected,
            message: "configurator_handoff did not run: there is not enough free memory.",
            tool: "configurator_handoff",
            retryable: false,
            metadata: [
                "admission": "stable_memory_refusal",
                "refreshed_capacity": 0,
                "memory_decision": [
                    "canonical_model": "raptor-0.7-4b-jang_6m",
                    "target_already_resident": true,
                    "target_load_bytes": 4 * gib,
                    "per_child_bytes": 2 * gib,
                    "reclaimable_bytes": 3 * gib,
                    "os_reserve_bytes": 3 * gib,
                    "memory_pressure": pressure,
                    "limited_by": ["memoryCapacity"],
                ] as [String: Any],
                "setting_id": ChatRunOutcome.delegationMemoryCheckSettingId,
            ]
        )
    }

    @Test func stableMemoryRefusalIsMemoryRefusedWithDecisionFacts() throws {
        let outcome = try #require(ChatRunOutcome.classify(envelope: Self.stableRefusal()))
        #expect(outcome.kind == .memoryRefused)
        #expect(outcome.cause == .memory)
        #expect(outcome.tool == "configurator_handoff")
        #expect(outcome.retryable)
        #expect(outcome.settingId == ChatRunOutcome.delegationMemoryCheckSettingId)
        let labels = outcome.facts.map(\.label)
        #expect(labels.first == L("Model"))
        #expect(labels.contains(L("Needed for this run")))
        #expect(labels.contains(L("Kept free for macOS")))
        // A resident target is not charged its load footprint again.
        let needed = outcome.facts.first { $0.label == L("Needed for this run") }?.value
        #expect(needed == ChatRunOutcome.bytes(2 * Self.gib))
        #expect(outcome.facts.first { $0.label == L("Memory pressure") }?.value == L("Elevated"))
        #expect(outcome.facts.first { $0.label == L("Limited by") }?.value == L("Free memory"))
        #expect(outcome.memoryPressure == "warning")
        #expect(outcome.limitedBy == ["memoryCapacity"])
    }

    @Test func admissionTimeoutIsModelBusy() throws {
        let envelope = ToolEnvelope.failure(
            kind: .unavailable, message: "busy", tool: "spawn", retryable: true,
            metadata: ["admission": "timeout"])
        let outcome = try #require(ChatRunOutcome.classify(envelope: envelope))
        #expect(outcome.kind == .modelBusy)
        #expect(!outcome.canFreeMemory)
    }

    @Test func unrelatedFailuresAndSuccessesAreNotOutcomes() {
        #expect(ChatRunOutcome.classify(envelope: ToolEnvelope.failure(kind: .invalidArgs, message: "bad")) == nil)
        #expect(ChatRunOutcome.classify(envelope: ToolEnvelope.success(result: "ok")) == nil)
        // Message text alone never classifies.
        let textOnly = ToolEnvelope.failure(kind: .executionError, message: "not enough free memory")
        #expect(ChatRunOutcome.classify(envelope: textOnly) == nil)
    }

    @Test func thrownMemoryErrorsCrossTheEnvelopeBoundary() throws {
        let refusal = ModelRuntime.MemorySafetyLoadRefusal(
            modelName: "big-model", estimatedWorkingSetBytes: 40 * Self.gib,
            loadBudgetBytes: 24 * Self.gib, issues: ["over budget"])
        let direct = try #require(ChatRunOutcome.classify(error: refusal))
        #expect(direct.kind == .memoryLoadRefused)
        #expect(direct.settingId == ChatRunOutcome.memorySafetySettingId)
        #expect(!direct.canFreeMemory)

        let envelope = SubagentSession.envelope(for: refusal, tool: "spawn")
        let viaEnvelope = try #require(ChatRunOutcome.classify(envelope: envelope))
        #expect(viaEnvelope.kind == .memoryLoadRefused)
        #expect(viaEnvelope.facts.map(\.value).contains("big-model"))

        let handoff = ChatResidencyHandoff.HandoffError.insufficientMemory(neededGB: 6, availableGB: 2)
        #expect(ChatRunOutcome.classify(error: handoff)?.kind == .memoryRefused)
        let busy = SubagentSession.envelope(for: ChatResidencyHandoff.HandoffError.chatBusy, tool: "spawn")
        #expect(ChatRunOutcome.classify(envelope: busy)?.kind == .modelBusy)
    }

    @Test func unrelatedErrorsAreNotOutcomes() {
        struct Other: Error {}
        #expect(ChatRunOutcome.classify(error: Other()) == nil)
        #expect(ChatRunOutcome.classify(error: CancellationError()) == nil)
    }

    @Test(arguments: [
        (AgentToolLoop.Exit.lengthExhausted, ChatRunOutcome.Kind.outputLimit),
        (.truncatedToolCallExhausted, .outputLimit),
        (.incompleteReasoningExhausted, .reasoningOnly),
        (.emptyResponseExhausted, .emptyResponse),
        (.overBudget, .contextTooLong),
        (.iterationCapReached, .stepLimit),
    ])
    func loopExitsMapToKinds(exit: AgentToolLoop.Exit, kind: ChatRunOutcome.Kind) {
        #expect(ChatRunOutcome.classify(exit: exit)?.kind == kind)
    }

    @Test func answeredOrStoppedExitsAreNotOutcomes() {
        for exit in [AgentToolLoop.Exit.finalResponse, .cancelled, .toolRejected, .endedBySurface] {
            #expect(ChatRunOutcome.classify(exit: exit) == nil)
        }
    }

    @Test func loopFallbacksMapToKinds() {
        #expect(ChatRunOutcome.classify(loopFallback: AgentToolLoop.lengthExhaustedFallback)?.kind == .outputLimit)
        #expect(ChatRunOutcome.classify(loopFallback: AgentToolLoop.lengthExhaustedFallback, architect: true) == nil)
        #expect(ChatRunOutcome.classify(loopFallback: AgentToolLoop.truncatedToolCallFallback)?.kind == .outputLimit)
        #expect(ChatRunOutcome.classify(loopFallback: AgentToolLoop.emptyTurnFallback)?.kind == .emptyResponse)
        #expect(ChatRunOutcome.classify(loopFallback: AgentToolLoop.emptyToolTaskFallback)?.kind == .emptyResponse)
        #expect(ChatRunOutcome.classify(loopFallback: "A desktop summary") == nil)
    }

    @Test func stopReasonRoundTripsEveryKind() {
        for kind in ChatRunOutcome.Kind.allCases {
            let outcome = ChatRunOutcome(kind: kind)
            #expect(ChatRunOutcome(stopReason: outcome.stopReason)?.kind == kind)
        }
        #expect(ChatRunOutcome(stopReason: "tool_rejected") == nil)
        #expect(ChatRunOutcome(stopReason: "outcome:unknown") == nil)
        #expect(ChatRunOutcome(stopReason: nil) == nil)
    }

    @Test func titleIsAppendedOnceAndRemovedForRendering() {
        let outcome = ChatRunOutcome(kind: .outputLimit)
        #expect(outcome.contentAppendingTitle("") == outcome.title)
        let partial = outcome.contentAppendingTitle("Partial answer")
        #expect(partial == "Partial answer\n\n" + outcome.title)
        #expect(outcome.contentAppendingTitle(partial) == partial)
        #expect(outcome.contentRemovingTitle(partial) == "Partial answer")
        #expect(outcome.contentRemovingTitle(outcome.title).isEmpty)
        #expect(outcome.contentRemovingTitle("Unrelated") == "Unrelated")
    }

    @Test func freeUpMemoryNeedsSomethingToFree() {
        var outcome = ChatRunOutcome(kind: .memoryRefused)
        #expect(!outcome.canFreeMemory)
        outcome.freeableModels = ["other-model"]
        #expect(outcome.canFreeMemory)
        outcome.freeableModels = []
        outcome.hasReclaimableCache = true
        #expect(outcome.canFreeMemory)
    }

    @Test func contextTooLongLinksTheCapOnlyWhenItWasTheLimit() {
        var outcome = ChatRunOutcome(kind: .contextTooLong)
        #expect(!outcome.retryable)
        #expect(outcome.settingId == nil)
        outcome.contextLimitedByCap = true
        #expect(outcome.settingId == ChatRunOutcome.contextWindowCapSettingId)
    }

    @Test func linkedSettingsExistInTheCatalog() {
        let ids = Set(SettingsSearchIndex.entries.map(\.id))
        for kind in ChatRunOutcome.Kind.allCases {
            var outcome = ChatRunOutcome(kind: kind)
            outcome.contextLimitedByCap = true
            if let id = outcome.settingId { #expect(ids.contains(id), "\(kind) links \(id)") }
        }
    }

    @MainActor
    @Test func turnKeepsLiveDetailsAndPersistsTheKind() {
        let turn = ChatTurn(role: .assistant, content: "")
        var outcome = ChatRunOutcome(kind: .memoryRefused, facts: [.init(label: "Model", value: "m")])
        outcome.freeableModels = ["idle"]
        turn.runOutcome = outcome
        #expect(turn.terminalStopReason == "outcome:memory_refused")
        #expect(turn.runOutcome == outcome)

        let reloaded = ChatTurn(role: .assistant, content: "")
        reloaded.terminalStopReason = turn.terminalStopReason
        #expect(reloaded.runOutcome?.kind == .memoryRefused)
        #expect(reloaded.runOutcome?.facts.isEmpty == true)
    }

    @MainActor
    @Test func noticeBlockReplacesTheOutcomeSentence() {
        let outcome = ChatRunOutcome(kind: .outputLimit)
        let turn = ChatTurn(role: .assistant, content: outcome.contentAppendingTitle("Partial answer"))
        turn.runOutcome = outcome
        let blocks = ContentBlock.generateBlocks(from: [turn], streamingTurnId: nil, agentName: "Assistant")

        let paragraphs = blocks.compactMap { block -> String? in
            guard case let .paragraph(_, text, _, _) = block.kind else { return nil }
            return text
        }
        #expect(paragraphs == ["Partial answer"])
        let notices = blocks.compactMap { block -> ChatRunOutcome? in
            guard case let .runNotice(turnId, noticed) = block.kind, turnId == turn.id else { return nil }
            return noticed
        }
        #expect(notices.map(\.kind) == [.outputLimit])

        let empty = ChatTurn(role: .assistant, content: ChatRunOutcome(kind: .memoryRefused).title)
        empty.runOutcome = ChatRunOutcome(kind: .memoryRefused)
        let emptyBlocks = ContentBlock.generateBlocks(from: [empty], streamingTurnId: nil, agentName: "Assistant")
        #expect(!emptyBlocks.contains { if case .paragraph = $0.kind { return true } else { return false } })
        #expect(emptyBlocks.contains { if case .runNotice = $0.kind { return true } else { return false } })
    }

    @MainActor
    @Test func streamingTurnShowsNoNotice() {
        let turn = ChatTurn(role: .assistant, content: "")
        turn.runOutcome = ChatRunOutcome(kind: .outputLimit)
        let blocks = ContentBlock.generateBlocks(from: [turn], streamingTurnId: turn.id, agentName: "Assistant")
        #expect(!blocks.contains { if case .runNotice = $0.kind { return true } else { return false } })
    }
}
