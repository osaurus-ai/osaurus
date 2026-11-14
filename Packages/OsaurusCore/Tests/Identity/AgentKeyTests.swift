//
//  AgentKeyTests.swift
//  OsaurusCoreTests
//

import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

private extension AgentKey {
    static func deriveAddress(master: Data, index: UInt32, scope: String) throws -> OsaurusID {
        try deriveAddress(masterKey: master, path: .deviceScoped(index: index, deviceScope: scope))
    }
}

struct AgentKeyTests {

    // MARK: - Deterministic Derivation

    @Test func derive_sameInputs_sameOutput() {
        let key1 = AgentKey.derive(masterKey: TestKeys.alicePrivateKey, index: 0)
        let key2 = AgentKey.derive(masterKey: TestKeys.alicePrivateKey, index: 0)
        #expect(key1 == key2)
    }

    @Test func derive_outputIs32Bytes() {
        let key = AgentKey.derive(masterKey: TestKeys.alicePrivateKey, index: 0)
        #expect(key.count == 32)
    }

    @Test func derive_differentIndices_differentKeys() {
        let key0 = AgentKey.derive(masterKey: TestKeys.alicePrivateKey, index: 0)
        let key1 = AgentKey.derive(masterKey: TestKeys.alicePrivateKey, index: 1)
        let key2 = AgentKey.derive(masterKey: TestKeys.alicePrivateKey, index: 2)
        #expect(key0 != key1)
        #expect(key1 != key2)
        #expect(key0 != key2)
    }

    @Test func derive_differentMasterKeys_differentChildren() {
        let fromAlice = AgentKey.derive(masterKey: TestKeys.alicePrivateKey, index: 0)
        let fromBob = AgentKey.derive(masterKey: TestKeys.bobPrivateKey, index: 0)
        #expect(fromAlice != fromBob)
    }

    @Test func derive_maxIndex_doesNotCrash() {
        let key = AgentKey.derive(masterKey: TestKeys.alicePrivateKey, index: UInt32.max)
        #expect(key.count == 32)
    }

    // MARK: - Address Derivation

    @Test func deriveAddress_validOsaurusId() throws {
        let address = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 0)
        #expect(address.hasPrefix("0x"))
        #expect(address.count == 42)
    }

    @Test func deriveAddress_differentFromMasterAddress() throws {
        let masterAddress = TestKeys.aliceAddress
        let agentAddress = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 0)
        #expect(agentAddress.lowercased() != masterAddress.lowercased())
    }

    @Test func deriveAddress_deterministic() throws {
        let addr1 = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 5)
        let addr2 = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 5)
        #expect(addr1 == addr2)
    }

    @Test func deriveAddress_differentIndices_differentAddresses() throws {
        let addr0 = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 0)
        let addr1 = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 1)
        #expect(addr0 != addr1)
    }

    // MARK: - Device-scoped (v2) Derivation

    @Test func deviceScoped_sameInputs_sameOutput() {
        let path = AgentKeyPath.deviceScoped(index: 0, deviceScope: "a1b2c3d4")
        let key1 = AgentKey.derive(masterKey: TestKeys.alicePrivateKey, path: path)
        let key2 = AgentKey.derive(masterKey: TestKeys.alicePrivateKey, path: path)
        #expect(key1 == key2)
        #expect(key1.count == 32)
    }

    @Test func deviceScoped_differsFromLegacyAtSameIndex() {
        let legacy = AgentKey.derive(masterKey: TestKeys.alicePrivateKey, index: 0)
        let scoped = AgentKey.derive(
            masterKey: TestKeys.alicePrivateKey,
            path: .deviceScoped(index: 0, deviceScope: "a1b2c3d4")
        )
        #expect(legacy != scoped)
    }

    @Test func deviceScoped_twoDevicesSameMasterSameIndex_disjointAddresses() throws {
        // The whole point of v2: Mac A's agent #0 and Mac B's agent #0 must
        // NOT collide even though both derive from the same master.
        let master = TestKeys.alicePrivateKey
        let onA = try AgentKey.deriveAddress(master: master, index: 0, scope: "aaaa0001")
        let onB = try AgentKey.deriveAddress(master: master, index: 0, scope: "bbbb0002")
        #expect(onA.lowercased() != onB.lowercased())

        // And across a handful of indices on both devices no address repeats.
        var seen = Set<String>()
        for scope in ["aaaa0001", "bbbb0002"] {
            for index: UInt32 in 0..<8 {
                let address = try AgentKey.deriveAddress(master: master, index: index, scope: scope)
                #expect(seen.insert(address.lowercased()).inserted, "collision at \(scope)/\(index)")
            }
        }
    }

    @Test func deviceScoped_scopeBoundaryIsUnambiguous() {
        // "ab" + index 0x01020304 must not equal "ab\u{01}" + a shifted index —
        // the zero terminator after the scope keeps the layouts apart.
        let master = TestKeys.alicePrivateKey
        let a = AgentKey.derive(masterKey: master, path: .deviceScoped(index: 1, deviceScope: "ab"))
        let b = AgentKey.derive(masterKey: master, path: .deviceScoped(index: 1, deviceScope: "ab\u{00}"))
        let c = AgentKey.derive(masterKey: master, path: .deviceScoped(index: 1, deviceScope: "a"))
        #expect(a != b)
        #expect(a != c)
    }

    @Test func pathBased_legacyPath_matchesIndexOverload() throws {
        // `AgentKeyPath.legacy` must reproduce the exact v1 bytes so every
        // pre-existing agent keeps its address.
        let viaIndex = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 5)
        let viaPath = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, path: .legacy(index: 5))
        #expect(viaIndex == viaPath)
        #expect(!AgentKeyPath.legacy(index: 5).isDeviceScoped)
        #expect(AgentKeyPath.deviceScoped(index: 5, deviceScope: "x").isDeviceScoped)
        // An empty scope is not a scope — falls back to v1 rather than
        // silently minting a third layout.
        #expect(!AgentKeyPath(index: 5, deviceScope: "").isDeviceScoped)
        let viaEmptyScope = try AgentKey.deriveAddress(
            masterKey: TestKeys.alicePrivateKey, path: AgentKeyPath(index: 5, deviceScope: "")
        )
        #expect(viaEmptyScope == viaIndex)
    }

    @Test func legacy_v1_vector_isStable() throws {
        // Pin the v1 layout: HMAC-SHA512(master, "osaurus-agent-v1" || BE32(index))[0..<32].
        let master = TestKeys.alicePrivateKey
        var indexBytes = Data(count: 4)
        indexBytes.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(7).bigEndian, as: UInt32.self) }
        let mac = HMAC<SHA512>.authenticationCode(
            for: Data("osaurus-agent-v1".utf8) + indexBytes,
            using: SymmetricKey(data: master)
        )
        let expected = Data(mac.prefix(32))
        #expect(AgentKey.derive(masterKey: master, index: 7) == expected)
    }

    @Test func deviceScoped_v2_vector_isStable() throws {
        // Pin the v2 layout:
        // HMAC-SHA512(master, "osaurus-agent-v2" || utf8(scope) || 0x00 || BE32(index))[0..<32].
        let master = TestKeys.alicePrivateKey
        var indexBytes = Data(count: 4)
        indexBytes.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(7).bigEndian, as: UInt32.self) }
        let mac = HMAC<SHA512>.authenticationCode(
            for: Data("osaurus-agent-v2".utf8) + Data("a1b2c3d4".utf8) + Data([0x00]) + indexBytes,
            using: SymmetricKey(data: master)
        )
        let expected = Data(mac.prefix(32))
        let actual = AgentKey.derive(
            masterKey: master, path: .deviceScoped(index: 7, deviceScope: "a1b2c3d4")
        )
        #expect(actual == expected)
    }

    @Test func deviceScoped_sign_recoversToScopedAddress() throws {
        let master = TestKeys.alicePrivateKey
        let path = AgentKeyPath.deviceScoped(index: 2, deviceScope: "a1b2c3d4")
        let address = try AgentKey.deriveAddress(masterKey: master, path: path)
        let payload = Data("scoped payload".utf8)
        let signature = try AgentKey.sign(payload: payload, masterKey: master, path: path)
        let recovered = try recoverAddress(
            payload: payload, signature: signature, domainPrefix: "Osaurus Signed Access"
        )
        #expect(recovered.lowercased() == address.lowercased())
    }

    @Test func agentKeyPath_roundTripsThroughAgentModel() throws {
        var agent = Agent(name: "Scoped", autonomousExec: AutonomousExecConfig(enabled: false))
        #expect(agent.agentKeyPath == nil)
        agent.agentIndex = 4
        #expect(agent.agentKeyPath == .legacy(index: 4))
        agent.agentDeviceScope = "a1b2c3d4"
        #expect(agent.agentKeyPath == .deviceScoped(index: 4, deviceScope: "a1b2c3d4"))

        // Persisted JSON carries the scope; pre-scope JSON decodes as legacy.
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Agent.self, from: encoder.encode(agent))
        #expect(decoded.agentKeyPath == .deviceScoped(index: 4, deviceScope: "a1b2c3d4"))

        var legacyJSON = try JSONSerialization.jsonObject(with: encoder.encode(agent)) as! [String: Any]
        legacyJSON.removeValue(forKey: "agentDeviceScope")
        let legacyDecoded = try decoder.decode(
            Agent.self, from: JSONSerialization.data(withJSONObject: legacyJSON)
        )
        #expect(legacyDecoded.agentKeyPath == .legacy(index: 4))
    }

    // MARK: - Signing & Recovery

    @Test func sign_recoversToAgentAddress() throws {
        let masterKey = TestKeys.alicePrivateKey
        let index: UInt32 = 0
        let agentAddress = try AgentKey.deriveAddress(masterKey: masterKey, index: index)

        let payload = Data("agent payload".utf8)
        let signature = try AgentKey.sign(payload: payload, masterKey: masterKey, index: index)

        #expect(signature.count == 65)

        let recovered = try recoverAddress(
            payload: payload,
            signature: signature,
            domainPrefix: "Osaurus Signed Access"
        )
        #expect(recovered.lowercased() == agentAddress.lowercased())
    }

    @Test func sign_differentAgents_differentSignatures() throws {
        let masterKey = TestKeys.alicePrivateKey
        let payload = Data("same payload".utf8)

        let sig0 = try AgentKey.sign(payload: payload, masterKey: masterKey, index: 0)
        let sig1 = try AgentKey.sign(payload: payload, masterKey: masterKey, index: 1)
        #expect(sig0 != sig1)
    }

    @Test func sign_agentSignature_doesNotRecoverToMaster() throws {
        let masterKey = TestKeys.alicePrivateKey
        let masterAddress = TestKeys.aliceAddress

        let payload = Data("agent-only".utf8)
        let signature = try AgentKey.sign(payload: payload, masterKey: masterKey, index: 0)

        let recovered = try recoverAddress(
            payload: payload,
            signature: signature,
            domainPrefix: "Osaurus Signed Access"
        )
        #expect(recovered.lowercased() != masterAddress.lowercased())
    }
}
