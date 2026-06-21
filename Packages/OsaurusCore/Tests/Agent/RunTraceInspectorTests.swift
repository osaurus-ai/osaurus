import Foundation
import Testing

@testable import OsaurusCore

struct RunTraceInspectorTests {
    @Test func validRunTraceSummarizesAndRedactsToolData() throws {
        let inspection = try inspectFixture("valid-run")

        #expect(inspection.artifactKind == .runTrace)
        #expect(inspection.summary.runId == "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        #expect(inspection.summary.agentId == "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
        #expect(inspection.summary.turnCount == 4)
        #expect(inspection.summary.toolCallCount == 1)
        #expect(inspection.summary.durationMs == 4_000)
        #expect(inspection.summary.tokensIn == 123)
        #expect(inspection.summary.tokensOut == 45)

        let call = try #require(inspection.toolCalls.first)
        #expect(call.name == "get_weather")
        #expect(call.resultStatus == "ok")
        #expect(call.argumentsPreview.contains(#""api_key":"[REDACTED]""#))
        #expect(call.resultPreview?.contains(#""authorization":"[REDACTED]""#) == true)
        #expect(!call.argumentsPreview.contains("sk-live-secret"))
        #expect(inspection.redactionCount == 2)
        #expect(inspection.findings.contains { $0.code == .redactionApplied })
        #expect(inspection.findings.contains { $0.code == .timingUnavailable })
    }

    @Test func malformedRunTraceReportsTypedFindingsWithoutDroppingTheArtifact() throws {
        let inspection = try inspectFixture("malformed-run")
        let codes = Set(inspection.findings.map(\.code))

        #expect(inspection.artifactKind == .runTrace)
        #expect(inspection.hasErrors)
        #expect(codes.contains(.invalidFieldValue))
        #expect(codes.contains(.malformedToolArguments))
        #expect(codes.contains(.missingToolResult))
        #expect(codes.contains(.orphanToolResult))
        #expect(!codes.contains(.decodeFailed))
        #expect(inspection.toolCalls.count == 1)
        #expect(inspection.toolCalls[0].argumentFormat == "invalid_json")
    }

    @Test func terminalErrorMessageRedactsInlineSecretsAndCountsRedactions() throws {
        let data = Data(
            """
            {
              "runId": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
              "agentId": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
              "sessionId": "session-1",
              "triggerSource": "chat",
              "status": "error",
              "startedAt": "2026-06-21T10:00:00Z",
              "endedAt": "2026-06-21T10:00:01Z",
              "tokensIn": null,
              "tokensOut": null,
              "costUSD": null,
              "errorMessage": "request failed: {\\"access_token\\":\\"live-token-value\\"}; Authorization: Bearer raw-secret-token",
              "turns": [
                {
                  "id": "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
                  "role": "assistant",
                  "content": "The provider returned an error.",
                  "thinking": null,
                  "toolCalls": null,
                  "toolCallId": null,
                  "toolResults": null
                }
              ]
            }
            """.utf8
        )

        let inspection = RunTraceInspector.inspect(data: data, options: .init(previewLimit: 400))
        let notes = inspection.summary.notes.joined(separator: "\n")
        let markdown = inspection.markdownReport()
        let json = String(decoding: try inspection.jsonReport(prettyPrinted: true), as: UTF8.self)

        #expect(notes.contains("[REDACTED]"))
        #expect(!notes.contains("live-token-value"))
        #expect(!notes.contains("raw-secret-token"))
        #expect(inspection.redactionCount == 2)
        #expect(inspection.findings.contains { $0.code == .redactionApplied })
        #expect(!markdown.contains("live-token-value"))
        #expect(!json.contains("raw-secret-token"))
    }

    @Test func structuralMalformedRunReportsMissingAndInvalidFields() {
        let data = Data(
            """
            {
              "runId": 17,
              "agentId": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
              "turns": {}
            }
            """.utf8
        )
        let inspection = RunTraceInspector.inspect(data: data)
        let codes = Set(inspection.findings.map(\.code))

        #expect(inspection.artifactKind == .runTrace)
        #expect(inspection.hasErrors)
        #expect(codes.contains(.invalidFieldType))
        #expect(codes.contains(.missingRequiredField))
        #expect(codes.contains(.decodeFailed))
    }

    @Test func evalReportInspectionSummarizesCasesAndToolUsage() throws {
        let inspection = try inspectFixture("eval-report")
        let codes = Set(inspection.findings.map(\.code))

        #expect(inspection.artifactKind == .evalReport)
        #expect(inspection.summary.modelId == "foundation")
        #expect(inspection.summary.stepCount == 2)
        #expect(inspection.summary.toolCallCount == 3)
        #expect(inspection.summary.toolErrorCount == 1)
        #expect(inspection.summary.status == "1 passed, 1 failed, 0 errored, 0 skipped")
        #expect(codes.contains(.traceError))
        #expect(codes.contains(.redactionApplied))
        #expect(!inspection.steps.compactMap(\.detail).joined().contains("abc12345"))
        #expect(inspection.toolCalls.map(\.name).contains("shell_run"))
    }

    @Test func markdownAndJSONReportsAreConciseAndRedacted() throws {
        let inspection = try inspectFixture("valid-run")
        let markdown = inspection.markdownReport()
        let jsonData = try inspection.jsonReport(prettyPrinted: true)
        let json = String(decoding: jsonData, as: UTF8.self)

        #expect(markdown.contains("# Run Trace Diagnostic"))
        #expect(markdown.contains("## Tool Calls"))
        #expect(markdown.contains("[REDACTED]"))
        #expect(!markdown.contains("sk-live-secret"))
        #expect(json.contains(#""artifactKind" : "runTrace""#))
        #expect(json.contains("[REDACTED]"))
        #expect(!json.contains("live-token-value"))
    }

    @Test func copiedReportsUseSafeSourcePathLabels() throws {
        let data = try fixtureData("valid-run")
        let inspection = RunTraceInspector.inspect(
            data: data,
            sourcePath: "/Users/alice/.osaurus/agents/private-agent/runs/private-run.json",
            options: .init(previewLimit: 400)
        )
        let markdown = inspection.markdownReport()
        let json = String(decoding: try inspection.jsonReport(prettyPrinted: true), as: UTF8.self)

        #expect(inspection.sourcePath == "private-run.json")
        #expect(markdown.contains("private-run.json"))
        #expect(!markdown.contains("/Users/alice"))
        #expect(json.contains("private-run.json"))
        #expect(!json.contains("/Users/alice"))
    }

    @Test func tokenLikeDiagnosticKeysAreNotOverRedacted() {
        let data = Data(
            """
            {
              "runId": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
              "agentId": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
              "sessionId": "session-1",
              "triggerSource": "chat",
              "status": "success",
              "startedAt": "2026-06-21T10:00:00Z",
              "endedAt": "2026-06-21T10:00:01Z",
              "tokensIn": null,
              "tokensOut": null,
              "costUSD": null,
              "errorMessage": null,
              "turns": [
                {
                  "id": "11111111-1111-1111-1111-111111111111",
                  "role": "assistant",
                  "content": "",
                  "thinking": null,
                  "toolCalls": [
                    {
                      "id": "call_config",
                      "name": "configure_model",
                      "arguments": "{\\"max_tokens\\":128,\\"token_type\\":\\"bearer\\",\\"tokenizer\\":\\"qwen\\",\\"access_token\\":\\"sensitive-token\\"}"
                    }
                  ],
                  "toolCallId": null,
                  "toolResults": null
                },
                {
                  "id": "22222222-2222-2222-2222-222222222222",
                  "role": "tool",
                  "content": "{\\"ok\\":true}",
                  "thinking": null,
                  "toolCalls": null,
                  "toolCallId": "call_config",
                  "toolResults": null
                }
              ]
            }
            """.utf8
        )

        let inspection = RunTraceInspector.inspect(data: data, options: .init(previewLimit: 400))
        let preview = inspection.toolCalls.first?.argumentsPreview ?? ""

        #expect(preview.contains(#""max_tokens":128"#))
        #expect(preview.contains(#""token_type":"bearer""#))
        #expect(preview.contains(#""tokenizer":"qwen""#))
        #expect(preview.contains(#""access_token":"[REDACTED]""#))
        #expect(!preview.contains("sensitive-token"))
    }

    @Test func markdownTableEscapesToolPreviewHTMLAndPipes() {
        let data = Data(
            """
            {
              "runId": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
              "agentId": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
              "sessionId": "session-1",
              "triggerSource": "chat",
              "status": "success",
              "startedAt": "2026-06-21T10:00:00Z",
              "endedAt": "2026-06-21T10:00:01Z",
              "tokensIn": null,
              "tokensOut": null,
              "costUSD": null,
              "errorMessage": null,
              "turns": [
                {
                  "id": "11111111-1111-1111-1111-111111111111",
                  "role": "assistant",
                  "content": "",
                  "thinking": null,
                  "toolCalls": [
                    {
                      "id": "call_html",
                      "name": "render|html",
                      "arguments": "unsafe <tag> & value|with|pipes"
                    }
                  ],
                  "toolCallId": null,
                  "toolResults": null
                },
                {
                  "id": "22222222-2222-2222-2222-222222222222",
                  "role": "tool",
                  "content": "ok <done> & stable|yes",
                  "thinking": null,
                  "toolCalls": null,
                  "toolCallId": "call_html",
                  "toolResults": null
                }
              ]
            }
            """.utf8
        )

        let markdown = RunTraceInspector.inspect(data: data, options: .init(previewLimit: 400)).markdownReport()

        #expect(markdown.contains("render\\|html"))
        #expect(markdown.contains("unsafe &lt;tag&gt; &amp; value\\|with\\|pipes"))
        #expect(markdown.contains("ok &lt;done&gt; &amp; stable\\|yes"))
    }

    @Test func plainTextNoErrorsResultDoesNotCountAsToolFailure() {
        let data = Data(
            """
            {
              "runId": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
              "agentId": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
              "sessionId": "session-1",
              "triggerSource": "chat",
              "status": "success",
              "startedAt": "2026-06-21T10:00:00Z",
              "endedAt": "2026-06-21T10:00:01Z",
              "tokensIn": null,
              "tokensOut": null,
              "costUSD": null,
              "errorMessage": null,
              "turns": [
                {
                  "id": "11111111-1111-1111-1111-111111111111",
                  "role": "assistant",
                  "content": "",
                  "thinking": null,
                  "toolCalls": [
                    {"id": "call_check", "name": "check_logs", "arguments": "{}"}
                  ],
                  "toolCallId": null,
                  "toolResults": null
                },
                {
                  "id": "22222222-2222-2222-2222-222222222222",
                  "role": "tool",
                  "content": "no errors found in the log",
                  "thinking": null,
                  "toolCalls": null,
                  "toolCallId": "call_check",
                  "toolResults": null
                }
              ]
            }
            """.utf8
        )

        let inspection = RunTraceInspector.inspect(data: data, options: .init(previewLimit: 400))

        #expect(inspection.toolCalls.first?.resultStatus == "ok")
        #expect(inspection.summary.toolErrorCount == 0)
        #expect(!inspection.findings.contains { $0.code == .traceError })
    }

    @Test func duplicateToolResultsAreReported() {
        let data = Data(
            """
            {
              "runId": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
              "agentId": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
              "sessionId": "session-1",
              "triggerSource": "chat",
              "status": "success",
              "startedAt": "2026-06-21T10:00:00Z",
              "endedAt": "2026-06-21T10:00:01Z",
              "tokensIn": null,
              "tokensOut": null,
              "costUSD": null,
              "errorMessage": null,
              "turns": [
                {
                  "id": "11111111-1111-1111-1111-111111111111",
                  "role": "assistant",
                  "content": "",
                  "thinking": null,
                  "toolCalls": [
                    {"id": "call_dup", "name": "lookup", "arguments": "{}"}
                  ],
                  "toolCallId": null,
                  "toolResults": null
                },
                {
                  "id": "22222222-2222-2222-2222-222222222222",
                  "role": "tool",
                  "content": "first result",
                  "thinking": null,
                  "toolCalls": null,
                  "toolCallId": "call_dup",
                  "toolResults": {"call_dup": "second result"}
                }
              ]
            }
            """.utf8
        )

        let inspection = RunTraceInspector.inspect(data: data, options: .init(previewLimit: 400))

        #expect(inspection.findings.contains { $0.code == .duplicateToolResult })
    }

    @Test func genericStepTraceRedactsDetailsAndCanHideInfoFindings() {
        let data = Data(
            """
            {
              "title": "Replay",
              "status": "failed",
              "durationMs": 250,
              "steps": [
                {"title": "prepare", "status": "ok", "detail": "ready"},
                {"title": "call", "status": "failed", "detail": "{\\"api_key\\":\\"secret-value\\",\\"message\\":\\"boom\\"}"}
              ]
            }
            """.utf8
        )

        let inspection = RunTraceInspector.inspect(data: data, options: .init(includeInformationalFindings: false))

        #expect(inspection.artifactKind == .genericSteps)
        #expect(inspection.summary.stepCount == 2)
        #expect(inspection.summary.toolErrorCount == 1)
        #expect(inspection.redactionCount == 1)
        #expect(inspection.steps[1].detail?.contains("[REDACTED]") == true)
        #expect(!inspection.steps[1].detail.orEmpty.contains("secret-value"))
        #expect(inspection.findings.allSatisfy { $0.severity != .info })
    }

    @Test func fileAndUnsupportedArtifactsReturnTypedErrors() throws {
        let missingURL = URL(fileURLWithPath: "/tmp/osaurus-missing-run-trace.json")
        let missing = RunTraceInspector.inspectFile(at: missingURL)
        let unsupported = RunTraceInspector.inspect(data: Data("[1,2,3]".utf8))
        let unknown = RunTraceInspector.inspect(data: Data(#"{"unexpected":true}"#.utf8))

        #expect(missing.sourcePath == "osaurus-missing-run-trace.json")
        #expect(missing.findings.contains { $0.code == .fileReadFailed })
        #expect(unsupported.findings.contains { $0.code == .invalidFieldType })
        #expect(unknown.findings.contains { $0.code == .unsupportedArtifact })
    }

    @Test func previewLimitHasUpperBound() {
        let options = RunTraceInspector.Options(previewLimit: 50_000)

        #expect(options.previewLimit == RunTraceInspector.Options.maximumPreviewLimit)
    }

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureURL(name))
    }

    private func inspectFixture(_ name: String) throws -> RunTraceInspection {
        let data = try fixtureData(name)
        let url = try fixtureURL(name)
        return RunTraceInspector.inspect(
            data: data,
            sourcePath: url.path,
            options: .init(previewLimit: 400)
        )
    }

    private func fixtureURL(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/RunTrace"
        ) else {
            throw FixtureError.missing(name)
        }
        return url
    }
}

private enum FixtureError: Error {
    case missing(String)
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
