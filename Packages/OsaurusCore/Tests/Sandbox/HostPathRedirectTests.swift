//
//  HostPathRedirectTests.swift
//
//  Pin `hostPathRedirectHint` — the hint for a Mac path handed to a
//  sandbox-routed path tool. Every workspace tool in sandbox mode runs in
//  the VM, so the hint must not point at another file tool; it names the
//  one real fix (attach the folder). Must NOT misfire on relative paths or
//  legitimate sandbox absolute paths.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct HostPathRedirectTests {

    @Test func macPathSaysNoToolHereCanReachIt() {
        let hint = hostPathRedirectHint(path: "/Users/tpae/Desktop")
        #expect(hint?.contains("path on the user's Mac") == true)
        #expect(hint?.contains("Folder chip") == true)
        #expect(hint?.contains("file_read") == false)
        #expect(hint?.contains("file_search") == false)
    }

    /// osaurus#2439: `shell_run` cloned a repo into `/tmp/psapp/wiki`, then
    /// `file_read` rejected that path as outside the agent home. The bare
    /// rejection reads as "the file tools are broken" — the model abandoned
    /// the read path entirely rather than copying the tree one level over.
    @Test func sandboxPathOutsideAgentHomeSuggestsCopyingItIn() {
        let home = "/workspace/agents/abc"
        let requirement = requirePath("/tmp/psapp/wiki/Home.md", home: home, tool: "file_read")
        guard case .failure(let envelope) = requirement else {
            Issue.record("expected a rejection for a path outside the agent home")
            return
        }
        #expect(envelope.contains("shell_run"))
        #expect(envelope.contains("cp -r /tmp/psapp/wiki/Home.md \(home)/"))
    }

    /// A Mac path gets the Mac-path hint; it must not also pick up the
    /// copy-it-in advice, which does not apply across the sandbox boundary.
    @Test func hostPathKeepsHostHintNotTheCopyHint() {
        let requirement = requirePath(
            "/Users/tpae/Desktop/notes.txt",
            home: "/workspace/agents/abc",
            tool: "file_read"
        )
        guard case .failure(let envelope) = requirement else {
            Issue.record("expected a rejection for a host path")
            return
        }
        #expect(envelope.contains("Folder chip"))
        #expect(!envelope.contains("cp -r"))
    }

    @Test func relativePathDoesNotRedirect() {
        #expect(hostPathRedirectHint(path: "Desktop") == nil)
        #expect(hostPathRedirectHint(path: "src/main.py") == nil)
    }

    @Test func legitSandboxAbsolutePathDoesNotRedirect() {
        // Agent-home / workspace paths are valid sandbox targets — no hint.
        #expect(hostPathRedirectHint(path: "/workspace/agents/abc/file.txt") == nil)
        #expect(hostPathRedirectHint(path: "/workspace/shared/data.json") == nil)
    }

    @Test func genericLinuxRootDoesNotRedirect() {
        // `/etc/os-release` is a legitimate sandbox read; the macOS-only
        // prefix list must not capture generic Linux roots.
        #expect(hostPathRedirectHint(path: "/etc/os-release") == nil)
        #expect(hostPathRedirectHint(path: "/usr/bin/python3") == nil)
        #expect(hostPathRedirectHint(path: "/var/log/app.log") == nil)
    }

    // MARK: - sandboxDirectoryReadHint
    //
    // A file read on a directory means the model wanted to list, not read.
    // Recovery guidance must use the same public workspace vocabulary the
    // request schema exposes rather than private sandbox adapters.

    @Test func directoryReadSuggestsListingInSandbox() {
        let hint = sandboxDirectoryReadHint(stderr: "cat: /workspace/agents/abc/: Is a directory")
        #expect(hint?.contains("is a directory") == true)
        #expect(hint?.contains("file_read") == true)
        #expect(hint?.contains("file_search") == true)
        #expect(hint?.contains("sandbox_search_files") == false)
        #expect(hint?.contains("host workspace") == false)
    }

    @Test func nonDirectoryReadErrorGetsNoDirectoryHint() {
        #expect(sandboxDirectoryReadHint(stderr: "cat: missing.txt: No such file or directory") == nil)
        #expect(sandboxDirectoryReadHint(stderr: "permission denied") == nil)
    }
}
