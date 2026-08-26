//
//  ConfigAppCoverageTests.swift
//  OsaurusCoreTests
//
//  Wave 3b — app behavior coverage, post scope reductions. Scope
//  reduction 1 removed the vanity sections (computer-use, sandbox,
//  privacy-filter, image-generation, app theme/toast keys); scope
//  reduction 2 removed `server`, `chat`, and `app` entirely. What remains
//  here pins delegation (SubagentConfiguration) and per-agent relay
//  through the planner (validation, risk flags), the shared enum mappings,
//  and an apply -> export round trip against the real stores (under
//  OSAURUS_TEST_ROOT).
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Enum / value mappings

struct ConfigAppBehaviorEnumTests {

    @Test
    func storeEnumKeys_matchTheRuntimeRawValues() {
        // The manifest's allowed lists derive from the store enums; a raw
        // value rename upstream must fail here, not in a live apply.
        #expect(ConfigAppBehaviorEnums.spawnToolAccessValues.contains("read_only"))
        #expect(ConfigAppBehaviorEnums.permissionPolicies.contains("always_allow"))
        #expect(!ConfigAppBehaviorEnums.permissionKindIds.isEmpty)
        #expect(ConfigAppBehaviorEnums.applescriptMode(forKey: "confirm_each") == .confirmEach)
        #expect(
            ConfigAppBehaviorEnums.applescriptMode(forKey: "auto_run_with_warning")
                == .autoRunWithWarning)
    }

    @Test
    func removedVanitySections_stayRemovedFromTheSchema() {
        // Scope-reduction regression pin: re-adding a removed section bloats
        // the schema every small local model has to page through.
        let sectionNames = Set(ConfigSectionID.allNames)
        for removed in [
            "voice", "computer_use", "sandbox", "privacy_filter", "image_generation",
            "server", "chat", "app",
        ] {
            #expect(!sectionNames.contains(removed), "`\(removed)` crept back into the schema")
        }
        let schema = ConfigSchemaReference.text
        for removedKey in [
            "toast_position", "font_size_multiplier", "cloud_vision_consent",
            "expose_to_network", "disk_cache_enabled", "core_model", "hide_dock_icon",
            "model_exposure",
        ] {
            #expect(!schema.contains(removedKey), "`\(removedKey)` crept back into the schema")
        }
        // The per-agent capability toggles stay declarative.
        #expect(schema.contains("computer_use_enabled"))
        #expect(schema.contains("browser_use_enabled"))
        // The 16-section roster after scope reduction 2.
        #expect(ConfigSectionID.allNames.count == 16, "\(ConfigSectionID.allNames)")
    }
}

// MARK: - Planner validation

@Suite(.serialized)
@MainActor
struct ConfigAppCoveragePlannerTests {

    private func plan(_ mutate: (inout OsaurusConfigDocument) -> Void) throws -> ConfigPlan {
        var document = OsaurusConfigDocument()
        mutate(&document)
        return try ConfigPlanner.plan(document: document, prune: false)
    }

    private func planIssues(_ mutate: (inout OsaurusConfigDocument) -> Void) -> [String] {
        do {
            _ = try plan(mutate)
            return []
        } catch let error as ConfigPlanIssues {
            return error.issues
        } catch {
            return ["unexpected error: \(error)"]
        }
    }

    @Test
    func invalidEnumValues_failWithCanonicalLists() {
        let issues = planIssues { document in
            var delegation = DelegationSection()
            delegation.applescriptExecutionMode = "just_run_it"
            delegation.spawnToolAccess = "full"
            document.delegation = delegation
        }
        #expect(issues.contains { $0.contains("delegation.applescript_execution_mode") })
        #expect(issues.contains { $0.contains("delegation.spawn_tool_access") })
    }

    @Test
    func outOfRangeValues_failValidation() {
        let budgetIssues = planIssues { document in
            var delegation = DelegationSection()
            delegation.budgetMaxTokens = 1
            delegation.budgetMaxTurns = 100
            delegation.budgetMaxSeconds = 1
            document.delegation = delegation
        }
        #expect(budgetIssues.contains { $0.contains("delegation.budget_max_tokens") })
        #expect(budgetIssues.contains { $0.contains("delegation.budget_max_turns") })
        #expect(budgetIssues.contains { $0.contains("delegation.budget_max_seconds") })
    }

    @Test
    func unknownMapKeys_failValidation() {
        let issues = planIssues { document in
            var delegation = DelegationSection()
            delegation.permissionDefaults = ["teleport": "always_allow", "image": "shrug"]
            document.delegation = delegation
        }
        #expect(issues.contains { $0.contains("delegation.permission_defaults[teleport]") })
        #expect(issues.contains { $0.contains("delegation.permission_defaults[image]") })
    }

    @Test
    func spawnableAgents_rejectUnknownAndDefault() {
        let issues = planIssues { document in
            var delegation = DelegationSection()
            delegation.spawnableAgents = ["Default", "No Such Agent \(UUID().uuidString.prefix(6))"]
            document.delegation = delegation
        }
        #expect(issues.contains { $0.contains("cannot spawn itself") })
        #expect(issues.contains { $0.contains("no agent named") })
    }

    @Test
    func spawnableAgents_acceptAgentsCreatedByTheSameDocument() throws {
        let name = "Spawn Probe Agent \(UUID().uuidString.prefix(6))"
        let plan = try plan { document in
            document.agents = [AgentEntry(name: name)]
            var delegation = DelegationSection()
            delegation.spawnableAgents = [name]
            document.delegation = delegation
        }
        #expect(plan.actions.contains { $0.section == "delegation" })
    }

    // MARK: Risk flags

    @Test
    func delegationLoosening_isFlaggedHighRisk() throws {
        let current = ConfigExporter.export().delegation
        guard let kind = ConfigAppBehaviorEnums.permissionKindIds.first else {
            Issue.record("no subagent capability kinds registered")
            return
        }
        let plan = try plan { document in
            var section = DelegationSection()
            section.permissionDefaults = [kind: "always_allow"]
            section.applescriptExecutionMode = "auto_run_with_warning"
            section.ramSafetyPreflight = false
            document.delegation = section
        }
        if current?.permissionDefaults?[kind] != "always_allow" {
            #expect(plan.risks.contains(ConfigRisk.alwaysAllowSubagent(kind)))
        }
        if current?.applescriptExecutionMode != "auto_run_with_warning" {
            #expect(plan.risks.contains(ConfigRisk.applescriptAutoRun))
        }
        if current?.ramSafetyPreflight != false {
            #expect(plan.risks.contains(ConfigRisk.ramPreflightDisabled))
        }
    }

    @Test
    func newAgentWithRelay_isFlaggedHighRisk() throws {
        let name = "Relay Probe Agent \(UUID().uuidString.prefix(6))"
        var caps = AgentCapabilitiesEntry()
        caps.relayEnabled = true
        var agent = AgentEntry(name: name)
        agent.capabilities = caps
        let plan = try plan { $0.agents = [agent] }
        #expect(plan.risks.contains(ConfigRisk.relayEnabled(name)))
        #expect(plan.hasHighRiskChanges)
    }
}

// MARK: - Apply -> export round trips

@Suite(.serialized)
@MainActor
struct ConfigAppCoverageApplyTests {

    private static func apply(_ mutate: (inout OsaurusConfigDocument) -> Void) async
        -> [ConfigApplyResult]
    {
        var document = OsaurusConfigDocument()
        mutate(&document)
        return await ConfigApplier.apply(document: document, prune: false)
    }

    private static func expectNoFailures(_ results: [ConfigApplyResult]) {
        #expect(results.allSatisfy { $0.status != .failed }, "\(results)")
    }

    /// Re-planning a fresh export must be a no-op after every apply.
    /// Scoped to the sections under test so concurrent suites mutating
    /// unrelated live state (providers, agents, server, ...) cannot poison
    /// the check in the full parallel run.
    private static func expectIdempotentExport(sections: Set<ConfigSectionID>) throws {
        let scoped = ConfigExporter.export().filtered(to: sections)
        let plan = try ConfigPlanner.plan(document: scoped, prune: false)
        #expect(plan.isEmpty, "expected no-op plan, got:\n\(plan.summaryText())")
    }

    @Test
    func delegation_applyThenExportRoundTrip() async throws {
        // Cross-suite lock: delegation suites sandbox the same store via
        // `SubagentConfigurationStore.setOverrideDirectory`; mutating the
        // live store while a sandbox lease is active races both sides.
        await SubagentStoreTestLock.shared.acquire()
        defer { SubagentStoreTestLock.shared.release() }

        let before = ConfigExporter.export().delegation

        var desired = DelegationSection()
        desired.budgetMaxTokens = before?.budgetMaxTokens == 4096 ? 2048 : 4096
        desired.budgetMaxTurns = before?.budgetMaxTurns == 4 ? 2 : 4
        desired.spawnToolAccess = before?.spawnToolAccess == "none" ? "read_only" : "none"
        desired.coexistenceEnabled = !(before?.coexistenceEnabled ?? false)
        Self.expectNoFailures(await Self.apply { $0.delegation = desired })

        let after = ConfigExporter.export().delegation
        #expect(after?.budgetMaxTokens == desired.budgetMaxTokens)
        #expect(after?.budgetMaxTurns == desired.budgetMaxTurns)
        #expect(after?.spawnToolAccess == desired.spawnToolAccess)
        #expect(after?.coexistenceEnabled == desired.coexistenceEnabled)
        try Self.expectIdempotentExport(sections: [.delegation])

        var restore = DelegationSection()
        restore.budgetMaxTokens = before?.budgetMaxTokens
        restore.budgetMaxTurns = before?.budgetMaxTurns
        restore.spawnToolAccess = before?.spawnToolAccess
        restore.coexistenceEnabled = before?.coexistenceEnabled
        _ = await Self.apply { $0.delegation = restore }
    }

    @Test
    func exportedDocument_containsNoSecretShapedKeys() throws {
        let yaml = try ConfigYAML.encode(ConfigExporter.export())
        let lowered = yaml.lowercased()
        for forbidden in ["api_key", "apikey", "access_token", "bearer ", "password"] {
            #expect(!lowered.contains(forbidden), "exported YAML contains `\(forbidden)`")
        }
    }
}
