//
//  AgentKeyTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

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
