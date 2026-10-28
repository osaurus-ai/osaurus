//
//  GroundedFileSideEffectCheckTests.swift
//  osaurusTests
//
//  Coverage for the file side-effect advisory: a message that narrates a
//  file write ("appended to the file") while no file-writing tool succeeded
//  this run gets a factual `[System Notice]` staged for the next step. The
//  notice describes recorded execution only; it does not authorize or
//  instruct a file write.
//

import Foundation
import Testing

@testable import OsaurusCore

private enum LiveReadOnlyFileRegression {
    static let request =
        "Use a file-reading tool to read probe.json in the working folder and report its nonce and integer value. Do not modify it."

    // Exact first final answer from the native 9aac/877 SQL transcript,
    // session D97F5BFB-F49E-4C8E-92DA-D59008FF7BCF. The old bare "to file"
    // regex misclassified the closing memory comparison as a write claim.
    static let answer = "\n\n" + #"""
        I read `probe.json` in the working folder. Here are its contents (unmodified):

        **probe.json**
        ```json
        {"nonce":"responses-integrated-20261025","value":42}
        ```

        **Reported values:**
        - **Nonce:** `responses-integrated-20261025`
        - **Integer value:** `42`

        The file is 53 bytes, one line, valid JSON, and was read without any modification. (Note: the file's actual `value` is 42, which matches the "Integer value: 42" memory entry; the "Current integer value in probe.json is 43" memory entry appears stale relative to the file on disk.)
        """#
}

@Suite
struct GroundedFileSideEffectCheckTests {

    // MARK: containsFileSideEffectClaim

    @Test
    func appendedToFile_trips() {
        #expect(
            GroundedFileSideEffectCheck.containsFileSideEffectClaim(
                "I've appended the summary to the file. Fetching the next page now."
            )
        )
    }

    @Test
    func progressiveNarration_trips() {
        #expect(
            GroundedFileSideEffectCheck.containsFileSideEffectClaim(
                "Appending the extracted text to the file now, then fetching the next page."
            )
        )
    }

    @Test
    func savedTheReport_trips() {
        #expect(GroundedFileSideEffectCheck.containsFileSideEffectClaim("Saved the report."))
    }

    @Test
    func createdMarkdownDocument_trips() {
        #expect(
            GroundedFileSideEffectCheck.containsFileSideEffectClaim(
                "I created the markdown document with the three sections you asked for."
            )
        )
    }

    @Test
    func futureIntent_doesNotTrip() {
        #expect(
            !GroundedFileSideEffectCheck.containsFileSideEffectClaim(
                "I'll append it to the file once the page is fetched."
            )
        )
        #expect(
            !GroundedFileSideEffectCheck.containsFileSideEffectClaim(
                "Let me save the report next."
            )
        )
    }

    @Test
    func honestNegation_doesNotTrip() {
        #expect(
            !GroundedFileSideEffectCheck.containsFileSideEffectClaim(
                "Nothing was written to the file — no write tool is available in this chat."
            )
        )
        #expect(
            !GroundedFileSideEffectCheck.containsFileSideEffectClaim(
                "I couldn't save the report because the write failed."
            )
        )
    }

    @Test
    func question_doesNotTrip() {
        #expect(
            !GroundedFileSideEffectCheck.containsFileSideEffectClaim(
                "Should I append this to the file?"
            )
        )
    }

    @Test
    func ordinaryProse_doesNotTrip() {
        #expect(
            !GroundedFileSideEffectCheck.containsFileSideEffectClaim(
                "Here is the report you asked for, with three sections."
            )
        )
        #expect(
            !GroundedFileSideEffectCheck.containsFileSideEffectClaim(
                "The page describes how the compiler writes object files."
            )
        )
    }

    @Test func exactLiveReadOnlyAnswerWithFencedJSONAndMemoryComparisonIsNotAWriteClaim() {
        #expect(!GroundedFileSideEffectCheck.containsFileSideEffectClaim(LiveReadOnlyFileRegression.answer))
    }

    @Test(arguments: [
        "The memory entry appears stale relative to the file on disk.",
        "These values are identical to the file contents.",
        "The report refers to the file we read.",
        "The written report contains the nonce ABC and value 42.",
        "The written report points to the file.",
        "The written instructions refer to the file.",
    ])
    func fileDestinationWithoutWritePredicateIsNotAClaim(text: String) {
        #expect(!GroundedFileSideEffectCheck.containsFileSideEffectClaim(text))
    }

    @Test(arguments: [
        "The summary was written to the file.",
        "Appended it to your file.",
        "Wrote the extracted content to the file.",
        "I added the summary to the file.",
        "I pasted the result to the file.",
        "I have written the report.",
    ])
    func affirmativeWritePredicateWithDestinationStillTrips(text: String) {
        #expect(GroundedFileSideEffectCheck.containsFileSideEffectClaim(text))
    }

    // MARK: isGroundedFileWriteOutcome

    @Test(arguments: ["image", "video"])
    func completedMediaArtifact_groundsButQueuedOrEmptyDoesNot(tool: String) {
        var payload: [String: Any] = [
            "kind": tool == "image" ? "native_image_generation_job" : "generated_media_job",
            "status": "completed",
            "images": [["path": "/tmp/generated.png"]],
            "media": ["path": "/tmp/generated.mp4"],
        ]
        func grounded() -> Bool {
            GroundedFileSideEffectCheck.isGroundedFileWriteOutcome(
                toolName: tool, result: ToolEnvelope.success(tool: tool, result: payload))
        }
        #expect(grounded())
        payload["status"] = "queued"
        #expect(!grounded())
        payload["status"] = "failed"
        #expect(!grounded())
        payload["status"] = "completed"
        payload["images"] = [["path": ""]]
        payload["media"] = ["path": ""]
        #expect(!grounded())
        #expect(!GroundedFileSideEffectCheck.isGroundedFileWriteOutcome(
            toolName: tool,
            result: ToolEnvelope.failure(kind: .invalidArgs, message: "invalid size", tool: tool)))
    }

    @Test
    func successfulFileWrite_grounds() {
        #expect(
            GroundedFileSideEffectCheck.isGroundedFileWriteOutcome(
                toolName: "file_write",
                result: ToolEnvelope.success(tool: "file_write", text: "ok")
            )
        )
        #expect(
            GroundedFileSideEffectCheck.isGroundedFileWriteOutcome(
                toolName: "sandbox_write_file",
                result: ToolEnvelope.success(tool: "sandbox_write_file", text: "ok")
            )
        )
    }

    @Test
    func failedFileWrite_doesNotGround() {
        #expect(
            !GroundedFileSideEffectCheck.isGroundedFileWriteOutcome(
                toolName: "file_write",
                result: ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "path is outside the workspace",
                    tool: "file_write"
                )
            )
        )
    }

    @Test
    func nonWriteTool_doesNotGround() {
        #expect(
            !GroundedFileSideEffectCheck.isGroundedFileWriteOutcome(
                toolName: "fetch_html",
                result: ToolEnvelope.success(tool: "fetch_html", text: "<html/>")
            )
        )
    }
}

// MARK: - Driver behavior tests

/// Scripted surface for the file side-effect advisory. Each model step
/// consumes the next entry of `visibleTexts` when the driver asks for the
/// assistant's visible text (tool-calling turns read it BEFORE the batch
/// executes; finals read it at classification time).
@MainActor
private final class FileClaimLoopSurface {
    var steps: [AgentLoopModelStep]
    var visibleTexts: [String]
    var toolResults: [String: AgentLoopToolExecution] = [:]

    var builtNotices: [[String]] = []
    var retryPreparations = 0
    var visibleTextReads = 0

    init(steps: [AgentLoopModelStep], visibleTexts: [String]) {
        self.steps = steps
        self.visibleTexts = visibleTexts
    }

    func makeHooks(includeVisibleTextHook: Bool = true) -> AgentLoopHooks {
        var hooks = AgentLoopHooks(
            buildMessages: { notices in
                self.builtNotices.append(notices)
                return AgentLoopIterationInput(
                    messages: [ChatMessage(role: "user", content: "task")]
                )
            },
            modelStep: { _, _ in
                guard !self.steps.isEmpty else { return .finalResponse }
                return self.steps.removeFirst()
            },
            executeTool: { inv, _ in
                self.toolResults[inv.toolName]
                    ?? AgentLoopToolExecution(
                        result: ToolEnvelope.success(tool: inv.toolName, text: "ok")
                    )
            }
        )
        if includeVisibleTextHook {
            hooks.assistantVisibleText = {
                self.visibleTextReads += 1
                guard !self.visibleTexts.isEmpty else { return nil }
                return self.visibleTexts.removeFirst()
            }
            hooks.prepareGroundedClaimRetry = {
                self.retryPreparations += 1
            }
        }
        return hooks
    }

    func noticeCount() -> Int {
        builtNotices.filter { iteration in
            iteration.contains { $0.contains(GroundedFileSideEffectCheck.ungroundedFileClaimNotice) }
        }.count
    }
}

@MainActor
struct FileClaimLoopDriverTests {

    private var policy: AgentLoopPolicy {
        AgentLoopPolicy(
            maxIterations: 8,
            stopOnToolRejection: false,
            dedupeNoticeEnabled: false
        )
    }

    private func fetchHTML() -> ServiceToolInvocation {
        ServiceToolInvocation(
            toolName: "fetch_html",
            jsonArguments: #"{"url": "https://example.com"}"#
        )
    }

    private func fileWrite() -> ServiceToolInvocation {
        ServiceToolInvocation(
            toolName: "file_write",
            jsonArguments: #"{"path": "notes.md", "content": "summary", "append": true}"#
        )
    }

    @Test(arguments: [
        LiveReadOnlyFileRegression.answer,
        "The written report contains the nonce ABC and value 42.",
    ])
    func readOnlyExchangeExecutesOneReadAndAcceptsItsFirstFinalWithoutRetry(answer: String) async throws {
        let call = ServiceToolInvocation(
            toolName: "file_read", jsonArguments: #"{"path":"probe.json"}"#, toolCallId: "call_live_read"
        )
        let readPayload: [String: Any] = [
            "path": "probe.json", "text": #"{"nonce":"responses-integrated-20261025","value":42}"#,
            "file_size": 53, "bytes_read": 53, "truncated": false,
        ]
        let readResult = ToolEnvelope.success(tool: "file_read", result: readPayload)
        var history = [ChatMessage(role: "user", content: LiveReadOnlyFileRegression.request)]
        var modelInputs: [[ChatMessage]] = []
        var deliveredNotices: [[String]] = []
        var executedCalls: [ServiceToolInvocation] = []
        var visibleText = ""
        var retryPreparations = 0
        var finalSteps = 0
        let hooks = AgentLoopHooks(
            buildMessages: { notices in
                deliveredNotices.append(notices)
                return AgentLoopIterationInput(messages: AgentLoopBudget.appendingTransientNotices(notices, to: history))
            },
            modelStep: { messages, _ in
                modelInputs.append(messages)
                if modelInputs.count == 1 { return .toolCalls([call]) }
                finalSteps += 1
                visibleText = finalSteps == 1 ? answer : "Unexpected regeneration"
                return .finalResponse
            },
            executeTool: { invocation, _ in
                executedCalls.append(invocation)
                return AgentLoopToolExecution(result: readResult)
            },
            onBatchComplete: { outcomes in
                history.append(ChatMessage(role: "assistant", content: nil, tool_calls: outcomes.map {
                    ToolCall(id: $0.callId, type: "function", function: ToolCallFunction(
                        name: $0.invocation.toolName, arguments: $0.invocation.jsonArguments))
                }, tool_call_id: nil))
                history += outcomes.map {
                    ChatMessage(role: "tool", content: $0.result, tool_calls: nil, tool_call_id: $0.callId)
                }
            },
            prepareGroundedClaimRetry: { retryPreparations += 1 },
            assistantVisibleText: { visibleText }
        )
        let result = try await AgentToolLoop.run(policy: policy, state: AgentTaskState(), hooks: hooks)
        #expect(result.exit == .finalResponse && result.iterations == 2)
        #expect(retryPreparations == 0, "The valid final must not be excluded or regenerated")
        #expect(finalSteps == 1 && visibleText == answer)
        #expect(deliveredNotices.allSatisfy { $0.isEmpty })
        #expect(executedCalls.map(\.toolName) == ["file_read"])
        #expect(executedCalls.first?.jsonArguments == #"{"path":"probe.json"}"#)
        try #require(modelInputs.count == 2)
        #expect(modelInputs[1].map(\.role) == ["user", "assistant", "tool"])
        #expect(modelInputs[1].first?.content == LiveReadOnlyFileRegression.request)
        #expect(modelInputs[1].last?.tool_call_id == "call_live_read")
        #expect(modelInputs[1].last?.content == readResult)
    }

    /// The reported shape: "appended to the file" narrated on a turn whose
    /// only call is `fetch_html`. The notice rides the NEXT iteration's
    /// transient channel; the run continues and ends normally.
    @Test
    func narratedWriteWithoutWriteTool_stagesNoticeAndContinues() async throws {
        let surface = FileClaimLoopSurface(
            steps: [.toolCalls([fetchHTML()]), .finalResponse],
            visibleTexts: [
                "I've appended the summary to the file. Fetching the next page now.",
                "Done — both pages are summarised above.",
            ]
        )
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.noticeCount() == 1)
        // The tool-calling turn's narration was read (before the batch), and
        // no final-answer regeneration was needed — advisory, not a stop.
        #expect(surface.retryPreparations == 0)
        #expect(result.iterations == 2)
    }

    /// Same narration with a successful `file_write` in the batch is
    /// grounded: no notice.
    @Test
    func narratedWriteWithSuccessfulWriteTool_isGrounded() async throws {
        let surface = FileClaimLoopSurface(
            steps: [.toolCalls([fileWrite(), fetchHTML()]), .finalResponse],
            visibleTexts: [
                "I've appended the summary to the file. Fetching the next page now.",
                "Done.",
            ]
        )
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.noticeCount() == 0)
        #expect(surface.retryPreparations == 0)
    }

    /// The hard shape: a `file_write` that FAILED grounds nothing, so the
    /// narration is still ungrounded and the notice still stages.
    @Test
    func narratedWriteWithFailedWriteTool_isStillUngrounded() async throws {
        let surface = FileClaimLoopSurface(
            steps: [.toolCalls([fileWrite()]), .finalResponse],
            visibleTexts: [
                "Saved the report to notes.md.",
                "The write failed — nothing was saved. Here is the report inline instead.",
            ]
        )
        surface.toolResults["file_write"] = AgentLoopToolExecution(
            result: ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "path is outside the workspace",
                tool: "file_write"
            )
        )
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.noticeCount() == 1)
    }

    /// Stated intent on a tool-calling turn is not a claim.
    @Test
    func futureIntentOnToolCallingTurn_noNotice() async throws {
        let surface = FileClaimLoopSurface(
            steps: [.toolCalls([fetchHTML()]), .finalResponse],
            visibleTexts: [
                "I'll append it to the file after fetching the page.",
                "Done.",
            ]
        )
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.noticeCount() == 0)
    }

    /// A FINAL answer that claims a write with no write tool landed gets one
    /// noticed regeneration (same bounded channel as the config guard), and
    /// the honest rewrite is then accepted.
    @Test
    func ungroundedFinalClaim_getsOneNoticedRetry_thenAccepts() async throws {
        let surface = FileClaimLoopSurface(
            steps: [.finalResponse, .finalResponse],
            visibleTexts: [
                "I've saved the report to notes.md for you.",
                "I can't write files in this chat — no file tool is available. Here is the report inline.",
            ]
        )
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.retryPreparations == 1)
        #expect(surface.noticeCount() == 1)
        // The retry is protocol correction, not agent progress.
        #expect(result.iterations == 1)
    }

    /// Notices on tool-calling turns are bounded per run: a model that keeps
    /// narrating writes is nudged `maxUngroundedFileClaimNotices` times, then
    /// left alone — never stopped.
    @Test
    func toolCallingNotices_areBoundedPerRun() async throws {
        let surface = FileClaimLoopSurface(
            steps: [
                .toolCalls([fetchHTML()]),
                .toolCalls([fetchHTML()]),
                .toolCalls([fetchHTML()]),
                .finalResponse,
            ],
            visibleTexts: [
                "Appended page one to the file.",
                "Appended page two to the file.",
                "Appended page three to the file.",
                "Done.",
            ]
        )
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.noticeCount() == AgentToolLoop.maxUngroundedFileClaimNotices)
        // Delivery, not staging: the notice rides the transient channel of
        // the iteration AFTER each of the first two narrated turns (built
        // messages #2 and #3), exactly once per iteration. The third
        // narration is past the bound, so the final turn's build carries
        // nothing, and nothing was regenerated.
        let delivered = surface.builtNotices.map { notices in
            notices.filter { $0.contains(GroundedFileSideEffectCheck.ungroundedFileClaimNotice) }.count
        }
        #expect(delivered == [0, 1, 1, 0])
        #expect(surface.retryPreparations == 0)
        // Three tool-calling turns plus the final answer; nothing refunded.
        #expect(result.iterations == 4)
    }

    /// Surfaces that do not supply the hook are untouched.
    @Test
    func surfaceWithoutHook_isUnaffected() async throws {
        let surface = FileClaimLoopSurface(
            steps: [.toolCalls([fetchHTML()]), .finalResponse],
            visibleTexts: ["I've appended the summary to the file.", "Done."]
        )
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks(includeVisibleTextHook: false)
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.noticeCount() == 0)
        #expect(surface.visibleTextReads == 0)
    }
}
