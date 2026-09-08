//
//  GroundedKnowledgeClaimCheckTests.swift
//  osaurusTests
//
//  Coverage for the knowledge grounding advisory: a final answer that
//  states counts / dates / contents of a knowledge collection while every
//  knowledge tool call this run failed (and none succeeded) gets the
//  factual `[System Notice]` staged and ONE bounded regeneration. The loop
//  never stops on it, and a successful knowledge read anywhere in the run
//  grounds the answer.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct GroundedKnowledgeClaimCheckTests {

    // MARK: containsCollectionContentClaim

    /// The reported answer, verbatim.
    @Test
    func reportedFabricatedSummary_trips() {
        #expect(
            GroundedKnowledgeClaimCheck.containsCollectionContentClaim(
                "The Obsidian Vault contains 20 documents — 20 of them, all dated 2025. "
                    + "The last entry is 20250318."
            )
        )
    }

    @Test
    func countPhrasings_trip() {
        for text in [
            "There are 312 notes in the vault.",
            "The collection has 5 folders and 48 markdown files.",
            "I found a total of 20 entries.",
            "The knowledge base is organised into three top-level folders.",
            "The newest note is dated March 2025.",
            "It returned 50 files, so the vault holds roughly 50 documents.",
        ] {
            #expect(GroundedKnowledgeClaimCheck.containsCollectionContentClaim(text), "\(text)")
        }
    }

    @Test
    func honestFailure_doesNotTrip() {
        for text in [
            "I could not read the collection: list_knowledge rejected the collection name.",
            "The knowledge tool failed, so I cannot say how many documents the vault contains.",
            "Nothing was returned from the vault — no documents were listed.",
            "The listing is unavailable right now; I was unable to access the Obsidian Vault.",
        ] {
            #expect(!GroundedKnowledgeClaimCheck.containsCollectionContentClaim(text), "\(text)")
        }
    }

    @Test
    func intentAndQuestions_doNotTrip() {
        for text in [
            "Let me list the documents in the vault first.",
            "I'll check how many notes the collection has.",
            "How many documents does the vault contain?",
            "Should I summarise all 20 folders?",
        ] {
            #expect(!GroundedKnowledgeClaimCheck.containsCollectionContentClaim(text), "\(text)")
        }
    }

    @Test
    func unrelatedNumbers_doNotTrip() {
        for text in [
            "The meeting is at 10 and there are 3 agenda points.",
            "Python 3.12 has 4 new features worth noting.",
            "Here is the summary you asked for.",
        ] {
            #expect(!GroundedKnowledgeClaimCheck.containsCollectionContentClaim(text), "\(text)")
        }
    }

    // MARK: Outcome classification

    private static let failedListEnvelope = ToolEnvelope.failure(
        kind: .invalidArgs,
        message: "Unknown collection `knowledge`. Granted collections: Obsidian Vault.",
        field: "collection",
        expected: "one of the agent's granted collection names",
        tool: "list_knowledge",
        retryable: true
    )

    @Test
    func outcomeClassification() {
        #expect(
            GroundedKnowledgeClaimCheck.isFailedKnowledgeOutcome(
                toolName: "list_knowledge", result: Self.failedListEnvelope))
        #expect(
            !GroundedKnowledgeClaimCheck.isGroundedKnowledgeOutcome(
                toolName: "list_knowledge", result: Self.failedListEnvelope))
        let ok = ToolEnvelope.success(tool: "list_knowledge", text: "Found 3 knowledge document(s):")
        #expect(GroundedKnowledgeClaimCheck.isGroundedKnowledgeOutcome(toolName: "list_knowledge", result: ok))
        #expect(!GroundedKnowledgeClaimCheck.isFailedKnowledgeOutcome(toolName: "list_knowledge", result: ok))
        // Other tools never count either way.
        #expect(
            !GroundedKnowledgeClaimCheck.isFailedKnowledgeOutcome(
                toolName: "file_read",
                result: ToolEnvelope.failure(kind: .notFound, message: "x", tool: "file_read")))
        #expect(
            !GroundedKnowledgeClaimCheck.isGroundedKnowledgeOutcome(
                toolName: "file_read", result: ToolEnvelope.success(tool: "file_read", text: "x")))
    }

    // MARK: Granted names from the failure envelope

    @Test
    func grantedNamesParsedFromEnvelope() {
        #expect(
            GroundedKnowledgeClaimCheck.grantedCollectionNames(inFailure: Self.failedListEnvelope)
                == ["Obsidian Vault"])
        let two = ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "Unknown collection `x`. Granted collections: Obsidian Vault, Runbooks v2.1.",
            tool: "list_knowledge"
        )
        #expect(
            GroundedKnowledgeClaimCheck.grantedCollectionNames(inFailure: two)
                == ["Obsidian Vault", "Runbooks v2.1"])
        let none = ToolEnvelope.failure(
            kind: .rejected, message: "Knowledge tools require an active agent context.",
            tool: "list_knowledge")
        #expect(GroundedKnowledgeClaimCheck.grantedCollectionNames(inFailure: none).isEmpty)
    }

    @Test
    func noticeNamesTheGrantedCollectionAndTheTool() {
        let notice = GroundedKnowledgeClaimCheck.ungroundedKnowledgeClaimNotice(
            tool: "list_knowledge", grantedNames: ["Obsidian Vault"])
        #expect(notice.hasPrefix("[System Notice]"))
        #expect(notice.contains("`Obsidian Vault`"))
        #expect(notice.contains("`list_knowledge`"))
        #expect(notice.contains("do not estimate"))
        let bare = GroundedKnowledgeClaimCheck.ungroundedKnowledgeClaimNotice(
            tool: "search_knowledge", grantedNames: [])
        #expect(bare.contains("omitted"))
    }
}

// MARK: - Loop driver

@MainActor
private final class KnowledgeClaimLoopSurface {
    /// Scripted model steps and, per step, the visible text of that
    /// assistant message. Unlike a consume-on-read queue, the text is
    /// addressed by the step that produced it: the loop reads
    /// `assistantVisibleText` more than once per final answer (the file
    /// side-effect check reads it before this check does), exactly as chat's
    /// idempotent `assistantTurn.content` allows.
    let steps: [AgentLoopModelStep]
    let visibleTexts: [String]
    var toolResults: [String: AgentLoopToolExecution] = [:]
    /// Per-invocation override (wins over `toolResults`), for tests whose
    /// result depends on the arguments.
    var executeOverride: ((ServiceToolInvocation) -> AgentLoopToolExecution)?
    var executions = 0

    var builtNotices: [[String]] = []
    var retryPreparations = 0
    private var stepIndex = 0

    init(steps: [AgentLoopModelStep], visibleTexts: [String]) {
        self.steps = steps
        self.visibleTexts = visibleTexts
    }

    func makeHooks() -> AgentLoopHooks {
        var hooks = AgentLoopHooks(
            buildMessages: { notices in
                self.builtNotices.append(notices)
                return AgentLoopIterationInput(
                    messages: [ChatMessage(role: "user", content: "summarise the vault")]
                )
            },
            modelStep: { _, _ in
                guard self.stepIndex < self.steps.count else { return .finalResponse }
                let step = self.steps[self.stepIndex]
                self.stepIndex += 1
                return step
            },
            executeTool: { inv, _ in
                self.executions += 1
                if let override = self.executeOverride { return override(inv) }
                return self.toolResults[inv.toolName]
                    ?? AgentLoopToolExecution(
                        result: ToolEnvelope.success(tool: inv.toolName, text: "ok")
                    )
            }
        )
        hooks.assistantVisibleText = {
            let index = self.stepIndex - 1
            guard index >= 0, index < self.visibleTexts.count else { return nil }
            return self.visibleTexts[index]
        }
        hooks.prepareGroundedClaimRetry = {
            self.retryPreparations += 1
        }
        return hooks
    }

    func knowledgeNoticeCount() -> Int {
        builtNotices.filter { iteration in
            iteration.contains {
                $0.contains("every knowledge tool call this turn FAILED")
            }
        }.count
    }

    func lastKnowledgeNotice() -> String? {
        builtNotices.flatMap { $0 }.last(where: { $0.contains("every knowledge tool call this turn FAILED") })
    }
}

@MainActor
struct KnowledgeClaimLoopDriverTests {

    private var policy: AgentLoopPolicy {
        AgentLoopPolicy(
            maxIterations: 8,
            stopOnToolRejection: true,
            dedupeNoticeEnabled: false
        )
    }

    private func listKnowledge(collection: String) -> ServiceToolInvocation {
        ServiceToolInvocation(
            toolName: "list_knowledge",
            jsonArguments: #"{"collection":"\#(collection)","limit":"20"}"#
        )
    }

    private static let failedList = AgentLoopToolExecution(
        result: ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "Unknown collection `knowledge`. Granted collections: Obsidian Vault.",
            field: "collection",
            expected: "one of the agent's granted collection names",
            tool: "list_knowledge",
            retryable: true
        ),
        isError: true
    )

    /// The reported shape end-to-end: `list_knowledge` fails with
    /// invalid_args (which chat's `stopOnToolRejection` policy deliberately
    /// does NOT stop on), the model answers with invented counts, the loop
    /// stages the notice and regenerates once; the corrected answer is
    /// honest and the run ends normally.
    @Test
    func fabricatedSummaryAfterFailedListing_stagesNoticeAndRegenerates() async throws {
        let surface = KnowledgeClaimLoopSurface(
            steps: [.toolCalls([listKnowledge(collection: "knowledge")]), .finalResponse, .finalResponse],
            visibleTexts: [
                "",  // tool-calling turn narration (read before the batch)
                "The Obsidian Vault contains 20 documents — 20 of them, all dated 2025. The last entry is 20250318.",
                "I could not read the collection: list_knowledge rejected the collection name `knowledge`.",
            ]
        )
        surface.toolResults["list_knowledge"] = Self.failedList
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.retryPreparations == 1)
        #expect(surface.knowledgeNoticeCount() == 1)
        let notice = surface.lastKnowledgeNotice()
        #expect(notice?.contains("`Obsidian Vault`") == true)
        #expect(notice?.contains("`list_knowledge`") == true)
        // The regeneration is a protocol correction, not charged as an
        // agent iteration: tool turn + final = 2.
        #expect(result.iterations == 2)
    }

    /// The corrected turn retries with the granted name and succeeds: the
    /// second final answer is grounded, so no second notice.
    @Test
    func retryWithGrantedNameGroundsTheAnswer() async throws {
        let surface = KnowledgeClaimLoopSurface(
            steps: [
                .toolCalls([listKnowledge(collection: "knowledge")]),
                .finalResponse,
                .toolCalls([listKnowledge(collection: "Obsidian Vault")]),
                .finalResponse,
            ],
            visibleTexts: [
                "",
                "The Obsidian Vault contains 20 documents.",
                "",
                "The Obsidian Vault contains 312 documents across 5 folders.",
            ]
        )
        surface.executeOverride = { inv in
            if inv.jsonArguments.contains("Obsidian Vault") {
                return AgentLoopToolExecution(
                    result: ToolEnvelope.success(
                        tool: "list_knowledge",
                        text: "Found 312 knowledge document(s) in total; showing 1–100 (offset 0):"))
            }
            return Self.failedList
        }
        let result = try await AgentToolLoop.run(policy: policy, state: AgentTaskState(), hooks: surface.makeHooks())
        #expect(result.exit == .finalResponse)
        #expect(surface.executions == 2)
        #expect(surface.retryPreparations == 1)
        #expect(surface.knowledgeNoticeCount() == 1)
    }

    /// A successful knowledge read anywhere in the run grounds the answer:
    /// no notice, no regeneration, even with a failed call in the same run.
    @Test
    func successfulReadGroundsCounts() async throws {
        let surface = KnowledgeClaimLoopSurface(
            steps: [
                .toolCalls([listKnowledge(collection: "knowledge"), listKnowledge(collection: "Obsidian Vault")]),
                .finalResponse,
            ],
            visibleTexts: ["", "The Obsidian Vault contains 312 documents."]
        )
        surface.executeOverride = { inv in
            if inv.jsonArguments.contains("Obsidian Vault") {
                return AgentLoopToolExecution(
                    result: ToolEnvelope.success(tool: "list_knowledge", text: "Found 312 knowledge document(s)"))
            }
            return Self.failedList
        }
        let result = try await AgentToolLoop.run(policy: policy, state: AgentTaskState(), hooks: surface.makeHooks())
        #expect(result.exit == .finalResponse)
        #expect(surface.retryPreparations == 0)
        #expect(surface.knowledgeNoticeCount() == 0)
    }

    /// No knowledge tool ran at all: counts in the answer are none of this
    /// check's business (the model may be summarising an attached folder).
    @Test
    func noKnowledgeCall_neverTrips() async throws {
        let surface = KnowledgeClaimLoopSurface(
            steps: [
                .toolCalls([ServiceToolInvocation(toolName: "file_read", jsonArguments: #"{"path":"README.md"}"#)]),
                .finalResponse,
            ],
            visibleTexts: ["", "The folder contains 20 documents, all dated 2025."]
        )
        let result = try await AgentToolLoop.run(policy: policy, state: AgentTaskState(), hooks: surface.makeHooks())
        #expect(result.exit == .finalResponse)
        #expect(surface.retryPreparations == 0)
        #expect(surface.knowledgeNoticeCount() == 0)
    }

    /// Honest failure narration after the failed call passes untouched.
    @Test
    func honestFailureAnswer_passes() async throws {
        let surface = KnowledgeClaimLoopSurface(
            steps: [.toolCalls([listKnowledge(collection: "knowledge")]), .finalResponse],
            visibleTexts: ["", "I could not read the Obsidian Vault: the knowledge tool rejected the call."]
        )
        surface.toolResults["list_knowledge"] = Self.failedList
        let result = try await AgentToolLoop.run(policy: policy, state: AgentTaskState(), hooks: surface.makeHooks())
        #expect(result.exit == .finalResponse)
        #expect(surface.retryPreparations == 0)
        #expect(surface.knowledgeNoticeCount() == 0)
    }

    /// Bounded: the model that fabricates twice in a row gets at most
    /// `maxGroundedClaimRetries` regenerations, then its answer stands.
    @Test
    func repeatedFabrication_isBounded() async throws {
        let surface = KnowledgeClaimLoopSurface(
            steps: [.toolCalls([listKnowledge(collection: "knowledge")]), .finalResponse, .finalResponse, .finalResponse, .finalResponse],
            visibleTexts: [
                "", "The vault contains 20 documents.", "The vault contains 20 documents.",
                "The vault contains 20 documents.", "The vault contains 20 documents.",
            ]
        )
        surface.toolResults["list_knowledge"] = Self.failedList
        let result = try await AgentToolLoop.run(policy: policy, state: AgentTaskState(), hooks: surface.makeHooks())
        #expect(result.exit == .finalResponse)
        #expect(surface.retryPreparations == AgentToolLoop.maxGroundedClaimRetries)
        #expect(surface.knowledgeNoticeCount() == AgentToolLoop.maxGroundedClaimRetries)
    }
}
