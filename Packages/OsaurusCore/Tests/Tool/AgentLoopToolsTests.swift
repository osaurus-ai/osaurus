//
//  AgentLoopToolsTests.swift
//  osaurusTests
//
//  Pins down the contracts of the three tools that drive the unified
//  Chat agent loop: `todo`, `complete`, `clarify`. Each tool has a tiny
//  schema; tests focus on the validation gates and the side effects
//  on `AgentTodoStore` (for `todo`) so regressions surface as test
//  failures rather than as agents that silently misbehave.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct AgentLoopToolsTests {

    @Test("shared todo schema stays optional outside targeted family policy")
    func sharedTodoSchemaStaysOptional() {
        let description = TodoTool().description
        #expect(description.contains("OPTIONAL"))
        #expect(description.contains("never decides whether the turn stays open"))
        #expect(description.contains("answer the user exactly once and stop"))
        #expect(description.contains("direct question"))
        #expect(!description.contains("It is REQUIRED"))
        #expect(!description.contains("unchecked items keep this agent run open"))
    }

    @Test("complete schema cannot invite literal protocol text")
    func completeSchemaRequiresStructuredInvocationOnly() {
        let description = CompleteTool().description
        #expect(description.contains("structured tool protocol only"))
        #expect(description.contains("never by typing `complete(...)`"))
        #expect(description.contains("successful task does not need this tool"))
        #expect(!description.contains("same message as"))
    }

    // MARK: - Helpers

    private func withSession<T>(
        _ sessionId: String = "test-session-\(UUID().uuidString)",
        body: (String) async throws -> T
    ) async throws -> T {
        await AgentTodoStore.shared.clear(for: sessionId)
        return try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
            try await body(sessionId)
        }
    }

    // MARK: - todo

    @Test
    func todo_writesMarkdownIntoStore() async throws {
        try await withSession { sessionId in
            let result = try await TodoTool().execute(
                argumentsJSON: #"""
                    {"markdown": "- [ ] Read existing config\n- [ ] Add new field\n- [x] Stub test"}
                    """#
            )
            #expect(ToolEnvelope.isSuccess(result))
            #expect(result.contains("Todo updated"))
            #expect(result.contains("1/3 complete"))
            #expect(result.contains("Todo never keeps the turn open"))
            #expect(!result.contains("Unchecked items keep this agent run open"))

            let stored = await AgentTodoStore.shared.todo(for: sessionId)
            #expect(stored?.totalCount == 3)
            #expect(stored?.doneCount == 1)
            #expect(stored?.items.first?.text == "Read existing config")
            #expect(stored?.items.last?.isDone == true)
        }
    }

    @Test
    func todo_unchangedReplayIsSuccessfulNoOp() async throws {
        try await withSession { sessionId in
            _ = try await TodoTool().execute(
                argumentsJSON: #"{"markdown": "- [ ] inspect\n- [ ] fix"}"#
            )
            let before = try #require(await AgentTodoStore.shared.todo(for: sessionId))

            let result = try await TodoTool().execute(
                argumentsJSON: #"""
                    {"markdown": "# Plan\n* [ ] inspect\n* [ ] fix\n\nUnchanged prose."}
                    """#
            )

            #expect(ToolEnvelope.isSuccess(result))
            #expect(result.contains("Todo unchanged: 0/2 complete"))
            #expect(result.contains("Do not call `todo` again"))
            #expect(result.contains("answer the user once and stop"))
            let after = try #require(await AgentTodoStore.shared.todo(for: sessionId))
            #expect(after.updatedAt == before.updatedAt)
            #expect(after.markdown == before.markdown)
        }
    }

    @Test
    func todo_checkboxTransitionStillUpdatesStore() async throws {
        try await withSession { sessionId in
            _ = try await TodoTool().execute(
                argumentsJSON: #"{"markdown": "- [ ] inspect\n- [ ] fix"}"#
            )
            let before = try #require(await AgentTodoStore.shared.todo(for: sessionId))

            let result = try await TodoTool().execute(
                argumentsJSON: #"{"markdown": "- [x] inspect\n- [ ] fix"}"#
            )

            #expect(result.contains("Todo updated: 1/2 complete"))
            let after = try #require(await AgentTodoStore.shared.todo(for: sessionId))
            #expect(after.updatedAt >= before.updatedAt)
            #expect(after.doneCount == 1)
        }
    }

    @Test
    func todo_replacesWholesale() async throws {
        try await withSession { sessionId in
            _ = try await TodoTool().execute(
                argumentsJSON: #"{"markdown": "- [ ] one\n- [ ] two\n- [ ] three"}"#
            )
            _ = try await TodoTool().execute(
                argumentsJSON: #"{"markdown": "- [x] just one"}"#
            )
            let stored = await AgentTodoStore.shared.todo(for: sessionId)
            #expect(stored?.totalCount == 1)
            #expect(stored?.items.first?.text == "just one")
            #expect(stored?.doneCount == 1)
        }
    }

    @Test
    func todo_emptyMarkdownRejected() async throws {
        try await withSession { _ in
            let result = try await TodoTool().execute(argumentsJSON: #"{"markdown": "   "}"#)
            #expect(ToolEnvelope.isError(result))
            #expect(result.contains("non-empty"))
        }
    }

    @Test
    func todo_noChecklistLinesRejected() async throws {
        try await withSession { sessionId in
            let result = try await TodoTool().execute(
                argumentsJSON: #"{"markdown": "Just prose, no checkboxes"}"#
            )
            // Regression (E4B loop): a checkbox-less list used to be stored
            // as a zero-item todo — `todoUpdatedBeforeComplete` could never
            // pass and the staleness nudge went dark, all silently. The
            // contract is now enforced: invalidArgs + resend instructions,
            // and nothing is stored.
            #expect(ToolEnvelope.isError(result))
            #expect(result.contains("- [ ]") && result.contains("- [x]"))
            let stored = await AgentTodoStore.shared.todo(for: sessionId)
            #expect(stored == nil)
        }
    }

    @Test
    func todo_numberedListWithoutBoxesRejected() async throws {
        try await withSession { _ in
            // The exact live-run shape from the E4B baseline: a numbered
            // plan with no checkbox syntax.
            let result = try await TodoTool().execute(
                argumentsJSON: #"{"markdown": "1. Create table\n2. Insert rows\n3. Verify"}"#
            )
            #expect(ToolEnvelope.isError(result))
            #expect(result.contains("Re-send"))
        }
    }

    @Test
    func todo_returnsErrorWithoutSessionContext() async throws {
        // Deliberately do NOT bind currentSessionId.
        let result = try await TodoTool().execute(
            argumentsJSON: #"{"markdown": "- [ ] step"}"#
        )
        #expect(ToolEnvelope.isError(result))
        #expect(result.lowercased().contains("no active session"))
    }

    // MARK: - complete

    @Test
    func complete_acceptsWellFormedSummary() async throws {
        let result = try await CompleteTool().execute(
            argumentsJSON: #"""
                {"summary": "Added /health route in app.py and verified with curl returning 200 OK."}
                """#
        )
        #expect(ToolEnvelope.isSuccess(result))
        #expect(result.contains("Task completed"))
    }

    @Test
    func complete_rejectsShortSummary() async throws {
        let result = try await CompleteTool().execute(argumentsJSON: #"{"summary": "done"}"#)
        #expect(result.contains("too short") || result.contains("placeholder"))
    }

    @Test
    func complete_rejectsPlaceholders() async throws {
        for placeholder in ["done", "ok", "looks good", "all good", "complete", "finished"] {
            let result = try await CompleteTool().execute(
                argumentsJSON: "{\"summary\": \"\(placeholder)\"}"
            )
            // Either the length gate (short) or the placeholder gate trips.
            #expect(
                result.contains("placeholder") || result.contains("too short"),
                "expected rejection for `\(placeholder)`, got: \(result)"
            )
        }
    }

    @Test
    func complete_reportsBlockedOutcomeWhenTodoIsUnchecked() async throws {
        try await withSession { _ in
            _ = try await TodoTool().execute(
                argumentsJSON: #"{"markdown": "- [x] done step\n- [ ] left one\n- [ ] left two"}"#
            )
            let result = try await CompleteTool().execute(
                argumentsJSON: #"""
                    {"summary": "Finished the first step; verified by re-reading the file contents."}
                    """#
            )
            #expect(ToolEnvelope.isSuccess(result))
            #expect(result.contains("\"outcome\":\"blocked\""))
            #expect(result.contains("\"pending_todo_items\":2"))
            #expect(result.contains("still pending"))
        }
    }

    @Test
    func complete_noWarningWhenTodoFullyChecked() async throws {
        try await withSession { _ in
            _ = try await TodoTool().execute(
                argumentsJSON: #"{"markdown": "- [x] one\n- [x] two"}"#
            )
            let result = try await CompleteTool().execute(
                argumentsJSON: #"""
                    {"summary": "Did both steps and verified with the checker script exiting 0."}
                    """#
            )
            #expect(ToolEnvelope.isSuccess(result))
            #expect(!result.contains("unchecked"))
            #expect(result.contains("\"outcome\":\"completed\""))
            #expect(result.contains("\"pending_todo_items\":0"))
        }
    }

    @Test("prior-turn todo cannot make an unrelated current run blocked")
    func complete_rejectsStaleSessionTodoInsideCanonicalRun() async throws {
        try await withSession { sessionId in
            // Simulate the prior user turn: the checklist remains visible in
            // the session store after that turn returns a normal final answer.
            _ = try await TodoTool().execute(
                argumentsJSON: #"{"markdown": "- [x] report result\n- [ ] optional review"}"#
            )
            #expect(await AgentTodoStore.shared.todo(for: sessionId) != nil)

            // A new canonical run gets a fresh marker. It did not call Todo,
            // so an old unchecked checklist cannot authorize `complete` or
            // turn this unrelated response into a BLOCKED banner.
            let runScope = AgentTodoRunScope()
            let result =
                try await ChatExecutionContext.$agentTodoRunScope.withValue(runScope) {
                    try await CompleteTool().execute(
                        argumentsJSON: #"""
                            {"summary": "STALE_TODO_FOLLOWUP_OK - verified as the requested exact follow-up."}
                            """#
                    )
                }

            #expect(ToolEnvelope.isError(result))
            #expect(result.contains("current run called `todo`"))
            #expect(result.contains("earlier user turn does not apply"))
        }
    }

    @Test("an explicit unchanged todo still belongs to the current run")
    func complete_acceptsReaffirmedCurrentRunTodo() async throws {
        try await withSession { _ in
            let argumentsJSON =
                "{\"markdown\":\"- [x] report result\\n- [ ] optional review\"}"
            // Seed the same semantic checklist in a prior turn.
            _ = try await TodoTool().execute(
                argumentsJSON: argumentsJSON
            )

            let runScope = AgentTodoRunScope()
            let result =
                try await ChatExecutionContext.$agentTodoRunScope.withValue(runScope) {
                    // This is intentionally unchanged in the session store,
                    // but the explicit valid call must mark it current-run.
                    let todoResult = try await TodoTool().execute(
                        argumentsJSON: argumentsJSON
                    )
                    #expect(todoResult.contains("Todo unchanged"))
                    return try await CompleteTool().execute(
                        argumentsJSON: #"""
                            {"summary": "The requested work is blocked; verified the remaining review is still pending."}
                            """#
                    )
                }

            #expect(ToolEnvelope.isSuccess(result))
            #expect(result.contains("\"outcome\":\"blocked\""))
            #expect(result.contains("\"pending_todo_items\":1"))
        }
    }

    @Test
    func complete_validateHelperMatchesExecuteOutput() {
        // The intercept path in ChatView calls validate() directly; ensure
        // the same checks fire so behavior is consistent across both.
        #expect(CompleteTool.validate(summary: "ok") != nil)
        #expect(CompleteTool.validate(summary: "Wrote app.py and ran swift test, 12 passed.") == nil)
    }

    // MARK: - clarify

    @Test
    func clarify_acceptsNonEmptyQuestion() async throws {
        let result = try await ClarifyTool().execute(
            argumentsJSON: #"{"question": "Use Postgres or SQLite?"}"#
        )
        #expect(ToolEnvelope.isSuccess(result))
        #expect(result.contains("Awaiting"))
    }

    @Test
    func clarify_rejectsEmptyQuestion() async throws {
        let result = try await ClarifyTool().execute(argumentsJSON: #"{"question": ""}"#)
        #expect(ToolEnvelope.isError(result))
        // requireString with allowEmpty=false emits "must not be empty".
        #expect(result.contains("must not be empty") || result.contains("non-empty"))
    }

    @Test
    func clarify_acceptsOptions() async throws {
        let result = try await ClarifyTool().execute(
            argumentsJSON: #"{"question": "DB?", "options": ["Postgres", "SQLite"]}"#
        )
        #expect(ToolEnvelope.isSuccess(result))

        let parsed = ClarifyTool.parse(
            argumentsJSON: #"{"question": "DB?", "options": ["Postgres", "SQLite"]}"#
        )
        #expect(parsed?.question == "DB?")
        #expect(parsed?.options == ["Postgres", "SQLite"])
        #expect(parsed?.allowMultiple == false)
    }

    @Test
    func clarify_rejectsTooManyOptions() async throws {
        // 7 options when the cap is 6 — the model should pare the menu.
        let result = try await ClarifyTool().execute(
            argumentsJSON:
                #"{"question": "Pick", "options": ["a","b","c","d","e","f","g"]}"#
        )
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("capped"))
    }

    @Test
    func clarify_rejectsOverlongOption() async throws {
        // Build a single option that's exactly 81 chars — over the
        // per-option ceiling. Use a string repeat to keep the literal
        // inline and reviewable.
        let longLabel = String(repeating: "x", count: 81)
        let json = "{\"question\": \"Pick\", \"options\": [\"\(longLabel)\"]}"
        let result = try await ClarifyTool().execute(argumentsJSON: json)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("Use short labels") || result.contains("chars"))
    }

    @Test
    func clarify_normalizeDedupesAndTrims() {
        let cleaned = ClarifyTool.normalizeOptions(
            ["Yes", "  yes  ", "No", "", "no", "Maybe"]
        )
        // Case-insensitive dedupe keeps the first casing seen ("Yes",
        // "No") and drops blanks. Order is preserved by arrival.
        #expect(cleaned == ["Yes", "No", "Maybe"])
    }

    @Test
    func clarify_parseDropsAllowMultipleWithoutOptions() {
        // `allowMultiple: true` with no options is meaningless — the
        // payload should collapse it to false so callers don't render
        // a multi-select hint over a free-form question.
        let parsed = ClarifyTool.parse(
            argumentsJSON: #"{"question": "Why?", "allowMultiple": true}"#
        )
        #expect(parsed?.options.isEmpty == true)
        #expect(parsed?.allowMultiple == false)
    }

    @Test
    func clarify_parseRespectsAllowMultipleWithOptions() {
        let parsed = ClarifyTool.parse(
            argumentsJSON:
                #"{"question": "Pick platforms", "options": ["iOS","Android"], "allowMultiple": true}"#
        )
        #expect(parsed?.allowMultiple == true)
        #expect(parsed?.options == ["iOS", "Android"])
    }

    // MARK: - speak

    // Note: a happy path test that calls `execute` with valid `text`
    // would block on `TTSService.playAndWait` (model load + actual
    // audio output). We only assert validation gates here. end-to-end
    // playback is verified manually

    @Test
    func speak_rejectsEmptyText() async throws {
        let result = try await SpeakTool().execute(argumentsJSON: #"{"text": "   "}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("non-empty"))
    }

    @Test
    func speak_rejectsMissingText() async throws {
        let result = try await SpeakTool().execute(argumentsJSON: #"{}"#)
        #expect(ToolEnvelope.isError(result))
    }

    @Test
    func speak_rejectsMalformedArgs() async throws {
        let result = try await SpeakTool().execute(argumentsJSON: "not json")
        #expect(ToolEnvelope.isError(result))
    }

    @Test
    func speak_parseExtractsTrimmedText() {
        #expect(
            SpeakTool.parse(argumentsJSON: #"{"text": "  hi  "}"#) == "hi"
        )
        #expect(SpeakTool.parse(argumentsJSON: #"{"text": ""}"#) == nil)
        #expect(SpeakTool.parse(argumentsJSON: #"{"text": "   "}"#) == nil)
        #expect(SpeakTool.parse(argumentsJSON: #"{}"#) == nil)
        #expect(SpeakTool.parse(argumentsJSON: "garbage") == nil)
    }
}
