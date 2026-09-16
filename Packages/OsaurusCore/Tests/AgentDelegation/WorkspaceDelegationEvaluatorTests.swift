//
//  WorkspaceDelegationEvaluatorTests.swift
//  OsaurusCoreTests
//
//  The model-free bridge the `WorkspaceDelegation` eval suite rides on:
//  a scripted roster through the production resolver, the offline refusal
//  copy, the one-card-per-wave permission plan and the artifact relay caps.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("WorkspaceDelegationEvaluator")
struct WorkspaceDelegationEvaluatorTests {
    private static let acme = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa01"
    private static let beta = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb01"

    private static func shared(
        _ name: String, workspace: String, workspaceName: String, address: String,
        online: Bool = true, lastSeenSecondsAgo: Int? = nil
    ) -> WorkspaceDelegationEvaluator.SharedAgent {
        .init(
            name: name, workspaceId: workspace, workspaceName: workspaceName, address: address,
            online: online, lastSeenSecondsAgo: lastSeenSecondsAgo)
    }

    @Test("offline shared agent yields the dispatcher's exact refusal and plans no card")
    @MainActor
    func offlineRefusal() {
        let scenario = WorkspaceDelegationEvaluator.Scenario(
            localAgents: ["Coder"],
            sharedAgents: [
                Self.shared("Research", workspace: "ws-acme", workspaceName: "Acme", address: Self.acme,
                            online: false, lastSeenSecondsAgo: 120)
            ],
            localPolicy: "always_allow", workspacePolicy: "ask",
            steps: [.init(targets: ["Research@Acme"], artifacts: nil), .init(targets: ["Coder"], artifacts: nil)]
        )
        let observed = WorkspaceDelegationEvaluator.run(scenario)
        #expect(observed.count == 2)
        #expect(observed[0].resolutions == ["workspace:Research@Acme"])
        #expect(observed[0].refusals[0].hasPrefix("Workspace agent Research is offline (last seen 2 min ago)."))
        #expect(observed[0].refusals[0].hasSuffix("Pick a different agent for this task, or report that it is unavailable."))
        #expect(observed[0].policy == "" && observed[0].cardKinds.isEmpty)
        #expect(observed[1] == .init(
            resolutions: ["local:Coder"], refusals: [""], policy: "always_allow", cardKinds: ["spawn"],
            cardDescription: "Let this agent run 1 subagents in parallel?",
            returnedArtifacts: [], omittedArtifacts: []))
    }

    @Test("ambiguity lists the deterministic local id and both Name@Workspace forms")
    @MainActor
    func ambiguityForms() {
        let scenario = WorkspaceDelegationEvaluator.Scenario(
            localAgents: ["Research"],
            sharedAgents: [
                Self.shared("Research", workspace: "ws-acme", workspaceName: "Acme", address: Self.acme),
                Self.shared("Research", workspace: "ws-beta", workspaceName: "Beta Team", address: Self.beta),
            ],
            localPolicy: "always_allow", workspacePolicy: "ask",
            steps: [.init(targets: ["Research"], artifacts: nil),
                    .init(targets: ["Research@Acme", "Coder"], artifacts: nil)]
        )
        let observed = WorkspaceDelegationEvaluator.run(scenario)
        #expect(observed[0].resolutions == [
            "ambiguous:00000000-0000-4000-8000-000000000001|Research@Acme|Research@Beta Team"
        ])
        #expect(observed[1].resolutions == ["workspace:Research@Acme", "not_found"])
        // Only the resolved member counts toward the wave.
        #expect(observed[1].cardKinds == ["spawn_workspace"])
        #expect(observed[1].policy == "ask")
    }

    @Test("mixed wave: Ask on the workspace kind, Deny wins, artifacts honour the caps")
    @MainActor
    func mixedWaveAndArtifacts() {
        func scenario(workspacePolicy: String) -> WorkspaceDelegationEvaluator.Scenario {
            .init(
                localAgents: ["Coder"],
                sharedAgents: [Self.shared("Analyst", workspace: "ws-acme", workspaceName: "Acme", address: Self.acme)],
                localPolicy: "always_allow", workspacePolicy: workspacePolicy,
                steps: [
                    .init(
                        targets: ["Coder", "Analyst@Acme"],
                        artifacts: [
                            .init(name: "report.md", sizeBytes: 1200, isDirectory: nil),
                            .init(name: "dataset.bin", sizeBytes: 5_000_000, isDirectory: nil),
                            .init(name: "out", sizeBytes: 0, isDirectory: true),
                        ])
                ])
        }
        let ask = WorkspaceDelegationEvaluator.run(scenario(workspacePolicy: "ask"))[0]
        #expect(ask.policy == "ask")
        #expect(ask.cardKinds == ["spawn_workspace"])
        #expect(ask.cardDescription.contains("1 of them run on teammates' Macs"))
        #expect(ask.returnedArtifacts == ["report.md"])
        #expect(ask.omittedArtifacts == ["dataset.bin:too_large", "out:directory"])

        let deny = WorkspaceDelegationEvaluator.run(scenario(workspacePolicy: "deny"))[0]
        #expect(deny.policy == "deny")
        #expect(deny.cardKinds == ["spawn", "spawn_workspace"])
    }

    @Test("the pure wave plan treats an unknown kind as Ask")
    func purePlanDefaultsToAsk() {
        let plan = SpawnWaveGate.wavePermissionPlan(
            memberKinds: ["spawn", "spawn_workspace"],
            policies: ["spawn": .alwaysAllow])
        #expect(plan.policy == .ask)
        #expect(plan.kindIds == ["spawn_workspace"])
    }
}
