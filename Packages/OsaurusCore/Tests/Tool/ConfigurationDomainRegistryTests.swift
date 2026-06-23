//
//  ConfigurationDomainRegistryTests.swift
//  OsaurusCoreTests
//
//  Pins the contract of `ConfigurationDomainRegistry`:
//
//   * Registering a domain pushes the domain into `domains`, increments
//     the monotonic `generation` counter, and registers each `tool` in
//     `ToolRegistry` flagged as a built-in.
//   * Re-registering the same `id` is idempotent (no second tool
//     registration, no generation bump).
//   * The derived `ToolRegistry.configureWriteToolNames` /
//     `configureToolNames` collections see the new write tools so the
//     composer and capability search can use them as filters.
//
//  Tests use `_resetForTests()` to start from a known-empty registry
//  inside `@Suite(.serialized)`. The Bootstrap class is intentionally
//  *not* used so we exercise `register(_:)` directly.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ConfigurationDomainRegistryTests {

    private static func makeProbeDomain(id: String) -> ConfigurationDomain {
        ConfigurationDomain(
            id: id,
            displayName: "Probe \(id)",
            summary: "probe domain summary",
            menuHint: "probe / probe",
            searchKeywords: ["probe-\(id)", "configure probe"],
            exampleQueries: ["do the probe thing"],
            tools: [],
            writeToolNames: []
        )
    }

    @Test
    func register_addsDomainAndBumpsGeneration() async {
        let registry = ConfigurationDomainRegistry.shared
        registry._resetForTests()
        ConfigurationDomainBootstrap._resetForTests()
        defer {
            registry._resetForTests()
            ConfigurationDomainBootstrap._resetForTests()
        }

        let beforeGeneration = registry.generation
        let domain = Self.makeProbeDomain(id: "probe-add-\(UUID().uuidString.prefix(6))")
        registry.register(domain)

        #expect(registry.domains.contains { $0.id == domain.id })
        #expect(registry.generation == beforeGeneration &+ 1)
    }

    @Test
    func register_isIdempotentById() async {
        let registry = ConfigurationDomainRegistry.shared
        registry._resetForTests()
        ConfigurationDomainBootstrap._resetForTests()
        defer {
            registry._resetForTests()
            ConfigurationDomainBootstrap._resetForTests()
        }

        let domain = Self.makeProbeDomain(id: "probe-idem-\(UUID().uuidString.prefix(6))")
        registry.register(domain)
        let afterFirstGeneration = registry.generation
        let afterFirstCount = registry.domains.filter { $0.id == domain.id }.count
        #expect(afterFirstCount == 1)

        registry.register(domain)  // second time should be a no-op
        let afterSecondCount = registry.domains.filter { $0.id == domain.id }.count
        #expect(afterSecondCount == 1)
        #expect(registry.generation == afterFirstGeneration)
    }

    @Test
    func writeToolNames_aggregateAcrossDomains() async {
        let registry = ConfigurationDomainRegistry.shared
        registry._resetForTests()
        ConfigurationDomainBootstrap._resetForTests()
        defer {
            registry._resetForTests()
            ConfigurationDomainBootstrap._resetForTests()
        }

        // Re-bootstrap so we exercise the real domain wiring through
        // the registry; bootstrap is idempotent so this stays test-
        // friendly.
        ConfigurationDomainBootstrap.registerBuiltIns()

        let configureWrites = ToolRegistry.configureWriteToolNames
        // Provider, model, MCP, plugin, schedule, agent domains each
        // contribute exactly one consolidated `osaurus_*` write tool.
        #expect(configureWrites.contains("osaurus_provider"))
        #expect(configureWrites.contains("osaurus_model"))
        #expect(configureWrites.contains("osaurus_mcp"))
        #expect(configureWrites.contains("osaurus_plugin"))
        #expect(configureWrites.contains("osaurus_schedule"))
        #expect(configureWrites.contains("osaurus_agent"))

        let configureAll = ToolRegistry.configureToolNames
        #expect(configureAll.isSuperset(of: configureWrites))
        #expect(configureAll.contains("osaurus_status"))
        #expect(configureAll.contains("osaurus_list"))
        #expect(configureAll.contains("osaurus_describe"))
    }

    @Test
    func register_marksToolsAsBuiltIn() async {
        let registry = ConfigurationDomainRegistry.shared
        registry._resetForTests()
        ConfigurationDomainBootstrap._resetForTests()
        defer {
            registry._resetForTests()
            ConfigurationDomainBootstrap._resetForTests()
        }

        // Bootstrap drives `register(_:)` for each shipped domain.
        ConfigurationDomainBootstrap.registerBuiltIns()

        let builtIn = ToolRegistry.shared.builtInToolNames
        // The consolidated provider/model/etc. tools must end up flagged
        // built-in so the Default-agent baseline + capability infrastructure
        // can reach them.
        #expect(builtIn.contains("osaurus_provider"))
        #expect(builtIn.contains("osaurus_model"))
        #expect(builtIn.contains("osaurus_schedule"))
        #expect(builtIn.contains("osaurus_agent"))
    }

    @Test
    func defaultAgentAllowedToolNames_isTheConsolidatedConfigureSurfacePlusLoop() {
        // The Default-agent baseline is a hard product contract: the
        // consolidated configure surface (3 reads + 6 per-domain writes)
        // plus the three agent-loop tools, and NOTHING else. In particular
        // the capability-search gateway is no longer part of it. Changing
        // this set changes the model's first-turn schema and must be
        // reviewed deliberately.
        ConfigurationDomainBootstrap._resetForTests()
        ConfigurationDomainBootstrap.registerBuiltIns()
        defer { ConfigurationDomainBootstrap._resetForTests() }

        let expected: Set<String> = [
            "osaurus_status",
            "osaurus_list",
            "osaurus_describe",
            "osaurus_provider",
            "osaurus_model",
            "osaurus_mcp",
            "osaurus_plugin",
            "osaurus_schedule",
            "osaurus_agent",
            "todo",
            "complete",
            "clarify",
        ]
        #expect(ToolRegistry.defaultAgentAllowedToolNames == expected)
        // The capability-search gateway is explicitly NOT in the Default
        // agent's surface anymore (it stays available to custom agents).
        #expect(!ToolRegistry.defaultAgentAllowedToolNames.contains("capabilities_discover"))
        #expect(!ToolRegistry.defaultAgentAllowedToolNames.contains("capabilities_load"))
    }
}
