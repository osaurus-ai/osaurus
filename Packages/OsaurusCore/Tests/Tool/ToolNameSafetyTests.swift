//
//  ToolNameSafetyTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ToolNameSafetyTests {

    @Test func sanitizesIllegalCharacters() {
        #expect(ToolRegistry.sanitizeToolName("hello world!") == "hello_world_")
        #expect(ToolRegistry.sanitizeToolName("a-b-c_1") == "a-b-c_1")
        // `é` is a single Swift `Character` (grapheme cluster), so the
        // sanitizer maps it to a single underscore.
        #expect(ToolRegistry.sanitizeToolName("café") == "caf_")
    }

    @Test func emptyAfterSanitizeFallsBackToToolUnnamed() {
        #expect(ToolRegistry.sanitizeToolName("") == "tool_unnamed")
        // All-disallowed characters become _; not empty.
        #expect(ToolRegistry.sanitizeToolName("!!!") == "___")
    }

    @Test func truncatesOverLong() {
        let raw = String(repeating: "a", count: 200)
        let sanitized = ToolRegistry.sanitizeToolName(raw)
        #expect(sanitized.count == 64)
    }

    @Test func acceptsConformingNames() {
        #expect(ToolRegistry.sanitizeToolName("get_weather") == "get_weather")
        #expect(ToolRegistry.sanitizeToolName("MyTool-v2_3") == "MyTool-v2_3")
    }
}
