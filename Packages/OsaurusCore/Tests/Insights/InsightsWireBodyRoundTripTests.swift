//
//  InsightsWireBodyRoundTripTests.swift
//  osaurusTests
//
//  Verifies that `InsightsService.logInference` / `logRequest`
//  propagate the wire request + response bodies through to the
//  resulting `RequestLog` and that the formatted-body computed
//  properties pretty-print JSON the same way the existing
//  request/response surfaces do.
//
//  `InsightsService.shared` is a process-wide singleton, so each
//  test must locate its own log inside the shared ring buffer.
//  `.serialized` only orders tests within this suite — other
//  suites running in parallel can prepend their own entries
//  between our `logInference` call and the assertion. We tag
//  every log with a UUID-suffixed model and look it up by that
//  tag instead of trusting `logs.first`. PR #1244 CI run
//  77781199384 (job test-core) caught the regression.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite("Insights WireBody RoundTrip", .serialized)
struct InsightsWireBodyRoundTripTests {

    /// Wait for the next main-actor hop so a `Task { @MainActor in ... }`
    /// posted by `InsightsService.logRequest` lands into `logs`
    /// before the assertion fires. `InsightsService` posts the
    /// append asynchronously to keep callers off the actor; we
    /// have to flush that hop deterministically here.
    private func settle() async {
        await Task.yield()
        // A second yield + small sleep handles the case where the
        // posted Task has been enqueued but not yet drained — the
        // 5 ms is well under any reasonable CI runtime budget.
        try? await Task.sleep(nanoseconds: 5_000_000)
        await Task.yield()
    }

    /// Unique model identifier scoped to a single test run. Any
    /// log that uses this string is provably ours — other suites
    /// don't fabricate UUIDs into their model fields.
    private func uniqueModel(_ tag: String) -> String {
        "test-\(tag)-\(UUID().uuidString)"
    }

    /// Find the log this test wrote, ignoring anything written by
    /// concurrently-running suites that may have prepended into
    /// the shared ring buffer between `logInference` and assertion.
    private func findLog(model: String) -> RequestLog? {
        InsightsService.shared.logs.first { $0.model == model }
    }

    @Test func hasLog_tracksTurnAvailability() {
        let turnId = UUID()
        #expect(InsightsService.shared.hasLog(turnId: turnId) == false)

        InsightsService.shared.log(
            RequestLog(
                source: .chatUI,
                turnId: turnId,
                method: "POST",
                path: "/chat/completions",
                statusCode: 200,
                durationMs: 10,
                model: uniqueModel("turn-availability"),
                inputTokens: 1,
                outputTokens: 1
            )
        )

        #expect(InsightsService.shared.hasLog(turnId: turnId) == true)
    }

    @Test func requestIdFocusTargetsExactLog_whenTurnHasMultipleLogs() {
        let turnId = UUID()
        let first = RequestLog(
            source: .chatUI,
            turnId: turnId,
            requestId: "run-abc:1",
            method: "POST",
            path: "/chat/completions",
            statusCode: 200,
            durationMs: 10,
            model: uniqueModel("request-focus-first"),
            inputTokens: 1,
            outputTokens: 1
        )
        let second = RequestLog(
            source: .chatUI,
            turnId: turnId,
            requestId: "run-abc:2",
            method: "POST",
            path: "/chat/completions",
            statusCode: 200,
            durationMs: 10,
            model: uniqueModel("request-focus-second"),
            inputTokens: 1,
            outputTokens: 1
        )

        InsightsService.shared.log(first)
        InsightsService.shared.log(second)

        #expect(InsightsService.shared.hasLog(requestId: "run-abc:1") == true)
        #expect(InsightsService.shared.focus(requestId: "run-abc:1") == true)
        #expect(InsightsService.shared.pendingFocusLogId == first.id)
        #expect(InsightsService.shared.focus(requestId: "missing") == false)
    }

    @Test func logInference_propagatesWireBodies() async {
        let model = uniqueModel("wirebody-propagate")
        let reqJSON = #"{"model":"gpt-4o","messages":[]}"#
        let respJSON = #"{"id":"abc","object":"chat.completion"}"#
        InsightsService.logInference(
            source: .chatUI,
            model: model,
            inputTokens: 12,
            outputTokens: 3,
            durationMs: 80,
            temperature: 0.7,
            maxTokens: 1024,
            wireRequestBody: reqJSON.data(using: .utf8),
            wireResponseBody: respJSON.data(using: .utf8)
        )
        await settle()
        guard let log = findLog(model: model) else {
            Issue.record("Expected a log entry for model=\(model)")
            return
        }
        #expect(log.wireRequestBody == reqJSON)
        #expect(log.wireResponseBody == respJSON)
    }

    @Test func formattedWireRequestBody_prettyPrintsJSON() async {
        let model = uniqueModel("wirebody-pretty")
        let reqJSON = #"{"b":2,"a":1}"#
        InsightsService.logInference(
            source: .chatUI,
            model: model,
            inputTokens: 1,
            outputTokens: 1,
            durationMs: 10,
            temperature: nil,
            maxTokens: 1,
            wireRequestBody: reqJSON.data(using: .utf8)
        )
        await settle()
        guard let log = findLog(model: model) else {
            Issue.record("Expected a log entry for model=\(model)")
            return
        }
        // Sorted keys + newline indentation. `\` quoting is
        // standard JSONSerialization output.
        let formatted = log.formattedWireRequestBody
        #expect(formatted?.contains("\"a\" : 1") == true)
        #expect(formatted?.contains("\"b\" : 2") == true)
        #expect(formatted?.contains("\n") == true)
        // "a" must precede "b" — keys are sorted.
        if let formatted,
            let aRange = formatted.range(of: "\"a\""),
            let bRange = formatted.range(of: "\"b\"")
        {
            #expect(aRange.lowerBound < bRange.lowerBound)
        }
    }

    @Test func formattedWireResponseBody_passesThroughSSEBodyVerbatim() async {
        let model = uniqueModel("wirebody-sse")
        // SSE bodies aren't valid JSON in aggregate — formatter must
        // return them verbatim instead of dropping them.
        let sse =
            "data: {\"id\":\"1\"}\n\ndata: {\"id\":\"2\"}\n\ndata: [DONE]\n\n"
        InsightsService.logInference(
            source: .chatUI,
            model: model,
            inputTokens: 1,
            outputTokens: 1,
            durationMs: 10,
            temperature: nil,
            maxTokens: 1,
            wireResponseBody: sse.data(using: .utf8)
        )
        await settle()
        guard let log = findLog(model: model) else {
            Issue.record("Expected a log entry for model=\(model)")
            return
        }
        #expect(log.formattedWireResponseBody == sse)
    }

    @Test func absentWireBodies_leaveLogFieldsNil() async {
        let model = uniqueModel("wirebody-absent")
        InsightsService.logInference(
            source: .chatUI,
            model: model,
            inputTokens: 1,
            outputTokens: 1,
            durationMs: 10,
            temperature: nil,
            maxTokens: 1
        )
        await settle()
        guard let log = findLog(model: model) else {
            Issue.record("Expected a log entry for model=\(model)")
            return
        }
        #expect(log.wireRequestBody == nil)
        #expect(log.wireResponseBody == nil)
        #expect(log.formattedWireRequestBody == nil)
        #expect(log.formattedWireResponseBody == nil)
    }

    // MARK: - Sub-toggle default source

    /// When both bodies exist, the Request/Response tab must
    /// default to the Server view — that's the trust artifact the
    /// user opened the tab for. Used by `BodyTab.init` when the
    /// sheet first appears.
    @Test func bodyTab_defaultsToServer_whenWireBodyPresent() {
        let result = InsightsBodySource.defaultSource(local: "local", server: "server")
        #expect(result == .server)
    }

    /// When no wire body was captured (MLX / Foundation / plugin
    /// rows), the sub-toggle hides anyway, but the default source
    /// must still fall back to Local so the body view isn't empty.
    @Test func bodyTab_defaultsToLocal_whenNoWireBody() {
        let result = InsightsBodySource.defaultSource(local: "local", server: nil)
        #expect(result == .local)
    }

    /// Edge case: nothing captured at all (e.g. a failed request
    /// before the body materialized). Default still resolves
    /// deterministically; the BodyTab's empty-state takes over.
    @Test func bodyTab_defaultsToLocal_whenBothNil() {
        let result = InsightsBodySource.defaultSource(local: nil, server: nil)
        #expect(result == .local)
    }
}
