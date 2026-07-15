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
        #expect(description.contains("does not fetch data"))
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
}
