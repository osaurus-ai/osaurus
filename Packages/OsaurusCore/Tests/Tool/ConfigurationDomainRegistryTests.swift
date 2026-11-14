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
        // Since the declarative consolidation the write surface is the
        // declarative tool plus the import tool for pasted sources.
        #expect(configureWrites == ["osaurus_config", "osaurus_import"])

        let configureAll = ToolRegistry.configureToolNames
        #expect(configureAll.isSuperset(of: configureWrites))
        #expect(configureAll.contains("osaurus_inspect"))
        #expect(configureAll.contains("osaurus_help"))
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
        // The declarative config tool must end up flagged built-in so the
        // Default-agent baseline + capability infrastructure can reach it.
        #expect(builtIn.contains("osaurus_config"))
    }

    @Test
    func orchestratorAllowedToolNames_isTheRoutingSurfacePlusLegacyQuickTools() {
        // The orchestrator (Default agent) baseline is a hard product
        // contract: the routing surface (`status`, `state`, the Configurator
        // and Architect handoffs, `run_workflow` — dropped by the composer
        // when no workflow is Orchestrator-visible — and `clarify`). The
        // agent-loop pair, time, arithmetic, and the native search pair are
        // the legacy set it never holds. No configure tool: Osaurus
        // itself goes through `configurator_handoff`. Changing this set
        // changes the model's first-turn schema and must be reviewed
        // deliberately.
        ConfigurationDomainBootstrap._resetForTests()
        ConfigurationDomainBootstrap.registerBuiltIns()
        defer { ConfigurationDomainBootstrap._resetForTests() }

        let routing: Set<String> = [
            "status", "state", "configurator_handoff", "architect_handoff", "run_workflow", "clarify",
        ]
        let legacy: Set<String> = [
            "todo", "complete", "get_current_time", "calculate", "web_search", "search_and_extract",
        ]
        #expect(ToolRegistry.orchestratorRoutingToolNames == routing)
        #expect(ToolRegistry.orchestratorLegacyToolNames == legacy)
        #expect(ToolRegistry.orchestratorAllowedToolNames == routing)
        #expect(ToolRegistry.orchestratorAllowedToolNames.isDisjoint(with: ToolRegistry.configureToolNames))
        // The capability-search gateway is explicitly NOT in the Default
        // agent's surface anymore (it stays available to custom agents).
        #expect(!ToolRegistry.orchestratorAllowedToolNames.contains("capabilities_discover"))
        #expect(!ToolRegistry.orchestratorAllowedToolNames.contains("capabilities_load"))
        // Orchestrator/worker split: worker-owned tools never intersect the
        // orchestrator allowlist, and the worker baseline carries the
        // artifact-delivery tool.
        #expect(
            ToolRegistry.orchestratorAllowedToolNames
                .isDisjoint(with: ToolRegistry.orchestratorExcludedToolNames)
        )
        #expect(ToolRegistry.spawnedWorkerBaselineToolNames.contains("share_artifact"))
    }
}
