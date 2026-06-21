//
//  RemoteAgentHostWorkspaceTests.swift
//  osaurusTests
//
//  Pins the per-agent host-workspace feature that lets an AUTHENTICATED remote
//  agent run (Mode 2) create/edit files inside a folder its owner chose on the
//  agent's machine:
//    • The host-workspace bookmark + display path persist on the `Agent` and
//      decode back-compat for agents saved before the feature existed.
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

@Suite("Remote agent host workspace")
struct RemoteAgentHostWorkspaceTests {

    // MARK: - Agent persistence (bookmark + display path round-trip)

    @Test func agent_encodesAndDecodesHostWorkspaceFields() throws {
        let bookmark = Data([0x01, 0x02, 0x03, 0x04])
        let path = "/Users/tester/Desktop"
        let agent = Agent(
            name: "Filer",
            hostWorkspaceBookmark: bookmark,
            hostWorkspacePath: path
        )
        let data = try JSONEncoder().encode(agent)
        let decoded = try JSONDecoder().decode(Agent.self, from: data)
        #expect(decoded.hostWorkspaceBookmark == bookmark)
        #expect(decoded.hostWorkspacePath == path)
    }

    @Test func agent_nilHostWorkspaceFields_roundTripStaysNil() throws {
        let agent = Agent(name: "NoFolder")
        let data = try JSONEncoder().encode(agent)
        let decoded = try JSONDecoder().decode(Agent.self, from: data)
        #expect(decoded.hostWorkspaceBookmark == nil)
        #expect(decoded.hostWorkspacePath == nil)
    }

    @Test func agent_decodesLegacyJSONWithoutHostWorkspaceKeys() throws {
        // Encode a normal agent, strip the new keys from the JSON object, and
        // confirm decode still succeeds with nil host-workspace fields —
        // `decodeIfPresent` back-compat for agents persisted before the feature.
        let agent = Agent(
            name: "Legacy",
            hostWorkspaceBookmark: Data([9, 9, 9]),
            hostWorkspacePath: "/tmp/here"
        )
        let data = try JSONEncoder().encode(agent)
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "hostWorkspaceBookmark")
        obj.removeValue(forKey: "hostWorkspacePath")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(Agent.self, from: stripped)
        #expect(decoded.hostWorkspaceBookmark == nil)
        #expect(decoded.hostWorkspacePath == nil)
        #expect(decoded.name == "Legacy")
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
