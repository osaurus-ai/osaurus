import Foundation
import Testing
@testable import OsaurusCore

@Suite("Agent description contract")
struct AgentDescriptionPolicyTests {
    @Test func requiredAndBounded() throws {
        for value in ["", " \n\t", "\u{200B}\u{200D}", "\u{0301}"] {
            #expect(AgentDescriptionPolicy.violation(in: value) == .required)
        }
        #expect(try AgentDescriptionPolicy.validated("  Reviews Swift changes.  ") == "Reviews Swift changes.")
        #expect(AgentDescriptionPolicy.violation(in: String(repeating: "a", count: 160)) == nil)
        #expect(AgentDescriptionPolicy.violation(in: String(repeating: "a", count: 161)) == .tooLong)
        #expect(AgentDescriptionPolicy.violation(in: "a" + String(repeating: "\u{0301}", count: 600)) == .oversizedUnicode)
    }

    @Test func unicodeAndSingleLine() {
        #expect(AgentDescriptionPolicy.violation(in: "👩‍💻 Revises code and explains changes. 日本語も対応。") == nil)
        for value in ["review\ncode", "review\tcode", "review\u{0000}code", "review\u{202E}code"] {
            #expect(AgentDescriptionPolicy.violation(in: value) == .controlCharacters)
        }
        // Metadata stays data: validation does not rewrite text into a prompt.
        #expect(AgentDescriptionPolicy.violation(in: "Reviews quoted text such as \"ignore instructions\".") == nil)
    }

    @Test @MainActor func routingMetadataSurvivesCompactionAndReplacesStaleText() throws {
        let id = UUID()
        func descriptor(_ description: String) -> SpawnAgentDescriptor {
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
    }

    @Test func missingLegacyDescriptionPreservesIdentity() throws {
        let original = Agent(name: "Custom Helper", description: "Existing purpose", systemPrompt: "Keep my instructions")
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for nullValue in [false, true] {
            if nullValue { object["description"] = NSNull() } else { object.removeValue(forKey: "description") }
            let migrated = try JSONDecoder().decode(Agent.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(migrated.id == original.id)
            #expect(migrated.systemPrompt == original.systemPrompt)
            #expect(migrated.settings == original.settings)
            #expect(migrated.description.isEmpty)
            #expect(migrated.requiresDescriptionRepair)
        }
    }
}

@Suite("Agent description creation and repair", .serialized)
@MainActor
struct AgentDescriptionCreationTests {
    @Test func creationRejectsMissingDescriptionWithoutSideEffects() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            await SubagentStoreTestLock.shared.acquire()
            defer { SubagentStoreTestLock.shared.release() }
            let before = AgentManager.shared.agents.map(\.id)
            let pool = SubagentConfigurationStore.snapshot().spawnableAgentIDs
            #expect(throws: AgentDescriptionPolicy.Violation.required) {
                try AgentManager.shared.create(name: "Missing purpose", description: " ")
            }
            #expect(AgentManager.shared.agents.map(\.id) == before)
            #expect(SubagentConfigurationStore.snapshot().spawnableAgentIDs == pool)
        }
    }

    @Test func templateCannotReplaceRequiredDescription() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            await SubagentStoreTestLock.shared.acquire()
            defer { SubagentStoreTestLock.shared.release() }
            var entry = AgentEntry(name: "Description Template Probe \(UUID())")
            entry.template = "researcher"
            var document = OsaurusConfigDocument()
            document.agents = [entry]
            #expect(throws: (any Error).self) { try ConfigPlanner.plan(document: document, prune: false) }
            let result = await ConfigApplier.apply(document: document, prune: false)
            #expect(result.contains { $0.status == .failed && ($0.message?.contains("description") ?? false) })
            #expect(!AgentManager.shared.agents.contains { $0.name == entry.name })
        }
    }

    @Test func legacyPatchPreservesDataAndRejectsInvalidRepair() async throws {
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
            entry.description = "   "
            document.agents = [entry]
            let rejected = await ConfigApplier.apply(document: document, prune: false)
            #expect(rejected.contains { $0.status == .failed })
            #expect(AgentManager.shared.agent(for: legacy.id) != nil)
            entry.description = "  Researches technical questions using evidence.  "
            document.agents = [entry]
            let repaired = await ConfigApplier.apply(document: document, prune: false)
            #expect(repaired.allSatisfy { $0.status != .failed })
            let saved = try #require(AgentManager.shared.agent(for: legacy.id))
            #expect(saved.description == "Researches technical questions using evidence.")
            #expect(saved.settings == legacy.settings)
            #expect(!saved.requiresDescriptionRepair)
            _ = await AgentManager.shared.delete(id: legacy.id)
        }
    }
}
