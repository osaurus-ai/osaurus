//
//  ShellSandboxProfileTests.swift
//  osaurusTests
//
//  Verifies the Seatbelt profile generation for `shell_run` / `git_commit`
//  confinement (escaping, realpath resolution, wrapped invocation shape) and
//  — when `/usr/bin/sandbox-exec` exists — that the kernel actually permits
//  writes inside the selected folder and denies them outside it.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ShellSandboxProfileTests {

    // MARK: - Profile string generation

    @Test
    func profile_containsWritableRootTempDirsAndDenyRule() throws {
        let profile = ShellSandboxProfile.profile(writableRootRealPath: "/Users/me/project")
        #expect(profile.contains("(version 1)"))
        #expect(profile.contains("(allow default)"))
        #expect(profile.contains("(deny file-write*)"))
        #expect(profile.contains("(subpath \"/Users/me/project\")"))
        #expect(profile.contains("(subpath \"/private/tmp\")"))
        #expect(profile.contains("(subpath \"/private/var/tmp\")"))
        #expect(profile.contains("(literal \"/dev/null\")"))
        // Deny must come BEFORE the write allowances so the allowances win
        // (Seatbelt applies the most specific matching rule; ordering here
        // mirrors the canonical deny-then-allow profile layout).
        let denyIdx = try #require(profile.range(of: "(deny file-write*)")).lowerBound
        let allowIdx = try #require(profile.range(of: "(allow file-write* (subpath")).lowerBound
        #expect(denyIdx < allowIdx)
    }

    @Test
    func profile_escapesQuotesAndBackslashesInPaths() {
        let tricky = "/Users/me/we\"ird\\path"
        let profile = ShellSandboxProfile.profile(writableRootRealPath: tricky)
        #expect(profile.contains("(subpath \"/Users/me/we\\\"ird\\\\path\")"))
    }

    @Test
    func realPath_resolvesTmpSymlink() {
        // Seatbelt matches resolved paths: /tmp must become /private/tmp or
        // the subpath rule never fires.
        #expect(ShellSandboxProfile.realPath(of: "/tmp") == "/private/tmp")
    }

    @Test
    func wrappedInvocation_runsThroughSandboxExec() throws {
        guard ShellSandboxProfile.isAvailable else { return }
        let invocation = try ShellSandboxProfile.wrappedInvocation(
            executable: "/bin/zsh",
            arguments: ["-c", "echo hi"],
            writableRoot: URL(fileURLWithPath: "/private/tmp")
        )
        #expect(invocation.executableURL.path == "/usr/bin/sandbox-exec")
        #expect(invocation.arguments.first == "-p")
        #expect(invocation.arguments.suffix(3) == ["/bin/zsh", "-c", "echo hi"])
        #expect(invocation.arguments[1].contains("(deny file-write*)"))
    }

    // MARK: - Kernel-enforced integration

    private func runConfined(command: String, root: URL) throws -> Int32 {
        let invocation = try ShellSandboxProfile.wrappedInvocation(
            executable: "/bin/zsh",
            arguments: ["-c", command],
            writableRoot: root
        )
        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.currentDirectoryURL = root
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test
    func sandboxExec_allowsWritesInsideRootAndDeniesOutside() throws {
        guard ShellSandboxProfile.isAvailable else { return }
        let fm = FileManager.default
        // Two sibling dirs: one is the confined root, the other is "outside".
        let base = fm.temporaryDirectory
            .appendingPathComponent("osu-seatbelt-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("selected", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        // NOTE: `fm.temporaryDirectory` lives under the user temp dir, which
        // the profile allowlists — so confine to a root whose sibling is
        // NOT covered by that rule by pointing the profile at `root` and
        // writing to a decidedly non-temp outside path instead.
        let inside = try runConfined(
            command: "echo ok > inside.txt", root: root)
        #expect(inside == 0)
        #expect(fm.fileExists(atPath: root.appendingPathComponent("inside.txt").path))

        // Home directory is never in the allowlist. Use a unique name and
        // clean up defensively in case enforcement ever regresses.
        let escapePath = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".osu-seatbelt-escape-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: escapePath) }
        let escaped = try runConfined(
            command: "echo escape > '\(escapePath)'", root: root)
        #expect(escaped != 0)
        #expect(!fm.fileExists(atPath: escapePath))

        // Child processes inherit the confinement (`bash -c` hop).
        let childEscape = try runConfined(
            command: "/bin/bash -c \"echo escape > '\(escapePath)'\"", root: root)
        #expect(childEscape != 0)
        #expect(!fm.fileExists(atPath: escapePath))
    }
}
