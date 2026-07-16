//
//  RenderChartToolTests.swift
//  OsaurusCoreTests
//
//  Locks the source-agnostic chart contract: raw data retrieved from the web,
//  a sandbox, or computation is just as valid as attachment content.
//

import Foundation
import Testing

@testable import OsaurusCore

struct RenderChartToolTests {

    @Test func descriptionAcceptsRetrievedOrGeneratedData() {
        let description = RenderChartTool().description
        #expect(description.contains("web extraction"))
        #expect(description.contains("computation"))
        #expect(description.contains("does not fetch URLs"))
        #expect(description.contains("dataRef"))
        #expect(description.contains("header row"))
        #expect(description.contains("numeric columns are inferred"))
        #expect(description.contains("already displayed as an inline chart card"))
        #expect(!description.contains("use `share_artifact` instead"))
    }

    @Test func omittedSeriesAndQuotedCSVInferNumericColumns() async throws {
        let argumentsJSON = #"""
            {
              "chartType": "line",
              "data": "\"month,value\nJan,1\nFeb,2\nMar,3\"",
              "dataFormat": "csv",
              "title": "Monthly Values"
            }
            """#
        let tool = RenderChartTool()
        let normalizedJSON: String
        switch await ToolRegistry.shared.preflightForTest(
            argumentsJSON: argumentsJSON,
            schema: tool.parameters,
            toolName: tool.name
        ) {
        case .ready(let normalized):
            normalizedJSON = normalized
        case .rejected(let envelope):
            Issue.record("preflight rejected the observed Bonsai chart arguments: \(envelope)")
            return
        }

        let result = try await tool.execute(argumentsJSON: normalizedJSON)
        #expect(ToolEnvelope.isSuccess(result))
        let payload = try #require(ToolEnvelope.successPayload(result) as? [String: Any])
        let marker = try #require(payload["text"] as? String)
        #expect(marker.contains("\"categories\":[\"Jan\",\"Feb\",\"Mar\"]"))
        #expect(marker.contains("\"name\":\"value\""))
        #expect(marker.contains("\"data\":[1,2,3]"))
    }

    @Test func omittedSeriesAndHeaderlessRowsPreserveFirstPoint() async throws {
        let argumentsJSON = #"""
            {
              "chartType": "line",
              "data": "Jan,1\nFeb,2\nMar,3",
              "dataFormat": "csv",
              "title": "Monthly Values"
            }
            """#
        let tool = RenderChartTool()
        let normalizedJSON: String
        switch await ToolRegistry.shared.preflightForTest(
            argumentsJSON: argumentsJSON,
            schema: tool.parameters,
            toolName: tool.name
        ) {
        case .ready(let normalized):
            normalizedJSON = normalized
        case .rejected(let envelope):
            Issue.record("preflight rejected the observed Bonsai chart arguments: \(envelope)")
            return
        }

        let result = try await tool.execute(argumentsJSON: normalizedJSON)
        #expect(ToolEnvelope.isSuccess(result))
        let payload = try #require(ToolEnvelope.successPayload(result) as? [String: Any])
        let marker = try #require(payload["text"] as? String)
        #expect(marker.contains("\"categories\":[\"Jan\",\"Feb\",\"Mar\"]"))
        #expect(marker.contains("\"name\":\"value\""))
        #expect(marker.contains("\"data\":[1,2,3]"))
    }

    @Test func omittedSeriesPreservesNumericColumnHeader() async throws {
        let result = try await RenderChartTool().execute(
            argumentsJSON: #"""
                {
                  "chartType": "line",
                  "data": "month,2024\nJan,1\nFeb,2",
                  "dataFormat": "csv"
                }
                """#
        )

        #expect(ToolEnvelope.isSuccess(result))
        let payload = try #require(ToolEnvelope.successPayload(result) as? [String: Any])
        let marker = try #require(payload["text"] as? String)
        #expect(marker.contains("\"categories\":[\"Jan\",\"Feb\"]"))
        #expect(marker.contains("\"name\":\"2024\""))
        #expect(marker.contains("\"data\":[1,2]"))
    }

    @Test func headerlessDelimitedRowsRecoverFromRequestedSeries() async throws {
        let result = try await RenderChartTool().execute(
            argumentsJSON: #"""
                {
                  "data": "Jan,1200\nFeb,2400\nMar,1800",
                  "format": "csv",
                  "chartType": "column",
                  "series": ["Revenue"],
                  "title": "Monthly Revenue"
                }
                """#
        )

        #expect(ToolEnvelope.isSuccess(result))
        let payload = try #require(ToolEnvelope.successPayload(result) as? [String: Any])
        let marker = try #require(payload["text"] as? String)
        #expect(marker.contains("\"categories\":[\"Jan\",\"Feb\",\"Mar\"]"))
        #expect(marker.contains("\"name\":\"Revenue\""))
    }

    @Test func textualHeaderWithMisspelledSeriesStillFails() async throws {
        let result = try await RenderChartTool().execute(
            argumentsJSON: #"""
                {
                  "data": "month,revenue\nJan,1200\nFeb,2400",
                  "format": "csv",
                  "chartType": "column",
                  "series": ["Revenue"]
                }
                """#
        )

        #expect(!ToolEnvelope.isSuccess(result))
        #expect(result.contains("Column(s) not found: Revenue"))
    }

    @Test func rawCSVWithoutAttachmentRendersChart() async throws {
        let result = try await RenderChartTool().execute(
            argumentsJSON: #"""
                {
                  "data": "date,close\n2026-01-01,681.2\n2026-01-02,684.5",
                  "format": "csv",
                  "chartType": "line",
                  "xColumn": "date",
                  "series": ["close"],
                  "title": "S&P 500"
                }
                """#
        )

        #expect(ToolEnvelope.isSuccess(result))
        let payload = try #require(ToolEnvelope.successPayload(result) as? [String: Any])
        let marker = try #require(payload["text"] as? String)
        #expect(marker.contains("---CHART_START---"))
        #expect(marker.contains("\"categories\":[\"2026-01-01\",\"2026-01-02\"]"))
        #expect(marker.contains("\"name\":\"close\""))
    }

    @Test func missingChartTypeDefaultsToLineWithoutDroppingOtherArguments() async throws {
        let tool = RenderChartTool()
        let argumentsJSON = #"""
            {
              "data": "date,close\n2026-01-01,681.2\n2026-01-02,684.5",
              "format": "csv",
              "xColumn": "date",
              "series": ["close"]
            }
            """#

        switch await ToolRegistry.shared.preflightForTest(
            argumentsJSON: argumentsJSON,
            schema: tool.parameters,
            toolName: tool.name
        ) {
        case .ready:
            break
        case .rejected(let envelope):
            Issue.record("preflight rejected the recoverable default chart type: \(envelope)")
        }

        let result = try await tool.execute(argumentsJSON: argumentsJSON)
        #expect(ToolEnvelope.isSuccess(result))
        let payload = try #require(ToolEnvelope.successPayload(result) as? [String: Any])
        let marker = try #require(payload["text"] as? String)
        #expect(marker.contains("\"chartType\":\"line\""))
        #expect(marker.contains("\"name\":\"close\""))
    }

    @Test func stringifiedFunctionArgumentsEnvelopeRendersOnFirstCall() async throws {
        let sessionId = "chart-arguments-wrapper-\(UUID().uuidString)"
        let dataRef = try #require(
            await SearchStructuredDataStore.shared.store(
                raw: "date,open\n2026-01-01,127.49\n2026-01-02,128.10",
                format: "csv",
                sourceURL: "https://example.com/prices.csv",
                sessionId: sessionId
            )
        )
        let wrapped = try JSONSerialization.data(withJSONObject: [
            "arguments": try #require(
                String(
                    data: JSONSerialization.data(withJSONObject: [
                        "chartType": "line",
                        "dataRef": dataRef,
                        "format": "csv",
                        "series": ["open"],
                        "xColumn": "date",
                    ]),
                    encoding: .utf8
                )
            )
        ])
        let argumentsJSON = String(decoding: wrapped, as: UTF8.self)
        let tool = RenderChartTool()
        let normalizedJSON: String
        switch await ToolRegistry.shared.preflightForTest(
            argumentsJSON: argumentsJSON,
            schema: tool.parameters,
            toolName: tool.name
        ) {
        case .ready(let normalized):
            normalizedJSON = normalized
        case .rejected(let envelope):
            Issue.record("preflight rejected the observed Bonsai arguments wrapper: \(envelope)")
            return
        }

        let result = try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
            try await tool.execute(argumentsJSON: normalizedJSON)
        }
        #expect(ToolEnvelope.isSuccess(result))
        let payload = try #require(ToolEnvelope.successPayload(result) as? [String: Any])
        let marker = try #require(payload["text"] as? String)
        #expect(marker.contains("\"chartType\":\"line\""))
        #expect(marker.contains("\"name\":\"open\""))
    }

    @Test func structuredDataReferencesAreCompactStableAndSessionScoped() async throws {
        let sessionId = "chart-reference-contract-\(UUID().uuidString)"
        let sourceURL = "https://example.com/prices.csv"
        let first = try #require(
            await SearchStructuredDataStore.shared.store(
                raw: "date,open\n2026-01-01,127.49",
                format: "csv",
                sourceURL: sourceURL,
                sessionId: sessionId
            )
        )
        let refreshed = try #require(
            await SearchStructuredDataStore.shared.store(
                raw: "date,open\n2026-01-01,128.10",
                format: "csv",
                sourceURL: sourceURL,
                sessionId: sessionId
            )
        )

        #expect(first == refreshed)
        #expect(first.hasPrefix("webdata:"))
        #expect(first.count < 24)
        #expect(first.dropFirst("webdata:".count).allSatisfy { $0.isASCII && $0.isLetter || $0.isNumber })
        #expect(await SearchStructuredDataStore.shared.load(reference: first, sessionId: sessionId)?.raw.contains("128.10") == true)
        #expect(await SearchStructuredDataStore.shared.load(reference: first, sessionId: "other-session") == nil)
    }

    @Test func nestedJSONDataReferenceRendersWithoutCopyingRawPayload() async throws {
        let sessionId = "chart-ref-\(UUID().uuidString)"
        let raw =
            #"{"chart":{"result":[{"timestamp":[1752586200,1752672600],"indicators":{"quote":[{"close":[6243.75,6263.70]}]}}]}}"#
        let dataRef = try #require(
            await SearchStructuredDataStore.shared.store(
                raw: raw,
                format: "json",
                sourceURL: "https://example.com/chart.json",
                sessionId: sessionId
            )
        )

        let result = try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
            try await RenderChartTool().execute(
                argumentsJSON: #"""
                    {
                      "dataRef": "\#(dataRef)",
                      "format": "json",
                      "chartType": "line",
                      "xPath": "chart.result[0].timestamp",
                      "seriesPaths": [
                        {"name": "Close", "path": "chart.result[0].indicators.quote[0].close"}
                      ],
                      "title": "S&P 500"
                    }
                    """#
            )
        }

        #expect(ToolEnvelope.isSuccess(result))
        let payload = try #require(ToolEnvelope.successPayload(result) as? [String: Any])
        let marker = try #require(payload["text"] as? String)
        #expect(marker.contains("\"categories\":[\"2025-07-15\",\"2025-07-16\"]"))
        #expect(marker.contains("\"data\":[6243.75,6263.7]"))
        #expect(marker.contains("\"name\":\"Close\""))
    }

    @Test func nestedJSONReferenceAcceptsObservedLocalModelArgumentDrift() async throws {
        let sessionId = "chart-ref-drift-\(UUID().uuidString)"
        let raw =
            #"{"chart":{"result":[{"timestamp":[1752586200,1752672600],"indicators":{"quote":[{"close":[6243.75,6263.70]}]}}]}}"#
        let dataRef = try #require(
            await SearchStructuredDataStore.shared.store(
                raw: raw,
                format: "json",
                sourceURL: "https://example.com/chart.json",
                sessionId: sessionId
            )
        )

        let argumentsJSON = #"""
            {
              "dataRef": "\#(dataRef)",
              "dataFormat": "json",
              "chartType": "line",
              "series": "[Close]",
              "xPath": "chart.result[0].timestamp",
              "seriesPaths": [
                {"name": "Close", "path": "chart.result[0].indicators.quote[0].close"}
              ]
            }
            """#
        let tool = RenderChartTool()
        switch await ToolRegistry.shared.preflightForTest(
            argumentsJSON: argumentsJSON,
            schema: tool.parameters,
            toolName: tool.name
        ) {
        case .ready:
            break
        case .rejected(let envelope):
            Issue.record("preflight rejected observed local-model arguments: \(envelope)")
        }

        let result = try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
            try await tool.execute(argumentsJSON: argumentsJSON)
        }

        #expect(ToolEnvelope.isSuccess(result))
        let payload = try #require(ToolEnvelope.successPayload(result) as? [String: Any])
        let marker = try #require(payload["text"] as? String)
        #expect(marker.contains("\"categories\":[\"2025-07-15\",\"2025-07-16\"]"))
    }

    @Test func modelFacingResultOmitsChartPointsAfterInlineRendering() async throws {
        let csv = (["date,close"] + (0 ..< 252).map { "day-\($0),\(6_000 + $0)" })
            .joined(separator: "\n")
        let arguments = try JSONSerialization.data(withJSONObject: [
            "data": csv,
            "format": "csv",
            "chartType": "line",
            "xColumn": "date",
            "series": ["close"],
            "title": "S&P 500",
        ])
        let rendered = try await RenderChartTool().execute(
            argumentsJSON: String(decoding: arguments, as: UTF8.self)
        )
        let compact = try #require(RenderChartTool.compactModelResult(from: rendered))
        #expect(compact.count < 512)
        #expect(compact.count * 8 < rendered.count)
        #expect(!compact.contains("---CHART_START---"))
        #expect(!compact.contains("day-100"))
        #expect(!compact.contains("6100"))
        #expect(compact.contains("\"display\":\"inline_chart_card\""))
        #expect(compact.contains("\"point_count\":252"))
        #expect(compact.contains("\"series\":[\"close\"]"))
        #expect(compact.contains("\"x_start\":\"day-0\""))
        #expect(compact.contains("\"x_end\":\"day-251\""))
        #expect(compact.contains("\"artifact_created\":false"))
        #expect(compact.contains("\"first\":6000"))
        #expect(compact.contains("\"last\":6251"))
        #expect(compact.contains("already displayed inline"))
        #expect(compact.contains("No image or file was created"))
    }

    @Test func modelFacingResultIncludesCalendarDaySpanForISODateCategories() async throws {
        let rendered = try await RenderChartTool().execute(
            argumentsJSON: #"""
                {
                  "data": "date,close\n2025-07-15,6243.75\n2026-07-15,7572.40",
                  "format": "csv",
                  "chartType": "line",
                  "xColumn": "date",
                  "series": ["close"]
                }
                """#
        )
        let compact = try #require(RenderChartTool.compactModelResult(from: rendered))
        #expect(compact.contains("\"x_start\":\"2025-07-15\""))
        #expect(compact.contains("\"x_end\":\"2026-07-15\""))
        #expect(compact.contains("\"x_span_days\":365"))
    }
}
