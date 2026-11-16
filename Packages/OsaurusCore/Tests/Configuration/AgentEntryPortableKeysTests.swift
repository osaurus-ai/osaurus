//
//  AgentEntryPortableKeysTests.swift
//  OsaurusCoreTests
//
//  The `agents[]` entity grew portable keys (tools, mcp_servers, plugins,
//  plugin_instructions, sandbox, subagents, working_folder) so an agent
//  template can travel between machines. These tests pin their strict
//  decoding, null-vs-absent handling, and round trip through YAML.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentEntryPortableKeysTests {

    @Test
    func portableKeys_decodeStrictly() throws {
        let yaml = """
            version: 1
            agents:
              - name: Cloud Agent
                tools:
                  mode: manual
                  enabled: [fetch, time]
                mcp_servers:
                  enabled: [Linear]
                  disabled: [Notion]
                plugins:
                  enabled: [osaurus.notes]
                plugin_instructions:
                  osaurus.notes: "Always file notes under Work."
                sandbox:
                  enabled: true
                  network_enabled: false
                  allowed_domains: ["api.example.com"]
                  max_commands_per_turn: 5
                subagents:
                  enabled: true
                  agents: [Researcher]
                  models: [qwen3-coder-30b]
                working_folder: "~/Documents/Invoices"
            """
        let document = try ConfigYAML.decode(yaml)
        let entry = try #require(document.agents?.first)
        #expect(entry.tools?.mode == "manual")
        #expect(entry.tools?.enabled == ["fetch", "time"])
        #expect(entry.mcpServers?.enabled == ["Linear"])
        #expect(entry.mcpServers?.disabled == ["Notion"])
        #expect(entry.plugins?.enabled == ["osaurus.notes"])
        #expect(entry.pluginInstructions?["osaurus.notes"] == "Always file notes under Work.")
        #expect(entry.sandbox?.enabled == true)
        #expect(entry.sandbox?.networkEnabled == false)
        #expect(entry.sandbox?.allowedDomains == ["api.example.com"])
        #expect(entry.sandbox?.maxCommandsPerTurn == 5)
        #expect(entry.subagents?.enabled == true)
        #expect(entry.subagents?.agents == ["Researcher"])
        #expect(entry.subagents?.models == ["qwen3-coder-30b"])
        #expect(entry.workingFolder == .value("~/Documents/Invoices"))
    }

    @Test
    func workingFolder_nullClearsAbsentLeavesAlone() throws {
        let cleared = try ConfigYAML.decode(
            """
            version: 1
            agents:
              - name: A
                working_folder: null
            """)
        #expect(cleared.agents?.first?.workingFolder == .null)
        let untouched = try ConfigYAML.decode(
            """
            version: 1
            agents:
              - name: A
            """)
        #expect(untouched.agents?.first?.workingFolder == .absent)
        #expect(untouched.agents?.first?.tools == nil)
        #expect(untouched.agents?.first?.sandbox == nil)
    }

    @Test
    func unknownKeyInsidePortableMapping_isRejected() {
        let yaml = """
            version: 1
            agents:
              - name: A
                sandbox:
                  enabled: true
                  netwrk_enabled: false
            """
        do {
            _ = try ConfigYAML.decode(yaml)
            Issue.record("expected rejection of the typo'd sandbox key")
        } catch let error as ConfigYAMLError {
            let joined = error.messages.joined(separator: "\n")
            #expect(joined.contains("netwrk_enabled"))
            #expect(joined.contains("network_enabled"))
            #expect(joined.contains("agents[0].sandbox"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test
    func roundTrip_preservesPortableKeys() throws {
        var document = OsaurusConfigDocument()
        var entry = AgentEntry(name: "Local Agent")
        var tools = AgentToolsEntry()
        tools.mode = "manual"
        tools.enabled = ["fetch"]
        entry.tools = tools
        var mcp = AgentToolGroupsEntry()
        mcp.enabled = ["Linear"]
        entry.mcpServers = mcp
        var sandbox = AgentSandboxEntry()
        sandbox.enabled = true
        entry.sandbox = sandbox
        var subagents = AgentSubagentsEntry()
        subagents.enabled = false
        entry.subagents = subagents
        entry.workingFolder = .value("~/Work")
        document.agents = [entry]

        let yaml = try ConfigYAML.encode(document)
        let decoded = try ConfigYAML.decode(yaml)
        #expect(decoded.agents?.first == entry)
    }
}
