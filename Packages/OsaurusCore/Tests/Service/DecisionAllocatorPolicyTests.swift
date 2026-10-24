import Foundation
import Testing

@testable import OsaurusCore

struct DecisionAllocatorPolicyTests {
    private let gib = 1 << 30

    @Test func activeReuseIsBoundedRatherThanTheWholeLoadBudget() {
        #expect(
            DecisionService.allocatorReuseLimit(
                weightsBytes: Int64(24 * gib),
                physicalMemoryBytes: UInt64(128 * gib), admittedMemoryLimit: 96 * gib,
                budgetHeadroom: 64 * gib, explicitAllocatorBytes: nil) == 8 * gib)
    }

    @Test func explicitUserAndResidentCapsRemainHardCeilings() {
        for cap in [0, 128 << 20, gib] {
            #expect(
                DecisionService.allocatorReuseLimit(
                    weightsBytes: Int64(24 * gib),
                    physicalMemoryBytes: UInt64(128 * gib), admittedMemoryLimit: 96 * gib,
                    budgetHeadroom: 64 * gib, explicitAllocatorBytes: UInt64(cap)) == cap)
        }
        #expect(
            DecisionService.allocatorReuseLimit(
                weightsBytes: Int64(24 * gib),
                physicalMemoryBytes: UInt64(128 * gib), admittedMemoryLimit: 96 * gib,
                budgetHeadroom: 64 * gib, explicitAllocatorBytes: nil, residentCaps: [gib]) == gib)
    }

    @Test func admittedCapacityAndScratchFloorMatchExistingPolicy() {
        #expect(
            DecisionService.allocatorReuseLimit(
                weightsBytes: Int64(24 * gib),
                physicalMemoryBytes: UInt64(128 * gib), admittedMemoryLimit: 4 * gib,
                budgetHeadroom: 64 * gib, explicitAllocatorBytes: nil) == 4 * gib)
        #expect(
            DecisionService.allocatorReuseLimit(
                weightsBytes: Int64(24 * gib),
                physicalMemoryBytes: UInt64(128 * gib), admittedMemoryLimit: 96 * gib,
                budgetHeadroom: 0, explicitAllocatorBytes: nil) == 2 * gib)
    }
}
