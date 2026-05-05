//
//  FolderContextToolModeTests.swift
//
//
//  Mirrors the gating pattern already used by `capabilityDiscoveryNudge`
//  in SystemPromptComposer.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("folderContext gates folder-tool guidance on toolMode")
struct FolderContextToolModeTests {

    private static let folderToolNames: [String] = [
        "file_tree",
        "file_search",
        "file_read",
        "file_edit",
        "file_write",
        "shell_run",
    ]

    private func sampleFolder() -> FolderContext {
        FolderContext(
            rootPath: URL(fileURLWithPath: "/tmp/demo-project"),
            projectType: .swift,
            tree: "demo-project/\n  README.md\n  Sources/\n",
            manifest: nil,
            gitStatus: nil,
            isGitRepo: false,
            contextFiles: nil
        )
    }

    @Test("manual mode names concrete folder tools")
    func manualModeIncludesGuidance() {
        let out = SystemPromptTemplates.folderContext(
            from: sampleFolder(),
            toolMode: .manual
        )
        for name in Self.folderToolNames {
            #expect(
                out.contains(name),
                "manual-mode folderContext is missing `\(name)` — the tool guidance should be present when all folder tools are pre-loaded"
            )
        }
    }

    @Test("auto mode hides concrete folder-tool names")
    func autoModeHidesGuidance() {
        let out = SystemPromptTemplates.folderContext(
            from: sampleFolder(),
            toolMode: .auto
        )
        for name in Self.folderToolNames {
            #expect(
                !out.contains(name),
                "auto-mode folderContext leaked `\(name)` — these tools aren't in the schema until `capabilities_load` runs, so naming them makes the model call tools it doesn't have"
            )
        }
    }

    @Test("auto mode points at the capability discovery flow")
    func autoModeMentionsCapabilities() {
        let out = SystemPromptTemplates.folderContext(
            from: sampleFolder(),
            toolMode: .auto
        )
        #expect(out.contains("capabilities_search"))
        #expect(out.contains("capabilities_load"))
    }

    @Test("nil folder returns empty regardless of tool mode")
    func nilFolderReturnsEmpty() {
        #expect(SystemPromptTemplates.folderContext(from: nil, toolMode: .auto).isEmpty)
        #expect(SystemPromptTemplates.folderContext(from: nil, toolMode: .manual).isEmpty)
    }
}
