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
}
