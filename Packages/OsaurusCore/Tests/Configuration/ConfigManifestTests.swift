//
//  ConfigManifestTests.swift
//  OsaurusCoreTests
//
//  `ConfigManifest` is the single source of truth for the declarative
//  schema. These tests pin the derivations in BOTH directions:
//   * every manifest key decodes through the Codable structs (the
//     rendered example document is a legal document), and
//   * every key the Codable structs can emit is known to the manifest
//     (a fully-populated document round-trips strict validation).
//  Plus JSON Schema shape and derived-table sanity.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ConfigManifestDerivationTests {

    @Test
    func knownKeysMatchManifestSections() {
        // Root must know every section plus `version`.
        let root = ConfigManifest.knownKeys[""]
        #expect(root == Set(ConfigSectionID.allNames + ["version"]))
        // Spot-check derived paths exist.
        for path in ["memory", "delegation", "agents[]", "agents[].capabilities",
            "search_providers.providers[]"]
        {
            #expect(ConfigManifest.knownKeys[path] != nil, "missing knownKeys path `\(path)`")
        }
        // Scope reduction 2: the removed sections must not resurface.
        for removed in ["server", "chat", "app"] {
            #expect(ConfigManifest.knownKeys[removed] == nil, "`\(removed)` crept back")
        }
    }

    @Test
    func listItemRequiredKeys_deriveFromEntityLists() {
        #expect(ConfigManifest.listItemRequiredKey["agents"] == "name")
        #expect(ConfigManifest.listItemRequiredKey["mcp_servers"] == "name")
        #expect(ConfigManifest.listItemRequiredKey["providers"] == "name")
        #expect(ConfigManifest.listItemRequiredKey["schedules"] == "name")
        #expect(ConfigManifest.listItemRequiredKey["watchers"] == "name")
        #expect(ConfigManifest.listItemRequiredKey["search_providers.providers"] == "id")
    }

    @Test
    func exampleDocument_decodesThroughTheCodableStructs() throws {
        // The schema reference's own examples must form a legal document.
        // A manifest key with no Codable field (or a typo'd example) fails
        // here instead of shipping a reference the model cannot follow.
        let document = try ConfigYAML.decode(ConfigManifest.exampleDocumentYAML())
        #expect(document.version == 1)
        #expect(document.memory != nil)
        #expect(document.agents?.isEmpty == false)
        #expect(document.providers?.isEmpty == false)
    }

    @Test
    func fullyPopulatedDocument_emitsOnlyManifestKnownKeys() throws {
        // The reverse direction: encode the decoded example document (which
        // populates every field the schema shows) and strict-validate the
        // emitted YAML. A Codable field missing from the manifest fails.
        let document = try ConfigYAML.decode(ConfigManifest.exampleDocumentYAML())
        let yaml = try ConfigYAML.encode(document)
        _ = try ConfigYAML.decode(yaml)
    }

    @Test
    func schemaReferenceText_containsEveryEnforcedKey() {
        let text = ConfigSchemaReference.text
        for (path, keys) in ConfigManifest.knownKeys {
            for key in keys where key != "version" {
                let location = path.isEmpty ? "top level" : path
                #expect(
                    text.contains("\(key):"),
                    "`\(key)` (at `\(location)`) enforced but missing from the schema text")
            }
        }
    }

    @Test
    func schemaReferenceText_supportsSectionFilter() {
        // Small-window models fetch the schema one section at a time; the
        // filtered render must contain the asked section and none other.
        let filtered = ConfigSchemaReference.text(sections: [.models])
        #expect(filtered.contains("models:"))
        #expect(!filtered.contains("mcp_servers:"))
        #expect(!filtered.contains("agents:"))
        // Preamble semantics and footer survive the filter.
        #expect(filtered.contains("Merge-by-default"))
        #expect(filtered.contains("Not configurable here"))
        // nil filter matches the full text.
        #expect(ConfigSchemaReference.text(sections: nil) == ConfigSchemaReference.text)
    }

    @Test
    func sectionNameSuggestions_bridgeCommonMisses() {
        #expect(OsaurusConfigTool.closestSectionName(to: "mcp") == "mcp_servers")
        #expect(OsaurusConfigTool.closestSectionName(to: "knowledge") == "knowledge_collections")
        #expect(OsaurusConfigTool.closestSectionName(to: "provider") == "providers")
        #expect(OsaurusConfigTool.closestSectionName(to: "zzz_nonsense") == nil)
    }

    @Test
    func jsonSchema_isSerializableAndCoversEverySection() throws {
        let schema = ConfigManifest.jsonSchema()
        let data = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        #expect(!data.isEmpty)

        let properties = try #require(schema["properties"] as? [String: Any])
        for name in ConfigSectionID.allNames {
            #expect(properties[name] != nil, "JSON schema missing section `\(name)`")
        }
        #expect(properties["version"] != nil)
        #expect(schema["additionalProperties"] as? Bool == false)

        // Entity lists carry their required key.
        let agents = try #require(properties["agents"] as? [String: Any])
        let items = try #require(agents["items"] as? [String: Any])
        #expect(items["required"] as? [String] == ["name"])

        // Enum constraints survive derivation.
        let delegation = try #require(properties["delegation"] as? [String: Any])
        let delegationProps = try #require(delegation["properties"] as? [String: Any])
        let spawnAccess = try #require(delegationProps["spawn_tool_access"] as? [String: Any])
        #expect((spawnAccess["enum"] as? [String])?.contains("read_only") == true)
    }

    @Test
    func freeformValueConstraints_coverToolPolicies() {
        #expect(
            ConfigManifest.freeformValueConstraints["tools.policies"] == ["auto", "ask", "deny"])
    }

    @Test
    func derivedSearchKeywords_humanizeKeyNames() {
        let keywords = ConfigManifest.derivedSearchKeywords()
        #expect(keywords.contains("mcp servers"))
        #expect(keywords.contains("search providers"))
        #expect(!keywords.contains("mcp_servers"), "keywords must be humanized")
    }
}

// MARK: - JSON as an alternate document format

struct ConfigJSONFormatTests {

    @Test
    func jsonDocument_decodesThroughTheSamePipeline() throws {
        // JSON is a YAML 1.2 subset: plan/apply accept a JSON document in
        // the same field, with the same strict unknown-key validation.
        let json = """
            {
              "version": 1,
              "default_agent": {"max_tokens": 2048, "temperature": null},
              "agents": [{"name": "Research Agent", "temperature": 0.4}]
            }
            """
        let document = try ConfigYAML.decode(json)
        #expect(document.defaultAgent?.maxTokens == .value(2048))
        #expect(document.defaultAgent?.temperature == .null)
        #expect(document.agents?.first?.name == "Research Agent")
        #expect(document.agents?.first?.temperature == .value(0.4))
    }

    @Test
    func jsonDocument_unknownKeysAreStillRejected() {
        let json = """
            {"default_agent": {"temprature": 0.7}}
            """
        do {
            _ = try ConfigYAML.decode(json)
            Issue.record("expected rejection of the typo'd key in JSON input")
        } catch let error as ConfigYAMLError {
            let joined = error.messages.joined(separator: "\n")
            #expect(joined.contains("temprature"))
            #expect(joined.contains("temperature"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test
    func legacyDefaultAgentDisableToolsIsAcceptedButDropped() throws {
        let json = #"{"default_agent": {"disable_tools": true, "max_tokens": 2048}}"#
        let document = try ConfigYAML.decode(json)
        #expect(document.defaultAgent?.maxTokens == .value(2048))

        let encoded = try ConfigJSON.encode(document)
        #expect(!encoded.contains("disable_tools"))
    }

    @Test
    func encodeJSON_roundTripsAndOmitsAbsentKeys() throws {
        var document = OsaurusConfigDocument()
        var defaultAgent = DefaultAgentSection()
        defaultAgent.maxTokens = .value(2048)
        defaultAgent.temperature = .null
        document.defaultAgent = defaultAgent
        document.models = ["mlx-community/Some-Model-4bit"]

        let json = try ConfigJSON.encode(document)
        // Explicit null survives; absent keys are omitted.
        #expect(json.contains("\"temperature\" : null"))
        #expect(!json.contains("system_prompt"))

        let decoded = try ConfigYAML.decode(json)
        #expect(decoded.defaultAgent?.maxTokens == .value(2048))
        #expect(decoded.defaultAgent?.temperature == .null)
        #expect(decoded.models == ["mlx-community/Some-Model-4bit"])
    }

    @Test
    func exportedJSON_neverContainsSecretShapedKeys() throws {
        var document = OsaurusConfigDocument()
        document.providers = [ProviderEntry(name: "Anthropic")]
        let json = try ConfigJSON.encode(document).lowercased()
        for forbidden in ["api_key", "apikey", "access_token", "refresh_token", "password"] {
            #expect(!json.contains(forbidden), "exported JSON contains `\(forbidden)`")
        }
    }
}
