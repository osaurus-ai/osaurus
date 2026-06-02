//
//  HostPathRedirectTests.swift
//
//  Pin `hostPathRedirectHint` — the self-heal that catches a host
//  filesystem path handed to a `sandbox_*` tool by mistake and redirects
//  the model to the read-only `file_*` host tools. Two signals: the
//  combined-mode host workspace root (`hostReadOnlyScope`) and a broad
//  macOS-distinctive prefix. Must NOT misfire on relative paths or
//  legitimate sandbox absolute paths.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct HostPathRedirectTests {

    @Test func hostWorkspaceRootRedirectsToFileTools() {
        ChatExecutionContext.$hostReadOnlyScope.withValue(URL(fileURLWithPath: "/Users/tpae/Desktop")) {
            let hint = hostPathRedirectHint(path: "/Users/tpae/Desktop")
            #expect(hint?.contains("file_read") == true)
            #expect(hint?.contains("read-only host workspace") == true)
        }
    }

    @Test func fileUnderHostWorkspaceRedirects() {
        ChatExecutionContext.$hostReadOnlyScope.withValue(URL(fileURLWithPath: "/Users/tpae/Desktop")) {
            let hint = hostPathRedirectHint(path: "/Users/tpae/Desktop/notes.txt")
            #expect(hint?.contains("file_read") == true)
        }
    }

    @Test func siblingPathOutsideScopeFallsBackToBroadMacHint() {
        // A macOS path that is NOT under the bound workspace still trips
        // the broad heuristic, but with the generic (non-workspace) wording.
        ChatExecutionContext.$hostReadOnlyScope.withValue(URL(fileURLWithPath: "/Users/tpae/Desktop")) {
            let hint = hostPathRedirectHint(path: "/Users/tpae/Documents/x")
            #expect(hint?.contains("macOS host path") == true)
        }
    }

    @Test func broadMacPathRedirectsWithoutScope() {
        let hint = hostPathRedirectHint(path: "/Users/tpae/Desktop")
        #expect(hint?.contains("macOS host path") == true)
        #expect(hint?.contains("file_read") == true)
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
    // `sandbox_read_file` on a directory: the model wanted to *list*, not
    // read. Catches the "read my Desktop with sandbox_read_file" slip that
    // hostPathRedirectHint misses (the path is a valid sandbox directory).

    @Test func directoryReadSuggestsListingInSandbox() {
        let hint = sandboxDirectoryReadHint(stderr: "cat: /workspace/agents/abc/: Is a directory")
        #expect(hint?.contains("is a directory") == true)
        #expect(hint?.contains("sandbox_search_files") == true)
    }

    @Test func directoryReadInCombinedModeAlsoSuggestsFileRead() {
        ChatExecutionContext.$hostReadOnlyScope.withValue(URL(fileURLWithPath: "/Users/tpae/Desktop")) {
            let hint = sandboxDirectoryReadHint(stderr: "cat: /workspace/agents/abc/: Is a directory")
            #expect(hint?.contains("file_read") == true)
        }
    }

    @Test func directoryReadOutsideCombinedModeDoesNotMentionHost() {
        // No host workspace bound → don't dangle a file_read reference at a
        // pure-sandbox session where the host tools don't exist.
        let hint = sandboxDirectoryReadHint(stderr: "cat: /workspace/agents/abc/: Is a directory")
        #expect(hint?.contains("file_read") == false)
    }

    @Test func nonDirectoryReadErrorGetsNoDirectoryHint() {
        #expect(sandboxDirectoryReadHint(stderr: "cat: missing.txt: No such file or directory") == nil)
        #expect(sandboxDirectoryReadHint(stderr: "permission denied") == nil)
    }

    // MARK: - hostWorkspaceSearchRedirectHint
    //
    // Empty `sandbox_search_files` at the sandbox home, in combined mode,
    // is the "what's in my Desktop?" → sandbox_search_files slip. These
    // searches succeed emptily (no rejection), so this soft nudge is the
    // only signal the model gets.

    @Test func emptyHomeRootSearchInCombinedModeRedirects() {
        ChatExecutionContext.$hostReadOnlyScope.withValue(URL(fileURLWithPath: "/Users/tpae/Desktop")) {
            // Default `path: "."` resolves to `home + "/."`.
            let hint = hostWorkspaceSearchRedirectHint(
                resolvedPath: "/workspace/agents/abc/.",
                home: "/workspace/agents/abc"
            )
            #expect(hint?.contains("file_read") == true)
            #expect(hint?.contains("file_search") == true)
        }
    }

    @Test func emptySubdirectorySearchDoesNotRedirect() {
        // A real sandbox search of a populated subtree must never be nagged.
        ChatExecutionContext.$hostReadOnlyScope.withValue(URL(fileURLWithPath: "/Users/tpae/Desktop")) {
            let hint = hostWorkspaceSearchRedirectHint(
                resolvedPath: "/workspace/agents/abc/src",
                home: "/workspace/agents/abc"
            )
            #expect(hint == nil)
        }
    }

    @Test func homeRootSearchOutsideCombinedModeDoesNotRedirect() {
        // Pure sandbox session: an empty home search is just an empty search.
        let hint = hostWorkspaceSearchRedirectHint(
            resolvedPath: "/workspace/agents/abc/.",
            home: "/workspace/agents/abc"
        )
        #expect(hint == nil)
    }
}
