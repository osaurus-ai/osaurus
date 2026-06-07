//
//  CapabilitiesSearchDefaultAgentScopeTests.swift
//  OsaurusCoreTests
//
//  Default-agent scoping for `capabilities_discover` and the
//  composer-level schema gate that complements it:
//
//   * Search results from the default agent never carry method/skill
//     hits — the tools-only fast path skips those lanes entirely.
//   * `composeChatContext` with `Agent.defaultId` keeps the fixed
//     baseline schema regardless of query — no non-baseline tool can
//     leak into the default-agent schema.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct CapabilitiesSearchDefaultAgentScopeTests {

    @Test
    func defaultAgent_searchReturnsOnlyConfigureWrites() async throws {
        let tool = CapabilitiesDiscoverTool()
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await tool.execute(
                argumentsJSON: "{\"queries\": [\"add provider\", \"download model\"]}"
            )
        }
        // Either we get hits or we get the no-match envelope — both are
        // valid for source-only tests (the catalog state depends on
        // whether ConfigurationDomainBootstrap has run). What we care
        // about is that no method/ or skill/ hit ever shows up.
        #expect(!result.contains("[method]"))
        #expect(!result.contains("[skill]"))
        let methodPrefix = "method/"
        let skillPrefix = "skill/"
        #expect(!result.contains(methodPrefix))
        #expect(!result.contains(skillPrefix))
    }
}

@Suite(.serialized)
@MainActor
struct DefaultAgentSchemaScopeTests {

    private static func ensureBootstrapped() {
        ConfigurationDomainBootstrap.registerBuiltIns()
    }

    /// The schema for the default agent remains the fixed baseline (no
    /// non-baseline tool leaks in) regardless of what the user asks.
    @Test
    func defaultAgent_keepsBaselineRegardlessOfQuery() async {
        Self.ensureBootstrapped()
        let context = await SystemPromptComposer.composeChatContext(
            agentId: Agent.defaultId,
            executionMode: .none,
            query: "I want to set up a daily schedule that summarizes news"
        )
        let names = Set(context.tools.map { $0.function.name })
        // Every name in the schema must belong to the fixed baseline.
        for name in names {
            #expect(
                ToolRegistry.defaultAgentAllowedToolNames.contains(name),
                "non-baseline tool \(name) leaked into default-agent schema"
            )
        }
    }
}
