import Testing
@testable import OsaurusCore

@Suite(.serialized)
struct SubagentEvalSettingsTests {
    @Test func evalControlsUseProductionSnapshotAndRestoreAllFields() async {
        let before = SubagentConfigurationStore.snapshot()
        for ram in [false, true] {
            for handoff in [false, true] {
                for coexist in [false, true] {
                    await SubagentJobEvaluator.withDelegationSettings(.init(
                        ramSafety: ram, handoff: handoff, coexistence: coexist
                    )) {
                        let effective = SubagentConfigurationStore.snapshot()
                        #expect(effective.ramSafetyPreflightEnabled == ram)
                        #expect(effective.localOrchestratorTextHandoffActive == handoff)
                        #expect(effective.subagentCoexistenceEnabled == coexist)
                    }
                    #expect(SubagentConfigurationStore.snapshot() == before)
                }
            }
        }
    }
}
