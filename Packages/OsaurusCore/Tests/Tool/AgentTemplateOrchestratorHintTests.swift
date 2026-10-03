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
}
