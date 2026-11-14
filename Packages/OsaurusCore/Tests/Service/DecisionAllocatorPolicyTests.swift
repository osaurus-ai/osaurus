import Foundation
import Testing
import MLXLMCommon

@testable import OsaurusCore

struct DecisionAllocatorPolicyTests {
    private let gib = 1 << 30

    @Test func exposureUsesTheExistingLowercaseSlugVisibilityContract() {
        let id = DecisionService.exposureID(for: "OsaurusAI/d3-flash-JANG_4M")
        #expect(id == "d3-flash-jang_4m")
        #expect(DecisionService.exposureID(for: "d3-flash-JANG_4M") == id)
        let hidden = ModelExposureSettings(overrides: [id: false])
        #expect(!hidden.isExposed(id: id, kind: .local))
        #expect(hidden.isExposed(id: "d3-flash-jang_6m", kind: .local))
    }

    @Test func unsupportedQuestionFieldsAreNotSilentlyIgnored() throws {
        let valid = try DecisionJSON.parse(Data(#"{"type":"noul","instructions":"Is it code?"}"#.utf8))
        try DecisionService.validateQuestionFields(valid)
        for extra in ["images", "videos", "assets", "at", "track", "unknown"] {
            let question = DecisionJSON.object((valid.entries ?? []) + [(extra, .array([]))])
            #expect(throws: (any Error).self) {
                try DecisionService.validateQuestionFields(question)
            }
        }
        #expect(throws: (any Error).self) {
            try DecisionService.validateQuestionFields(.array([]))
        }
    }

    @Test func activeReuseIsBoundedRatherThanTheWholeLoadBudget() {
        #expect(
            DecisionService.allocatorReuseLimit(
                weightsBytes: Int64(24 * gib),
                physicalMemoryBytes: UInt64(128 * gib),
                admittedMemoryLimit: 96 * gib,
                budgetHeadroom: 64 * gib,
                explicitAllocatorBytes: nil
            ) == 8 * gib
        )
    }

    @Test func explicitUserAndResidentCapsRemainHardCeilings() {
        for cap in [0, 128 << 20, gib] {
            #expect(
                DecisionService.allocatorReuseLimit(
                    weightsBytes: Int64(24 * gib),
                    physicalMemoryBytes: UInt64(128 * gib),
                    admittedMemoryLimit: 96 * gib,
                    budgetHeadroom: 64 * gib,
                    explicitAllocatorBytes: UInt64(cap)
                ) == cap
            )
        }
        #expect(
            DecisionService.allocatorReuseLimit(
                weightsBytes: Int64(24 * gib),
                physicalMemoryBytes: UInt64(128 * gib),
                admittedMemoryLimit: 96 * gib,
                budgetHeadroom: 64 * gib,
                explicitAllocatorBytes: nil,
                residentCaps: [gib]
            ) == gib
        )
    }

    @Test func admittedCapacityAndScratchFloorMatchExistingPolicy() {
        #expect(
            DecisionService.allocatorReuseLimit(
                weightsBytes: Int64(24 * gib),
                physicalMemoryBytes: UInt64(128 * gib),
                admittedMemoryLimit: 4 * gib,
                budgetHeadroom: 64 * gib,
                explicitAllocatorBytes: nil
            ) == 4 * gib
        )
        #expect(
            DecisionService.allocatorReuseLimit(
                weightsBytes: Int64(24 * gib),
                physicalMemoryBytes: UInt64(128 * gib),
                admittedMemoryLimit: 96 * gib,
                budgetHeadroom: 0,
                explicitAllocatorBytes: nil
            ) == 2 * gib
        )
    }
}
