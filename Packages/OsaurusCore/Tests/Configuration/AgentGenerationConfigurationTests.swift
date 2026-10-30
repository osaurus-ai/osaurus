import Foundation
import Testing

@testable import OsaurusCore

struct AgentGenerationConfigurationTests {
    @Test("strict configuration preserves nested template JSON and exact nullable overrides")
    func strictRoundTrip() throws {
        let document = try ConfigYAML.decode("""
            version: 1
            agents:
              - name: Generation fixture
                temperature: 0
                max_tokens: 1234
                generation_settings:
                  top_p: 0
                  top_k: 0
                  min_p: 0
                  repetition_penalty: 1
                  frequency_penalty: 0
                  presence_penalty: 0
                  seed: -7
                  stop: []
                  enable_thinking: false
                  reasoning_effort: low
                  speculative_decoding: false
                  template_kwargs:
                    custom:
                      enabled: false
                      count: 0
                      values: [null, value]
            """)
        let entry = try #require(document.agents?.first)
        #expect(entry.generationSettings == .value(AgentGenerationSettingsTests.explicit))
        let yaml = try ConfigYAML.encode(document)
        #expect(try ConfigYAML.decode(yaml).agents?.first?.generationSettings == entry.generationSettings)
        #expect(try ConfigYAML.decode(ConfigJSON.encode(document)).agents?.first?.generationSettings == entry.generationSettings)
    }

    @Test("only template_kwargs permits arbitrary nested keys")
    func rejectsUnknownAndInvalidShapes() {
        for group in [
            "topP: 0.5", "reasoning_budget: 100", "temperature: 0.5",
            "max_tokens: 100", "template_kwargs: [value]", "stop: false",
        ] {
            #expect(throws: (any Error).self) {
                _ = try ConfigYAML.decode("agents:\n  - name: Probe\n    generation_settings:\n      \(group)\n")
            }
        }
        #expect(throws: (any Error).self) {
            _ = try ConfigYAML.decode("agents:\n  - name: Probe\n    generation_settings: []\n")
        }
        // Built-in defaults remain on their existing schema.
        #expect(throws: (any Error).self) {
            _ = try ConfigYAML.decode("default_agent:\n  generation_settings: {}\n")
        }
    }

    @Test("group omission preserves, null clears, and template overrides replace atomically")
    func templateReplacement() throws {
        var entry = AgentEntry(name: "Probe")
        entry.generationSettings = .value(AgentGenerationSettingsTests.explicit)
        let template = AgentTemplate(name: "Probe", agent: entry)
        let absent = try ConfigYAML.decode("agents:\n  - name: Probe\n")
        let omitted = try #require(absent.agents?.first)
        #expect(omitted.generationSettings == .absent)
        #expect(template.document(overrides: omitted).agents?.first?.generationSettings == entry.generationSettings)

        let clear = try ConfigYAML.decode("agents:\n  - name: Probe\n    generation_settings: null\n")
        let clearing = try #require(clear.agents?.first)
        #expect(clearing.generationSettings == .null)
        #expect(template.document(overrides: clearing).agents?.first?.generationSettings == .null)
        var replacement = AgentEntry(name: "Probe")
        replacement.generationSettings = .value(AgentGenerationSettings(enableThinking: true))
        #expect(template.document(overrides: replacement).agents?.first?.generationSettings == replacement.generationSettings)
    }

    @Test("JSON schema has a closed nullable override group and an open nullable template object")
    func schemaContract() throws {
        let schema = ConfigManifest.jsonSchema()
        let properties = try #require(schema["properties"] as? [String: Any])
        let agents = try #require(properties["agents"] as? [String: Any])
        let items = try #require(agents["items"] as? [String: Any])
        let agentProperties = try #require(items["properties"] as? [String: Any])
        let group = try #require(agentProperties["generation_settings"] as? [String: Any])
        #expect(group["type"] as? [String] == ["object", "null"])
        #expect(group["additionalProperties"] as? Bool == false)
        let fields = try #require(group["properties"] as? [String: Any])
        #expect(Set(fields.keys) == Set([
            "top_p", "top_k", "min_p", "repetition_penalty", "frequency_penalty",
            "presence_penalty", "seed", "stop", "enable_thinking", "reasoning_effort", "template_kwargs", "speculative_decoding",
        ]))
        let kwargs = try #require(fields["template_kwargs"] as? [String: Any])
        #expect(kwargs["type"] as? [String] == ["object", "null"])
        #expect(kwargs["additionalProperties"] as? Bool == true)
        let stop = try #require(fields["stop"] as? [String: Any])
        #expect(stop["type"] as? [String] == ["array", "null"])
        _ = try ConfigYAML.decode(ConfigManifest.exampleDocumentYAML())
    }
}

@MainActor
@Suite(.serialized)
struct AgentGenerationConfigurationPersistenceTests {
    @Test("export, template JSON, draft and real configuration apply preserve saved defaults")
    func exportAndApply() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Agent(
                name: "Generation fixture", temperature: 0, maxTokens: 1234,
                generationSettings: AgentGenerationSettingsTests.explicit,
                autonomousExec: AutonomousExecConfig(enabled: false)
            )
            AgentStore.save(agent)
            AgentManager.shared.refresh()
            let exported = ConfigExporter.exportAgent(agent)
            let template = AgentTemplate(name: agent.name, agent: exported)
            let restored = try AgentTemplate.parse(template.jsonString())
            let draft = ConfigApplier.draftAgent(from: restored.agent).agent
            #expect(draft.generationSettings == agent.generationSettings)
            #expect(draft.temperature == 0)
            #expect(draft.maxTokens == 1234)

            // A real existing-agent patch must preserve omission and clear null.
            let absent = try ConfigYAML.decode("agents:\n  - name: Generation fixture\n    description: changed\n")
            _ = await ConfigApplier.apply(document: absent, prune: false)
            #expect(AgentStore.load(id: agent.id)?.generationSettings == agent.generationSettings)
            let clear = try ConfigYAML.decode("agents:\n  - name: Generation fixture\n    generation_settings: null\n")
            _ = await ConfigApplier.apply(document: clear, prune: false)
            #expect(AgentStore.load(id: agent.id)?.generationSettings == nil)
            #expect(AgentStore.load(id: agent.id)?.maxTokens == 1234)
            #expect(ConfigExporter.exportAgent(try #require(AgentStore.load(id: agent.id))).generationSettings == .null)

            var replace = AgentEntry(name: agent.name)
            replace.generationSettings = .value(AgentGenerationSettings(enableThinking: false))
            var document = OsaurusConfigDocument()
            document.agents = [replace]
            let plan = try ConfigPlanner.plan(document: document, prune: false)
            #expect(plan.actions.contains { $0.changes.contains { $0.contains("generation_settings") } })
            _ = await ConfigApplier.apply(document: document, prune: false)
            #expect(AgentStore.load(id: agent.id)?.generationSettings == replace.generationSettings.valueOrNil)

            replace.generationSettings = .value(AgentGenerationSettings(topK: -1))
            document.agents = [replace]
            #expect(throws: ConfigPlanIssues.self) { try ConfigPlanner.plan(document: document, prune: false) }
        }
    }
}
