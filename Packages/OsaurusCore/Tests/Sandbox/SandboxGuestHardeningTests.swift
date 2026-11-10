//
//  SandboxGuestHardeningTests.swift
//  OsaurusCoreTests
//

import Containerization
import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct SandboxGuestHardeningTests {
    @Test
    func containerMounts_hideOtherUsersProcessesAndKeepTheRestStock() {
        let stock = LinuxContainer.defaultMounts()
        let mounts = SandboxManager.containerBaseMounts()
        #expect(mounts.count == stock.count)
        let proc = mounts.first { $0.destination == "/proc" }
        #expect(proc?.options.contains("hidepid=2") == true)
        #expect(proc?.options.contains("nosuid") == true)
        for (built, original) in zip(mounts, stock) where original.destination != "/proc" {
            #expect(built.options == original.options)
            #expect(built.type == original.type)
        }
        #expect(SandboxManager.perBootSetupScript.contains("hidepid=(2|invisible)' /proc/mounts || {"))
        #expect(!SandboxManager.perBootSetupScript.contains("remount"))
    }

    @Test
    func agentRLimits_capProcessesFilesAndCores() {
        let byKind = Dictionary(uniqueKeysWithValues: SandboxManager.agentRLimits.map { ($0.kind, $0) })
        #expect(byKind[.numberOfProcesses]?.hard == 4096)
        #expect(byKind[.openFiles]?.hard == 65536)
        #expect(byKind[.coreFileSize]?.hard == 0)
        #expect(SandboxManager.agentRLimits.allSatisfy { $0.soft == $0.hard })
    }

    @Test
    func execArguments_quoteTheWorkingDirectory() {
        let args = SandboxManager.execArguments(user: "agent-a", command: "ls", cwd: "/workspace/x y; rm -rf /")
        #expect(args.prefix(4) == ["su", "-s", "/bin/bash", "agent-a"])
        #expect(args.last == "cd '/workspace/x y; rm -rf /' && ls")
    }

    @Test
    func userCreation_pinsTheUIDAndRecreatesAMismatchedUser() {
        let lines = SandboxManager.userCreationLines(linuxName: "agent-a", homeDir: "/workspace/agents/a", uid: 10_002)
        #expect(
            lines == [
                "if ! id agent-a >/dev/null 2>&1; then",
                "  adduser -D -H -u 10002 -h '/workspace/agents/a' agent-a",
                "elif [ \"$(id -u agent-a)\" != \"10002\" ]; then",
                "  deluser agent-a",
                "  delgroup agent-a >/dev/null 2>&1 || true",
                "  adduser -D -H -u 10002 -h '/workspace/agents/a' agent-a",
                "fi",
            ])
        let unpinned = SandboxManager.userCreationLines(linuxName: "agent-a", homeDir: "/h", uid: nil)
        #expect(unpinned == ["if ! id agent-a >/dev/null 2>&1; then", "  adduser -D -H -h '/h' agent-a", "fi"])

        let script = SandboxManager.agentBootstrapScript(
            agentName: "a", homeDir: "/workspace/agents/a", bridgeTokenDir: "/run/osaurus",
            token: nil, soulSeedBody: nil, uid: 10_002)
        #expect(script.contains("adduser -D -H -u 10002"))
    }

    @Test
    func agentUIDs_areDistinctStableAndPersisted() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-sandbox-uids-\(UUID().uuidString)", isDirectory: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
            }
            let a = SandboxAgentUIDs.uid(for: "agent-a")
            let b = SandboxAgentUIDs.uid(for: "agent-b")
            #expect(a == SandboxAgentUIDs.firstUID)
            #expect(b == SandboxAgentUIDs.firstUID + 1)
            #expect(SandboxAgentUIDs.uid(for: "agent-a") == a)
            let file = OsaurusPaths.config().appendingPathComponent("sandbox-agent-uids.json")
            let saved = try JSONDecoder().decode([String: UInt32].self, from: Data(contentsOf: file))
            #expect(saved == ["agent-a": SandboxAgentUIDs.firstUID, "agent-b": SandboxAgentUIDs.firstUID + 1])
        }
    }

    @Test
    func agentUIDs_wrapToTheFirstFreeOnceTheTopIsTaken() {
        let first = SandboxAgentUIDs.firstUID
        let last = SandboxAgentUIDs.lastUID
        #expect(SandboxAgentUIDs.nextFree(after: nil, used: []) == first)
        #expect(SandboxAgentUIDs.nextFree(after: first + 4, used: [first + 4]) == first + 5)
        #expect(SandboxAgentUIDs.nextFree(after: last, used: [first, last]) == first + 1)
        #expect(SandboxAgentUIDs.nextFree(after: last, used: Set(first ... last)) == nil)
    }
}
