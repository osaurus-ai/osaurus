//
//  PreviousIdentitiesTests.swift
//  OsaurusCoreTests
//
//  Previous Identities: the pure candidate scoring behind the sheet's
//  "Unlock to compare" (`IdentityHealthCheck.match` / `rank`), the archive's
//  gating in test and keychain-disabled processes, its real-Keychain
//  round trip against a throwaway service, and the switch engine failing
//  loudly when the archive can't be read.
//

import Foundation
import LocalAuthentication
import Testing

@testable import OsaurusCore

// MARK: - Candidate scoring

@Suite("IdentityHealthCheck.match")
struct IdentityCandidateMatchTests {

    @Test("the match carries the candidate's own address")
    func reportsCandidateAddress() {
        let match = IdentityHealthCheck.match(masterKey: TestKeys.alicePrivateKey, agents: [], accessKeys: [])
        #expect(match?.address.lowercased() == TestKeys.aliceAddress.lowercased())
        #expect(match?.matchesAnything == false)
    }

    @Test("an invalid seed produces no match")
    func invalidSeedHasNoMatch() {
        let match = IdentityHealthCheck.match(masterKey: Data(repeating: 0, count: 32), agents: [], accessKeys: [])
        #expect(match == nil)
    }

    @Test("counts only agents the candidate re-derives, skipping built-in and unaddressed agents")
    func countsReproducedAgents() throws {
        let alice = try agent(from: TestKeys.alicePrivateKey, path: .deviceScoped(index: 0, deviceScope: "a1b2c3d4"))
        let aliceLegacy = try agent(from: TestKeys.alicePrivateKey, path: .legacy(index: 4))
        let bob = try agent(from: TestKeys.bobPrivateKey, path: .deviceScoped(index: 1, deviceScope: "a1b2c3d4"))
        let unaddressed = makeAgent(name: "no address")

        let match = try #require(
            IdentityHealthCheck.match(
                masterKey: TestKeys.alicePrivateKey,
                agents: [alice, aliceLegacy, bob, unaddressed, Agent.default],
                accessKeys: []
            )
        )
        #expect(match.matchedAgents == 2)
        #expect(match.addressedAgents == 3)
        #expect(match.matchesAnything)
    }

    @Test("an agent whose device scope an older build dropped matches under this Mac's scope")
    func dropsScopeRecoveredUnderCurrentDevice() throws {
        var dropped = try agent(from: TestKeys.alicePrivateKey, path: .deviceScoped(index: 2, deviceScope: "a1b2c3d4"))
        dropped.agentDeviceScope = nil

        let withoutScope = IdentityHealthCheck.match(
            masterKey: TestKeys.alicePrivateKey,
            agents: [dropped],
            accessKeys: []
        )
        #expect(withoutScope?.matchedAgents == 0)

        let withScope = IdentityHealthCheck.match(
            masterKey: TestKeys.alicePrivateKey,
            agents: [dropped],
            accessKeys: [],
            currentDeviceScope: "a1b2c3d4"
        )
        #expect(withScope?.matchedAgents == 1)
    }

    @Test("counts active keys issued by the master or a matched agent, never revoked or foreign ones")
    func countsMatchingAccessKeys() throws {
        let alice = try agent(from: TestKeys.alicePrivateKey, path: .deviceScoped(index: 0, deviceScope: "a1b2c3d4"))
        let aliceAgentAddress = try #require(alice.agentAddress)
        let keys = [
            makeAccessKey(iss: TestKeys.aliceAddress, revoked: false),
            makeAccessKey(iss: aliceAgentAddress, revoked: false),
            makeAccessKey(iss: TestKeys.aliceAddress, revoked: true),
            makeAccessKey(iss: TestKeys.bobAddress, revoked: false),
        ]

        let match = IdentityHealthCheck.match(
            masterKey: TestKeys.alicePrivateKey,
            agents: [alice],
            accessKeys: keys
        )
        #expect(match?.matchedAccessKeys == 2)
    }

    @Test("rank puts the most reproduced agents first, then access keys, keeping ties in order")
    func ranksByAgentsThenKeys() {
        let a = candidate("0xa", agents: 1, keys: 5)
        let b = candidate("0xb", agents: 3, keys: 0)
        let c = candidate("0xc", agents: 1, keys: 9)
        let d = candidate("0xd", agents: 1, keys: 5)

        let ranked = IdentityHealthCheck.rank([a, b, c, d]).map(\.address)
        #expect(ranked == ["0xb", "0xc", "0xa", "0xd"])
    }

    @Test("the sheet summarizes a match, and says so when nothing matches")
    @MainActor
    func matchSummaryText() {
        let none = PreviousIdentitiesSheet.matchSummary(candidate("0xa", agents: 0, keys: 0, of: 2))
        #expect(none.contains("none"))

        let some = PreviousIdentitiesSheet.matchSummary(candidate("0xa", agents: 1, keys: 3, of: 2))
        #expect(some.contains("1"))
        #expect(some.contains("2"))
        #expect(some.contains("3"))
    }

    // MARK: Helpers

    private func candidate(_ address: OsaurusID, agents: Int, keys: Int, of total: Int = 3) -> IdentityCandidateMatch {
        IdentityCandidateMatch(address: address, matchedAgents: agents, addressedAgents: total, matchedAccessKeys: keys)
    }

    private func agent(from masterKey: Data, path: AgentKeyPath) throws -> Agent {
        var agent = makeAgent(name: "agent-\(path.index)")
        agent.agentIndex = path.index
        agent.agentDeviceScope = path.deviceScope
        agent.agentAddress = try AgentKey.deriveAddress(masterKey: masterKey, path: path)
        return agent
    }

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

    private func makeAccessKey(iss: OsaurusID, revoked: Bool) -> AccessKeyInfo {
        AccessKeyInfo(
            id: UUID(),
            label: "test key",
            prefix: "osk-v1.test",
            nonce: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            cnt: 1,
            iss: iss,
            aud: iss,
            createdAt: Date(),
            expiration: .days90,
            expiresAt: Date().addingTimeInterval(3600 * 24 * 30),
            revoked: revoked
        )
    }
}

// MARK: - Archive store

/// One serialized suite: the real-Keychain tests set
/// `MasterKeyArchive.serviceOverrideForTesting`, which the gating tests
/// require to be nil.
@Suite("MasterKeyArchive", .serialized)
struct MasterKeyArchiveTests {

    @Test("test processes never touch the real archive")
    func gatedWithoutOverride() {
        #expect(MasterKeyArchive.serviceOverrideForTesting == nil)
        MasterKeyArchive.remember(seed: TestKeys.alicePrivateKey, source: .created, force: true)
        #expect(MasterKeyArchive.list().isEmpty)
        #expect(throws: OsaurusIdentityError.self) {
            _ = try MasterKeyArchive.loadSeed(address: TestKeys.aliceAddress, context: LAContext())
        }
        #expect(MasterKeyArchive.forget(address: TestKeys.aliceAddress))
    }

    @Test(
        "remember, list, load and forget round-trip through a throwaway Keychain service",
        .enabled(if: !KeychainQueryHelpers.disablesKeychainForProcess)
    )
    func realKeychainRoundTrip() throws {
        try withThrowawayService {
            MasterKeyArchive.remember(seed: TestKeys.alicePrivateKey, source: .created)
            MasterKeyArchive.remember(seed: TestKeys.bobPrivateKey, source: .keychain)
            MasterKeyArchive.remember(seed: Data(repeating: 1, count: 16), source: .created)

            let listed = MasterKeyArchive.list()
            #expect(Set(listed.map(\.id)) == [TestKeys.aliceAddress.lowercased(), TestKeys.bobAddress.lowercased()])
            #expect(listed.first { $0.id == TestKeys.aliceAddress.lowercased() }?.source == .created)

            let context = LAContext()
            context.interactionNotAllowed = true
            var seed = try MasterKeyArchive.loadSeed(address: TestKeys.aliceAddress, context: context)
            defer { seed.zeroOut() }
            #expect(seed == TestKeys.alicePrivateKey)

            #expect(MasterKeyArchive.forget(address: TestKeys.bobAddress))
            #expect(MasterKeyArchive.list().map(\.id) == [TestKeys.aliceAddress.lowercased()])
        }
    }

    @Test(
        "remembering an address again keeps its source and first-seen date",
        .enabled(if: !KeychainQueryHelpers.disablesKeychainForProcess)
    )
    func rememberIsIdempotentPerAddress() throws {
        try withThrowawayService {
            MasterKeyArchive.remember(seed: TestKeys.alicePrivateKey, source: .created)
            let first = try #require(MasterKeyArchive.list().first)

            MasterKeyArchive.remember(seed: TestKeys.alicePrivateKey, source: .restored, force: true)
            let listed = MasterKeyArchive.list()
            #expect(listed.count == 1)
            let second = try #require(listed.first)
            #expect(second.source == .created)
            #expect(second.firstSeenAt == first.firstSeenAt)
            #expect(second.lastActiveAt >= first.lastActiveAt)
        }
    }

    /// Lives in this suite, not its own: with the override set by a parallel
    /// test, `switchTo` could read a fixture seed and install it over the
    /// developer's real master.
    @Test("switching to an unreadable archive entry fails before any state changes")
    @MainActor
    func switchToUnreadableEntryFailsLoudly() async {
        #expect(MasterKeyArchive.serviceOverrideForTesting == nil)
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        let observer = NotificationCenter.default.addObserver(
            forName: .osaurusIdentityChanged,
            object: nil,
            queue: nil
        ) { _ in counter.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        await #expect(throws: OsaurusIdentityError.self) {
            _ = try await OsaurusIdentity.switchTo(archivedAddress: TestKeys.aliceAddress, context: LAContext())
        }
        #expect(counter.value == 0)
    }

    private func withThrowawayService(_ body: () throws -> Void) throws {
        MasterKeyArchive.serviceOverrideForTesting = "com.osaurus.account.archive.test.\(UUID().uuidString)"
        MasterKeyArchive.resetProcessCacheForTesting()
        defer {
            for entry in MasterKeyArchive.list() {
                MasterKeyArchive.forget(address: entry.address)
            }
            MasterKeyArchive.serviceOverrideForTesting = nil
            MasterKeyArchive.resetProcessCacheForTesting()
        }
        try body()
    }
}