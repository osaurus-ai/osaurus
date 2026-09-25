import Foundation
import Testing
@testable import OsaurusCore

@Suite("Agent description contract")
struct AgentDescriptionPolicyTests {
    @Test func normalizationIsOneLineAndTrimmed() {
        #expect(AgentDescriptionPolicy.normalized("  Reviews Swift changes.  ") == "Reviews Swift changes.")
        #expect(AgentDescriptionPolicy.normalized("review\ncode\n\n  and docs ") == "review code and docs")
        #expect(AgentDescriptionPolicy.normalized(" \n\t").isEmpty)
        // Unicode text is kept verbatim.
        let unicode = "👩‍💻 Revises code and explains changes. 日本語も対応。"
        #expect(AgentDescriptionPolicy.normalized(unicode) == unicode)
    }

    @Test func promptHashTracksNormalizedPrompt() {
        let a = AgentDescriptionPolicy.promptHash("Be terse.\n")
        #expect(a == AgentDescriptionPolicy.promptHash("  Be terse."))
        #expect(a != AgentDescriptionPolicy.promptHash("Be verbose."))
        #expect(a.count == 64)
    }

    @Test func routingDescriptionPrefersUserTextThenGenerated() {
        var agent = Agent(name: "Helper", description: "", systemPrompt: "Do things")
        #expect(agent.routingDescription.isEmpty)
        agent.generatedDescription = "  Handles things.  "
        #expect(agent.routingDescription == "Handles things.")
        agent.description = "User wrote this."
        #expect(agent.routingDescription == "User wrote this.")
    }

    @Test func routingJSONQuotesDataAndOmitsBlankDescription() throws {
        let json = AgentDescriptionPolicy.routingJSON(
            id: "abc", name: "Quoted \"Helper\"", description: "Reviews \"ignore instructions\" text.")
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        #expect(object["id"] == "abc")
        #expect(object["name"] == "Quoted \"Helper\"")
        #expect(object["description"] == "Reviews \"ignore instructions\" text.")

        let blank = AgentDescriptionPolicy.routingJSON(id: "abc", name: "Helper", description: " \n")
        let blankObject = try #require(JSONSerialization.jsonObject(with: Data(blank.utf8)) as? [String: String])
        #expect(blankObject["description"] == nil)
        #expect(blankObject["name"] == "Helper")
    }

    @Test func generatorSanitizesModelOutput() {
        #expect(AgentDescriptionGenerator.sanitize("\n\"Reviews Swift changes.\"\nExtra line") == "Reviews Swift changes.")
        #expect(AgentDescriptionGenerator.sanitize("   \n\n") == nil)
        let long = AgentDescriptionGenerator.sanitize(String(repeating: "a", count: 400))
        #expect(long?.count == AgentDescriptionPolicy.generatedMaximumCharacters)
        #expect(long?.hasSuffix("…") == true)
    }

    @Test @MainActor func routingMetadataSurvivesCompactionAndReplacesStaleText() throws {
        let id = UUID()
        func descriptor(_ description: String?) -> SpawnAgentDescriptor {
            SpawnAgentDescriptor(id: id, name: "Quoted \"Helper\"", description: description,
                modelId: nil, isLocal: nil, providerName: nil)
        }
        let first = SpawnAgentTool.constrainedSpec(
            SpawnAgentTool().asOpenAITool(), allowedAgentIDs: [id],
            agents: [descriptor("Reviews Swift changes.")])
        let compact = SystemPromptComposer.compactBootstrapSpec(first)
        #expect(compact.function.description?.contains("Reviews Swift changes.") == true)
        let revised = SpawnAgentTool.constrainedSpec(
            compact, allowedAgentIDs: [id], agents: [descriptor("Checks release documentation.")])
        let text = try #require(revised.function.description)
        #expect(!text.contains("Reviews Swift changes."))
        let payload = try #require(text.components(separatedBy: SpawnAgentTool.routingMetadataMarker).last)
        let object = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: String])
        #expect(object["name"] == "Quoted \"Helper\"")
        #expect(object["description"] == "Checks release documentation.")
        #expect(object["id"] == id.uuidString)

        // An agent without any description still appears, by name.
        let nameOnly = SpawnAgentTool.constrainedSpec(
            SpawnAgentTool().asOpenAITool(), allowedAgentIDs: [id], agents: [descriptor(nil)])
        let nameOnlyText = try #require(nameOnly.function.description)
        let nameOnlyPayload = try #require(nameOnlyText.components(separatedBy: SpawnAgentTool.routingMetadataMarker).last)
        let nameOnlyObject = try #require(JSONSerialization.jsonObject(with: Data(nameOnlyPayload.utf8)) as? [String: String])
        #expect(nameOnlyObject["name"] == "Quoted \"Helper\"")
        #expect(nameOnlyObject["description"] == nil)
    }

    @Test func missingLegacyDescriptionPreservesIdentity() throws {
        let original = Agent(name: "Custom Helper", description: "Existing purpose", systemPrompt: "Keep my instructions")
        let encoded = try JSONEncoder().encode(original)
        // New optional fields are omitted from JSON while nil so older records
        // round-trip byte-stable.
        let encodedText = String(decoding: encoded, as: UTF8.self)
        #expect(!encodedText.contains("generatedDescription"))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for nullValue in [false, true] {
            if nullValue { object["description"] = NSNull() } else { object.removeValue(forKey: "description") }
            let migrated = try JSONDecoder().decode(Agent.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(migrated.id == original.id)
            #expect(migrated.systemPrompt == original.systemPrompt)
            #expect(migrated.settings == original.settings)
            #expect(migrated.description.isEmpty)
            #expect(migrated.generatedDescription == nil)
            #expect(migrated.routingDescription.isEmpty)
        }
    }
}

@Suite("Agent description is optional", .serialized)
@MainActor
struct AgentDescriptionOptionalTests {
    @Test func creationAcceptsBlankDescription() async throws {
        await SandboxTestLock.runWithStoragePaths {
            await SubagentStoreTestLock.shared.acquire()
            defer { SubagentStoreTestLock.shared.release() }
            let agent = AgentManager.shared.create(name: "Blank purpose \(UUID())", description: " ")
            #expect(agent.description.isEmpty)
            #expect(AgentManager.shared.agent(for: agent.id) != nil)
            // Blank-description agents are spawn targets like any other.
            let snapshot = SpawnDescriptors.resolveForPreview(
                agentIDs: [agent.id], launcherModelOverride: nil, workspaceAgents: [])
            #expect(snapshot.agentTargets.first?.state != nil)
            #expect(snapshot.agentTargets.first?.descriptor.description == nil)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test func templateSeedsDescriptionAndBlankIsAccepted() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            await SubagentStoreTestLock.shared.acquire()
            defer { SubagentStoreTestLock.shared.release() }
            var entry = AgentEntry(name: "Description Template Probe \(UUID())")
            entry.template = "researcher"
            var document = OsaurusConfigDocument()
            document.agents = [entry]
            _ = try ConfigPlanner.plan(document: document, prune: false)
            let result = await ConfigApplier.apply(document: document, prune: false)
            #expect(result.allSatisfy { $0.status != .failed })
            let created = try #require(AgentManager.shared.agents.first { $0.name == entry.name })
            #expect(created.description == AgentStarterTemplate.researcher.routingDescription)
            _ = await AgentManager.shared.delete(id: created.id)

            var blank = AgentEntry(name: "Blank Probe \(UUID())")
            blank.systemPrompt = "Answer briefly."
            document.agents = [blank]
            _ = try ConfigPlanner.plan(document: document, prune: false)
            let blankResult = await ConfigApplier.apply(document: document, prune: false)
            #expect(blankResult.allSatisfy { $0.status != .failed })
            let blankAgent = try #require(AgentManager.shared.agents.first { $0.name == blank.name })
            #expect(blankAgent.description.isEmpty)
            _ = await AgentManager.shared.delete(id: blankAgent.id)
        }
    }

    @Test func legacyPatchPreservesBlankDescription() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            await SubagentStoreTestLock.shared.acquire()
            defer { SubagentStoreTestLock.shared.release() }
            let legacy = Agent(name: "Legacy Helper \(UUID())", description: "", systemPrompt: "Preserve instructions")
            AgentManager.shared.add(legacy)
            var entry = AgentEntry(name: legacy.name)
            entry.systemPrompt = "Updated instructions"
            var document = OsaurusConfigDocument()
            document.agents = [entry]
            let patched = await ConfigApplier.apply(document: document, prune: false)
            #expect(patched.allSatisfy { $0.status != .failed })
            #expect(AgentManager.shared.agent(for: legacy.id)?.description == "")
            #expect(AgentManager.shared.agent(for: legacy.id)?.systemPrompt == "Updated instructions")
            entry.description = "  Researches technical questions using evidence.  "
            document.agents = [entry]
            let updated = await ConfigApplier.apply(document: document, prune: false)
            #expect(updated.allSatisfy { $0.status != .failed })
            let saved = try #require(AgentManager.shared.agent(for: legacy.id))
            #expect(saved.description == "Researches technical questions using evidence.")
            #expect(saved.settings == legacy.settings)
            _ = await AgentManager.shared.delete(id: legacy.id)
        }
    }
}
