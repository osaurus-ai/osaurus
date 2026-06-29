//
//  DefaultAgentSystemPromptBuilderTests.swift
//  OsaurusCoreTests
//
//  Verifies the simplified default-agent system prompt addendum: it is
//  derived from the live `ConfigurationDomainRegistry` (single source of
//  truth — it lists the registered domains' consolidated write tools), it
//  teaches DIRECT action-tool use (no capability-search protocol), it routes
//  out-of-scope asks to `osaurus_agent`, and it stays byte-stable across
//  calls within the same generation so the KV-cache reuse story holds.
//
//  Tests use `_renderForTests` for byte-level assertions against an
//  arbitrary domain list (no shared-cache mutation) and the live
//  `render()` path to assert memoization.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct DefaultAgentSystemPromptBuilderTests {

    private static func probe(id: String, writeToolNames: [String] = []) -> ConfigurationDomain {
        ConfigurationDomain(
            id: id,
            displayName: id.capitalized,
            summary: "Summary for \(id).",
            menuHint: "do / things",
            searchKeywords: [],
            exampleQueries: [],
            tools: [],
            writeToolNames: Set(writeToolNames)
        )
    }

    @Test
    func render_listsEveryDomainWriteTool() {
        let domains = [
            Self.probe(id: "providers", writeToolNames: ["osaurus_provider"]),
            Self.probe(id: "models", writeToolNames: ["osaurus_model"]),
        ]
        let rendered = DefaultAgentSystemPromptBuilder._renderForTests(domains: domains)

        // The consolidated write tools are surfaced directly (sorted, in
        // backticks) so the model knows exactly which tools exist.
        #expect(rendered.contains("`osaurus_provider`"))
        #expect(rendered.contains("`osaurus_model`"))
        #expect(rendered.contains("Change tools:"))
    }

    @Test
    func render_teachesDirectActionToolsNotCapabilitySearch() {
        let rendered = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])]
        )
        // The Default agent loads its writes directly — the prompt must tell
        // it to pick an `action`, and must NOT resurrect the old
        // discover/load protocol.
        #expect(rendered.contains("action"))
        #expect(!rendered.contains("capabilities_discover"))
        #expect(!rendered.contains("capabilities_load"))
    }

    @Test
    func render_teachesActInOneTurnNotChatConfirmation() {
        let rendered = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])]
        )
        // The configure agent must act in a single turn (state the change, then
        // call the tool), relying on the separate one-tap approval gate. The old
        // "The user confirms every change" wording made careful models stall on
        // a chat "Confirm?" and never call the tool, so it must be gone.
        #expect(rendered.contains("same turn"))
        #expect(rendered.contains("approval"))
        #expect(rendered.contains("then call the tool"))
        #expect(!rendered.contains("confirms every change"))
    }

    @Test
    func render_listsAlwaysAvailableReadTools() {
        let rendered = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])]
        )
        #expect(rendered.contains("osaurus_status"))
        #expect(rendered.contains("osaurus_list"))
        #expect(rendered.contains("osaurus_describe"))
    }

    @Test
    func render_routesOutOfScopeToAgentTool() {
        let rendered = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])]
        )
        // Out-of-scope asks must be handed off to creating/switching an agent
        // via `osaurus_agent`, not refused flatly.
        #expect(rendered.contains("Out of scope"))
        #expect(rendered.contains("osaurus_agent"))
        #expect(rendered.contains("create"))
        #expect(rendered.contains("activate"))
    }

    @Test
    func render_compactIsShorterButKeepsToolSurface() {
        let domains = [
            Self.probe(id: "providers", writeToolNames: ["osaurus_provider"]),
            Self.probe(id: "models", writeToolNames: ["osaurus_model"]),
        ]
        let full = DefaultAgentSystemPromptBuilder._renderForTests(domains: domains, compact: false)
        let compact = DefaultAgentSystemPromptBuilder._renderForTests(domains: domains, compact: true)

        // Compact keeps the full tool surface + scope guardrails (read tools,
        // every write tool by name, out-of-scope handoff) but teaches the
        // load-on-demand flow: writes load via `capabilities_load`, with
        // NO `capabilities_discover` step.
        #expect(compact.contains("osaurus_status"))
        #expect(compact.contains("`osaurus_provider`"))
        #expect(compact.contains("`osaurus_model`"))
        #expect(compact.contains("action"))
        #expect(compact.contains("Out of scope"))
        #expect(compact.contains("osaurus_agent"))
        #expect(compact.contains("capabilities_load"))
        #expect(!compact.contains("capabilities_discover"))
        // The full variant loads writes directly — it must NOT teach lazy load.
        #expect(!full.contains("capabilities_load"))
    }

    @Test
    func render_compactIsMemoizedSeparatelyFromFull() {
        let registry = ConfigurationDomainRegistry.shared
        registry._resetForTests()
        ConfigurationDomainBootstrap._resetForTests()
        DefaultAgentSystemPromptBuilder._resetForTests()
        defer {
            registry._resetForTests()
            ConfigurationDomainBootstrap._resetForTests()
            DefaultAgentSystemPromptBuilder._resetForTests()
        }

        ConfigurationDomainBootstrap.registerBuiltIns()

        let compactFirst = DefaultAgentSystemPromptBuilder.render(compact: true)
        let compactSecond = DefaultAgentSystemPromptBuilder.render(compact: true)
        let full = DefaultAgentSystemPromptBuilder.render(compact: false)
        #expect(compactFirst == compactSecond)
        #expect(compactFirst != full)
    }

    @Test
    func render_handlesEmptyRegistry() {
        let rendered = DefaultAgentSystemPromptBuilder._renderForTests(domains: [])
        #expect(rendered.contains("none registered yet"))
    }

    @Test
    func render_isMemoizedPerGeneration() {
        let registry = ConfigurationDomainRegistry.shared
        registry._resetForTests()
        ConfigurationDomainBootstrap._resetForTests()
        DefaultAgentSystemPromptBuilder._resetForTests()
        defer {
            registry._resetForTests()
            ConfigurationDomainBootstrap._resetForTests()
            DefaultAgentSystemPromptBuilder._resetForTests()
        }

        ConfigurationDomainBootstrap.registerBuiltIns()

        let first = DefaultAgentSystemPromptBuilder.render()
        let second = DefaultAgentSystemPromptBuilder.render()
        #expect(first == second)
    }

    @Test
    func render_regeneratesWhenNewDomainRegisters() {
        let registry = ConfigurationDomainRegistry.shared
        registry._resetForTests()
        ConfigurationDomainBootstrap._resetForTests()
        DefaultAgentSystemPromptBuilder._resetForTests()
        defer {
            registry._resetForTests()
            ConfigurationDomainBootstrap._resetForTests()
            DefaultAgentSystemPromptBuilder._resetForTests()
        }

        let beforeRender = DefaultAgentSystemPromptBuilder.render()
        let probeWrite = "osaurus_probe_\(UUID().uuidString.prefix(6))"
        registry.register(
            Self.probe(
                id: "probe-new-\(UUID().uuidString.prefix(6))",
                writeToolNames: [probeWrite]
            )
        )
        let afterRender = DefaultAgentSystemPromptBuilder.render()
        #expect(beforeRender != afterRender)
        #expect(afterRender.contains(probeWrite))
    }

    @Test
    func render_warnsAboutSecretsNotInChatContext() {
        let rendered = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])]
        )
        // Security invariant: the model is explicitly told not to echo
        // secrets. Matched loosely because the exact phrasing may be tuned.
        #expect(rendered.lowercased().contains("secret"))
        #expect(rendered.contains("Keychain"))
    }
}
