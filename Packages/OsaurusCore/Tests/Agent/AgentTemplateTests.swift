//
//  AgentTemplateTests.swift
//  OsaurusCoreTests
//
//  Pins the agent template envelope: accepted input shapes (envelope,
//  one-agent document, bare agent), strict validation of the agent
//  payload, slug derivation, JSON round trip, and the on-disk library.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentTemplateParseTests {

    @Test
    func envelopeJSON_parses() throws {
        let json = """
            {
              "format": "osaurus.template",
              "kind": "agent",
              "id": "8D7A2C51-0B7E-4D52-9E61-2F2E7A4B9C10",
              "version": 3,
              "name": "Cloud Agent",
              "summary": "General cloud worker",
              "available_to_orchestrator": true,
              "created_at": "2026-09-16T10:00:00Z",
              "agent": {
                "name": "Cloud Agent",
                "model": "sonnet-5",
                "tools": { "mode": "manual", "enabled": ["fetch", "time"] },
                "sandbox": { "enabled": true },
                "subagents": { "enabled": true },
                "working_folder": "~/Downloads/Medical Stuff"
              },
              "requirements": {
                "models": [{ "slot": "main", "preferred": "sonnet-5", "strictness": "always" }],
                "working_folder": { "path": "~/Downloads/Medical Stuff", "label": "Case files" }
              }
            }
            """
        let template = try AgentTemplate.parse(json)
        #expect(template.name == "Cloud Agent")
        #expect(template.id == UUID(uuidString: "8D7A2C51-0B7E-4D52-9E61-2F2E7A4B9C10"))
        #expect(template.version == 3)
        #expect(template.slug == "cloud-agent")
        #expect(template.availableToOrchestrator)
        #expect(template.agent.model == .value("sonnet-5"))
        #expect(template.agent.tools?.enabled == ["fetch", "time"])
        #expect(template.requires.count == 2)
        #expect(template.modelPolicy == .always)
        #expect(template.requirements(of: .workingFolder).first?.label == "Case files")
    }

    @Test
    func requirementsFollowThePayload_notTheFile() throws {
        // A hand-edited file that drops the MCP requirement gets it back.
        let json = """
            {"format": "osaurus.template", "name": "Linear Bot",
             "agent": {"name": "Linear Bot", "mcp_servers": {"enabled": ["Linear"]}},
             "requirements": {}}
            """
        let template = try AgentTemplate.parse(json)
        #expect(template.requirements.mcpServers == ["Linear"])
    }

    @Test
    func envelopeYAML_parses() throws {
        let yaml = """
            format: osaurus.template
            name: Local Agent
            agent:
              name: Local Agent
              model: qwen3-coder-next-mlx
              capabilities:
                memory_enabled: true
            """
        let template = try AgentTemplate.parse(yaml)
        #expect(template.agent.capabilities?.memoryEnabled == true)
        #expect(template.availableToOrchestrator)  // default
    }

    @Test
    func oneAgentDocument_wrapsIntoTemplate() throws {
        let yaml = """
            version: 1
            agents:
              - name: Researcher
                description: Digs into topics
            """
        let template = try AgentTemplate.parse(yaml)
        #expect(template.name == "Researcher")
        #expect(template.summary == "Digs into topics")
    }

    @Test
    func bareAgent_wrapsIntoTemplate() throws {
        let template = try AgentTemplate.parse(#"{"name": "Helper", "system_prompt": "Be kind."}"#)
        #expect(template.name == "Helper")
        #expect(template.agent.systemPrompt == "Be kind.")
    }

    @Test
    func twoAgentDocument_isRejected() {
        let yaml = """
            agents:
              - name: A
              - name: B
            """
        #expect(throws: AgentTemplateError.wrongAgentCount(2)) {
            _ = try AgentTemplate.parse(yaml)
        }
    }

    @Test
    func unknownAgentKey_isRejectedWithDidYouMean() {
        let json = """
            {"format": "osaurus.template", "name": "X",
             "agent": {"name": "X", "sytem_prompt": "oops"}}
            """
        do {
            _ = try AgentTemplate.parse(json)
            Issue.record("expected invalidAgent")
        } catch let AgentTemplateError.invalidAgent(issues) {
            #expect(issues.joined().contains("sytem_prompt"))
            #expect(issues.joined().contains("system_prompt"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test
    func wrongFormat_and_newerVersion_areRejected() {
        #expect(throws: AgentTemplateError.self) {
            _ = try AgentTemplate.parse(#"{"format": "osaurus.knowledge-template", "name": "K", "agent": {"name": "K"}}"#)
        }
        #expect(throws: AgentTemplateError.unsupportedVersion(7)) {
            _ = try AgentTemplate.parse(
                #"{"format": "osaurus.template", "format_version": 7, "name": "K", "agent": {"name": "K"}}"#)
        }
    }

    @Test
    func unknownKind_isRejectedWithItsName() {
        #expect(throws: AgentTemplateError.wrongKind(expected: .agent, got: "bundle")) {
            _ = try AgentTemplate.parse(#"{"format": "osaurus.template", "kind": "bundle", "name": "K"}"#)
        }
    }

    @Test
    func emptyAndGarbage_areRejected() {
        #expect(throws: AgentTemplateError.empty) { _ = try AgentTemplate.parse("   \n") }
        #expect(throws: AgentTemplateError.self) { _ = try AgentTemplate.parse("- just\n- a list") }
    }

    @Test
    func slug_isFileSafe() {
        #expect(AgentTemplate.slug(for: "Cloud Agent") == "cloud-agent")
        #expect(AgentTemplate.slug(for: "  ../../etc/passwd ") == "etc-passwd")
        #expect(AgentTemplate.slug(for: "Médical / Stuff!!") == "m-dical-stuff")
        #expect(AgentTemplate.slug(for: "...") == "template")
        #expect(AgentTemplate.slug(for: String(repeating: "a", count: 200)).count == 80)
    }

    @Test
    func jsonRoundTrip_preservesEverything() throws {
        var entry = AgentEntry(name: "Sub Agent")
        entry.model = .value("qwen3-coder-30b")
        var tools = AgentToolsEntry()
        tools.mode = "manual"
        tools.enabled = ["fetch"]
        entry.tools = tools
        var mcp = AgentToolGroupsEntry()
        mcp.enabled = ["mcp-c"]
        mcp.disabled = ["mcp-a", "mcp-b"]
        entry.mcpServers = mcp
        var sandbox = AgentSandboxEntry()
        sandbox.enabled = true
        entry.sandbox = sandbox
        var subagents = AgentSubagentsEntry()
        subagents.enabled = false
        entry.subagents = subagents
        let template = AgentTemplate(
            name: "Sub Agent", agent: entry, summary: "Small worker",
            author: "me", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            availableToOrchestrator: false,
            requirements: TemplateRequirements(
                models: [ModelRequirement(slot: "main", preferred: "qwen3-coder-30b", strictness: .always)]))
        let json = try template.jsonString()
        let decoded = try AgentTemplate.parse(json)
        #expect(decoded == template)
        #expect(decoded.hashIsValid)
        #expect(decoded.modelPolicy == .always)
    }

    @Test
    func document_appliesOverridesOnTop() {
        var entry = AgentEntry(name: "Cloud Agent")
        entry.systemPrompt = "Base prompt"
        entry.model = .value("sonnet-5")
        let template = AgentTemplate(name: "Cloud Agent", agent: entry)
        var overrides = AgentEntry(name: "Invoice Bot")
        overrides.systemPrompt = "Summarise invoices"
        let doc = template.document(overrides: overrides)
        #expect(doc.agents?.count == 1)
        #expect(doc.agents?.first?.name == "Invoice Bot")
        #expect(doc.agents?.first?.systemPrompt == "Summarise invoices")
        #expect(doc.agents?.first?.model == .value("sonnet-5"))
    }
}

@MainActor
@Suite(.serialized)
struct TemplateStoreTests {

    private func withTemporaryRoot(_ body: @MainActor @Sendable (TemplateStore) throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run { @MainActor in
            let previous = OsaurusPaths.overrideRoot
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("template-store-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            let store = TemplateStore.shared
            store.reload()
            defer {
                OsaurusPaths.overrideRoot = previous
                try? FileManager.default.removeItem(at: root)
                store.reload()
            }
            try body(store)
        }
    }

    @Test
    func saveWritesImmutableVersions() async throws {
        try await withTemporaryRoot { store in
            let template = AgentTemplate(name: "Scout", agent: AgentEntry(name: "Scout"))
            let v1 = try store.save(template)
            #expect(v1.version == 1)
            #expect(FileManager.default.fileExists(atPath: TemplateStore.versionURL(template.id, version: 1).path))

            var edited = v1
            edited.summary = "Finds things"
            let v2 = try store.save(edited, changelog: "Added a summary")
            #expect(v2.version == 2)
            #expect(v2.changelog == "Added a summary")
            #expect(store.latest(id: template.id)?.version == 2)
            #expect(store.versions(of: template.id).map(\.version) == [2, 1])
            #expect(store.template(id: template.id, version: 1)?.summary == nil)
            #expect(v1.contentHash != v2.contentHash)
        }
    }

    @Test
    func restoreSavesOldVersionAsNewest() async throws {
        try await withTemporaryRoot { store in
            let v1 = try store.save(AgentTemplate(name: "Scout", agent: AgentEntry(name: "Scout")))
            var edited = v1
            edited.summary = "Changed"
            try store.save(edited)
            let v3 = try store.restore(id: v1.id, version: 1)
            #expect(v3.version == 3)
            #expect(v3.summary == nil)
            #expect(store.versions(of: v1.id).count == 3)
        }
    }

    @Test
    func renameIsANewVersionAndLookupIsByNameOrSlug() async throws {
        try await withTemporaryRoot { store in
            let v1 = try store.save(AgentTemplate(name: "Scout Agent", agent: AgentEntry(name: "Scout Agent")))
            #expect(store.template(named: "scout agent")?.id == v1.id)
            #expect(store.template(named: "SCOUT-AGENT")?.id == v1.id)
            #expect(store.template(named: v1.id.uuidString)?.id == v1.id)
            let renamed = try store.rename(id: v1.id, to: "Sky Agent")
            #expect(renamed.version == 2)
            #expect(renamed.agent.name == "Sky Agent")
            #expect(store.template(named: "sky agent")?.id == v1.id)
        }
    }

    @Test
    func orchestratorVisibilityLivesInTheIndex() async throws {
        try await withTemporaryRoot { store in
            let v1 = try store.save(AgentTemplate(name: "Scout", agent: AgentEntry(name: "Scout")))
            store.setAvailableToOrchestrator(false, id: v1.id)
            #expect(!store.orchestratorVisible.contains { $0.id == v1.id })
            // Toggling never mints a version.
            #expect(store.versions(of: v1.id).count == 1)
            store.setAvailableToOrchestrator(true, id: v1.id)
            #expect(store.orchestratorVisible(kind: .agent).contains { $0.id == v1.id })
        }
    }

    @Test
    func deleteRemovesEveryVersion() async throws {
        try await withTemporaryRoot { store in
            let v1 = try store.save(AgentTemplate(name: "Scout", agent: AgentEntry(name: "Scout")))
            try store.save(v1)
            try store.delete(id: v1.id)
            #expect(store.latest(id: v1.id) == nil)
            #expect(TemplateStore.versionNumbers(v1.id).isEmpty)
        }
    }

    @Test
    func nonTemplateEntriesInDirectory_areIgnored() async throws {
        try await withTemporaryRoot { store in
            let dir = TemplateStore.directory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("version: 1\nagents: []\n".utf8).write(to: dir.appendingPathComponent("full.yaml"))
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("not-a-uuid"), withIntermediateDirectories: true)
            let junkID = UUID()
            try FileManager.default.createDirectory(
                at: TemplateStore.templateDirectory(junkID), withIntermediateDirectories: true)
            try Data(#"{"hello": "world"}"#.utf8).write(to: TemplateStore.versionURL(junkID, version: 1))
            #expect(TemplateStore.loadLatest().isEmpty)
        }
    }

    @Test
    func importIdentity_newUpdateOlderPresentConflict() async throws {
        try await withTemporaryRoot { store in
            let original = AgentTemplate(name: "Scout", agent: AgentEntry(name: "Scout"))
            #expect(store.disposition(for: original) == .new)
            let stored = try store.importTemplate(original)
            #expect(stored.version == 1)
            #expect(store.disposition(for: original) == .alreadyPresent)

            var v2 = original
            v2.version = 2
            v2.summary = "Newer"
            v2 = v2.sealed()
            #expect(store.disposition(for: v2) == .update(fromVersion: 1))
            try store.importTemplate(v2)
            #expect(store.latest(id: original.id)?.version == 2)
            #expect(store.disposition(for: original) == .alreadyPresent)

            var conflicting = original
            conflicting.summary = "Same version, different content"
            conflicting = conflicting.sealed()
            #expect(store.disposition(for: conflicting) == .conflict)

            let copy = try store.importTemplate(conflicting, resolution: .keepBoth(name: "Scout 2"))
            #expect(copy.id != original.id)
            #expect(copy.version == 1)
            #expect(copy.name == "Scout 2")

            let replaced = try store.importTemplate(conflicting, resolution: .replace)
            #expect(replaced.id == original.id)
            #expect(replaced.version == 3)
            #expect(replaced.summary == "Same version, different content")
        }
    }

    @Test
    func olderImportIsKeptForHistoryOnly() async throws {
        try await withTemporaryRoot { store in
            var v3 = AgentTemplate(name: "Scout", agent: AgentEntry(name: "Scout"))
            v3.version = 3
            v3 = v3.sealed()
            try store.importTemplate(v3)
            var v1 = v3
            v1.version = 1
            v1.summary = "Old"
            v1 = v1.sealed()
            #expect(store.disposition(for: v1) == .older(localLatest: 3))
            try store.importTemplate(v1)
            #expect(store.latest(id: v3.id)?.version == 3)
            #expect(store.versions(of: v3.id).map(\.version) == [3, 1])
        }
    }
}

struct AgentTemplateSectionTests {
    @Test
    func excluding_dropsSectionsAndMatchingRequirements() {
        var entry = AgentEntry(name: "Invoice Bot")
        entry.systemPrompt = "Secret sauce"
        entry.description = "Files invoices"
        entry.model = .value("sonnet-5")
        var tools = AgentToolsEntry()
        tools.mode = "manual"
        tools.enabled = ["fetch"]
        entry.tools = tools
        var mcp = AgentToolGroupsEntry()
        mcp.enabled = ["Linear"]
        entry.mcpServers = mcp
        entry.workingFolder = .value("~/Invoices")
        var caps = AgentCapabilitiesEntry()
        caps.knowledgeEnabled = true
        entry.capabilities = caps
        let template = AgentTemplate(
            name: "Invoice Bot", agent: entry,
            requirements: TemplateRequirements(knowledge: ["Guides"]))

        let shared = template.excluding([.systemPrompt, .tools, .workingFolder])
        #expect(shared.agent.systemPrompt == nil)
        #expect(shared.agent.description == "Files invoices")
        #expect(shared.agent.tools == nil)
        #expect(shared.agent.mcpServers == nil)
        #expect(shared.agent.workingFolder == .absent)
        #expect(shared.agent.model == .value("sonnet-5"))
        #expect(shared.requires.map(\.kind) == [.model, .knowledgeCollection])
        #expect(template.requires.map(\.kind) == [.model, .mcpServer, .knowledgeCollection, .workingFolder])

        #expect(template.excluding([]) == template)
        let noKnowledge = template.excluding([.knowledge])
        #expect(noKnowledge.agent.capabilities?.knowledgeEnabled == nil)
        #expect(!noKnowledge.requires.contains { $0.kind == .knowledgeCollection })
    }
}

struct AgentTemplateSmartQuoteTests {

    /// A name hand-edited in a text view that swaps `"` for `”`.
    @Test
    func smartQuoteDelimiter_parsesAfterStraightening() throws {
        let json = """
            {
              "format": "osaurus.template",
              "name": "Plato Ultra”,
              "agent": { "name": “Plato Ultra" }
            }
            """
        let template = try AgentTemplate.parse(json)
        #expect(template.name == "Plato Ultra")
        #expect(template.agent.name == "Plato Ultra")
    }

    /// Curly quotes inside a prompt are content and must survive as-is.
    @Test
    func curlyQuotesInsideValues_areKept() throws {
        let json = """
            {
              "format": "osaurus.template",
              "name": "Plato",
              "agent": { "name": "Plato", "system_prompt": "Say “hi” first." }
            }
            """
        let template = try AgentTemplate.parse(json)
        #expect(template.agent.systemPrompt == "Say “hi” first.")
    }
}

struct AgentTemplateImportNameTests {

    private func template(name: String, agentName: String) -> AgentTemplate {
        AgentTemplate(name: name, agent: AgentEntry(name: agentName))
    }

    @Test
    func availableName_keepsFreeName() {
        #expect(AgentTemplate.availableName(for: "Plato", takenSlugs: []) == "Plato")
    }

    @Test
    func availableName_suffixesTakenName() {
        #expect(AgentTemplate.availableName(for: "Plato", takenSlugs: ["plato"]) == "Plato 2")
        #expect(AgentTemplate.availableName(for: "Plato", takenSlugs: ["plato", "plato-2"]) == "Plato 3")
    }

    @Test
    func suggestedName_prefersHandEditedAgentName() {
        let edited = template(name: "Plato", agentName: "Plato Ultra")
        #expect(edited.suggestedImportName(takenSlugs: ["plato"]) == "Plato Ultra")
    }

    @Test
    func suggestedName_prefersHandEditedEnvelopeName() {
        let edited = template(name: "Plato Ultra", agentName: "Plato")
        #expect(edited.suggestedImportName(takenSlugs: ["plato"]) == "Plato Ultra")
    }

    @Test
    func suggestedName_collisionOffersCopy() {
        let same = template(name: "Plato", agentName: "Plato")
        #expect(same.suggestedImportName(takenSlugs: ["plato"]) == "Plato 2")
    }

    @Test
    func renamed_updatesTemplateAndAgent() {
        let renamed = template(name: "Plato", agentName: "Plato").renamed(to: " Plato 2 ")
        #expect(renamed.name == "Plato 2")
        #expect(renamed.agent.name == "Plato 2")
        #expect(renamed.slug == "plato-2")
    }
}

struct AgentTemplateStaleToolTests {

    @Test
    func unregisteredToolNames_areDropped() {
        var entry = AgentEntry(name: "Plato")
        var tools = AgentToolsEntry()
        tools.mode = "manual"
        tools.enabled = ["browser_click", "underwriting_217e41d2_case_get", "underwriting_mcp_production_apps_count"]
        entry.tools = tools
        let cleaned = AgentTemplate.droppingUnregisteredTools(entry, registered: ["browser_click"])
        #expect(cleaned.tools?.enabled == ["browser_click"])
        #expect(cleaned.tools?.mode == "manual")
    }

    @Test
    func autoMode_isUntouched() {
        var entry = AgentEntry(name: "Plato")
        var tools = AgentToolsEntry()
        tools.mode = "auto"
        entry.tools = tools
        #expect(AgentTemplate.droppingUnregisteredTools(entry, registered: []) == entry)
    }
}

struct AgentTemplateSlugLengthTests {

    /// 79 letters then a space: the 80-char cut lands on the dash.
    @Test
    func longName_slugIsStable() {
        let name = String(repeating: "a", count: 79) + " tail"
        let slug = AgentTemplate.slug(for: name)
        #expect(!slug.hasSuffix("-"))
        #expect(slug.count <= 80)
        #expect(AgentTemplate.slug(for: slug) == slug)
    }
}
