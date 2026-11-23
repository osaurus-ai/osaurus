//
//  SandboxAgentPathScopeTests.swift
//
//  VirtioFS reports every `/workspace` file as owned by whichever guest
//  user touches it, so host code is the boundary between agents' homes.
//  These pin that boundary: an agent's host-side reach is its own home plus
//  `/workspace/shared`, and a guest-planted symlink (relative to a sibling
//  home, absolute to a host file, or replacing a directory) is never
//  followed by a host read or write.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SandboxAgentPathScopeTests {

    private static let agentA = "scope-a-\(UUID().uuidString.prefix(8).lowercased())"
    private static let agentB = "scope-b-\(UUID().uuidString.prefix(8).lowercased())"

    /// Private storage root with both agents' homes, a shared dir, and a
    /// "host" directory outside the share holding a secret.
    private func withShare<T: Sendable>(
        _ body: @Sendable (_ homeA: URL, _ homeB: URL, _ hostSecret: URL) async throws -> T
    ) async throws -> T {
        try await StoragePathsTestLock.shared.run {
            let previousRoot = OsaurusPaths.overrideRoot
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("scope-root-\(UUID().uuidString)", isDirectory: true)
            let fm = FileManager.default
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? fm.removeItem(at: root)
            }
            let homeA = OsaurusPaths.containerAgentDir(Self.agentA)
            let homeB = OsaurusPaths.containerAgentDir(Self.agentB)
            for dir in [homeA, homeB, OsaurusPaths.containerSharedDir()] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try "b-secret".write(to: homeB.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
            let hostDir = root.appendingPathComponent("host-only", isDirectory: true)
            try fm.createDirectory(at: hostDir, withIntermediateDirectories: true)
            let hostSecret = hostDir.appendingPathComponent("id_rsa")
            try "host-secret".write(to: hostSecret, atomically: true, encoding: .utf8)
            return try await body(homeA, homeB, hostSecret)
        }
    }

    @Test func splitAdmitsOnlyOwnHomeAndShared() {
        let scope = SandboxAgentPathScope(agentName: "a1")
        #expect(scope.split(sandboxPath: "/workspace/agents/a1/x.txt")?.relative == "x.txt")
        #expect(scope.split(sandboxPath: "/workspace/agents/a1")?.relative == "")
        #expect(scope.split(sandboxPath: "/workspace/shared/d/x.csv")?.relative == "d/x.csv")
        for outside in [
            "/workspace/agents/b2/x.txt", "/workspace/agents/a1x/x.txt", "/workspace/sharedX/x",
            "/workspace/x.txt", "/workspace", "/workspace/agents/a1/../b2/x", "agents/a1/x", "/etc/passwd",
        ] {
            #expect(scope.split(sandboxPath: outside) == nil, "\(outside)")
        }
        #expect(SandboxAgentPathScope(agentHome: "/workspace/agents/a1")?.agentHome == "/workspace/agents/a1")
        #expect(SandboxAgentPathScope(agentHome: "/workspace/agents/a1/sub") == nil)
        #expect(SandboxAgentPathScope(agentHome: "/workspace/agents/..") == nil)
        #expect(SandboxAgentPathScope(agentHome: "/workspace") == nil)
    }

    @Test func sanitizerRejectsSiblingPrefixHomes() {
        let home = "/workspace/agents/a1"
        #expect(SandboxPathSanitizer.sanitize("/workspace/agents/a1/x", agentHome: home) == "/workspace/agents/a1/x")
        #expect(SandboxPathSanitizer.sanitize("/workspace/agents/a1x/x", agentHome: home) == nil)
        #expect(SandboxPathSanitizer.sanitize("/workspace/sharedX/x", agentHome: home) == nil)
        #expect(SandboxPathSanitizer.sanitize("/workspace/shared", agentHome: home) == "/workspace/shared")
    }

    @Test func hostURLRefusesSymlinksIntoAnotherHomeOrTheHost() async throws {
        try await withShare { homeA, homeB, hostSecret in
            let fm = FileManager.default
            // Relative link to the sibling home, as a guest `ln -s ../B/secret.txt` makes.
            try fm.createSymbolicLink(
                atPath: homeA.appendingPathComponent("peek.txt").path,
                withDestinationPath: "../\(Self.agentB)/secret.txt"
            )
            try fm.createSymbolicLink(
                at: homeA.appendingPathComponent("key.txt"), withDestinationURL: hostSecret)
            let scope = SandboxAgentPathScope(agentName: Self.agentA)
            let home = scope.agentHome
            #expect(throws: (any Error).self) { _ = try scope.hostURL(forSandboxPath: "\(home)/peek.txt") }
            #expect(throws: (any Error).self) { _ = try scope.hostURL(forSandboxPath: "\(home)/key.txt") }
            #expect(throws: (any Error).self) {
                _ = try scope.hostURL(forSandboxPath: "/workspace/agents/\(Self.agentB)/secret.txt")
            }
            #expect(!scope.contains(hostURL: homeB.appendingPathComponent("secret.txt")))
            #expect(scope.contains(hostURL: homeA.appendingPathComponent("new.txt").deletingLastPathComponent()))
        }
    }

    @Test func readContainedRefusesSymlinksAndLinkedHomes() async throws {
        try await withShare { homeA, homeB, hostSecret in
            let fm = FileManager.default
            let soul = homeA.appendingPathComponent("SOUL.md")
            try "# me".write(to: soul, atomically: true, encoding: .utf8)
            #expect(SandboxAgentPathScope.readContained(soul, within: homeA) == Data("# me".utf8))
            #expect(SandboxAgentPathScope.readContained(soul, within: homeA, maxBytes: 2) == Data("# ".utf8))
            #expect(SystemPromptComposer.loadSoulContent(linuxName: Self.agentA) == "# me")

            try fm.removeItem(at: soul)
            try fm.createSymbolicLink(at: soul, withDestinationURL: hostSecret)
            #expect(SandboxAgentPathScope.readContained(soul, within: homeA) == nil)
            #expect(SystemPromptComposer.loadSoulContent(linuxName: Self.agentA) == nil)

            // Relative link into the sibling home, as `ln -s ../B/secret.txt SOUL.md` makes.
            try fm.removeItem(at: soul)
            try fm.createSymbolicLink(atPath: soul.path, withDestinationPath: "../\(Self.agentB)/secret.txt")
            #expect(SystemPromptComposer.loadSoulContent(linuxName: Self.agentA) == nil)

            // A linked parent directory is refused too.
            let linkedDir = homeA.appendingPathComponent("notes")
            try fm.createSymbolicLink(at: linkedDir, withDestinationURL: homeB)
            #expect(
                SandboxAgentPathScope.readContained(linkedDir.appendingPathComponent("secret.txt"), within: homeA)
                    == nil)

            // The home itself swapped for a link to a host directory.
            try fm.removeItem(at: homeA)
            try fm.createSymbolicLink(at: homeA, withDestinationURL: hostSecret.deletingLastPathComponent())
            #expect(SandboxAgentPathScope.readContained(homeA.appendingPathComponent("id_rsa"), within: homeA) == nil)
        }
    }

    @Test func writeContainedRefusesLinkedDirectories() async throws {
        try await withShare { homeA, _, hostSecret in
            let fm = FileManager.default
            let pluginFile = homeA.appendingPathComponent("plugins/p1/src/main.py")
            try SandboxAgentPathScope.writeContained(Data("print(1)".utf8), to: pluginFile, within: homeA)
            #expect(try String(contentsOf: pluginFile, encoding: .utf8) == "print(1)")

            let hostDir = hostSecret.deletingLastPathComponent()
            try fm.createSymbolicLink(at: homeA.appendingPathComponent("plugins/p2"), withDestinationURL: hostDir)
            #expect(throws: (any Error).self) {
                try SandboxAgentPathScope.writeContained(
                    Data("x".utf8), to: homeA.appendingPathComponent("plugins/p2/evil.plist"), within: homeA)
            }
            #expect(!fm.fileExists(atPath: hostDir.appendingPathComponent("evil.plist").path))

            // A planted file link is not written through.
            try fm.createSymbolicLink(
                at: homeA.appendingPathComponent("plugins/p1/run.sh"), withDestinationURL: hostSecret)
            #expect(throws: (any Error).self) {
                try SandboxAgentPathScope.writeContained(
                    Data("x".utf8), to: homeA.appendingPathComponent("plugins/p1/run.sh"), within: homeA)
            }
            #expect(try String(contentsOf: hostSecret, encoding: .utf8) == "host-secret")

            #expect(
                !SandboxAgentPathScope.parentIsContained(
                    homeA.appendingPathComponent("plugins/p2/x"), within: homeA))
            #expect(
                SandboxAgentPathScope.parentIsContained(homeA.appendingPathComponent("plugins/p1"), within: homeA))
        }
    }

    @Test func confinedLogTailerDoesNotFollowLinks() async throws {
        try await withShare { homeA, _, hostSecret in
            let log = homeA.appendingPathComponent("bg-1.log")
            try FileManager.default.createSymbolicLink(at: log, withDestinationURL: hostSecret)
            let tailer = LogFileTailer(path: log.path, confinedTo: homeA)
            tailer.start()
            defer { tailer.stop() }
            #expect(tailer.snapshot().isEmpty)

            let real = homeA.appendingPathComponent("bg-2.log")
            let realTailer = LogFileTailer(path: real.path, confinedTo: homeA)
            realTailer.start()
            defer { realTailer.stop() }
            try "hello".write(to: real, atomically: false, encoding: .utf8)
            #expect(realTailer.snapshot() == Data("hello".utf8))
        }
    }

    @Test func seatbeltProfileGrantsOnlyOwnHomeAndShared() {
        let profile = SeatbeltSandbox.profile(
            workspaceRoot: "/tmp/osaurus-scope-ws",
            tempDir: "/tmp/osaurus-scope-tmp/a1",
            network: .denied,
            writableRoots: ["/tmp/osaurus-scope-ws/agents/a1", "/tmp/osaurus-scope-ws/shared"]
        )
        #expect(profile.contains("osaurus-scope-ws/agents/a1\""))
        #expect(profile.contains("osaurus-scope-ws/shared\""))
        #expect(!profile.contains("(subpath \"/tmp/osaurus-scope-ws\")"))
        #expect(!profile.contains("(subpath \"/private/tmp/osaurus-scope-ws\")"))

        let system = SeatbeltSandbox.profile(
            workspaceRoot: "/tmp/osaurus-scope-ws", tempDir: "/tmp/osaurus-scope-tmp", network: .denied)
        #expect(system.contains("osaurus-scope-ws\""))
        #expect(SeatbeltSandbox.scratchDir(forAgent: "a1").hasSuffix("/osaurus-seatbelt/a1"))
    }
}
