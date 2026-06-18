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

    private func inspectFixture(_ name: String) throws -> RunTraceInspection {
        let data = try Data(contentsOf: fixtureURL(name))
        return RunTraceInspector.inspect(
            data: data,
            sourcePath: fixtureURL(name).path,
            options: .init(previewLimit: 400)
        )
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RunTrace/\(name).json")
    }
}
