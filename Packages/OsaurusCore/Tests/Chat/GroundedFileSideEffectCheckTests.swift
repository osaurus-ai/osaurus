//
//  GroundedFileSideEffectCheckTests.swift
//  osaurusTests
//
//  Coverage for the file side-effect advisory: a message that narrates a
//  file write ("appended to the file") while no file-writing tool succeeded
//  this run gets a factual `[System Notice]` staged for the next step. The
//  loop never stops on it — the model either calls the file tool or says
//  nothing was written.
//

import Foundation
import Testing

@testable import OsaurusCore

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

    // MARK: isGroundedFileWriteOutcome

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
