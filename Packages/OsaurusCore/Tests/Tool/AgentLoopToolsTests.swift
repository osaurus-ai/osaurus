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
            #expect(result.contains("1\\/3 complete"))

            let stored = await AgentTodoStore.shared.todo(for: sessionId)
            #expect(stored?.totalCount == 3)
            #expect(stored?.doneCount == 1)
            #expect(stored?.items.first?.text == "Read existing config")
            #expect(stored?.items.last?.isDone == true)
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
    func todo_noChecklistLinesWarns() async throws {
        try await withSession { _ in
            let result = try await TodoTool().execute(
                argumentsJSON: #"{"markdown": "Just prose, no checkboxes"}"#
            )
            // Stored — but the response warns the model the format is wrong.
            // JSON-encoding turns `/` into `\/` inside the envelope's `text`
            // field, so assert on the escaped form.
            #expect(ToolEnvelope.isSuccess(result))
            #expect(result.contains("- [ ]") && result.contains("- [x]"))
            #expect(result.contains("lines were found"))
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
