//
//  AgentBundleImportIdentityTests.swift
//  OsaurusCoreTests
//
//  `.osaurus-agent` bundles carry the agent's cryptographic identity
//  (`agentIndex` / `agentAddress` / `agentDeviceScope`). Importing one on a
//  second device must neither duplicate an address a local agent already
//  owns (relay `superseded` ping-pong, cross-agent key confusion) nor
//  silently re-mint an address the user is deliberately MOVING between
//  their own devices (which would break every pairing and share). These
//  tests pin the pure rule behind both the review sheet and `activate`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Agent bundle import identity rule")
struct AgentBundleImportIdentityTests {

    private func agent(
        name: String,
        index: UInt32? = nil,
        scope: String? = nil,
        address: String? = nil,
        builtIn: Bool = false
    ) -> Agent {
        var a = Agent(
            id: UUID(),
            name: name,
            isBuiltIn: builtIn,
            agentIndex: index,
            agentAddress: address,
            autonomousExec: AutonomousExecConfig(enabled: false)
        )
        a.agentDeviceScope = scope
        return a
    }

    @Test func foreignScope_noCollision_isAMove_addressKept() {
        let imported = agent(name: "Writer", index: 0, scope: "a1b2c3d4", address: "0xAAA1")
        let local = agent(name: "Local zero", index: 0, scope: "c3d4e5f6", address: "0xBBB1")

        let result = AgentBundleService.resolveImportIdentity(
            agent: imported, localAgents: [local], currentDeviceScope: "c3d4e5f6"
        )
        #expect(result.note == .mintedOnAnotherDevice(scope: "a1b2c3d4"))
        #expect(result.agent.agentAddress == "0xAAA1")
        #expect(result.agent.agentIndex == 0)
        #expect(result.agent.agentDeviceScope == "a1b2c3d4")
    }

    @Test func sameIndexSameScope_isCollision_identityCleared() {
        let imported = agent(name: "Writer", index: 0, scope: "c3d4e5f6", address: "0xAAA1")
        let local = agent(name: "Local zero", index: 0, scope: "c3d4e5f6", address: "0xBBB1")

        let result = AgentBundleService.resolveImportIdentity(
            agent: imported, localAgents: [local], currentDeviceScope: "c3d4e5f6"
        )
        #expect(result.note == .collidesWithLocalAgent(name: "Local zero"))
        #expect(result.agent.agentAddress == nil)
        #expect(result.agent.agentIndex == nil)
        #expect(result.agent.agentDeviceScope == nil)
        // Everything that is not identity survives the clear.
        #expect(result.agent.id == imported.id)
        #expect(result.agent.name == "Writer")
    }

    @Test func sameAddressDifferentSlot_isCollision() {
        // A restored backup running on two machines: same address, whatever
        // the slots say.
        let imported = agent(name: "Copy", index: 4, scope: "a1b2c3d4", address: "0xSAME")
        let local = agent(name: "Original", index: 9, scope: "c3d4e5f6", address: "0xsame")

        let result = AgentBundleService.resolveImportIdentity(
            agent: imported, localAgents: [local], currentDeviceScope: "c3d4e5f6"
        )
        #expect(result.note == .collidesWithLocalAgent(name: "Original"))
        #expect(result.agent.agentAddress == nil)
    }

    @Test func sameUUID_isOverwriteNotCollision() {
        // Re-importing a bundle of an agent that already lives here.
        let imported = agent(name: "Writer", index: 2, scope: "c3d4e5f6", address: "0xAAA2")
        var local = imported
        local.name = "Writer (older copy)"

        let result = AgentBundleService.resolveImportIdentity(
            agent: imported, localAgents: [local], currentDeviceScope: "c3d4e5f6"
        )
        #expect(result.note == nil)
        #expect(result.agent.agentAddress == "0xAAA2")
    }

    @Test func legacyV1_noCollision_isKeptAndLabelled() {
        let imported = agent(name: "Old", index: 1, scope: nil, address: "0xV1")
        let localV2 = agent(name: "New", index: 1, scope: "c3d4e5f6", address: "0xV2")

        // Same index, but v1 vs v2 is a different derivation slot.
        let result = AgentBundleService.resolveImportIdentity(
            agent: imported, localAgents: [localV2], currentDeviceScope: "c3d4e5f6"
        )
        #expect(result.note == .legacyV1)
        #expect(result.agent.agentAddress == "0xV1")
    }

    @Test func legacyV1_collidingWithLocalV1_isCleared() {
        let imported = agent(name: "Old", index: 1, scope: nil, address: "0xV1a")
        let localV1 = agent(name: "Also old", index: 1, scope: nil, address: "0xV1b")

        let result = AgentBundleService.resolveImportIdentity(
            agent: imported, localAgents: [localV1], currentDeviceScope: "c3d4e5f6"
        )
        #expect(result.note == .collidesWithLocalAgent(name: "Also old"))
    }

    @Test func mintedOnThisDevice_noCollision_hasNoNote() {
        let imported = agent(name: "Mine", index: 5, scope: "c3d4e5f6", address: "0xMINE")
        let result = AgentBundleService.resolveImportIdentity(
            agent: imported, localAgents: [], currentDeviceScope: "c3d4e5f6"
        )
        #expect(result.note == nil)
        #expect(result.agent.agentAddress == "0xMINE")
    }

    @Test func noIdentityOrBuiltIn_isPassedThrough() {
        let bare = agent(name: "Bare")
        let builtIn = agent(name: "Default", index: 0, address: "0x1", builtIn: true)
        let local = agent(name: "Local", index: 0, address: "0x1")

        #expect(
            AgentBundleService.resolveImportIdentity(
                agent: bare, localAgents: [local], currentDeviceScope: "x"
            ).note == nil
        )
        let b = AgentBundleService.resolveImportIdentity(
            agent: builtIn, localAgents: [local], currentDeviceScope: "x"
        )
        #expect(b.note == nil)
        #expect(b.agent.agentAddress == "0x1")
    }

    @Test func builtInLocalAgent_neverCounts() {
        let imported = agent(name: "Writer", index: 0, scope: nil, address: "0xAAA")
        let builtInLocal = agent(name: "Default", index: 0, scope: nil, address: "0xAAA", builtIn: true)
        let result = AgentBundleService.resolveImportIdentity(
            agent: imported, localAgents: [builtInLocal], currentDeviceScope: nil
        )
        #expect(result.note == .legacyV1)
    }
}
