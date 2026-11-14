//
//  SubagentBudgetsRemoteLimitTests.swift
//  OsaurusCoreTests
//
//  `maxRemoteParallelSpawns` decouples cloud fan-out from the local
//  Concurrent Sessions ceiling. Persisted configurations written before the
//  field existed must keep decoding, and the declarative config surface must
//  carry the key both ways.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Subagent budgets: remote fan-out limit")
struct SubagentBudgetsRemoteLimitTests {
    @Test("legacy budgets without the remote field decode to the default remote limit")
    func legacyDecodeFallsBackToDefault() throws {
        let legacy = """
            {"maxDelegateTokens":1024,"maxDelegateTurns":3,"maxToolCalls":4,"maxElapsedSeconds":90,"maxParallelSpawns":5}
            """
        let decoded = try JSONDecoder().decode(SubagentBudgets.self, from: Data(legacy.utf8))
        #expect(decoded.maxParallelSpawns == 5)
        #expect(decoded.maxRemoteParallelSpawns == SubagentBudgets.defaultMaxRemoteParallelSpawns)
        #expect(decoded.maxRemoteParallelSpawns == 8)
        #expect(decoded.maxDelegateTokens == 1024)

        // A malformed remote value falls back on its own, keeping the rest.
        let malformed = """
            {"maxParallelSpawns":2,"maxRemoteParallelSpawns":"lots"}
            """
        let tolerant = try JSONDecoder().decode(SubagentBudgets.self, from: Data(malformed.utf8))
        #expect(tolerant.maxParallelSpawns == 2)
        #expect(tolerant.maxRemoteParallelSpawns == 8)
    }

    @Test("the remote limit round-trips and is clamped independently of the local limit")
    func roundTripAndClamp() throws {
        let budgets = SubagentBudgets(maxParallelSpawns: 3, maxRemoteParallelSpawns: 12)
        let data = try JSONEncoder().encode(budgets)
        let decoded = try JSONDecoder().decode(SubagentBudgets.self, from: data)
        #expect(decoded == budgets)
        #expect(String(decoding: data, as: UTF8.self).contains("maxRemoteParallelSpawns"))

        let wild = SubagentBudgets(maxParallelSpawns: 99, maxRemoteParallelSpawns: 0).normalized
        #expect(wild.maxParallelSpawns == SubagentBudgets.parallelSpawnBounds.upperBound)
        #expect(wild.maxRemoteParallelSpawns == SubagentBudgets.remoteParallelSpawnBounds.lowerBound)
        #expect(wild.maxTotalParallelSpawns == 33)
        #expect(SubagentBudgets.jobCountUpperBound == 64)
    }

    @Test("the shared server limit rewrites only the local ceiling")
    func serverLimitLeavesRemoteAlone() {
        let budgets = SubagentBudgets(maxParallelSpawns: 6, maxRemoteParallelSpawns: 10)
        let limited = SpawnBatchConcurrencyContract.applyingLimit(2, to: budgets)
        #expect(limited.maxParallelSpawns == 2)
        #expect(limited.maxRemoteParallelSpawns == 10)
    }

    @Test("declarative config carries budget_max_remote_parallel_spawns both ways")
    func declarativeKeyRoundTrips() throws {
        var section = DelegationSection()
        section.budgetMaxParallelSpawns = 3
        section.budgetMaxRemoteParallelSpawns = 5
        let data = try JSONEncoder().encode(section)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"budget_max_remote_parallel_spawns\":5"))
        let decoded = try JSONDecoder().decode(DelegationSection.self, from: data)
        #expect(decoded.budgetMaxRemoteParallelSpawns == 5)
        #expect(decoded.budgetMaxParallelSpawns == 3)
    }
}
