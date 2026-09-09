//
//  RemoteAgentWorkingFolderTests.swift
//  osaurusTests
//
//  Pins the per-agent working folder as seen by an AUTHENTICATED remote agent
//  run (Mode 2), which may create/edit files inside the folder the agent's
//  owner chose on the agent's machine:
//    • The working-folder bookmark + display path persist on the `Agent`,
//      decode back-compat for agents saved before the feature existed, and
//      decode the pre-rename `hostWorkspace*` JSON keys (re-encoding emits
//      only the new keys).
//    • `resolveSecurityScopedURL` fails closed on unusable bookmark data.
//    • `resolveExecutionMode` yields `.hostFolder` when a folder is configured.
//    • The external-surface deny list is relaxed for `file_write`/`file_edit`
//      ONLY when the authenticated host-folder root is bound — `shell_run`,
//      `git_commit`, and `file_undo` stay denied, and nothing is relaxed for
//      in-app / loopback / unauthenticated surfaces (no task-local set).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Remote agent working folder")
struct RemoteAgentWorkingFolderTests {

    // MARK: - Agent persistence (bookmark + display path round-trip)

    @Test func agent_encodesAndDecodesWorkingFolderFields() throws {
        let bookmark = Data([0x01, 0x02, 0x03, 0x04])
        let path = "/Users/tester/Desktop"
        let agent = Agent(
            name: "Filer",
            autonomousExec: AutonomousExecConfig(enabled: false),
            workingFolderBookmark: bookmark,
            workingFolderPath: path
        )
        let data = try JSONEncoder().encode(agent)
        let decoded = try JSONDecoder().decode(Agent.self, from: data)
        #expect(decoded.workingFolderBookmark == bookmark)
        #expect(decoded.workingFolderPath == path)
    }

    @Test func agent_nilWorkingFolderFields_roundTripStaysNil() throws {
        let agent = Agent(name: "NoFolder", autonomousExec: AutonomousExecConfig(enabled: false))
        let data = try JSONEncoder().encode(agent)
        let decoded = try JSONDecoder().decode(Agent.self, from: data)
        #expect(decoded.workingFolderBookmark == nil)
        #expect(decoded.workingFolderPath == nil)
    }

    @Test func agent_decodesLegacyJSONWithoutWorkingFolderKeys() throws {
        // Encode a normal agent, strip the folder keys from the JSON object,
        // and confirm decode still succeeds with nil working-folder fields —
        // `decodeIfPresent` back-compat for agents persisted before the feature.
        let agent = Agent(
            name: "Legacy",
            autonomousExec: AutonomousExecConfig(enabled: false),
            workingFolderBookmark: Data([9, 9, 9]),
            workingFolderPath: "/tmp/here"
        )
        let data = try JSONEncoder().encode(agent)
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "workingFolderBookmark")
        obj.removeValue(forKey: "workingFolderPath")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(Agent.self, from: stripped)
        #expect(decoded.workingFolderBookmark == nil)
        #expect(decoded.workingFolderPath == nil)
        #expect(decoded.name == "Legacy")
    }

    @Test func agent_decodesPreRenameHostWorkspaceKeys_andReencodesOnlyNewKeys() throws {
        // An agent JSON written before the rename carries only the legacy
        // `hostWorkspaceBookmark` / `hostWorkspacePath` keys. The grant must
        // survive the rename, and the next save must emit only the new keys.
        let legacyBookmark = Data([0xAA, 0xBB, 0xCC])
        let legacyPath = "/Users/tester/Projects/legacy"
        let agent = Agent(name: "PreRename", autonomousExec: AutonomousExecConfig(enabled: false))
        let data = try JSONEncoder().encode(agent)
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "workingFolderBookmark")
        obj.removeValue(forKey: "workingFolderPath")
        obj["hostWorkspaceBookmark"] = legacyBookmark.base64EncodedString()
        obj["hostWorkspacePath"] = legacyPath
        let legacyJSON = try JSONSerialization.data(withJSONObject: obj)

        let decoded = try JSONDecoder().decode(Agent.self, from: legacyJSON)
        #expect(decoded.workingFolderBookmark == legacyBookmark)
        #expect(decoded.workingFolderPath == legacyPath)

        let reencoded = try JSONEncoder().encode(decoded)
        let reobj = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        #expect(reobj["hostWorkspaceBookmark"] == nil)
        #expect(reobj["hostWorkspacePath"] == nil)
        #expect(reobj["workingFolderBookmark"] as? String == legacyBookmark.base64EncodedString())
        #expect(reobj["workingFolderPath"] as? String == legacyPath)
    }

    @Test func agent_newKeysWinOverLegacyKeysWhenBothPresent() throws {
        let agent = Agent(
            name: "Both",
            autonomousExec: AutonomousExecConfig(enabled: false),
            workingFolderBookmark: Data([1]),
            workingFolderPath: "/new"
        )
        let data = try JSONEncoder().encode(agent)
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["hostWorkspaceBookmark"] = Data([2]).base64EncodedString()
        obj["hostWorkspacePath"] = "/old"
        let both = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(Agent.self, from: both)
        #expect(decoded.workingFolderBookmark == Data([1]))
        #expect(decoded.workingFolderPath == "/new")
    }

    // MARK: - Security-scoped bookmark resolution (fail-closed)

    @Test func resolveSecurityScopedURL_returnsNilForGarbageData() {
        let garbage = Data("not a real bookmark".utf8)
        #expect(FolderContextService.resolveSecurityScopedURL(from: garbage) == nil)
    }

    @Test func resolveSecurityScopedURL_returnsNilForEmptyData() {
        #expect(FolderContextService.resolveSecurityScopedURL(from: Data()) == nil)
    }

    // MARK: - Execution-mode resolution

    @MainActor
    @Test func resolveExecutionMode_noFolder_isNone() {
        let mode = ToolRegistry.shared.resolveExecutionMode(
            folderContext: nil,
            autonomousEnabled: false
        )
        #expect(!mode.usesHostFolderTools)
        #expect(mode.folderContext == nil)
        if case .none = mode {
            // expected
        } else {
            Issue.record("expected .none, got \(mode)")
        }
    }

    @MainActor
    @Test func resolveExecutionMode_withFolder_isHostFolder() {
        let ctx = Self.makeFolderContext(path: "/tmp/agent-desktop")
        let mode = ToolRegistry.shared.resolveExecutionMode(
            folderContext: ctx,
            autonomousEnabled: false
        )
        #expect(mode.usesHostFolderTools)
        #expect(mode.folderContext?.rootPath.path == "/tmp/agent-desktop")
    }

    // MARK: - Bounded external-surface deny matrix

    @Test func deny_inAppSurface_allowsEverything() {
        // In-app surfaces (chat/plugin) never set `isExternalSurface`, so this
        // policy is inert there — even mutating/exec tools pass this gate.
        for tool in [
            "file_write", "file_edit", "file_read", "shell_run", "git_commit", "file_undo",
        ] {
            #expect(ToolRegistry.isDeniedForCurrentSurface(tool) == false)
        }
    }

    @Test func deny_externalSurface_noHostFolder_deniesMutatingAndExecTools() {
        // External surface with NO authenticated host-folder root (loopback,
        // unauthenticated, `/mcp/call`, cross-agent): the full deny list bites.
        ChatExecutionContext.$isExternalSurface.withValue(true) {
            #expect(ToolRegistry.isDeniedForCurrentSurface("file_write"))
            #expect(ToolRegistry.isDeniedForCurrentSurface("file_edit"))
            #expect(ToolRegistry.isDeniedForCurrentSurface("shell_run"))
            #expect(ToolRegistry.isDeniedForCurrentSurface("git_commit"))
            #expect(ToolRegistry.isDeniedForCurrentSurface("file_undo"))
            // file_read is never on the deny list — reads are always permitted.
            #expect(ToolRegistry.isDeniedForCurrentSurface("file_read") == false)
        }
    }

    @Test func deny_externalSurface_withHostFolder_allowsFileWriteEditOnly() {
        let root = URL(fileURLWithPath: "/tmp/agent-desktop")
        ChatExecutionContext.$isExternalSurface.withValue(true) {
            ChatExecutionContext.$authenticatedHostFolderRoot.withValue(root) {
                // File create/edit allowed — confined to the granted folder by
                // the folder tools' own captured root.
                #expect(ToolRegistry.isDeniedForCurrentSurface("file_write") == false)
                #expect(ToolRegistry.isDeniedForCurrentSurface("file_edit") == false)
                #expect(ToolRegistry.isDeniedForCurrentSurface("file_read") == false)
                // Shell / git / undo stay denied even for an authenticated run.
                #expect(ToolRegistry.isDeniedForCurrentSurface("shell_run"))
                #expect(ToolRegistry.isDeniedForCurrentSurface("git_commit"))
                #expect(ToolRegistry.isDeniedForCurrentSurface("file_undo"))
            }
        }
    }

    @Test func deny_hostFolderRootWithoutExternalSurface_isInert() {
        // The relaxation hinges on `isExternalSurface`; binding only the host
        // root (without the external flag) must not change the in-app verdict.
        let root = URL(fileURLWithPath: "/tmp/agent-desktop")
        ChatExecutionContext.$authenticatedHostFolderRoot.withValue(root) {
            #expect(ToolRegistry.isDeniedForCurrentSurface("file_write") == false)
            #expect(ToolRegistry.isDeniedForCurrentSurface("shell_run") == false)
        }
    }

    // MARK: - Fixtures

    private static func makeFolderContext(path: String) -> FolderContext {
        FolderContext(
            rootPath: URL(fileURLWithPath: path),
            projectType: .unknown,
            tree: "",
            manifest: nil,
            gitStatus: nil,
            isGitRepo: false
        )
    }
}
