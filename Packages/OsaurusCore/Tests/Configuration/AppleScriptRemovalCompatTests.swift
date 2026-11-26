//
//  AppleScriptRemovalCompatTests.swift
//  osaurusTests
//
//  Data written while the AppleScript subagent shipped keeps loading:
//  agent settings, declarative documents, installed bundles, and saved
//  workflows each degrade to a clear replacement instead of failing.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AppleScriptRemovalCompatTests {

    @Test func legacyAgentSettingsDecodeWithoutTheRemovedFields() throws {
        let json = #"""
            {"computerUseEnabled":true,"appleScriptEnabled":true,
            "appleScriptModelId":"OsaurusAI/Osaurus-AppleScript-4B","appleScriptExecutionMode":"auto_run"}
            """#
        let settings = try JSONDecoder().decode(AgentSettings.self, from: Data(json.utf8))
        #expect(settings.computerUseEnabled)
        let reencoded = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(!reencoded.localizedCaseInsensitiveContains("applescript"))
    }

    @Test func declarativeCapabilityKeyIsIgnoredWithAHint() throws {
        let entry = try JSONDecoder().decode(
            AgentCapabilitiesEntry.self, from: Data(#"{"applescript_enabled":true}"#.utf8))
        #expect(entry.removedKeyHints.count == 1)
        #expect(entry.removedKeyHints.first?.contains("computer_use_enabled") == true)
        #expect(AgentCapabilitiesEntry.removedKeys.contains(.applescriptEnabled))

        let none = try JSONDecoder().decode(AgentCapabilitiesEntry.self, from: Data(#"{}"#.utf8))
        #expect(none.removedKeyHints.isEmpty)
    }

    @Test func declarativeDelegationKeysAreIgnoredWithHints() throws {
        let section = try JSONDecoder().decode(
            DelegationSection.self,
            from: Data(#"{"applescript_enabled":true,"applescript_execution_mode":"confirm_each"}"#.utf8))
        #expect(section.removedKeyHints.contains { $0.hasPrefix("delegation.applescript_enabled was removed") })
        #expect(section.removedKeyHints.contains { $0.hasPrefix("delegation.applescript_execution_mode was removed") })
        let reencoded = String(decoding: try JSONEncoder().encode(section), as: UTF8.self)
        #expect(!reencoded.contains("applescript"))
    }

    @Test func installedAppleScriptBundlesAreRetired() {
        #expect(RetiredModelBundles.isRetired(id: "OsaurusAI/Osaurus-AppleScript-16B-A4B-JANG_4M"))
        #expect(RetiredModelBundles.isRetired(id: "osaurusai/osaurus-applescript-4b"))
        #expect(RetiredModelBundles.isRetired(id: "JANGQ-AI/AppleScript-8B"))
        #expect(!RetiredModelBundles.isRetired(id: "mlx-community/Qwen3-VL-8B-Instruct-4bit"))
        #expect(!RetiredModelBundles.isRetired(id: "someone/not-OsaurusAI/Osaurus-AppleScript-4B"))
    }

    @Test func savedAppleScriptRunLogStillDecodes() throws {
        let saved = SubagentRunLog(
            kindId: "applescript", title: "Create a note", startedAt: Date(timeIntervalSince1970: 0),
            success: true, summary: "Ran 1 script(s) successfully.",
            events: [SubagentActivityEvent(step: 1, kind: .act, title: "Run script", success: true)],
            truncatedEventCount: 0)
        let decoded = try JSONDecoder().decode(SubagentRunLog.self, from: JSONEncoder().encode(saved))
        #expect(decoded == saved)
        #expect(!SubagentRunLog.persistedKindIds.contains("applescript"))
    }

    @Test func savedWorkflowStepsCallingRemovedToolsFailValidation() {
        for tool in ["applescript", "mac_query"] {
            let def = WorkflowDefinition(
                inputSchema: WF.object([:]),
                nodes: [
                    WorkflowNode(
                        id: "drive", name: "drive", kind: .tool(ToolNodeSpec(tool: ToolRef(name: tool))),
                        input: .object(["task": "Open Notes"]))
                ],
                output: .object([:]))
            let issues = WorkflowValidator.validate(def, allowPlaceholders: false)
            #expect(
                issues.contains { $0.nodeID == "drive" && $0.message.contains("replaced by Computer Use") },
                "\(tool): \(issues.map(\.message))")
        }
    }
}
