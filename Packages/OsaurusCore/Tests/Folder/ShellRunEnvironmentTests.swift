import Foundation
import Testing

@testable import OsaurusCore

struct ShellRunEnvironmentTests {
    @Test func loginShellEntriesComeBeforeTheSparseAppPath() {
        let env = ShellRunTool.childEnvironment(
            inherited: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/test"],
            loginShellEntries: ["/Users/test/.local/share/mise/installs/node/22/bin", "/opt/homebrew/bin"]
        )
        let entries = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(entries.first == "/Users/test/.local/share/mise/installs/node/22/bin")
        #expect(entries.firstIndex(of: "/opt/homebrew/bin")! < entries.firstIndex(of: "/usr/bin")!)
        #expect(env["HOME"] == "/Users/test")
    }

    @Test func relativeEntriesAreDropped() {
        let env = ShellRunTool.childEnvironment(
            inherited: ["PATH": ".:/usr/bin:bin"],
            loginShellEntries: ["node_modules/.bin", "/opt/homebrew/bin", ""]
        )
        let entries = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(entries.allSatisfy { $0.hasPrefix("/") })
        #expect(entries.contains("/opt/homebrew/bin"))
        #expect(entries.contains("/usr/bin"))
    }

    @Test func missingProbeStillAddsVersionManagerShims() {
        let env = ShellRunTool.childEnvironment(
            inherited: ["PATH": "/usr/bin:/bin"],
            loginShellEntries: nil
        )
        let path = env["PATH"] ?? ""
        #expect(path.contains("/.local/share/mise/shims"))
        #expect(path.contains("/usr/bin"))
    }

    /// Regression for review on #3056: a probe still running when the first
    /// `shell_run` lands must be awaited, not read as nil, or a tool only on
    /// the login-shell PATH (nvm/fnm, no static shim) is not found.
    @Test func delayedProbeIsAwaitedBeforeLaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("osaurus_probe_tool")
        try "#!/bin/sh\necho VERSION_MANAGER_OK\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let env = await ShellRunTool.resolvedChildEnvironment(
            inherited: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            loginShellEntries: {
                try? await Task.sleep(nanoseconds: 200_000_000)
                return [dir.path]
            }
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "osaurus_probe_tool"]
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0)
        #expect(output.contains("VERSION_MANAGER_OK"))
    }

    @Test func failedProbeKeepsInheritedPathAndFallbacks() async {
        let env = await ShellRunTool.resolvedChildEnvironment(
            inherited: ["PATH": "/usr/bin:/bin"],
            loginShellEntries: { nil }
        )
        let path = env["PATH"] ?? ""
        #expect(path.contains("/usr/bin"))
        #expect(path.contains("/.local/share/mise/shims"))
    }
}
