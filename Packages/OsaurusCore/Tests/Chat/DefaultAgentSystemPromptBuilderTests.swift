//
//  DefaultAgentSystemPromptBuilderTests.swift
//  OsaurusCoreTests
//
//  Verifies that the default-agent system prompt addendum is derived
//  from the live `ConfigurationDomainRegistry` (single source of truth)
//  and stays byte-stable across calls within the same generation so
//  the KV-cache reuse story holds.
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

    private static func probe(id: String, summary: String, menuHint: String) -> ConfigurationDomain {
        ConfigurationDomain(
            id: id,
            displayName: id.capitalized,
            summary: summary,
            menuHint: menuHint,
            searchKeywords: [],
            exampleQueries: [],
            tools: [],
            writeToolNames: []
        )
    }

    @Test
    func render_listsEveryRegisteredDomain() {
        let domains = [
            Self.probe(id: "providers", summary: "Connect cloud LLMs.", menuHint: "add / update / remove"),
            Self.probe(id: "models", summary: "Local MLX models.", menuHint: "download / cancel / delete"),
        ]
        let rendered = DefaultAgentSystemPromptBuilder._renderForTests(domains: domains)

        #expect(rendered.contains("**providers**"))
        #expect(rendered.contains("Connect cloud LLMs."))
        #expect(rendered.contains("add / update / remove"))

        #expect(rendered.contains("**models**"))
        #expect(rendered.contains("Local MLX models."))
        #expect(rendered.contains("download / cancel / delete"))
    }

    @Test
    func render_explainsSearchLoadCallPattern() {
        let rendered = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", summary: "S", menuHint: "H")]
        )
        // The default-agent's "I can't see the write tool" recovery
        // loop depends on these three sentences being present so the
        // model knows to call capabilities_search → capabilities_load
        // → write tool rather than fabricate a name.
        #expect(rendered.contains("capabilities_search"))
        #expect(rendered.contains("capabilities_load"))
        #expect(rendered.contains("Performing writes"))
    }

    @Test
    func render_listsAlwaysAvailableReadTools() {
        let rendered = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", summary: "S", menuHint: "H")]
        )
        #expect(rendered.contains("osaurus_status"))
        #expect(rendered.contains("osaurus_list"))
        #expect(rendered.contains("osaurus_describe"))
    }

    @Test
    func render_handlesEmptyRegistry() {
        let rendered = DefaultAgentSystemPromptBuilder._renderForTests(domains: [])
        #expect(rendered.contains("no configuration domains registered yet"))
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
        registry.register(
            Self.probe(
                id: "probe-new-\(UUID().uuidString.prefix(6))",
                summary: "Newly registered probe domain.",
                menuHint: "do new things"
            )
        )
        let afterRender = DefaultAgentSystemPromptBuilder.render()
        #expect(beforeRender != afterRender)
        #expect(afterRender.contains("Newly registered probe domain."))
    }

    @Test
    func render_warnsAboutSecretsNotInChatContext() {
        let rendered = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", summary: "S", menuHint: "H")]
        )
        // Phase C security invariant: the model is explicitly told not
        // to echo secrets. The string is matched loosely because the
        // exact phrasing may be tuned over time.
        #expect(rendered.lowercased().contains("secret"))
        #expect(rendered.contains("Keychain"))
    }
}
