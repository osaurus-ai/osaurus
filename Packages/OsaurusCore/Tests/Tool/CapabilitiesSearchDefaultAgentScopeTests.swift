//
//  CapabilitiesSearchDefaultAgentScopeTests.swift
//  OsaurusCoreTests
//
//  Default-agent scoping for `capabilities_search` and the
//  composer-level preflight gate that complements it:
//
//   * Search results from the default agent never carry method/skill
//     hits — the tools-only fast path skips those lanes entirely.
//   * `composeChatContext` with `Agent.defaultId` returns
//     `preflightItems.isEmpty` even for a non-trivial query, because
//     the preflight LLM selector is short-circuited (any picks would
//     be stripped by `resolveTools` anyway).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct CapabilitiesSearchDefaultAgentScopeTests {

    @Test
    func defaultAgent_searchReturnsOnlyConfigureWrites() async throws {
        let tool = CapabilitiesSearchTool()
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
struct DefaultAgentPreflightSkipTests {

    private static func ensureBootstrapped() {
        ConfigurationDomainBootstrap.registerBuiltIns()
    }

    /// The composer must short-circuit the preflight LLM call for the
    /// default agent. Even with a non-trivial query that would normally
    /// trigger a search, `preflightItems` stays empty.
    @Test
    func defaultAgent_skipsPreflightOnNonTrivialQuery() async {
        Self.ensureBootstrapped()
        let context = await SystemPromptComposer.composeChatContext(
            agentId: Agent.defaultId,
            executionMode: .none,
            query: "help me add an Anthropic API key"
        )
        #expect(context.preflightItems.isEmpty)
    }

    /// Sanity check: the schema for the default agent remains the
    /// 8-tool baseline (no preflight picks ever leak in).
    @Test
    func defaultAgent_keepsEightToolBaselineRegardlessOfQuery() async {
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
                "non-baseline tool \(name) leaked into default-agent schema via preflight"
            )
        }
    }
}
