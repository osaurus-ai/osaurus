//
//  TimeContextTests.swift
//  osaurusTests
//
//  Coverage for the per-turn [Current Time] block: deterministic
//  minute-granularity rendering for a fixed instant/zone, and its placement
//  at the tail of the injected user prefix — after the stabler
//  automation/screen/memory blocks — so fresh chats diverge as late as
//  possible in the shared prefill.
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
        #expect(block.contains("2026-07-27T09:15+05:30"))
        #expect(block.contains("Asia/Kolkata"))
    }

    @Test func rendersMinuteGranularityAcrossSameMinuteInstants() throws {
        // Two sends 20s apart in the same minute must render byte-identical
        // blocks — seconds in the block made every fresh chat's first turn
        // unique by construction and killed cross-chat prefill reuse.
        let zone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let a = SystemPromptTemplates.timeContext(now: fixedInstant, timeZone: zone)
        let b = SystemPromptTemplates.timeContext(
            now: fixedInstant.addingTimeInterval(20), timeZone: zone)
        #expect(a == b)
    }

    @Test func prefixPlacesTimeContextLast() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let time = SystemPromptTemplates.timeContext(now: fixedInstant, timeZone: zone)
        let prefix = SystemPromptComposer.composeInjectedUserPrefix(
            memorySection: "a fact",
            screenContext: "[Screen Context]\nDoing: In Safari\n[/Screen Context]",
            timeContext: time
        )
        let rendered = try #require(prefix)
        #expect(rendered.hasPrefix("[Screen Context]"))
        #expect(rendered.hasSuffix("[/Current Time]\n\n"))
        let memoryRange = try #require(rendered.range(of: "[/Memory]"))
        let timeRange = try #require(rendered.range(of: "[Current Time]"))
        #expect(memoryRange.upperBound <= timeRange.lowerBound)
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
