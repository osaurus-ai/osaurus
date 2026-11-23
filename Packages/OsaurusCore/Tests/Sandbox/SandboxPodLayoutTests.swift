//
//  SandboxPodLayoutTests.swift
//  osaurus
//
//  The per-agent pod layout is the isolation boundary between agents, so
//  its shape is pinned here: which host paths each container mounts, how
//  execs are routed, which identity each bridge socket accepts, and the
//  one-time move off the shared-workspace layout.
//

import Foundation
import Testing

@testable import OsaurusCore

#if os(macOS)

    struct SandboxPodLayoutTests {
        private let workspace = URL(fileURLWithPath: "/tmp/osaurus-pod-test/workspace")
        private let containerRoot = URL(fileURLWithPath: "/tmp/osaurus-pod-test/container")

        @Test
        func systemContainerComesFirstWithNoWorkspaceMounts() {
            let specs = SandboxPodLayout.containers(
                members: ["alice"],
                workspace: workspace,
                containerRoot: containerRoot
            )
            let system = specs[0]
            #expect(system.id == SandboxPodLayout.systemContainerID)
            #expect(system.target == .system)
            #expect(system.environmentName == SandboxPodLayout.systemEnvironmentName)
            #expect(system.mounts.map(\.destination) == [SandboxPodLayout.guestShimPath])
            #expect(system.bridgeLinuxName == "agent-diag")
        }

        @Test
        func agentContainerMountsOnlyItsOwnHomeSharedAndTheShim() {
            let specs = SandboxPodLayout.containers(
                members: ["alice", "bob"],
                workspace: workspace,
                containerRoot: containerRoot
            )
            #expect(specs.map(\.id) == ["osaurus-system", "agent-alice", "agent-bob"])
            let alice = specs[1]
            #expect(alice.target == .agent("alice"))
            #expect(alice.environmentName == "alice")
            #expect(alice.bridgeLinuxName == "agent-alice")
            #expect(
                alice.mounts == [
                    .init(
                        source: workspace.appendingPathComponent("agents/alice").path,
                        destination: "/workspace/agents/alice",
                        readOnly: false
                    ),
                    .init(
                        source: workspace.appendingPathComponent("shared").path,
                        destination: "/workspace/shared",
                        readOnly: false
                    ),
                    .init(
                        source: SandboxPodLayout.shimFile(containerRoot: containerRoot).path,
                        destination: "/usr/local/bin/osaurus-host",
                        readOnly: true
                    ),
                ]
            )
            // Never the share root, and never another agent's home.
            for spec in specs {
                #expect(!spec.mounts.contains { $0.source == workspace.path })
                #expect(!spec.mounts.contains { $0.source == workspace.appendingPathComponent("agents").path })
            }
            #expect(!alice.mounts.contains { $0.source.hasSuffix("agents/bob") })
        }

        @Test
        func shimLivesAloneInItsOwnDirectory() {
            let shim = SandboxPodLayout.shimFile(containerRoot: containerRoot)
            #expect(shim.deletingLastPathComponent() == SandboxPodLayout.shimDirectory(containerRoot: containerRoot))
            #expect(shim.deletingLastPathComponent() != containerRoot)
        }

        @Test
        func bridgeSocketsAreDistinctPerIdentityAndFitSunPath() {
            let names = ["agent-diag", "agent-alice", "agent-" + UUID().uuidString.lowercased()]
            let paths = names.map { SandboxPodLayout.bridgeSocketPath(linuxName: $0, containerRoot: containerRoot) }
            #expect(Set(paths).count == names.count)
            for path in paths {
                #expect(path.utf8.count < 104)
                #expect(path.hasSuffix(".sock"))
            }
        }

        /// A Space's data root is deep; sockets beneath it overflowed
        /// `sun_path` and NIO refused to bind (`unixDomainSocketPathTooLong`).
        @Test
        func bridgeSocketsFitSunPathForSpaceRootsAndStaySeparatePerRoot() {
            let spaceRoot = URL(
                fileURLWithPath:
                    "/Users/someone-with-a-long-name/.osaurus-spaces/\(UUID().uuidString.lowercased())/data/container"
            )
            let otherSpaceRoot = URL(
                fileURLWithPath: "/Users/someone/.osaurus-spaces/\(UUID().uuidString.lowercased())/data/container"
            )
            let linuxName = "agent-" + UUID().uuidString.lowercased()
            let real = SandboxPodLayout.bridgeSocketPath(linuxName: linuxName, containerRoot: spaceRoot)
            #expect(real.utf8.count < 104)
            #expect(!real.hasPrefix(spaceRoot.path))

            // The longest per-user temp dir macOS hands out, once symlinks resolve.
            let darwinTemp = URL(
                fileURLWithPath: "/private/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000/T/",
                isDirectory: true
            )
            let worstCase = SandboxPodLayout.bridgeSocketPath(
                linuxName: linuxName,
                containerRoot: spaceRoot,
                runtimeRoot: darwinTemp
            )
            #expect(worstCase.utf8.count < 104)

            #expect(
                SandboxPodLayout.bridgeSocketDirectory(containerRoot: spaceRoot)
                    != SandboxPodLayout.bridgeSocketDirectory(containerRoot: otherSpaceRoot)
            )
        }

        @Test
        func selectMembersPutsRequesterFirstDedupesAndCaps() {
            let members = SandboxPodLayout.selectMembers(
                requester: "carol",
                recentFirst: ["alice", "carol", "bob", "alice", "dave"],
                cap: 3
            )
            #expect(members == ["carol", "alice", "bob"])
        }

        @Test
        func selectMembersDropsNonAgentNamesAndKeepsAtLeastOne() {
            let members = SandboxPodLayout.selectMembers(
                requester: nil,
                recentFirst: ["osaurus-system", "Bad Name", "../x", "ok-1"],
                cap: 0
            )
            #expect(members == ["ok-1"])
        }

        @Test
        func fillersKeepWorkflowsAndSandboxAgentsOnly() {
            let workflow = "wf-" + UUID().uuidString.lowercased()
            let fillers = SandboxPodLayout.eligibleFillers(
                ["deleted-agent", workflow, "sandbox-on", "sandbox-off"],
                sandboxAgents: ["sandbox-on"]
            )
            #expect(fillers == [workflow, "sandbox-on"])
        }

        @Test
        func agentNamesAreLowercaseAsciiAndNeverTheSystemEnvironment() {
            #expect(SandboxPodLayout.isAgentName("1a2b-3c"))
            #expect(SandboxPodLayout.isAgentName("wf-" + UUID().uuidString.lowercased()))
            #expect(!SandboxPodLayout.isAgentName(""))
            #expect(!SandboxPodLayout.isAgentName("osaurus-system"))
            #expect(!SandboxPodLayout.isAgentName("Alice"))
            #expect(!SandboxPodLayout.isAgentName("a/b"))
            #expect(!SandboxPodLayout.isAgentName("é"))
        }

        @Test
        func containerIDsFitTheSDKLimit() {
            let longest = "wf-" + UUID().uuidString.lowercased()
            #expect(SandboxPodLayout.containerID(for: .agent(longest)).count <= 64)
        }
    }

    struct SandboxExecRoutingTests {
        @Test
        func agentUsersRunInTheirOwnContainerAndEverythingElseInSystem() {
            #expect(SandboxManager.target(forLinuxName: "agent-alice") == .agent("alice"))
            #expect(SandboxManager.target(forLinuxName: nil) == .system)
            #expect(SandboxManager.target(forLinuxName: "root") == .system)
            #expect(SandboxManager.target(forLinuxName: "agent-") == .system)
        }

        @Test
        func diagnosticsUserRunsInTheSystemContainer() {
            #expect(SandboxManager.target(forLinuxName: "agent-diag") == .system)
        }

        @Test
        func cwdIsQuotedSoItCannotSplitOrInject() {
            let args = SandboxManager.execArguments(
                user: "agent-alice",
                command: "ls",
                cwd: "/workspace/agents/alice/my dir'; rm -rf /; '"
            )
            #expect(args.prefix(5) == ["su", "-s", "/bin/bash", "agent-alice", "-c"])
            #expect(
                args.last == #"cd '/workspace/agents/alice/my dir'"'"'; rm -rf /; '"'"'' && ls"#
            )
        }

        @Test
        func rootExecWithoutUserUsesAPlainShell() {
            #expect(SandboxManager.execArguments(user: nil, command: "true", cwd: nil) == ["sh", "-c", "true"])
        }
    }

    struct SandboxBridgeSocketBindingTests {
        @Test
        func perContainerSocketAcceptsOnlyItsOwnIdentity() {
            #expect(HostAPIBridgeServer.identityMatchesSocket("agent-alice", boundLinuxName: "agent-alice"))
            #expect(!HostAPIBridgeServer.identityMatchesSocket("agent-bob", boundLinuxName: "agent-alice"))
            #expect(!HostAPIBridgeServer.identityMatchesSocket("agent-alice", boundLinuxName: "agent-diag"))
        }

        @Test
        func unboundSocketAcceptsAnyValidToken() {
            #expect(HostAPIBridgeServer.identityMatchesSocket("agent-alice", boundLinuxName: nil))
        }
    }

    struct SandboxWorkspaceRootMigrationTests {
        private func makeWorkspace() throws -> URL {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-migrate-\(UUID().uuidString)", isDirectory: true)
            for dir in ["agents/alice", "shared"] {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
            }
            return root
        }

        @Test
        func looseRootFilesMoveToSharedAndTheShimStagingIsDropped() throws {
            let workspace = try makeWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            try Data("notes".utf8).write(to: workspace.appendingPathComponent("notes.txt"))
            try FileManager.default.createDirectory(
                at: workspace.appendingPathComponent("project"), withIntermediateDirectories: true)
            try Data("shim".utf8).write(to: workspace.appendingPathComponent(".osaurus-host-shim"))

            SandboxManager.migrateWorkspaceRoot(workspace)

            let fm = FileManager.default
            #expect(fm.fileExists(atPath: workspace.appendingPathComponent("shared/notes.txt").path))
            #expect(fm.fileExists(atPath: workspace.appendingPathComponent("shared/project").path))
            #expect(!fm.fileExists(atPath: workspace.appendingPathComponent(".osaurus-host-shim").path))
            #expect(
                Set(try fm.contentsOfDirectory(atPath: workspace.path)) == ["agents", "shared"]
            )
            #expect(fm.fileExists(atPath: workspace.appendingPathComponent("agents/alice").path))
        }

        @Test
        func nameCollisionsGoToLegacyFolderWithoutOverwriting() throws {
            let workspace = try makeWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            try Data("root".utf8).write(to: workspace.appendingPathComponent("a.txt"))
            try Data("shared".utf8).write(to: workspace.appendingPathComponent("shared/a.txt"))

            SandboxManager.migrateWorkspaceRoot(workspace)

            let shared = try String(
                contentsOf: workspace.appendingPathComponent("shared/a.txt"), encoding: .utf8)
            let legacy = try String(
                contentsOf: workspace.appendingPathComponent("shared/legacy-workspace-root/a.txt"),
                encoding: .utf8)
            #expect(shared == "shared")
            #expect(legacy == "root")
        }
    }

#endif
