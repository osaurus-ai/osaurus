//
//  WorkspaceDelegationEvaluator.swift
//  osaurus
//
//  Model-free eval bridge for the Orchestrator's workspace (Mode 2)
//  delegation seams. A scripted roster replaces the relay: local agents by
//  name, teammates' shared agents with presence, and the launcher's two
//  spawn policies. Each step is one wave of `spawn_agent` targets; the
//  observation records what the PRODUCTION code decides for it:
//
//    * `AgentTargetResolver.resolve` — `Name@Workspace`, bare names,
//      `0x…` addresses, the durable key; ambiguity lists the exact forms the
//      model should retry with.
//    * The offline refusal a shared agent produces before anything runs
//      (`WorkspaceAgentRunError.offline` → `SubagentError.unavailable`
//      copy), so the parent can re-plan to another target or tell the user.
//    * `SpawnWaveGate.wavePermissionPlan` — one card per wave with the
//      workspace kind on Ask and the local kind on Always Allow, and the
//      pool-spend wording.
//    * `RemoteRunArtifactRelay.payload` — which of the run's shared files
//      travel back to the requester and which are listed as omitted.
//
//  No relay, no model, no Keychain: the roster is a fixture. Live two-Mac
//  proof (auto-join, real Ask card, digest + artifact back, `continue`)
//  stays a manual release row.
//

import Foundation

public enum WorkspaceDelegationEvaluator {
    public struct SharedAgent: Sendable, Codable {
        public let name: String
        public let workspaceId: String
        public let workspaceName: String
        /// 42-char `0x…` address (lowercased on use).
        public let address: String
        public let online: Bool
        /// Seconds since the host was last seen; nil → never seen.
        public let lastSeenSecondsAgo: Int?
    }

    /// One `share_artifact` a hosted run made, as the relay sees it.
    public struct Artifact: Sendable, Codable {
        public let name: String
        public let sizeBytes: Int
        public let isDirectory: Bool?
    }

    public struct Step: Sendable, Codable {
        /// The `agent` strings of one wave (several `spawn_agent` calls
        /// issued in one assistant message).
        public let targets: [String]
        /// Artifacts a remote member shared during its run (payload check).
        public let artifacts: [Artifact]?
    }

    public struct Scenario: Sendable, Codable {
        public let localAgents: [String]
        public let sharedAgents: [SharedAgent]
        /// `ask` | `deny` | `always_allow` for the local `spawn` kind.
        public let localPolicy: String
        /// Same for `spawn_workspace`.
        public let workspacePolicy: String
        public let steps: [Step]
    }

    public struct Observation: Sendable, Codable, Equatable {
        /// Per target: `local:<name>`, `workspace:<Name@Workspace>`,
        /// `ambiguous:<form>|<form>…` or `not_found`.
        public let resolutions: [String]
        /// Per target: `""` when it may run, else the typed refusal the model
        /// reads in the tool result (offline shared agent).
        public let refusals: [String]
        /// Combined wave policy for the members that resolved.
        public let policy: String
        /// Sorted permission kinds the one card covers.
        public let cardKinds: [String]
        public let cardDescription: String
        /// Artifact names that reach the requester with bytes.
        public let returnedArtifacts: [String]
        /// `name:reason` for artifacts listed without bytes.
        public let omittedArtifacts: [String]
    }

    /// `00000000-0000-4000-8000-0000000000NN` for the NN-th (1-based) local
    /// agent of a scenario.
    public static func localAgentId(index: Int) -> UUID {
        let suffix = String(format: "%012d", index + 1)
        return UUID(uuidString: "00000000-0000-4000-8000-\(suffix)")!
    }

    @MainActor
    public static func run(_ scenario: Scenario) -> [Observation] {
        // Deterministic ids so an `ambiguous` hint that lists a local twin's
        // UUID (the resolver's exact retry form) is reproducible in fixtures:
        // `00000000-0000-4000-8000-0000000000NN`, NN = 1-based index.
        let localAgents = scenario.localAgents.enumerated().map { index, name in
            Agent(id: Self.localAgentId(index: index), name: name)
        }
        let shared: [(ref: WorkspaceAgentRef, name: String?)] = scenario.sharedAgents.map {
            (WorkspaceAgentRef(workspaceId: $0.workspaceId, agentAddress: $0.address.lowercased()), $0.name)
        }
        var workspaceNames: [String: String] = [:]
        for agent in scenario.sharedAgents {
            workspaceNames[agent.workspaceId.lowercased()] = agent.workspaceName
        }
        let policies: [String: SubagentPermissionPolicy] = [
            SubagentCapabilityRegistry.spawn.id:
                SubagentPermissionPolicy(rawValue: scenario.localPolicy) ?? .ask,
            SubagentPermissionDefaults.workspaceSpawnKindId:
                SubagentPermissionPolicy(rawValue: scenario.workspacePolicy) ?? .ask,
        ]
        let now = Date()

        return scenario.steps.map { step in
            var resolutions: [String] = []
            var refusals: [String] = []
            var memberKinds: [String] = []
            for target in step.targets {
                switch AgentTargetResolver.resolve(
                    target, scope: .localAndWorkspace,
                    localAgents: localAgents, sharedAgents: shared, workspaceNames: workspaceNames
                ) {
                case .success(.local(let id)):
                    let name = localAgents.first { $0.id == id }?.name ?? id.uuidString
                    resolutions.append("local:\(name)")
                    refusals.append("")
                    memberKinds.append(SubagentCapabilityRegistry.spawn.id)
                case .success(.workspace(let ref)):
                    let entry = shared.first { $0.ref == ref }
                    let qualified = entry.map {
                        AgentTargetResolver.qualifiedName(for: $0, workspaceNames: workspaceNames)
                    } ?? ref.key
                    resolutions.append("workspace:\(qualified)")
                    let fixture = scenario.sharedAgents.first {
                        $0.workspaceId == ref.workspaceId && $0.address.lowercased() == ref.agentAddress
                    }
                    if let fixture, !fixture.online {
                        let lastSeen = fixture.lastSeenSecondsAgo.map {
                            now.addingTimeInterval(-TimeInterval($0))
                        }
                        refusals.append(
                            AgentDelegationDispatcher.workspaceRefusal(
                                reason: WorkspaceAgentRunError.offline(lastSeen: lastSeen)
                                    .message(agentName: fixture.name, now: now)
                            )
                        )
                    } else {
                        refusals.append("")
                        memberKinds.append(SubagentPermissionDefaults.workspaceSpawnKindId)
                    }
                case .failure(.ambiguous(let forms)):
                    resolutions.append("ambiguous:" + forms.joined(separator: "|"))
                    refusals.append("")
                case .failure(.notFound):
                    resolutions.append("not_found")
                    refusals.append("")
                }
            }

            let plan = SpawnWaveGate.wavePermissionPlan(memberKinds: memberKinds, policies: policies)

            var returned: [String] = []
            var omitted: [String] = []
            if let artifacts = step.artifacts, !artifacts.isEmpty {
                let typed = artifacts.map { artifact in
                    SharedArtifact(
                        contextId: "eval",
                        contextType: .chat,
                        filename: artifact.name,
                        mimeType: SharedArtifact.mimeType(from: artifact.name),
                        fileSize: artifact.sizeBytes,
                        hostPath: "",
                        isDirectory: artifact.isDirectory ?? false,
                        content: (artifact.isDirectory ?? false)
                            ? nil : String(repeating: "x", count: max(0, artifact.sizeBytes))
                    )
                }
                for row in RemoteRunArtifactRelay.payload(for: typed) {
                    if let reason = row.omitted_reason {
                        omitted.append("\(row.name):\(reason)")
                    } else {
                        returned.append(row.name)
                    }
                }
            }

            return Observation(
                resolutions: resolutions,
                refusals: refusals,
                policy: memberKinds.isEmpty ? "" : plan.policy.rawValue,
                cardKinds: memberKinds.isEmpty ? [] : plan.kindIds.sorted(),
                cardDescription: memberKinds.isEmpty ? "" : plan.description,
                returnedArtifacts: returned,
                omittedArtifacts: omitted
            )
        }
    }
}
