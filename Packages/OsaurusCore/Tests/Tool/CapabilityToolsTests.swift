//
//  CapabilityToolsTests.swift
//  osaurus
//
//  Tests for capabilities_search, capabilities_load, and CapabilityLoadBuffer.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - CapabilityLoadBuffer

struct CapabilityLoadBufferTests {

    @Test func drainReturnsAndClearsPendingTools() async {
        let buffer = CapabilityLoadBuffer()
        let tool1 = Tool(
            type: "function",
            function: ToolFunction(name: "test_tool_1", description: "A test", parameters: nil)
        )
        let tool2 = Tool(
            type: "function",
            function: ToolFunction(name: "test_tool_2", description: "Another test", parameters: nil)
        )

        await buffer.add(tool1)
        await buffer.add(tool2)

        let drained = await buffer.drain()
        #expect(drained.count == 2)
        #expect(drained[0].function.name == "test_tool_1")
        #expect(drained[1].function.name == "test_tool_2")

        let empty = await buffer.drain()
        #expect(empty.isEmpty)
    }

    @Test func drainOnEmptyBufferReturnsEmpty() async {
        let buffer = CapabilityLoadBuffer()
        let result = await buffer.drain()
        #expect(result.isEmpty)
    }
}

// MARK: - CapabilitiesSearchTool

struct CapabilitiesSearchToolTests {

    @Test func rejectsEmptyQueries() async throws {
        let tool = CapabilitiesSearchTool()
        let result = try await tool.execute(argumentsJSON: "{\"queries\": []}")
        #expect(result.contains("Error"))
    }

    @Test func rejectsMissingQueries() async throws {
        let tool = CapabilitiesSearchTool()
        let result = try await tool.execute(argumentsJSON: "{}")
        #expect(result.contains("Error"))
    }

    @Test func returnsNoMatchMessage() async throws {
        let tool = CapabilitiesSearchTool()
        let result = try await tool.execute(
            argumentsJSON: "{\"queries\": [\"zzz_completely_nonexistent_capability_xyz\"]}"
        )
        #expect(result.contains("No capabilities found") || result.contains("capability"))
    }
}

// MARK: - CapabilitiesLoadTool

struct CapabilitiesLoadToolTests {

    @Test func rejectsEmptyIds() async throws {
        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(argumentsJSON: "{\"ids\": []}")
        #expect(result.contains("Error"))
    }

    @Test func rejectsMissingIds() async throws {
        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(argumentsJSON: "{}")
        #expect(result.contains("Error"))
    }

    @Test func handlesInvalidIdFormat() async throws {
        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(argumentsJSON: "{\"ids\": [\"no-slash\"]}")
        #expect(result.contains("Warning"))
        #expect(result.contains("Invalid ID format"))
    }

    @Test func handlesUnknownTypePrefix() async throws {
        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(argumentsJSON: "{\"ids\": [\"widget/abc\"]}")
        #expect(result.contains("Warning"))
        #expect(result.contains("Unknown type"))
    }

    @Test func methodNotFoundReturnsError() async throws {
        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(
            argumentsJSON: "{\"ids\": [\"method/nonexistent-method-id\"]}"
        )
        #expect(result.contains("Error") || result.contains("not found"))
    }

    @Test func toolNotFoundReturnsError() async throws {
        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(
            argumentsJSON: "{\"ids\": [\"tool/zzz_nonexistent_tool\"]}"
        )
        #expect(result.contains("Error") || result.contains("not found"))
    }

    @Test func skillNotFoundReturnsError() async throws {
        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(
            argumentsJSON: "{\"ids\": [\"skill/zzz_nonexistent_skill\"]}"
        )
        #expect(result.contains("Error") || result.contains("not found"))
    }

    @Test func dispatchesByTypePrefix() async throws {
        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(
            argumentsJSON: """
                {"ids": ["method/fake-m", "tool/fake-t", "skill/fake-s"]}
                """
        )
        #expect(result.contains("method") || result.contains("Method"))
        #expect(result.contains("tool") || result.contains("Tool"))
        #expect(result.contains("skill") || result.contains("Skill"))
    }

    @Test func toolLoadBuffersSpec() async throws {
        await MainActor.run {
            ToolRegistry.shared.setEnabled(true, for: "capabilities_search")
        }

        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(
            argumentsJSON: "{\"ids\": [\"tool/capabilities_search\"]}"
        )

        #expect(result.contains("loaded") || result.contains("available"))

        let buffered = await CapabilityLoadBuffer.shared.drain()
        #expect(buffered.contains(where: { $0.function.name == "capabilities_search" }))
    }
}
