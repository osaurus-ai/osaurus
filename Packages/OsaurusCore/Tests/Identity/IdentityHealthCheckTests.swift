//
//  IdentityHealthCheckTests.swift
//  OsaurusCoreTests
//
//  Verifies the pure drift-detection helper that powers the IdentityView's
//  broken-state banner. The helper compares stored agent addresses against
//  what the current master would derive at their stored index, and flags
//  access keys whose issuer does not derive from the current master.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("IdentityHealthCheck.diagnose")
struct IdentityHealthCheckTests {

    // MARK: - Healthy

    @Test
    func noAgents_noKeys_noDrift() {
        let drift = IdentityHealthCheck.diagnose(
            masterKey: TestKeys.alicePrivateKey,
            agents: [],
            accessKeys: []
        )
        #expect(!drift.hasDrift)
        #expect(drift.mismatchedAgents.isEmpty)
        #expect(drift.staleAccessKeys.isEmpty)
    }

    @Test
    func builtInAgentsAreIgnored() {
        let builtIn = Agent.default
        let drift = IdentityHealthCheck.diagnose(
            masterKey: TestKeys.alicePrivateKey,
            agents: [builtIn],
            accessKeys: []
        )
        #expect(!drift.hasDrift)
    }

    @Test
    func aliceMasterAndAliceAgent_isHealthy() throws {
        let aliceAgentAddress = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 0)
        var agent = makeAgent(name: "Alice's agent")
        agent.agentIndex = 0
        agent.agentAddress = aliceAgentAddress

        let drift = IdentityHealthCheck.diagnose(
            masterKey: TestKeys.alicePrivateKey,
            agents: [agent],
            accessKeys: []
        )
        #expect(!drift.hasDrift)
    }

    // MARK: - Device-scoped (v2) derivation

    @Test
    func deviceScopedAgent_matchingItsStoredScope_isHealthy() throws {
        let path = AgentKeyPath.deviceScoped(index: 0, deviceScope: "a1b2c3d4")
        let address = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, path: path)
        var agent = makeAgent(name: "Device A agent")
        agent.agentIndex = 0
        agent.agentDeviceScope = "a1b2c3d4"
        agent.agentAddress = address

        let drift = IdentityHealthCheck.diagnose(
            masterKey: TestKeys.alicePrivateKey,
            agents: [agent],
            accessKeys: []
        )
        #expect(!drift.hasDrift)
    }

    @Test
    func deviceScopedAgent_isNotFlaggedAgainstLegacyDerivationAtSameIndex() throws {
        // A v2 agent at index 0 must not be compared against the v1 address
        // at index 0 — they legitimately differ.
        let legacyAddress = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 0)
        let scopedAddress = try AgentKey.deriveAddress(
            masterKey: TestKeys.alicePrivateKey,
            path: .deviceScoped(index: 0, deviceScope: "a1b2c3d4")
        )
        #expect(legacyAddress.lowercased() != scopedAddress.lowercased())

        var scoped = makeAgent(name: "v2")
        scoped.agentIndex = 0
        scoped.agentDeviceScope = "a1b2c3d4"
        scoped.agentAddress = scopedAddress

        var legacy = makeAgent(name: "v1")
        legacy.agentIndex = 0
        legacy.agentAddress = legacyAddress

        let drift = IdentityHealthCheck.diagnose(
            masterKey: TestKeys.alicePrivateKey,
            agents: [scoped, legacy],
            accessKeys: []
        )
        #expect(!drift.hasDrift)
    }

    @Test
    func deviceScopedAgent_mintedOnOtherDevice_isStillHealthyWithItsOwnScope() throws {
        // The agent record carries the scope it was minted under, so the
        // same master re-derives it on any device.
        let path = AgentKeyPath.deviceScoped(index: 3, deviceScope: "deadbeef")
        let address = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, path: path)
        var agent = makeAgent(name: "Roaming")
        agent.agentIndex = 3
        agent.agentDeviceScope = "deadbeef"
        agent.agentAddress = address

        let drift = IdentityHealthCheck.diagnose(
            masterKey: TestKeys.alicePrivateKey,
            agents: [agent],
            accessKeys: []
        )
        #expect(!drift.hasDrift)
    }

    @Test
    func deviceScopedAgent_underWrongMaster_isMismatched() throws {
        let path = AgentKeyPath.deviceScoped(index: 0, deviceScope: "a1b2c3d4")
        let bobAddress = try AgentKey.deriveAddress(masterKey: TestKeys.bobPrivateKey, path: path)
        var agent = makeAgent(name: "Stranded v2")
        agent.agentIndex = 0
        agent.agentDeviceScope = "a1b2c3d4"
        agent.agentAddress = bobAddress

        let drift = IdentityHealthCheck.diagnose(
            masterKey: TestKeys.alicePrivateKey,
            agents: [agent],
            accessKeys: []
        )
        #expect(drift.mismatchedAgents.map(\.id) == [agent.id])
    }

    // MARK: - Drift

    @Test
    func agentDerivedFromBob_underAliceMaster_isMismatched() throws {
        // The agent's address was derived from Bob, but Alice is the current
        // master. The check should flag the agent.
        let bobAgentAddress = try AgentKey.deriveAddress(masterKey: TestKeys.bobPrivateKey, index: 0)
        var agent = makeAgent(name: "Stranded agent")
        agent.agentIndex = 0
        agent.agentAddress = bobAgentAddress

        let drift = IdentityHealthCheck.diagnose(
            masterKey: TestKeys.alicePrivateKey,
            agents: [agent],
            accessKeys: []
        )
        #expect(drift.hasDrift)
        #expect(drift.mismatchedAgents.count == 1)
        #expect(drift.mismatchedAgents.first?.id == agent.id)
    }

    @Test
    func accessKeyIssuedByPreviousMaster_isStale() {
        let staleKey = makeAccessKey(
            iss: TestKeys.bobAddress,
            aud: TestKeys.bobAddress
        )

        let drift = IdentityHealthCheck.diagnose(
            masterKey: TestKeys.alicePrivateKey,
            agents: [],
            accessKeys: [staleKey]
        )
        #expect(drift.hasDrift)
        #expect(drift.staleAccessKeys.count == 1)
        #expect(drift.staleAccessKeys.first?.id == staleKey.id)
    }

    @Test
    func accessKeyMatchingCurrentMaster_isNotStale() {
        let aliceKey = makeAccessKey(
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress
        )

        let drift = IdentityHealthCheck.diagnose(
            masterKey: TestKeys.alicePrivateKey,
            agents: [],
            accessKeys: [aliceKey]
        )
        #expect(!drift.hasDrift)
    }

    @Test
    func accessKeyMatchingCurrentAgent_isNotStale() throws {
        let aliceAgentAddress = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 0)
        var agent = makeAgent(name: "Alice agent")
        agent.agentIndex = 0
        agent.agentAddress = aliceAgentAddress

        let agentScopedKey = makeAccessKey(
            iss: aliceAgentAddress,
            aud: aliceAgentAddress
        )

        let drift = IdentityHealthCheck.diagnose(
            masterKey: TestKeys.alicePrivateKey,
            agents: [agent],
            accessKeys: [agentScopedKey]
        )
        #expect(!drift.hasDrift)
    }

    @Test
    func revokedStaleKey_isIgnored() {
        var revokedStale = makeAccessKey(
            iss: TestKeys.bobAddress,
            aud: TestKeys.bobAddress
        )
        revokedStale = revokedStale.withRevoked()

        let drift = IdentityHealthCheck.diagnose(
            masterKey: TestKeys.alicePrivateKey,
            agents: [],
            accessKeys: [revokedStale]
        )
        #expect(!drift.hasDrift)
    }

    @Test
    func combinedDrift_reportsBoth() throws {
        // Stranded agent + stale key in one shot.
        let bobAgentAddress = try AgentKey.deriveAddress(masterKey: TestKeys.bobPrivateKey, index: 0)
        var agent = makeAgent(name: "Stranded")
        agent.agentIndex = 0
        agent.agentAddress = bobAgentAddress

        let staleKey = makeAccessKey(iss: TestKeys.bobAddress, aud: TestKeys.bobAddress)

        let drift = IdentityHealthCheck.diagnose(
            masterKey: TestKeys.alicePrivateKey,
            agents: [agent],
            accessKeys: [staleKey]
        )
        #expect(drift.hasDrift)
        #expect(drift.mismatchedAgents.count == 1)
        #expect(drift.staleAccessKeys.count == 1)
    }

    // MARK: - Dropped device scope (downgrade signature)

    /// An older build re-saved a v2 agent without `agentDeviceScope`. Under
    /// the device that minted it, the v2 path reproduces the stored address,
    /// so the agent is recoverable — not drift — and its address stays valid
    /// for the stale-key filter.
    @Test
    func droppedScope_underMintingDevice_isRecoverableNotMismatched() throws {
        let scope = "a1b2c3d4"
        let v2Address = try AgentKey.deriveAddress(
            masterKey: TestKeys.alicePrivateKey, path: .deviceScoped(index: 0, deviceScope: scope)
        )
        var agent = makeAgent(name: "Downgraded")
        agent.agentIndex = 0
        agent.agentAddress = v2Address
        agent.agentDeviceScope = nil  // what the old build wrote back
        let scopedKey = makeAccessKey(iss: v2Address, aud: v2Address)

        let drift = IdentityHealthCheck.diagnose(
            masterKey: TestKeys.alicePrivateKey,
            agents: [agent],
            accessKeys: [scopedKey],
            currentDeviceScope: scope
        )
        #expect(!drift.hasDrift)
        #expect(drift.mismatchedAgents.isEmpty)
        #expect(drift.recoverableScopeAgents.map(\.id) == [agent.id])
        #expect(drift.staleAccessKeys.isEmpty)
    }

    /// Same dropped-scope agent, but diagnosed on a different device: the v2
    /// path under THIS device's scope does not reproduce the address, so
    /// there is nothing lossless to do — it is genuine mismatch.
    @Test
    func droppedScope_underOtherDevice_staysMismatched() throws {
        let v2Address = try AgentKey.deriveAddress(
            masterKey: TestKeys.alicePrivateKey, path: .deviceScoped(index: 0, deviceScope: "a1b2c3d4")
        )
        var agent = makeAgent(name: "Downgraded elsewhere")
        agent.agentIndex = 0
        agent.agentAddress = v2Address

        let drift = IdentityHealthCheck.diagnose(
            masterKey: TestKeys.alicePrivateKey,
            agents: [agent],
            accessKeys: [],
            currentDeviceScope: "c3d4e5f6"
        )
        #expect(drift.hasDrift)
        #expect(drift.mismatchedAgents.map(\.id) == [agent.id])
        #expect(drift.recoverableScopeAgents.isEmpty)
    }

    /// Without a device scope to try, the check behaves exactly as before.
    @Test
    func droppedScope_withoutCurrentScope_isPlainMismatch() throws {
        let v2Address = try AgentKey.deriveAddress(
            masterKey: TestKeys.alicePrivateKey, path: .deviceScoped(index: 0, deviceScope: "a1b2c3d4")
        )
        var agent = makeAgent(name: "No scope hint")
        agent.agentIndex = 0
        agent.agentAddress = v2Address

        let drift = IdentityHealthCheck.diagnose(
            masterKey: TestKeys.alicePrivateKey,
            agents: [agent],
            accessKeys: []
        )
        #expect(drift.mismatchedAgents.count == 1)
        #expect(drift.recoverableScopeAgents.isEmpty)
    }

    /// A healthy legacy v1 agent must never be re-labelled as recoverable
    /// just because a scope is on offer.
    @Test
    func legacyV1Agent_withCurrentScope_isUntouched() throws {
        let v1Address = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 3)
        var agent = makeAgent(name: "Legacy")
        agent.agentIndex = 3
        agent.agentAddress = v1Address

        let drift = IdentityHealthCheck.diagnose(
            masterKey: TestKeys.alicePrivateKey,
            agents: [agent],
            accessKeys: [],
            currentDeviceScope: "a1b2c3d4"
        )
        #expect(!drift.hasDrift)
        #expect(drift.recoverableScopeAgents.isEmpty)
    }

    /// A v2 agent under the wrong master is mismatch even when its scope is
    /// also missing: recovery must prove the address, not just the layout.
    @Test
    func droppedScope_underWrongMaster_isMismatched() throws {
        let scope = "a1b2c3d4"
        let bobV2 = try AgentKey.deriveAddress(
            masterKey: TestKeys.bobPrivateKey, path: .deviceScoped(index: 0, deviceScope: scope)
        )
        var agent = makeAgent(name: "Bob's, scope dropped")
        agent.agentIndex = 0
        agent.agentAddress = bobV2

        let drift = IdentityHealthCheck.diagnose(
            masterKey: TestKeys.alicePrivateKey,
            agents: [agent],
            accessKeys: [],
            currentDeviceScope: scope
        )
        #expect(drift.mismatchedAgents.count == 1)
        #expect(drift.recoverableScopeAgents.isEmpty)
    }

    /// The repair writes the scope back in place: address, index, and
    /// every minted key are untouched, and the agent stops being
    /// recoverable on the next diagnosis. Agents that already carry a
    /// scope, or have no identity, are skipped.
    @MainActor
    @Test
    func repairDeviceScope_writesScopeBackWithoutTouchingAddress() throws {
        let scope = "a1b2c3d4"
        let v2Address = try AgentKey.deriveAddress(
            masterKey: TestKeys.alicePrivateKey, path: .deviceScoped(index: 7, deviceScope: scope)
        )
        var downgraded = makeAgent(name: "Downgraded")
        downgraded.agentIndex = 7
        downgraded.agentAddress = v2Address
        var alreadyScoped = makeAgent(name: "Fine")
        alreadyScoped.agentIndex = 8
        alreadyScoped.agentDeviceScope = "ffffffff"
        // Unique to this test: other suites (owner / workspace redeem) use
        // `…deadbeef` as their "no such agent here" address against the
        // shared `AgentManager`, and suites run in parallel.
        alreadyScoped.agentAddress = "0x000000000000000000000000000000005c0be5c0"
        let noIdentity = makeAgent(name: "No address")
        AgentManager.shared.add(downgraded)
        AgentManager.shared.add(alreadyScoped)
        AgentManager.shared.add(noIdentity)
        defer {
            // Synchronous on purpose: a detached `Task { delete }` can be
            // dropped at process exit and leak these agents into the shared
            // test root, where they break other suites' "unknown agent" rows.
            for id in [downgraded.id, alreadyScoped.id, noIdentity.id] {
                _ = AgentStore.delete(id: id)
            }
            AgentManager.shared.refresh()
        }

        let repaired = AgentManager.shared.repairDeviceScope(
            for: [downgraded, alreadyScoped, noIdentity], scope: scope
        )
        #expect(repaired == 1)

        let after = try #require(AgentManager.shared.agent(for: downgraded.id))
        #expect(after.agentDeviceScope == scope)
        #expect(after.agentIndex == 7)
        #expect(after.agentAddress == v2Address)
        #expect(AgentManager.shared.agent(for: alreadyScoped.id)?.agentDeviceScope == "ffffffff")
        // `add` parks a path reservation (index + this device's scope) on an
        // address-less agent, so its scope is not ours to assert on; the
        // `repaired == 1` above already proves the repair skipped it, and
        // the repair must never mint an address.
        #expect(AgentManager.shared.agent(for: noIdentity.id)?.agentAddress == nil)

        let drift = IdentityHealthCheck.diagnose(
            masterKey: TestKeys.alicePrivateKey,
            agents: [after],
            accessKeys: [],
            currentDeviceScope: scope
        )
        #expect(!drift.hasDrift)
        #expect(drift.recoverableScopeAgents.isEmpty)
    }

    /// `rotateAddress` hands back what changed so callers can re-point the
    /// relay and workspace shares. Built-ins have no address to rotate and
    /// return nil; without a master the rotation is refused loudly rather
    /// than silently leaving the record half-updated.
    @MainActor
    @Test
    func rotateAddress_returnsNilForBuiltIn_andThrowsWithoutMaster() throws {
        var builtIn = makeAgent(name: "Default")
        builtIn = Agent(
            id: builtIn.id, name: builtIn.name, description: "", systemPrompt: "",
            isBuiltIn: true, createdAt: Date(), updatedAt: Date(),
            autonomousExec: AutonomousExecConfig(enabled: false)
        )
        #expect(try AgentManager.shared.rotateAddress(of: builtIn) == nil)

        // Keychain-disabled harness: no master exists.
        guard !MasterKey.exists() else { return }
        var custom = makeAgent(name: "Custom")
        custom.agentIndex = 0
        custom.agentAddress = "0x00000000000000000000000000000000000000aa"
        #expect(throws: OsaurusIdentityError.self) {
            try AgentManager.shared.rotateAddress(of: custom)
        }
    }

    // MARK: - Helpers

    private func makeAgent(name: String) -> Agent {
        Agent(
            id: UUID(),
            name: name,
            description: "",
            systemPrompt: "",
            isBuiltIn: false,
            createdAt: Date(),
            updatedAt: Date(),
            autonomousExec: AutonomousExecConfig(enabled: false)
        )
    }

    private func makeAccessKey(iss: OsaurusID, aud: OsaurusID) -> AccessKeyInfo {
        AccessKeyInfo(
            id: UUID(),
            label: "test key",
            prefix: "osk-v1.test",
            nonce: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            cnt: 1,
            iss: iss,
            aud: aud,
            createdAt: Date(),
            expiration: .days90,
            expiresAt: Date().addingTimeInterval(3600 * 24 * 30),
            revoked: false
        )
    }
}
