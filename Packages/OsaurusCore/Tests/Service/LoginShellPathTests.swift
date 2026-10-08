//
//  LoginShellPathTests.swift
//  OsaurusCoreTests
//
//  #3024: host stdio MCP servers (and the Claude Code launcher) must see version-manager toolchains (mise, nvm,
//  asdf) and the interpreter behind a `#!/usr/bin/env node` shebang.
//

import Foundation
import Darwin
import Testing

@testable import OsaurusCore

@Suite("Login shell PATH for host child processes")
struct LoginShellPathTests {
    private func tempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func script(_ url: URL, _ body: String) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func parseIgnoresStartupNoiseAndDeduplicates() {
        let noisy = "Welcome!\nmise activated\n__OSAURUS_LOGIN_PATH__/a:/b::/a:/c__OSAURUS_LOGIN_PATH__\nbye"
        #expect(LoginShellPath.parse(noisy) == ["/a", "/b", "/c"])
        #expect(LoginShellPath.parse("no markers") == nil)
    }

    @Test func probeReadsAFakeLoginShell() throws {
        let dir = try tempDir("fake-shell")
        defer { try? FileManager.default.removeItem(at: dir) }
        let shell = dir.appendingPathComponent("zsh")
        try script(shell, """
            #!/bin/sh
            echo "rc noise that must be ignored"
            printf '%s' '__OSAURUS_LOGIN_PATH__/Users/u/.local/share/mise/installs/node/lts/bin:/usr/bin__OSAURUS_LOGIN_PATH__'
            """)
        #expect(LoginShellPath.probe(shell: shell.path, timeout: 5)
            == ["/Users/u/.local/share/mise/installs/node/lts/bin", "/usr/bin"])
    }

    @Test func aHungShellTimesOutInsteadOfBlocking() throws {
        let dir = try tempDir("hung-shell")
        defer { try? FileManager.default.removeItem(at: dir) }
        let shell = dir.appendingPathComponent("zsh")
        try script(shell, "#!/bin/sh\nsleep 30\n")
        let start = Date()
        #expect(LoginShellPath.probe(shell: shell.path, timeout: 0.5) == nil)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func timeoutReapsShellThatIgnoresTermination() throws {
        let dir = try tempDir("term-ignoring-shell")
        defer { try? FileManager.default.removeItem(at: dir) }
        let shell = dir.appendingPathComponent("zsh")
        let pidFile = dir.appendingPathComponent("owned.pid")
        try script(shell, """
            #!/bin/sh
            trap '' TERM
            echo $$ > '\(pidFile.path)'
            while :; do :; done
            """)
        let start = Date()
        let result = LoginShellPath.probe(shell: shell.path, timeout: 0.2)
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) } }
        #expect(result == nil)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(kill(pid, 0) != 0, "A deadline must clean up the owned process, not just return early")
    }

    @Test func chattyStartupRetainsFinalPathWithinBoundedBuffer() throws {
        let dir = try tempDir("chatty-shell")
        defer { try? FileManager.default.removeItem(at: dir) }
        let shell = dir.appendingPathComponent("zsh")
        try script(shell, """
            #!/bin/sh
            i=0
            while [ "$i" -lt 10000 ]; do
              printf '%s\\n' 'startup-noise-startup-noise-startup-noise-startup-noise-startup-noise'
              i=$((i + 1))
            done
            printf '%s' '__OSAURUS_LOGIN_PATH__/fixture/bin:/usr/bin__OSAURUS_LOGIN_PATH__'
            """)
        #expect(LoginShellPath.probe(shell: shell.path, timeout: 5) == ["/fixture/bin", "/usr/bin"])
    }

    @Test func childPathPutsLoginShellEntriesFirstWithoutDuplicates() {
        let path = ExecutableLocator.childPath(
            inherited: ["PATH": "/usr/bin:/bin"], loginShellEntries: ["/mise/node/bin", "/usr/bin"])
        let entries = path.split(separator: ":").map(String.init)
        #expect(entries.first == "/mise/node/bin")
        #expect(entries.filter { $0 == "/usr/bin" }.count == 1)
        #expect(entries.contains("/opt/homebrew/bin"))
        #expect(entries.contains(FileManager.default.homeDirectoryForCurrentUser.path + "/.local/share/mise/shims"))
    }

    @Test func envShebangSiblingFindsTheToolchainBesideAFullPathScript() throws {
        let dir = try tempDir("mise-node")
        defer { try? FileManager.default.removeItem(at: dir) }
        let npx = dir.appendingPathComponent("npx")
        try script(npx, "#!/usr/bin/env node\nrequire('x')\n")
        #expect(ExecutableLocator.envShebangSiblingDirectory(executable: npx.path) == nil)  // no node yet
        try script(dir.appendingPathComponent("node"), "#!/bin/sh\necho node\n")
        #expect(ExecutableLocator.envShebangSiblingDirectory(executable: npx.path) == dir.path)

        let flagged = dir.appendingPathComponent("tool")
        try script(flagged, "#!/usr/bin/env -S node --no-warnings\n")
        #expect(ExecutableLocator.envShebangSiblingDirectory(executable: flagged.path) == dir.path)

        let direct = dir.appendingPathComponent("direct")
        try script(direct, "#!/bin/sh\necho hi\n")
        #expect(ExecutableLocator.envShebangSiblingDirectory(executable: direct.path) == nil)
    }

    @Test func childEnvironmentGetsLoginPathButAnExplicitProviderPathWins() {
        var provider = MCPProvider(name: "path-probe", url: "")
        let env = MCPStdioHostRunner.buildEnvForTesting(provider: provider, loginShellEntries: ["/mise/node/bin"])
        #expect(env["PATH"]?.hasPrefix("/mise/node/bin:") == true)

        provider.env = ["PATH": "/only/this"]
        let explicit = MCPStdioHostRunner.buildEnvForTesting(provider: provider, loginShellEntries: ["/mise/node/bin"])
        #expect(explicit["PATH"] == "/only/this")
    }

    /// End to end: a full-path `npx` whose `#!/usr/bin/env node` interpreter lives only beside it now runs.
    @Test func fullPathEnvShebangScriptRunsWithItsSiblingInterpreter() throws {
        let dir = try tempDir("e2e-node")
        defer { try? FileManager.default.removeItem(at: dir) }
        try script(dir.appendingPathComponent("node"), "#!/bin/sh\necho ran-with-sibling-node\n")
        let npx = dir.appendingPathComponent("npx")
        try script(npx, "#!/usr/bin/env node\n")
        let sibling = try #require(ExecutableLocator.envShebangSiblingDirectory(executable: npx.path))

        func run(path: String) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = npx
            process.environment = ["PATH": path]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            return (process.terminationStatus,
                    String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        // Before (#3024): GUI PATH only -> `env: node: No such file or directory`.
        #expect(try run(path: "/usr/bin:/bin").0 != 0)
        // After: the sibling directory is first on the child's PATH.
        let fixed = try run(path: sibling + ":/usr/bin:/bin")
        #expect(fixed.0 == 0)
        #expect(fixed.1.contains("ran-with-sibling-node"))
    }
}
