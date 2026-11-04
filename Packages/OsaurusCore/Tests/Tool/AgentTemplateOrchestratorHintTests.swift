//
//  AgentTemplateOrchestratorHintTests.swift
//  OsaurusCoreTests
//
//  The orchestrator only reaches for an agent template if something tells
//  it templates exist. A live run showed why this matters: the model read
//  the agents scope, followed the generic write contract ("compose a
//  minimal YAML and apply"), and hand-wrote four agents, copying a model id
//  off an unrelated agent that happened to be named "Local Agent". It never
//  called the templates action once.
//
//  Two surfaces carry the fix, and both are pinned here: the agents-scope
//  read hint (dynamic, names the user's visible templates) and the default
//  agent's delegation rubric (static, so the prompt prefix stays stable).
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentTemplateOrchestratorHintTests {

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

    // MARK: - Agents read hint

    @Test
    func agentsScopeHeader_namesVisibleTemplatesAndRoutesToPlan() {
        let header = ConfigurationReadNextStep.semanticsHeader(
            forScope: "agents",
            agentTemplateNames: ["Local Agent", "Sub Agent"]
        )
        #expect(header.contains("Local Agent"))
        #expect(header.contains("Sub Agent"))
        // The route has to be spelled out, not merely announced.
        #expect(header.contains("template:"))
        #expect(header.contains("PREFER a template"))
        // The decoy that actually fooled the model in the live run.
        #expect(header.contains("NOT an existing agent"))
    }

    @Test
    func agentsScopeHeader_saysNothingWhenNoTemplatesAreVisible() {
        let header = ConfigurationReadNextStep.semanticsHeader(
            forScope: "agents", agentTemplateNames: [])
        #expect(!header.contains("AGENT TEMPLATES"))
        // The shared semantics still ride along.
        #expect(header.contains("Entities match by name"))
    }

    @Test
    func templateLineIsAgentsScopeOnly() {
        // A providers or models read has nothing to do with agent
        // templates; the line would just be noise on every other result.
        for scope in ["providers", "models", "plugins", "knowledge"] {
            let header = ConfigurationReadNextStep.semanticsHeader(
                forScope: scope, agentTemplateNames: ["Local Agent"])
            #expect(!header.contains("AGENT TEMPLATES"), "scope \(scope) must not carry the line")
        }
    }

    @Test
    func capabilityLineIsNilWithoutNames() {
        #expect(ConfigurationReadNextStep.agentTemplateCapabilityLine(templateNames: []) == nil)
        #expect(ConfigurationReadNextStep.agentTemplateCapabilityLine(templateNames: ["A"]) != nil)
    }

    // MARK: - Delegation rubric

    @MainActor
    @Test
    func delegationChecksTemplatesBeforeHandWritingAnAgent() {
        for compact in [true, false] {
            let rendered = DefaultAgentSystemPromptBuilder._renderForTests(
                domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])],
                compact: compact
            )
            #expect(rendered.contains("action: 'templates'"), "compact: \(compact)")
            #expect(rendered.contains("no template fits"), "compact: \(compact)")
            // Creating an agent is still a same-turn action, not an offer.
            #expect(rendered.contains("spawn_agent"), "compact: \(compact)")
        }
    }

    /// The names of a user's templates must NOT reach the system prompt:
    /// the prefix has to stay byte-stable across a library edit or every
    /// such edit costs a full KV-cache rebuild. Names ride on the tool
    /// result instead, which is not part of the cached prefix.
    @MainActor
    @Test
    func delegationRubricCarriesNoTemplateNames() {
        let rendered = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])]
        )
        #expect(!rendered.contains("Local Agent"))
        #expect(!rendered.contains("Sub Agent"))
        #expect(!rendered.contains("Cloud Agent"))
    }

    // MARK: - Template plan

    /// A template plan has no YAML document to repeat. Told to apply "this
    /// same document", small models transcribed the plan into an `agents:`
    /// entry instead, dropping the template's model and its lineage.
    @Test
    func templatePlan_nextStepRepeatsTheTemplateNotADocument() async throws {
        let args: [String: Any] = [
            "action": "plan",
            "template": "Sub Agent",
            "overrides": ["name": "zz-template-plan-probe-\(UUID().uuidString.prefix(8))"],
        ]
        let data = try JSONSerialization.data(withJSONObject: args)
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await OsaurusConfigTool().execute(argumentsJSON: String(decoding: data, as: UTF8.self))
        }
        #expect(result.contains("dry_run_not_applied"), "plan did not run: \(result)")
        #expect(result.contains("the same `template` and `overrides`"), "next_step: \(result)")
        #expect(!result.contains("this same document"))
    }

    /// Models that fill every argument send `yaml: "{}"` with a template;
    /// refusing that looped Grok on the same rejected plan for eight turns.
    @Test
    func emptyYAMLBesideTemplate_plansTheTemplate() async throws {
        for empty in ["{}", " ", "null"] {
            let args: [String: Any] = [
                "action": "plan",
                "template": "Sub Agent",
                "yaml": empty,
                "overrides": ["name": "zz-empty-yaml-probe-\(UUID().uuidString.prefix(8))"],
            ]
            let data = try JSONSerialization.data(withJSONObject: args)
            let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
                try await OsaurusConfigTool().execute(argumentsJSON: String(decoding: data, as: UTF8.self))
            }
            #expect(result.contains("dry_run_not_applied"), "yaml \(empty): \(result)")
        }
    }

    @Test
    func unnamedTemplatePlan_saysHowToNameTheAgent() async throws {
        let unnamed = try await plan(["template": "Sub Agent", "yaml": "{}"])
        #expect(unnamed.contains("No `overrides.name` given"), "\(unnamed)")

        let named = try await plan([
            "template": "Sub Agent", "overrides": ["name": "zz-named-probe-\(UUID().uuidString.prefix(8))"],
        ])
        #expect(!named.contains("No `overrides.name` given"), "\(named)")
    }

    private func plan(_ args: [String: Any]) async throws -> String {
        var args = args
        args["action"] = "plan"
        let data = try JSONSerialization.data(withJSONObject: args)
        return try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await OsaurusConfigTool().execute(argumentsJSON: String(decoding: data, as: UTF8.self))
        }
    }

    /// Grok put the agent's fields in `yaml` next to `template` and kept
    /// re-sending them after being told to use `overrides`; agent fields
    /// (bare, or a one-entry `agents:` list) are the overrides.
    @Test
    func agentFieldsInYAMLBesideTemplate_becomeOverrides() async throws {
        let name = "zz-yaml-fields-\(UUID().uuidString.prefix(8))"
        for yaml in [
            "name: \(name)\nsystem_prompt: Track my budget.\ncapabilities:\n  calculator_enabled: true",
            "agents:\n  - name: \(name)\n    capabilities:\n      calculator_enabled: true",
            "name: \(name)\noverrides:\n  capabilities:\n    calculator_enabled: true",
        ] {
            let result = try await plan(["template": "Sub Agent", "yaml": yaml])
            #expect(result.contains("dry_run_not_applied"), "yaml \(yaml): \(result)")
            #expect(result.contains(name))
            #expect(result.contains("calculator"), "capabilities dropped: \(result)")
        }

        let invented = try await plan([
            "template": "Sub Agent",
            "yaml": "name: \(name)\noverrides:\n  capabilities:\n    file_search_enabled: true",
        ])
        #expect(invented.contains("Unknown `overrides.capabilities` key(s): file_search_enabled"), "\(invented)")
    }

    @Test
    func wholeDocumentBesideTemplate_staysAConflict() async throws {
        for yaml in ["memory:\n  enabled: true", "agents:\n  - name: A\n  - name: B"] {
            let result = try await plan(["template": "Sub Agent", "yaml": yaml])
            #expect(result.contains("not both"), "yaml \(yaml): \(result)")
            #expect(result.contains("`overrides`"))
            #expect(result.contains(#""retryable":false"#))
        }
        let both = try await plan([
            "template": "Sub Agent", "yaml": "name: A", "overrides": ["name": "B"],
        ])
        #expect(both.contains("not both"), "\(both)")
    }

    @Test
    func overridesCapabilities_reachThePlanAndRejectTypos() async throws {
        let name = "zz-caps-\(UUID().uuidString.prefix(8))"
        let ok = try await plan([
            "template": "Sub Agent",
            "overrides": ["name": name, "capabilities": ["redaction_tools_enabled": true]],
        ])
        #expect(ok.contains("dry_run_not_applied"), "\(ok)")
        #expect(ok.contains("redaction"), "capabilities dropped: \(ok)")

        let typo = try await plan([
            "template": "Sub Agent",
            "overrides": ["name": name, "capabilities": ["calculater_enabled": true]],
        ])
        #expect(typo.contains("Unknown `overrides.capabilities` key(s): calculater_enabled"), "\(typo)")
        #expect(typo.contains("calculator_enabled"))

        let stray = try await plan(["template": "Sub Agent", "overrides": ["name": name, "tools": "all"]])
        #expect(stray.contains("Unknown `overrides` key(s): tools"), "\(stray)")

        let numeric = try await plan([
            "template": "Sub Agent", "overrides": ["name": name, "capabilities": ["calculator_enabled": 1]],
        ])
        #expect(numeric.contains("on/off toggles"), "\(numeric)")
    }

    @Test
    func unknownTemplateWithOverrides_pointsAtAgentsEntryNotSaveAs() async throws {
        let args: [String: Any] = [
            "action": "plan",
            "template": "zz-missing-\(UUID().uuidString.prefix(8))",
            "overrides": ["name": "Researcher"],
        ]
        let data = try JSONSerialization.data(withJSONObject: args)
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await OsaurusConfigTool().execute(argumentsJSON: String(decoding: data, as: UTF8.self))
        }
        #expect(result.contains("No agent template named"), "message: \(result)")
        #expect(result.contains("Sub Agent"))
        #expect(result.contains("`agents:` entry"))
        #expect(!result.contains("save_as"))
    }

    @Test
    func starterPromptAsTemplate_pointsAtTheAgentsEntryTemplateKey() async throws {
        let args: [String: Any] = [
            "action": "plan",
            "template": "Researcher",
            "overrides": ["name": "Researcher"],
        ]
        let data = try JSONSerialization.data(withJSONObject: args)
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await OsaurusConfigTool().execute(argumentsJSON: String(decoding: data, as: UTF8.self))
        }
        #expect(result.contains("is a starter prompt, not an agent template"), "message: \(result)")
        #expect(result.contains("template: researcher"))
        #expect(result.contains("Cloud Agent"))
    }
}
