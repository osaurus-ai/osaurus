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

    // MARK: - Helpers

    private func makeAgent(name: String) -> Agent {
        Agent(
            id: UUID(),
            name: name,
            description: "",
            systemPrompt: "",
            isBuiltIn: false,
            createdAt: Date(),
            updatedAt: Date()
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
