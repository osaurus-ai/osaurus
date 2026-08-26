//
//  ConfigurationGapClosureTests.swift
//  OsaurusCoreTests
//
//  Functional coverage for the configuration-agent READ surfaces:
//
//   * osaurus_inspect list / describe — read scopes (skills, watchers,
//     knowledge, themes, commands, channels, search) return well-formed
//     payloads from live state.
//   * osaurus_inspect status — the enriched snapshot carries the server /
//     memory / sandbox / channels / watchers / skills / knowledge rollups.
//
//  Write-path coverage (agent capabilities, schedule reassignment,
//  watcher CRUD) moved to the declarative-config tests when the
//  per-domain write tools were replaced by `osaurus_config`.
//
//  All reads run against the OSAURUS_TEST_ROOT-scoped stores.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Shared helpers

private func parseEnvelope(_ envelope: String) throws -> [String: Any] {
    let data = try #require(envelope.data(using: .utf8))
    let obj = try JSONSerialization.jsonObject(with: data)
    return try #require(obj as? [String: Any])
}

/// Run a configure tool as the Default agent and parse its envelope.
private func runAsDefaultAgent(
    _ tool: any OsaurusTool, _ argumentsJSON: String
) async throws -> [String: Any] {
    let envelope = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
        try await tool.execute(argumentsJSON: argumentsJSON)
    }
    return try parseEnvelope(envelope)
}

// MARK: - Read scopes

@Suite(.serialized)
struct ConfigurationReadScopeFunctionalTests {

    @Test
    func list_skillsScope_returnsRowsWithOriginFlags() async throws {
        let dict = try await runAsDefaultAgent(OsaurusInspectTool(), #"{"action": "list", "scope": "skills"}"#)
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        #expect(result["scope"] as? String == "skills")
        let items = try #require(result["items"] as? [[String: Any]])
        // Built-in skills ship with the app, so the scope is never empty.
        #expect(!items.isEmpty)
        for item in items {
            #expect(item["id"] as? String != nil)
            #expect(item["name"] as? String != nil)
            #expect(item["built_in"] as? Bool != nil)
            #expect(item["from_plugin"] as? Bool != nil)
        }
    }

    @Test
    func list_commandsScope_includesBuiltIns() async throws {
        let dict = try await runAsDefaultAgent(OsaurusInspectTool(), #"{"action": "list", "scope": "commands"}"#)
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        let items = try #require(result["items"] as? [[String: Any]])
        #expect(items.contains { ($0["built_in"] as? Bool) == true })
    }

    @Test
    func list_themesScope_marksTheActiveTheme() async throws {
        let dict = try await runAsDefaultAgent(OsaurusInspectTool(), #"{"action": "list", "scope": "themes"}"#)
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        let items = try #require(result["items"] as? [[String: Any]])
        // Built-in presets are installed on first list.
        #expect(!items.isEmpty)
        for item in items {
            #expect(item["active"] as? Bool != nil)
            #expect(item["built_in"] as? Bool != nil)
        }
    }

    @Test
    func list_knowledgeWatchersChannels_returnWellFormedPayloads() async throws {
        for scope in ["knowledge", "watchers", "channels"] {
            let dict = try await runAsDefaultAgent(
                OsaurusInspectTool(), "{\"action\": \"list\", \"scope\": \"\(scope)\"}"
            )
            #expect(dict["ok"] as? Bool == true, "scope \(scope) should list")
            let result = try #require(dict["result"] as? [String: Any])
            #expect(result["scope"] as? String == scope)
            #expect(result["items"] as? [[String: Any]] != nil, "scope \(scope) items missing")
        }
    }

    // MARK: yaml_shape embedding (inspect → apply without a schema call)

    @Test
    func list_declarativeScope_embedsTheSectionYamlShape() async throws {
        let dict = try await runAsDefaultAgent(
            OsaurusInspectTool(), #"{"action": "list", "scope": "schedules"}"#)
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        let shape = try #require(result["yaml_shape"] as? String)
        #expect(shape.contains("schedules:"))
        // The shape-aware hint replaces the generic one: no schema call needed.
        let nextStep = try #require(result["next_step"] as? String)
        #expect(nextStep.contains("yaml_shape"))
        #expect(nextStep.contains("no schema call needed"))
        #expect(nextStep.contains("prune: true"))
    }

    @Test
    func list_agentsScope_shapeCoversAgentsAndActiveAgent() async throws {
        let dict = try await runAsDefaultAgent(
            OsaurusInspectTool(), #"{"action": "list", "scope": "agents"}"#)
        let result = try #require(dict["result"] as? [String: Any])
        let shape = try #require(result["yaml_shape"] as? String)
        // Activation ("switch to X") writes `active_agent`, so the agents
        // read must teach both sections.
        #expect(shape.contains("agents:"))
        #expect(shape.contains("active_agent:"))
    }

    @Test
    func list_nonDeclarativeScope_keepsThePlainHintWithoutShape() async throws {
        // Skills and themes have no declarative writer — embedding a shape
        // would teach a write that doesn't exist.
        for scope in ["skills", "themes"] {
            let dict = try await runAsDefaultAgent(
                OsaurusInspectTool(), "{\"action\": \"list\", \"scope\": \"\(scope)\"}")
            let result = try #require(dict["result"] as? [String: Any])
            #expect(result["yaml_shape"] == nil, "scope \(scope) must not embed a shape")
            let nextStep = try #require(result["next_step"] as? String)
            #expect(nextStep.contains("schema"), "plain hint should still route to schema")
        }
    }

    @Test
    func status_doesNotEmbedAShape() async throws {
        let dict = try await runAsDefaultAgent(OsaurusInspectTool(), #"{"action": "status"}"#)
        let result = try #require(dict["result"] as? [String: Any])
        #expect(result["yaml_shape"] == nil)
    }

    @Test
    func describe_declarativeScope_embedsTheSectionYamlShape() async throws {
        // Describe a built-in command by name: commands are declarative, so
        // the describe payload must carry the commands section shape.
        let list = try await runAsDefaultAgent(
            OsaurusInspectTool(), #"{"action": "list", "scope": "commands"}"#)
        let listResult = try #require(list["result"] as? [String: Any])
        let items = try #require(listResult["items"] as? [[String: Any]])
        let first = try #require(items.first)
        let name = try #require(first["name"] as? String)
        let dict = try await runAsDefaultAgent(
            OsaurusInspectTool(),
            "{\"action\": \"describe\", \"scope\": \"commands\", \"id\": \"\(name)\"}")
        let result = try #require(dict["result"] as? [String: Any])
        let shape = try #require(result["yaml_shape"] as? String)
        #expect(shape.contains("commands:"))
    }

    @Test
    func readHints_teachPruneAndSetApiKey() {
        // Knowledge-gap pins: delete = prune, key rotation = set_api_key —
        // on BOTH hint variants, since small models act on whichever hint
        // their last read carried. Both now ride on the single write
        // contract (Gap 0.5 consolidation).
        for hint in [
            ConfigurationReadNextStep.hint(hasShape: false),
            ConfigurationReadNextStep.hint(hasShape: true),
        ] {
            #expect(hint.contains("prune: true"))
            #expect(hint.contains("set_api_key: true"))
            #expect(hint.contains("never the key value"))
            #expect(hint.contains(ConfigurationReadNextStep.writeContract))
        }
    }

    @Test
    func removedScopes_getTheSettingsUIRedirect() async throws {
        // Scope reduction 2: `server`, `chat`, `app` are Settings-UI-only.
        // Guessing them as inspect scopes must return the honest redirect —
        // not the export redirect the model would loop on.
        for scope in ["server", "chat", "app"] {
            let dict = try await runAsDefaultAgent(
                OsaurusInspectTool(), "{\"action\": \"list\", \"scope\": \"\(scope)\"}")
            #expect(dict["ok"] as? Bool == false, "scope \(scope) must not list")
            let message = (dict["message"] as? String) ?? ""
            #expect(message.contains("Settings UI"), "no redirect for `\(scope)`: \(message)")
            #expect(!message.contains("export"), "removed scope must not route to export")
        }
    }

    @Test
    func modelAndProviderShapes_counterTheObservedFalseBeliefs() {
        // Iter-3 failure pins: with the roster in view the model still said
        // "downloads happen in the UI" (model-download) and "openrouter
        // isn't a real provider" (provider-add-openrouter). The scope
        // headers must contradict both outright.
        let models = ConfigurationReadNextStep.semanticsHeader(forScope: "models")
        #expect(models.contains("STARTS the download"))
        #expect(models.contains("Never redirect the user to the UI"))
        let providers = ConfigurationReadNextStep.semanticsHeader(forScope: "providers")
        #expect(providers.contains("openrouter included"))
        #expect(providers.contains("Never claim a listed provider is unsupported"))
        // And the secret semantics still ride on providers.
        #expect(providers.contains("set_api_key: true"))
    }

    @Test
    func list_searchScope_mirrorsProviderRanking() async throws {
        let dict = try await runAsDefaultAgent(OsaurusInspectTool(), #"{"action": "list", "scope": "search"}"#)
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        let items = try #require(result["items"] as? [[String: Any]])
        for item in items {
            #expect(item["id"] as? String != nil)
            #expect(item["rank"] as? Int != nil)
            #expect(item["enabled"] as? Bool != nil)
        }
    }

    @Test
    func describe_skillByName_matchesCaseInsensitively() async throws {
        // Pick a real skill from the list, then describe it by lowercased name.
        let listDict = try await runAsDefaultAgent(OsaurusInspectTool(), #"{"action": "list", "scope": "skills"}"#)
        let listResult = try #require(listDict["result"] as? [String: Any])
        let items = try #require(listResult["items"] as? [[String: Any]])
        let first = try #require(items.first)
        let skillName = try #require(first["name"] as? String)

        let dict = try await runAsDefaultAgent(
            OsaurusInspectTool(),
            "{\"action\": \"describe\", \"scope\": \"skills\", \"id\": \"\(skillName.lowercased())\"}"
        )
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        #expect((result["name"] as? String)?.caseInsensitiveCompare(skillName) == .orderedSame)
        #expect(result["keywords"] as? [String] != nil)
    }

    @Test
    func describe_unknownIdInNewScopes_failsCleanly() async throws {
        for scope in ["skills", "watchers", "knowledge", "themes", "commands", "channels", "search"] {
            let dict = try await runAsDefaultAgent(
                OsaurusInspectTool(),
                "{\"action\": \"describe\", \"scope\": \"\(scope)\", \"id\": \"definitely-not-a-real-id\"}"
            )
            #expect(dict["ok"] as? Bool == false, "scope \(scope) should not find the id")
            #expect(dict["kind"] as? String == "invalid_args")
        }
    }

    @Test
    func describe_agent_includesCapabilities() async throws {
        let agent = await MainActor.run {
            AgentManager.shared.create(
                name: "GapClosure Describe Probe",
                description: "",
                systemPrompt: "",
                defaultModel: nil,
                temperature: nil,
                maxTokens: nil
            )
        }
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

        let dict = try await runAsDefaultAgent(
            OsaurusInspectTool(),
            "{\"action\": \"describe\", \"scope\": \"agents\", \"id\": \"\(agent.id.uuidString)\"}"
        )
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        #expect(capabilities["tools_enabled"] as? Bool == true)
        #expect(capabilities["browser_use_enabled"] as? Bool == false)
        #expect(capabilities["knowledge_collection_ids"] as? [String] != nil)

        _ = await AgentManager.shared.delete(id: agent.id)
    }

    @Test
    func describe_agentByName_matchesAndUsesDocumentModelKey() async throws {
        // Regression for the live "set model on the coding agent" transcript:
        // describe must resolve names (not just UUIDs) so the model doesn't
        // burn a list round-trip, and the payload key must be `model` — the
        // old `default_model` key taught the model to write `default_model:`
        // into YAML, which the document schema rejects.
        let agent = await MainActor.run {
            AgentManager.shared.create(
                name: "GapClosure Name Probe",
                description: "",
                systemPrompt: "",
                defaultModel: "provider/some-model",
                temperature: nil,
                maxTokens: nil
            )
        }
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

        let dict = try await runAsDefaultAgent(
            OsaurusInspectTool(),
            #"{"action": "describe", "scope": "agents", "id": "gapclosure name probe"}"#
        )
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        #expect(result["name"] as? String == "GapClosure Name Probe")
        #expect(result["model"] as? String == "provider/some-model")
        #expect(result["default_model"] == nil)

        _ = await AgentManager.shared.delete(id: agent.id)
    }

    @Test
    func describe_providerByName_matchesCaseInsensitively() async throws {
        let provider = RemoteProvider(
            id: UUID(), name: "GapClosure Provider Probe", host: "api.example.test",
            enabled: false, autoConnect: false
        )
        await MainActor.run {
            RemoteProviderManager.shared.addProvider(provider, apiKey: nil, isEphemeral: false)
        }
        defer {
            Task { @MainActor in RemoteProviderManager.shared.removeProvider(id: provider.id) }
        }

        let dict = try await runAsDefaultAgent(
            OsaurusInspectTool(),
            #"{"action": "describe", "scope": "providers", "id": "gapclosure provider probe"}"#
        )
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        #expect(result["id"] as? String == provider.id.uuidString)

        await MainActor.run { RemoteProviderManager.shared.removeProvider(id: provider.id) }
    }

    @Test
    func status_carriesTheEnrichedRollups() async throws {
        let dict = try await runAsDefaultAgent(OsaurusInspectTool(), #"{"action": "status"}"#)
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])

        let server = try #require(result["server"] as? [String: Any])
        #expect(server["running"] as? Bool != nil)
        #expect(server["port"] as? Int != nil)

        let memory = try #require(result["memory"] as? [String: Any])
        #expect(memory["enabled"] as? Bool != nil)

        let sandbox = try #require(result["sandbox"] as? [String: Any])
        #expect(sandbox["provisioned"] as? Bool != nil)
        #expect(sandbox["state"] as? String != nil)

        let channels = try #require(result["channels"] as? [String: Any])
        #expect(channels["configured"] as? Int != nil)

        let watchers = try #require(result["watchers"] as? [String: Any])
        #expect(watchers["total"] as? Int != nil)

        let skills = try #require(result["skills"] as? [String: Any])
        #expect(skills["installed"] as? Int != nil)

        let knowledge = try #require(result["knowledge"] as? [String: Any])
        #expect(knowledge["collections"] as? Int != nil)
    }
}

// MARK: - Malformed-args teaches (observed eval dead ends)

/// Ornith-9B eval trials died on two malformed read calls: `list` with the
/// scope name in `filter` (and no `scope`), and `describe` with no `id`.
/// The generic missing-arg failure taught nothing, so the model never saw
/// the scope's items or capability lines and gave up. These envelopes must
/// name the exact corrected call.
@Suite(.serialized)
struct ConfigurationReadArgTeachTests {

    @Test
    func list_scopeNameInFilter_executesTheIntendedList() async throws {
        // Tolerant input handling: the intent is unambiguous, so the tool
        // runs the list against the misplaced scope instead of rejecting
        // (the reject-and-teach still left small models fabricating results
        // rather than retrying), and names the canonical shape in a note.
        let dict = try await runAsDefaultAgent(
            OsaurusInspectTool(), #"{"action": "list", "filter": "plugins"}"#
        )
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        #expect(result["scope"] as? String == "plugins")
        #expect(result["items"] is [Any])
        let note = try #require(dict["note"] as? String)
        #expect(note.contains("`plugins` is a scope, not a filter"))
        #expect(note.contains("{action: 'list', scope: 'plugins'}"))
    }

    @Test
    func list_missingScopeWithRealFilter_staysGenericMissingArg() async throws {
        // A genuine filter value must not trigger the scope-in-filter teach.
        let dict = try await runAsDefaultAgent(
            OsaurusInspectTool(), #"{"action": "list", "filter": "enabled"}"#
        )
        #expect(dict["ok"] as? Bool == false)
        let message = try #require(dict["message"] as? String)
        #expect(!message.contains("is a scope, not a filter"))
    }

    @Test
    func describe_missingId_routesToList() async throws {
        let dict = try await runAsDefaultAgent(
            OsaurusInspectTool(), #"{"action": "describe", "scope": "plugins"}"#
        )
        #expect(dict["ok"] as? Bool == false)
        let message = try #require(dict["message"] as? String)
        #expect(message.contains("`describe` needs `id`"))
        #expect(message.contains("{action: 'list', scope: 'plugins'}"))
    }
}
