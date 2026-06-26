//
//  CapabilitiesSearchDefaultAgentScopeTests.swift
//  OsaurusCoreTests
//
//  Composer-level schema scope for the Default (configuration) agent.
//
//  The Default agent no longer reaches capability search at all — it loads
//  its consolidated configure tools DIRECTLY. So the contract worth pinning
//  here is the composed schema itself: regardless of what the user asks,
//  `composeChatContext(agentId: Agent.defaultId)` resolves exactly the
//  consolidated configure surface + agent-loop tools, and never the
//  capability-search gateway or any non-baseline tool.
//

import Foundation
import Testing

@testable import OsaurusCore

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
        // Isolate the global delegation snapshot: the default-agent schema gates
        // `spawn` / `image` on `SubagentConfigurationStore.snapshot()`, so a
        // parallel suite that populates the main-chat pool / image switch would
        // otherwise leak `spawn` into this baseline mid-flight (the documented
        // cross-suite snapshot race — see SubagentStoreTestLock).
        let lease = await acquireSubagentStoreSandbox("default-agent-schema-baseline")
        defer { lease.release() }
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

    /// End-to-end through `composeChatContext`: the consolidated writes load
    /// directly, and the capability-search gateway is never present for the
    /// Default agent (it stays available to custom agents).
    @Test
    func defaultAgent_loadsConsolidatedWritesDirectlyNotViaSearch() async {
        Self.ensureBootstrapped()
        let lease = await acquireSubagentStoreSandbox("default-agent-schema-consolidated")
        defer { lease.release() }
        let context = await SystemPromptComposer.composeChatContext(
            agentId: Agent.defaultId,
            executionMode: .none,
            query: "connect my Anthropic account and download a small model"
        )
        let names = Set(context.tools.map { $0.function.name })
        // Consolidated writes are present without any discover/load step.
        #expect(names.contains("osaurus_provider"))
        #expect(names.contains("osaurus_model"))
        // The capability-search gateway is absent.
        #expect(!names.contains("capabilities_discover"))
        #expect(!names.contains("capabilities_load"))
    }
}
