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

    @Test func invertedRunTimingIsBlockedAndNeverRenderedAsNegative() {
        let data = Data(
            """
            {
              "runId": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
              "agentId": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
              "sessionId": "session-1",
              "triggerSource": "chat",
              "status": "error",
              "startedAt": "2026-06-21T10:00:05Z",
              "endedAt": "2026-06-21T10:00:00Z",
              "turns": []
            }
            """.utf8
        )

        let inspection = RunTraceInspector.inspect(data: data)
        #expect(inspection.summary.durationMs == nil)
        #expect(inspection.findings.contains { $0.code == .invalidFieldValue })
        #expect(!inspection.canExport)
    }

    @Test func negativeGenericTimingIsBlockedAndOmitted() {
        let data = Data(
            """
            {
              "title": "invalid timing",
              "durationMs": -10,
              "steps": [{"title": "bad step", "latencyMs": -2}]
            }
            """.utf8
        )

        let inspection = RunTraceInspector.inspect(data: data)
        #expect(inspection.summary.durationMs == nil)
        #expect(inspection.steps.first?.timingMs == nil)
        #expect(inspection.findings.filter { $0.code == .invalidFieldValue }.count == 2)
        #expect(!inspection.canExport)
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
        let markdown = try inspection.markdownReport()
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
        let markdown = try inspection.markdownReport()
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
        let markdown = try inspection.markdownReport()
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

    @Test func markdownTableEscapesToolPreviewHTMLAndPipes() throws {
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

        let markdown = try RunTraceInspector.inspect(data: data, options: .init(previewLimit: 400)).markdownReport()

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

    @Test func boundedFileReadRejectsOversizedArtifactBeforeParsing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x20, count: 2_049).write(to: url)

        let inspection = RunTraceInspector.inspectFile(
            at: url,
            options: .init(maximumFileBytes: 2_048)
        )

        #expect(inspection.findings.contains { $0.code == .fileTooLarge })
        #expect(!inspection.canExport)
        #expect(throws: RunTraceInspection.ExportError.self) { try inspection.markdownReport() }
    }

    @Test func fileInspectionRejectsOutsideRootAndHardLinkedTrace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let linked = root.appendingPathComponent("linked.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data(#"{"title":"safe","steps":[]}"#.utf8).write(to: outside)

        let escaped = RunTraceInspector.inspectFile(at: outside, allowedRoot: root)
        #expect(escaped.findings.contains { $0.code == .fileReadFailed })
        let escapedMessageContainsPath = (escaped.findings.first?.message ?? "").contains(outside.path)
        #expect(!escapedMessageContainsPath)

        try FileManager.default.linkItem(at: outside, to: linked)
        let hardLinked = RunTraceInspector.inspectFile(at: linked, allowedRoot: root)
        #expect(hardLinked.findings.contains { $0.code == .fileReadFailed })
        #expect(!hardLinked.canExport)
    }

    @Test func hostileDepthAndLongStringsFailBeforeJSONMaterialization() {
        let deep = Data((String(repeating: "[", count: 9) + "0" + String(repeating: "]", count: 9)).utf8)
        let long = Data("{\"steps\":[{\"detail\":\"\(String(repeating: "a", count: 513))\"}]}".utf8)

        let deepInspection = RunTraceInspector.inspect(
            data: deep,
            options: .init(maximumNestingDepth: 8)
        )
        let longInspection = RunTraceInspector.inspect(
            data: long,
            options: .init(maximumStringBytes: 512)
        )

        #expect(deepInspection.findings.contains { $0.code == .resourceLimitExceeded })
        #expect(longInspection.findings.contains { $0.code == .resourceLimitExceeded })
        #expect(!deepInspection.canExport)
        #expect(!longInspection.canExport)
    }

    @Test func collectionLimitsBoundTurnsStepsAndToolCalls() {
        let turns = (0 ..< 3).map { index in
            "{\"id\":\"00000000-0000-0000-0000-00000000000\(index)\",\"role\":\"assistant\",\"content\":\"\",\"thinking\":null,\"toolCalls\":[],\"toolCallId\":null,\"toolResults\":null}"
        }.joined(separator: ",")
        let data = Data(
            "{\"runId\":\"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA\",\"agentId\":\"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB\",\"turns\":[\(turns)]}".utf8
        )

        let inspection = RunTraceInspector.inspect(data: data, options: .init(maximumTurns: 2))

        #expect(inspection.findings.contains { $0.code == .resourceLimitExceeded })
        #expect(inspection.exportBlockReason?.contains("turns") == true)

        let eval = Data(
            "{\"modelId\":\"foundation\",\"startedAt\":\"2026-07-11T00:00:00Z\",\"cases\":[{\"id\":\"case\",\"domain\":\"agent\",\"outcome\":\"passed\",\"toolUsage\":[{\"tool\":\"a\"},{\"tool\":\"b\"}]}]}".utf8
        )
        let boundedEval = RunTraceInspector.inspect(
            data: eval,
            options: .init(maximumToolCalls: 1)
        )
        #expect(boundedEval.findings.contains { $0.code == .resourceLimitExceeded })
        #expect(!boundedEval.canExport)
    }

    @Test func malformedOrUnrecognizedArtifactsCannotBeCopied() {
        let malformed = RunTraceInspector.inspect(data: Data("{\"steps\":[".utf8))
        let unknown = RunTraceInspector.inspect(data: Data("{\"private\":true}".utf8))

        #expect(!malformed.canExport)
        #expect(!unknown.canExport)
        #expect(throws: RunTraceInspection.ExportError.self) { try malformed.jsonReport() }
        #expect(throws: RunTraceInspection.ExportError.self) { try unknown.markdownReport() }
    }

    @Test func reportEscapesMarkdownAndRefusesBidirectionalMetadata() throws {
        let markdownData = Data(
            "{\"title\":\"[click](https://example.com)\",\"steps\":[{\"title\":\"*unsafe*\",\"detail\":\"<script>bad</script>\"}]}".utf8
        )
        let markdown = try RunTraceInspector.inspect(data: markdownData).markdownReport()
        #expect(markdown.contains("\\[click\\](https://example.com)"))
        #expect(markdown.contains("\\*unsafe\\*"))
        #expect(markdown.contains("&lt;script&gt;"))

        let bidi = RunTraceInspector.inspect(
            data: Data("{\"title\":\"safe\\u202Etxt\",\"steps\":[]}".utf8)
        )
        #expect(bidi.summary.title == "safe�txt")
        #expect(bidi.canExport)
        _ = try bidi.jsonReport()
        _ = try bidi.markdownReport()

        let localPath = RunTraceInspector.inspect(
            data: Data("{\"title\":\"/Users/alice/private.txt\",\"steps\":[]}".utf8)
        )
        #expect(!localPath.canExport)
        #expect(localPath.exportBlockReason?.contains("local path") == true)
        #expect(throws: RunTraceInspection.ExportError.self) { try localPath.jsonReport() }
        #expect(throws: RunTraceInspection.ExportError.self) { try localPath.markdownReport() }

        for path in ["~/private/run.json", "/Library/Secret/run.json", "/opt/private/run.json"] {
            let inspection = RunTraceInspector.inspect(
                data: Data("{\"title\":\"\(path)\",\"steps\":[]}".utf8)
            )
            #expect(!inspection.canExport)
        }
    }

    @Test func redactionHasPositiveAndNegativeControls() throws {
        let data = Data(
            "{\"title\":\"controls\",\"steps\":[{\"title\":\"one\",\"detail\":\"api_key=abcdefgh tokenizer=qwen max_tokens=128\"}]}".utf8
        )
        let inspection = RunTraceInspector.inspect(data: data)
        let detail = try #require(inspection.steps.first?.detail)

        #expect(detail.contains("api_key=[REDACTED]"))
        #expect(detail.contains("tokenizer=qwen"))
        #expect(detail.contains("max_tokens=128"))
        #expect(!detail.contains("abcdefgh"))

        let camelCase = Data(
            #"{"title":"secrets","steps":[{"title":"one","detail":"{\"accessToken\":\"leak-a\",\"clientSecret\":\"leak-b\",\"privateKey\":\"leak-c\",\"aws_secret_access_key\":\"leak-d\"}"}]}"#.utf8
        )
        let camelInspection = RunTraceInspector.inspect(data: camelCase)
        let camelDetail = try #require(camelInspection.steps.first?.detail)
        #expect(!camelDetail.contains("leak-"))
        #expect(camelDetail.components(separatedBy: "[REDACTED]").count == 5)
        #expect(!String(decoding: try camelInspection.jsonReport(), as: UTF8.self).contains("leak-"))

        let plural = Data(
            #"{"steps":[{"detail":"{\"credentials\":\"leak-a\",\"cookies\":\"leak-b\",\"passwords\":\"leak-c\",\"secrets\":\"leak-d\"}"}]}"#.utf8
        )
        let pluralReport = String(decoding: try RunTraceInspector.inspect(data: plural).jsonReport(), as: UTF8.self)
        #expect(!pluralReport.contains("leak-"))
    }

    @Test func genericStepsTakePrecedenceOverMetadataOnlyEvalHeuristic() {
        let inspection = RunTraceInspector.inspect(
            data: Data(
                #"{"modelId":"foundation","startedAt":"2026-07-11T00:00:00Z","steps":[{"title":"kept"}]}"#.utf8
            )
        )

        #expect(inspection.artifactKind == .genericSteps)
        #expect(inspection.steps.first?.title == "kept")
    }

    @Test func uiFacingMetadataSanitizesBidirectionalControls() throws {
        let inspection = RunTraceInspector.inspect(
            data: Data(
                "{\"title\":\"safe\\u202Etitle\",\"status\":\"ok\\u2066spoof\",\"steps\":[{\"title\":\"step\\u202Ename\",\"status\":\"done\\u2069\"}]}".utf8
            )
        )

        #expect(!inspection.summary.title.contains("\u{202E}"))
        #expect(!(inspection.summary.status ?? "").contains("\u{2066}"))
        #expect(!inspection.steps[0].title.contains("\u{202E}"))
        #expect(!(inspection.steps[0].status ?? "").contains("\u{2069}"))
        #expect(inspection.canExport)
        _ = try inspection.markdownReport()
        _ = try inspection.jsonReport()
    }

    @Test func sourceLabelsDropPOSIXWindowsAndUNCPaths() throws {
        let fixture = try fixtureData("valid-run")
        for path in [
            "/Users/alice/private/run.json",
            #"C:\Users\Alice\private\run.json"#,
            #"\\server\share\private\run.json"#,
        ] {
            let inspection = RunTraceInspector.inspect(data: fixture, sourcePath: path)
            #expect(inspection.sourcePath == "run.json")
            let report = try inspection.markdownReport()
            #expect(!report.contains("Alice"))
            #expect(!report.contains("server"))
        }
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
