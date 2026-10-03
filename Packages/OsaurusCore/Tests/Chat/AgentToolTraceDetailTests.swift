//
//  AgentToolTraceDetailTests.swift
//  OsaurusCoreTests
//
//  Owner-only rich fields on the `osaurus_agent_tool` SSE trace: the Mac's
//  own labels / icons, capped arguments and results, and durations.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentToolTraceDetailTests {
    @Test func startedUsesTheMacRunningLabel() {
        let detail = AgentToolTraceDetail.started(toolName: "capabilities_discover", arguments: "{}")
        #expect(detail.label == ToolDisplayName.friendly(for: "capabilities_discover", running: true, arguments: "{}"))
        #expect(detail.arguments == "{}")
        #expect(detail.result == nil)
        #expect(!detail.icon.isEmpty)
    }

    @Test func completedUsesTheMacDoneLabelAndDuration() {
        let detail = AgentToolTraceDetail.completed(
            toolName: "capabilities_discover",
            arguments: "{}",
            result: "ok",
            isError: false,
            duration: 1.2345
        )
        #expect(detail.label == ToolDisplayName.friendly(for: "capabilities_discover", running: false, arguments: "{}"))
        #expect(detail.result == "ok")
        #expect(detail.resultTruncated == nil)
        #expect(detail.durationMs == 1235)
        #expect(detail.arguments == nil)
    }

    @Test func failedCallsUseTheFailedLabel() {
        let detail = AgentToolTraceDetail.completed(
            toolName: "web_search",
            arguments: "{}",
            result: "boom",
            isError: true,
            duration: nil
        )
        #expect(detail.label == ToolDisplayName.friendly(for: "web_search", running: false, arguments: "{}", failed: true))
        #expect(detail.durationMs == nil)
    }

    @Test func largeResultsAreCapped() {
        let big = String(repeating: "x", count: AgentToolTraceDetail.maxResultChars + 10)
        let detail = AgentToolTraceDetail.completed(
            toolName: "file_read",
            arguments: "{}",
            result: big,
            isError: false,
            duration: 0
        )
        #expect(detail.result?.count == AgentToolTraceDetail.maxResultChars)
        #expect(detail.resultTruncated == true)
    }

    @Test func timerMeasuresEachCallOnce() {
        let timer = AgentToolTraceTimer()
        timer.start("c1")
        #expect(timer.finish("c1") != nil)
        #expect(timer.finish("c1") == nil)
        #expect(timer.finish("never-started") == nil)
    }
}

struct AgentAvatarContentTypeTests {
    @Test func mapsImageExtensionsAndDefaultsToJPEG() {
        #expect(HTTPHandler.imageContentType(forPathExtension: "PNG") == "image/png")
        #expect(HTTPHandler.imageContentType(forPathExtension: "heic") == "image/heic")
        #expect(HTTPHandler.imageContentType(forPathExtension: "tif") == "image/tiff")
        #expect(HTTPHandler.imageContentType(forPathExtension: "jpg") == "image/jpeg")
        #expect(HTTPHandler.imageContentType(forPathExtension: "") == "image/jpeg")
    }
}
