//
//  MCPProviderToolNamingTests.swift
//  OsaurusCoreTests
//
//  Regression coverage for collision-safe MCP tool prefixes and description caps.
//

import Foundation
import MCP
import Testing

@testable import OsaurusCore

@Suite("MCP provider tool naming")
struct MCPProviderToolNamingTests {
    @Test func sanitizedPrefixCollapsesSpacesAndHyphens() {
        #expect(MCPProviderTool.sanitizedProviderPrefix(from: "My Server") == "my_server")
        #expect(MCPProviderTool.sanitizedProviderPrefix(from: "my-server") == "my_server")
    }

    @Test func exposedNameDisambiguatesCollidingProviderPrefixes() {
        let providerA = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let providerB = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!

        let reserved = Set([
            MCPProviderTool.exposedName(
                providerId: providerA,
                providerName: "My Server",
                mcpToolName: "search"
            )
        ])

        let nameB = MCPProviderTool.exposedName(
            providerId: providerB,
            providerName: "my-server",
            mcpToolName: "search",
            reservedNames: reserved
        )

        #expect(nameB.contains("bbbbbbbb"))
        #expect(nameB != reserved.first)
    }

    @Test func descriptionTruncationUsesRaisedCap() {
        let long = String(repeating: "x", count: MCPProviderTool.maxDescriptionLength + 50)
        let truncated = MCPProviderTool.truncatedDescription(long)
        #expect(truncated.hasSuffix("..."))
        #expect(truncated.count == MCPProviderTool.maxDescriptionLength + 3)
    }
}
