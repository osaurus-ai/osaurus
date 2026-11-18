//
//  SandboxPodLayout.swift
//  osaurus
//
//  The shape of the sandbox pod: one Linux VM, one container per agent,
//  plus a system container for VM-wide work. Each agent container has its
//  own rootfs (the agent's copy-on-write environment), its own mount and
//  PID namespaces, and only two shares: its own home and `shared/`. The
//  VirtioFS share root is never mounted, so other agents' homes are not
//  reachable from inside a container at all; the kernel namespace is the
//  boundary, not file permissions (VirtioFS reports every file as owned by
//  whoever accesses it).
//
//  Pure value types so the security-relevant layout is testable without a
//  VM. `SandboxManager` turns these into Containerization mounts.
//

import CryptoKit
import Foundation

/// Which container an exec runs in.
public enum SandboxExecTarget: Sendable, Equatable, Hashable {
    /// The system container: no workspace mounts, no agent identity. VM-wide
    /// probes, diagnostics, and runtime info run here.
    case system
    /// The agent's own container.
    case agent(String)

    /// Target implied by a Linux user name: `agent-<name>` runs in that
    /// agent's container, anything else in the system container.
    public static func implied(byUser user: String?) -> SandboxExecTarget {
        guard let user, user.hasPrefix("agent-") else { return .system }
        let name = String(user.dropFirst("agent-".count))
        return name.isEmpty ? .system : .agent(name)
    }
}

public enum SandboxPodLayout {
    public static let podID = "osaurus-sandbox"
    public static let systemContainerID = "osaurus-system"
    /// Environment name of the system container's rootfs clone. Not a valid
    /// agent Linux name (those are lowercased UUIDs or `wf-<uuid>`), so it
    /// can't collide with an agent's environment.
    public static let systemEnvironmentName = "osaurus-system"
    /// Linux user the diagnostics bridge check runs as, in the system
    /// container. Its socket accepts only the diagnostics token.
    public static let diagnosticsAgentName = "diag"

    public static let guestBridgeSocketPath = "/tmp/osaurus-bridge.sock"
    public static let guestShimPath = "/usr/local/bin/osaurus-host"
    public static let guestAgentsRoot = "/workspace/agents"
    public static let guestSharedPath = "/workspace/shared"

    public static func containerID(for target: SandboxExecTarget) -> String {
        switch target {
        case .system: return systemContainerID
        case .agent(let name): return "agent-\(name)"
        }
    }

    /// Host socket for one container's bridge. Both components are hashed
    /// so the path stays under the 104-byte `sun_path` limit for any agent
    /// name and any data root.
    public static func bridgeSocketPath(
        linuxName: String,
        containerRoot: URL,
        runtimeRoot: URL = FileManager.default.temporaryDirectory
    ) -> String {
        bridgeSocketDirectory(containerRoot: containerRoot, runtimeRoot: runtimeRoot)
            .appendingPathComponent("\(shortHash(linuxName, bytes: 8)).sock").path
    }

    /// Directory holding one data root's bridge sockets. Lives under the
    /// per-user temporary directory (mode 0700) rather than the container
    /// root: a Space's root (`~/.osaurus-spaces/<uuid>/data/container`) is
    /// deep enough that a socket beneath it overflows `sun_path`. Keyed by
    /// the container root so Spaces never share sockets.
    public static func bridgeSocketDirectory(
        containerRoot: URL,
        runtimeRoot: URL = FileManager.default.temporaryDirectory
    ) -> URL {
        // ~57 bytes of resolved temp dir + "osb-" + 8 + "/" + 16 + ".sock"
        // leaves ~12 bytes of headroom; keep both names this short.
        runtimeRoot.resolvingSymlinksInPath()
            .appendingPathComponent(
                "osb-\(shortHash(containerRoot.resolvingSymlinksInPath().path, bytes: 4))",
                isDirectory: true
            )
    }

    private static func shortHash(_ value: String, bytes: Int) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// The shim lives alone in its own host directory: a single-file mount
    /// shares the file's parent directory with the VM, so nothing else may
    /// live next to it.
    public static func shimDirectory(containerRoot: URL) -> URL {
        containerRoot.appendingPathComponent("shim", isDirectory: true)
    }

    public static func shimFile(containerRoot: URL) -> URL {
        shimDirectory(containerRoot: containerRoot).appendingPathComponent("osaurus-host")
    }

    public struct MountSpec: Sendable, Equatable {
        public let source: String
        public let destination: String
        public let readOnly: Bool
    }

    public struct ContainerSpec: Sendable, Equatable {
        public let id: String
        public let target: SandboxExecTarget
        public let environmentName: String
        public let mounts: [MountSpec]
        /// Linux user whose token this container's bridge socket accepts.
        public let bridgeLinuxName: String
    }

    /// Every container of a pod with `members` (agent Linux names, without
    /// the `agent-` prefix). The system container comes first.
    public static func containers(
        members: [String],
        workspace: URL,
        containerRoot: URL
    ) -> [ContainerSpec] {
        let shim = MountSpec(
            source: shimFile(containerRoot: containerRoot).path,
            destination: guestShimPath,
            readOnly: true
        )
        let system = ContainerSpec(
            id: systemContainerID,
            target: .system,
            environmentName: systemEnvironmentName,
            mounts: [shim],
            bridgeLinuxName: "agent-\(diagnosticsAgentName)"
        )
        let shared = workspace.appendingPathComponent("shared", isDirectory: true).path
        let agents = members.map { name in
            ContainerSpec(
                id: containerID(for: .agent(name)),
                target: .agent(name),
                environmentName: name,
                mounts: [
                    MountSpec(
                        source: workspace.appendingPathComponent("agents/\(name)", isDirectory: true).path,
                        destination: "\(guestAgentsRoot)/\(name)",
                        readOnly: false
                    ),
                    MountSpec(source: shared, destination: guestSharedPath, readOnly: false),
                    shim,
                ],
                bridgeLinuxName: "agent-\(name)"
            )
        }
        return [system] + agents
    }

    /// Agents kept in the pod: the requester first, then the most recently
    /// used other agents, up to `cap` in total. Membership is fixed for the
    /// life of a VM (VZ has no hotplug), so any other agent joins through a
    /// restart.
    public static func selectMembers(
        requester: String?,
        recentFirst candidates: [String],
        cap: Int
    ) -> [String] {
        var members: [String] = []
        for name in [requester].compactMap({ $0 }) + candidates
        where isAgentName(name) && !members.contains(name) {
            members.append(name)
        }
        return Array(members.prefix(Swift.max(cap, 1)))
    }

    /// Environments a boot may fill spare member slots with: workflow
    /// environments, and agents that have the sandbox on now. A deleted
    /// agent's leftover environment, or one whose sandbox was turned off,
    /// must not take a slot from an agent that needs it.
    public static func eligibleFillers(_ names: [String], sandboxAgents: Set<String>) -> [String] {
        names.filter { $0.hasPrefix("wf-") || sandboxAgents.contains($0) }
    }

    /// Agent Linux names are `[a-z0-9-]` and never the system environment.
    public static func isAgentName(_ name: String) -> Bool {
        !name.isEmpty && name != systemEnvironmentName
            && name.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
            && name.unicodeScalars.allSatisfy(\.isASCII)
    }
}
