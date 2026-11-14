//
//  SandboxPageModelTests.swift
//  OsaurusCoreTests
//
//  The Sandbox page's derived data: the Agents & Environments list, the
//  host-resource warnings on the CPU and Memory steppers, and the one-line
//  startup summary shown in the chat turn.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Sandbox page model")
struct SandboxPageModelTests {

    @Test
    func environmentsListAgentsAndWorkflowsRunningFirst() {
        let running = UUID()
        let idle = UUID()
        let deleted = UUID()
        let now = Date()
        let entries = SandboxEnvironmentEntry.entries(
            environments: [
                (name: SandboxPodLayout.systemEnvironmentName, lastUsedAt: now),
                (name: idle.uuidString.lowercased(), lastUsedAt: now),
                (name: "wf-template", lastUsedAt: now.addingTimeInterval(-60)),
                (name: running.uuidString.lowercased(), lastUsedAt: now.addingTimeInterval(-600)),
                (name: deleted.uuidString.lowercased(), lastUsedAt: nil),
                (name: "alice", lastUsedAt: now.addingTimeInterval(-3600)),
            ],
            runningMembers: [running.uuidString.lowercased()],
            agentNames: [running: "Runner", idle: "Idle"],
            allocatedBytes: { $0 == idle.uuidString.lowercased() ? 600_000_000 : nil }
        )

        #expect(entries.map(\.name) == [
            running.uuidString.lowercased(),
            idle.uuidString.lowercased(),
            "wf-template",
            "alice",
            deleted.uuidString.lowercased(),
        ])
        #expect(entries[0].isRunning && entries[0].displayName == "Runner")
        #expect(entries[0].kind == .agent(running))
        #expect(entries[1].allocatedBytes == 600_000_000)
        #expect(entries[2].kind == .workflow && entries[2].displayName == nil)
        #expect(entries[3].kind == .unused)
        #expect(entries[4].displayName == nil)
        #expect(entries[1].linuxUser == "agent-\(idle.uuidString.lowercased())")
    }

    @Test
    func environmentsUsePrecomputedSizes() {
        let sized = UUID().uuidString.lowercased()
        let unsized = UUID().uuidString.lowercased()
        let sizes: [String: Int64] = [sized: 42_000_000]
        let entries = SandboxEnvironmentEntry.entries(
            environments: [(name: sized, lastUsedAt: Date()), (name: unsized, lastUsedAt: nil)],
            runningMembers: [],
            agentNames: [:],
            allocatedBytes: { sizes[$0] }
        )
        #expect(entries.first { $0.name == sized }?.allocatedBytes == 42_000_000)
        #expect(entries.first { $0.name == unsized }?.allocatedBytes == nil)
    }

    @Test
    func memoryWarnsAboveHalfTheMac() {
        let eightGB: UInt64 = 8 * 1_073_741_824
        #expect(SandboxHostResourceWarning.memory(vmGB: 4, hostBytes: eightGB) == nil)
        #expect(SandboxHostResourceWarning.memory(vmGB: 5, hostBytes: eightGB) != nil)
        #expect(SandboxHostResourceWarning.memory(vmGB: 8, hostBytes: eightGB)?.contains("8 GB") == true)
        #expect(SandboxHostResourceWarning.memory(vmGB: 8, hostBytes: 64 * 1_073_741_824) == nil)
        #expect(SandboxHostResourceWarning.memory(vmGB: 8, hostBytes: 0) == nil)
    }

    @Test
    func cpuWarnsWhenTheSandboxCanUseEveryCore() {
        #expect(SandboxHostResourceWarning.cpu(cpus: 7, hostCores: 8) == nil)
        #expect(SandboxHostResourceWarning.cpu(cpus: 8, hostCores: 8) != nil)
        #expect(SandboxHostResourceWarning.cpu(cpus: 4, hostCores: 0) == nil)
    }

    @Test
    func inlineSummaryNamesTheStepBytesAndTimeLeft() {
        let download = ProvisioningStepState(
            id: .downloadInitFS,
            label: "Downloading runtime",
            status: .inProgress,
            bytesProcessed: 10,
            bytesTotal: 100,
            etaSeconds: 70
        )
        let journey = ProvisioningJourney(steps: [download], currentStepID: .downloadInitFS)
        let summary = journey.inlineSummary { done, total, _ in "\(done)/\(total)" }
        #expect(summary == "Downloading runtime · 10/100 · about 1m 10s left")

        let percent = ProvisioningJourney(
            steps: [ProvisioningStepState(id: .createContainer, label: "Unpacking", status: .inProgress, progress: 0.42)],
            currentStepID: .createContainer
        )
        #expect(percent.inlineSummary { _, _, _ in "" } == "Unpacking · 42%")

        #expect(ProvisioningJourney().inlineSummary { _, _, _ in "" } == nil)
    }
}
