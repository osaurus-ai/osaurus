//
//  ConfigToolDisplayTests.swift
//  osaurusTests
//
//  Pins the chat-surface presentation of the Osaurus self-configuration
//  tools: action-aware chip labels for `osaurus_config` / `osaurus_inspect`,
//  and the structured markdown rendering of config plan/apply results
//  (including the Settings deep-links on rows the user must finish by hand).
//

import Foundation
import Testing

@testable import OsaurusCore

struct ConfigToolDisplayTests {

    // MARK: - Chip labels

    @Test("osaurus_config chip label follows the action argument")
    func configLabelFollowsAction() {
        #expect(
            ToolDisplayName.friendly(
                for: "osaurus_config", running: true, arguments: #"{"action": "apply"}"#)
                == L("Applying configuration changes"))
        #expect(
            ToolDisplayName.friendly(
                for: "osaurus_config", running: false, arguments: #"{"action": "apply"}"#)
                == L("Applied configuration changes"))
        #expect(
            ToolDisplayName.friendly(
                for: "osaurus_config", running: true, arguments: #"{"action": "plan"}"#)
                == L("Planning configuration changes"))
        #expect(
            ToolDisplayName.friendly(
                for: "osaurus_config", running: false, arguments: #"{"action": "export"}"#)
                == L("Exported Osaurus configuration"))
    }

    @Test("osaurus_config chip label degrades cleanly without arguments")
    func configLabelWithoutAction() {
        #expect(
            ToolDisplayName.friendly(for: "osaurus_config", running: true)
                == L("Configuring Osaurus"))
        #expect(
            ToolDisplayName.friendly(for: "osaurus_config", running: false, arguments: "not json")
                == L("Configured Osaurus"))
    }

    @Test("osaurus_inspect chip label follows the action argument")
    func inspectLabelFollowsAction() {
        #expect(
            ToolDisplayName.friendly(
                for: "osaurus_inspect", running: true, arguments: #"{"action": "status"}"#)
                == L("Checking Osaurus status"))
        #expect(
            ToolDisplayName.friendly(
                for: "osaurus_inspect", running: false, arguments: #"{"action": "list"}"#)
                == L("Listed Osaurus items"))
        #expect(
            ToolDisplayName.friendly(
                for: "osaurus_inspect", running: false, arguments: #"{"action": "describe"}"#)
                == L("Inspected an Osaurus item"))
        #expect(
            ToolDisplayName.friendly(for: "osaurus_inspect", running: true)
                == L("Inspecting Osaurus"))
    }

    @Test("failed completed config call still reads as a failure")
    func failedConfigCall() {
        let title = ToolDisplayName.friendly(
            for: "osaurus_config", running: false,
            arguments: #"{"action": "apply"}"#, failed: true)
        #expect(title == String(format: L("Failed: %@"), "Osaurus config"))
    }

    // MARK: - Structured result rendering

    @MainActor
    @Test("apply payload renders per-target status lines")
    func applyPayloadRenders() {
        let payload: [String: Any] = [
            "status": "partial",
            "results": [
                [
                    "section": "providers", "target": "xai", "status": "done",
                    "message": "Configured",
                ],
                [
                    "section": "providers", "target": "anthropic", "status": "needs_user_action",
                    "message": "Enter the API key",
                ],
            ],
            "notes": ["1 item needs your attention."],
        ]
        let rendered = NativeToolCallRowView.markdownForConfigResult(payload)
        #expect(rendered != nil)
        let text = rendered ?? ""
        #expect(text.contains("**Partially applied**"))
        #expect(text.contains("✓ providers: **xai** — Configured"))
        #expect(text.contains("⚠ providers: **anthropic** — Enter the API key"))
        // The row the user must finish links straight into Settings.
        #expect(text.contains("(osaurus://settings?tab=providers)"))
        #expect(text.contains("_1 item needs your attention._"))
        // The completed row must NOT get a settings link.
        #expect(!text.contains("xai** — Configured [Open"))
    }

    @MainActor
    @Test("mcp rows deep-link to the Tools tab where MCP servers are managed")
    func mcpRowsLinkToToolsTab() {
        let payload: [String: Any] = [
            "status": "partial",
            "results": [
                [
                    "section": "mcp", "target": "linear", "status": "needs_user_action",
                    "message": "Authenticate the server",
                ]
            ],
        ]
        let text = NativeToolCallRowView.markdownForConfigResult(payload) ?? ""
        #expect(text.contains("(osaurus://settings?tab=tools)"))
    }

    @MainActor
    @Test("plan payload renders its summary, not raw JSON")
    func planPayloadRenders() {
        let payload: [String: Any] = [
            "change_count": 2,
            "actions": [["kind": "add", "section": "providers", "target": "xai"]],
            "summary": "+ provider xai\n~ server port 8080",
            "note": "This plan contains high-risk changes — apply will require explicit user approval.",
        ]
        let rendered = NativeToolCallRowView.markdownForConfigResult(payload)
        #expect(rendered != nil)
        let text = rendered ?? ""
        #expect(text.contains("+ provider xai"))
        #expect(text.contains("_This plan contains high-risk changes"))
    }

    @MainActor
    @Test("non-config-shaped payloads fall through to generic rendering")
    func unrelatedPayloadFallsThrough() {
        // Schema / export / templates payloads (and any other tool's payload)
        // must return nil so the generic JSON path renders them.
        #expect(NativeToolCallRowView.markdownForConfigResult(["yaml": "server:\n  port: 1337"]) == nil)
        #expect(NativeToolCallRowView.markdownForConfigResult(["results": []]) == nil)
        #expect(
            NativeToolCallRowView.markdownForConfigResult([
                "results": [["path": "/tmp/x", "type": "file"]]
            ]) == nil)
    }
}
