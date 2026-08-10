//
//  TimeContextTests.swift
//  osaurusTests
//
//  Coverage for the per-turn [Current Time] block: deterministic rendering
//  for a fixed instant/zone, and its placement at the head of the injected
//  user prefix ahead of automation/screen/memory blocks.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Time context injection")
struct TimeContextTests {

    private let fixedInstant = Date(timeIntervalSince1970: 1_785_123_932)  // 2026-07-27 03:45:32 UTC

    @Test func rendersReadableAndISOInTargetZone() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let block = SystemPromptTemplates.timeContext(now: fixedInstant, timeZone: zone)
        #expect(block.hasPrefix("[Current Time]"))
        #expect(block.hasSuffix("[/Current Time]"))
        #expect(block.contains("Monday, July 27, 2026 at 9:15 AM"))
        #expect(block.contains("2026-07-27T09:15:32+05:30"))
        #expect(block.contains("Asia/Kolkata"))
    }

    @Test func prefixPlacesTimeContextFirst() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let time = SystemPromptTemplates.timeContext(now: fixedInstant, timeZone: zone)
        let prefix = SystemPromptComposer.composeInjectedUserPrefix(
            memorySection: "a fact",
            screenContext: "[Screen Context]\nDoing: In Safari\n[/Screen Context]",
            timeContext: time
        )
        let rendered = try #require(prefix)
        #expect(rendered.hasPrefix("[Current Time]"))
        let timeRange = try #require(rendered.range(of: "[/Current Time]"))
        let memoryRange = try #require(rendered.range(of: "[Memory]"))
        #expect(timeRange.upperBound <= memoryRange.lowerBound)
    }

    @Test func timeContextAloneProducesPrefix() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let time = SystemPromptTemplates.timeContext(now: fixedInstant, timeZone: zone)
        let prefix = SystemPromptComposer.composeInjectedUserPrefix(
            memorySection: nil,
            screenContext: nil,
            timeContext: time
        )
        #expect(prefix?.hasPrefix("[Current Time]") == true)
    }
}
