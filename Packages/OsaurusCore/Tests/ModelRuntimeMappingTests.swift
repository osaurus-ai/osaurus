//
//  ModelRuntimeMappingTests.swift
//  osaurusTests
//

import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

struct ModelRuntimeMappingTests {

    @Test func mapsToolRoleToMLXTool() throws {
        // Build assistant tool call followed by tool result
        let toolCall = ToolCall(
            id: "call_1",
            type: "function",
            function: ToolCallFunction(name: "get_weather", arguments: "{}")
        )
        let assistant = ChatMessage(
            role: "assistant",
            content: nil,
            tool_calls: [toolCall],
            tool_call_id: nil
        )
        let toolMsg = ChatMessage(
            role: "tool",
            content: "{\"temp\":72}",
            tool_calls: nil,
            tool_call_id: "call_1"
        )

        let mapped = ModelRuntime.mapOpenAIChatToMLX([assistant, toolMsg])

        // Assistant had no content, only tool call => only one mapped message expected
        #expect(mapped.count == 1)
        let last = mapped[0]
        #expect(last.role == .tool)
        #expect(last.content.contains("\"temp\":72"))
    }
}
