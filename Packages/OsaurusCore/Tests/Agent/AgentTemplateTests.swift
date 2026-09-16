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
              "format": "osaurus.agent-template",
              "version": 1,
              "name": "Cloud Agent",
              "summary": "General cloud worker",
              "available_to_orchestrator": true,
              "created_at": "2026-09-16T10:00:00Z",
              "agent": {
                "name": "Cloud Agent",
                "model": "sonnet-5",
                "tools": { "mode": "manual", "enabled": ["fetch", "time"] },
                "sandbox": { "enabled": true },
                "subagents": { "enabled": true }
              },
              "requires": [
                { "kind": "model", "value": "sonnet-5", "policy": "always" },
                { "kind": "working_folder", "value": "~/Downloads/Medical Stuff", "label": "Case files" }
              ]
            }
            """
        let template = try AgentTemplate.parse(json)
        #expect(template.name == "Cloud Agent")
        #expect(template.id == "cloud-agent")
        #expect(template.availableToOrchestrator)
        #expect(template.agent.model == .value("sonnet-5"))
        #expect(template.agent.tools?.enabled == ["fetch", "time"])
        #expect(template.requires.count == 2)
        #expect(template.modelPolicy == .always)
        #expect(template.requirements(of: .workingFolder).first?.label == "Case files")
    }

    @Test
    func envelopeYAML_parses() throws {
        let yaml = """
            format: osaurus.agent-template
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
            {"format": "osaurus.agent-template", "name": "X",
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
                #"{"format": "osaurus.agent-template", "version": 7, "name": "K", "agent": {"name": "K"}}"#)
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
            requires: [TemplateRequirement(kind: .model, value: "qwen3-coder-30b", policy: .always)])
        let json = try template.jsonString()
        let decoded = try AgentTemplate.parse(json)
        #expect(decoded == template)
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
struct AgentTemplateStoreTests {

    private func withTemporaryRoot<T>(_ body: () throws -> T) throws -> T {
        let previous = OsaurusPaths.overrideRoot
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-template-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        OsaurusPaths.overrideRoot = root
        defer {
            OsaurusPaths.overrideRoot = previous
            try? FileManager.default.removeItem(at: root)
        }
        return try body()
    }

    @Test
    func saveLoadListDelete_roundTrip() throws {
        try withTemporaryRoot {
            let template = AgentTemplate(name: "Cloud Agent", agent: AgentEntry(name: "Cloud Agent"))
            let store = AgentTemplateStore.shared
            let url = try store.save(template)
            #expect(url.lastPathComponent == "cloud-agent.json")
            #expect(AgentTemplateStore.loadAll().map(\.id) == ["cloud-agent"])
            #expect(try AgentTemplateStore.load(slug: "cloud-agent").name == "Cloud Agent")
            #expect(store.template(named: "cloud agent")?.id == "cloud-agent")
            #expect(store.template(named: "CLOUD-AGENT")?.id == "cloud-agent")

            try store.setAvailableToOrchestrator(false, slug: "cloud-agent")
            // The library copy shadows the bundled Cloud Agent, so hiding it
            // removes the name from the orchestrator's list entirely.
            #expect(!store.orchestratorVisible.contains { $0.id == "cloud-agent" })

            try store.rename(slug: "cloud-agent", to: "Sky Agent")
            #expect(AgentTemplateStore.loadAll().map(\.id) == ["sky-agent"])

            try store.delete(slug: "sky-agent")
            #expect(AgentTemplateStore.loadAll().isEmpty)
        }
    }

    @Test
    func nonTemplateFilesInDirectory_areIgnored() throws {
        try withTemporaryRoot {
            let dir = AgentTemplateStore.directory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("version: 1\nagents: []\n".utf8).write(to: dir.appendingPathComponent("full.yaml"))
            try Data(#"{"hello": "world"}"#.utf8).write(to: dir.appendingPathComponent("junk.json"))
            #expect(AgentTemplateStore.loadAll().isEmpty)
        }
    }

    @Test
    func badSlugs_areRefused() throws {
        try withTemporaryRoot {
            #expect(throws: AgentTemplateStore.StoreError.badSlug) {
                _ = try AgentTemplateStore.load(slug: "../secrets")
            }
            #expect(throws: AgentTemplateStore.StoreError.badSlug) {
                _ = try AgentTemplateStore.load(slug: "Cloud Agent")
            }
        }
    }

    @Test
    func symlinkOutsideDirectory_isSkipped() throws {
        try withTemporaryRoot {
            let dir = AgentTemplateStore.directory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let outside = FileManager.default.temporaryDirectory
                .appendingPathComponent("outside-\(UUID().uuidString).json")
            let template = AgentTemplate(name: "Evil", agent: AgentEntry(name: "Evil"))
            try Data(try template.jsonString().utf8).write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.createSymbolicLink(
                at: dir.appendingPathComponent("evil.json"), withDestinationURL: outside)
            #expect(AgentTemplateStore.loadAll().isEmpty)
            #expect(throws: AgentTemplateStore.StoreError.badSlug) {
                _ = try AgentTemplateStore.load(slug: "evil")
            }
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
            requires: [
                TemplateRequirement(kind: .model, value: "sonnet-5", policy: .preferred),
                TemplateRequirement(kind: .mcpServer, value: "Linear"),
                TemplateRequirement(kind: .workingFolder, value: "~/Invoices"),
                TemplateRequirement(kind: .knowledgeCollection, value: "Guides"),
            ])

        let shared = template.excluding([.systemPrompt, .tools, .workingFolder])
        #expect(shared.agent.systemPrompt == nil)
        #expect(shared.agent.description == "Files invoices")
        #expect(shared.agent.tools == nil)
        #expect(shared.agent.mcpServers == nil)
        #expect(shared.agent.workingFolder == .absent)
        #expect(shared.agent.model == .value("sonnet-5"))
        #expect(shared.requires.map(\.kind) == [.model, .knowledgeCollection])

        #expect(template.excluding([]) == template)
        let noKnowledge = template.excluding([.knowledge])
        #expect(noKnowledge.agent.capabilities?.knowledgeEnabled == nil)
        #expect(!noKnowledge.requires.contains { $0.kind == .knowledgeCollection })
    }
}
