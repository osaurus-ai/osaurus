//
//  AgentAddressUniquenessTests.swift
//  OsaurusCoreTests
//
//  Issue #3386: pairs of agents showed the same address. A build that
//  couldn't decode some agent files minted their slots again; these pin the
//  mint-time guards and the launch-time repair.
//

import Foundation
import Testing

@testable import OsaurusCore

struct DuplicateAddressDetectionTests {
    private func agent(_ address: String?, createdAt: TimeInterval, builtIn: Bool = false) -> Agent {
        Agent(
            name: "a",
            isBuiltIn: builtIn,
            createdAt: Date(timeIntervalSince1970: createdAt),
            agentAddress: address
        )
    }

    @Test func oldestAgentKeepsTheSharedAddress() {
        let oldest = agent("0xAAA", createdAt: 100)
        let newer = agent("0xaaa", createdAt: 200)
        let newest = agent("0xaaa", createdAt: 300)
        let unique = agent("0xbbb", createdAt: 50)
        let duplicates = IdentityHealthCheck.duplicateAddressAgents([newest, unique, oldest, newer])
        #expect(Set(duplicates.map(\.id)) == [newer.id, newest.id])
    }

    @Test func builtInsAndAgentsWithoutAddressAreIgnored() {
        let agents = [
            agent(nil, createdAt: 1), agent(nil, createdAt: 2),
            agent("0xccc", createdAt: 3, builtIn: true), agent("0xccc", createdAt: 4),
        ]
        #expect(IdentityHealthCheck.duplicateAddressAgents(agents).isEmpty)
    }
}

struct UnclaimedIdentityDerivationTests {
    private let master = Data(repeating: 0x42, count: 32)

    @Test func skipsAFreeIndexWhoseAddressIsAlreadyHeld() throws {
        let held = try AgentKey.deriveAddress(
            masterKey: master,
            path: .deviceScoped(index: 0, deviceScope: "mac-1")
        )
        let claims = AgentManager.IdentityClaims(indexes: [], addresses: [held.lowercased()])
        let minted = try AgentManager.deriveUnclaimedIdentity(masterKey: master, claims: claims, deviceScope: "mac-1")
        #expect(minted.path == .deviceScoped(index: 1, deviceScope: "mac-1"))
        #expect(minted.address.lowercased() != held.lowercased())
    }

    @Test func skipsClaimedIndexes() throws {
        let claims = AgentManager.IdentityClaims(indexes: [0, 1, 3], addresses: [])
        let minted = try AgentManager.deriveUnclaimedIdentity(masterKey: master, claims: claims, deviceScope: nil)
        #expect(minted.path == .legacy(index: 2))
    }
}

@Suite(.serialized)
@MainActor
struct AgentAddressRepairTests {
    @Test func undecodableAgentFileStillClaimsItsSlot() throws {
        let index: UInt32 = 4_000_000_000 + UInt32.random(in: 0 ..< 1_000_000)
        let address = "0x\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())deadbeef"
        // No `id`/`name`: `Agent` can't decode it, like a record from another build.
        let json = #"{"agentIndex":\#(index),"agentAddress":"\#(address)","agentDeviceScope":"mac-x"}"#
        let directory = OsaurusPaths.agents()
        OsaurusPaths.ensureExistsSilent(directory)
        let file = directory.appendingPathComponent("\(UUID().uuidString).json")
        try Data(json.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let reserved = AgentStore.reservedIdentities()
        #expect(reserved.contains(.init(index: index, deviceScope: "mac-x", address: address)))
        let claims = AgentManager.shared.identityClaims()
        #expect(claims.indexes.contains(index))
        #expect(claims.addresses.contains(address))
    }

    @Test func duplicateGetsTheNewAddressAndKeeperIsUntouched() async throws {
        let shared = "0x\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())00000000"
        let keeper = Agent(
            name: "Address Keeper \(UUID().uuidString.prefix(6))",
            createdAt: Date(timeIntervalSince1970: 1_000),
            agentIndex: 3_900_000_000,
            agentAddress: shared
        )
        let duplicate = Agent(
            name: "Address Duplicate \(UUID().uuidString.prefix(6))",
            createdAt: Date(timeIntervalSince1970: 2_000),
            agentIndex: 3_900_000_000,
            agentAddress: shared
        )
        AgentManager.shared.add(keeper)
        AgentManager.shared.add(duplicate)
        RelayTunnelManager.shared.setTunnelEnabled(true, for: duplicate.id)

        let fresh = "0x\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())11111111"
        let path = AgentKeyPath.deviceScoped(index: 3_900_000_001, deviceScope: "mac-1")
        AgentManager.shared.applyReassignedAddresses([(duplicate.id, path, fresh)])

        #expect(AgentManager.shared.agent(for: keeper.id)?.agentAddress == shared)
        let repaired = AgentManager.shared.agent(for: duplicate.id)
        #expect(repaired?.agentAddress == fresh)
        #expect(repaired?.agentKeyPath == path)
        #expect(!RelayTunnelManager.shared.isTunnelEnabled(for: duplicate.id))
        #expect(
            IdentityHealthCheck.duplicateAddressAgents(AgentManager.shared.agents).allSatisfy {
                $0.id != duplicate.id
            }
        )

        // A second pass is a no-op: the agent is no longer a duplicate.
        let other = "0x\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())22222222"
        AgentManager.shared.applyReassignedAddresses([
            (duplicate.id, .deviceScoped(index: 3_900_000_002, deviceScope: "mac-1"), other)
        ])
        #expect(AgentManager.shared.agent(for: duplicate.id)?.agentAddress == fresh)

        _ = await AgentManager.shared.delete(id: keeper.id)
        _ = await AgentManager.shared.delete(id: duplicate.id)
    }
}
