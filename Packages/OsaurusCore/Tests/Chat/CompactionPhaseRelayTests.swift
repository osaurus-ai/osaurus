import Testing

@testable import OsaurusCore

struct CompactionPhaseRelayTests {
    @Test @MainActor func phasesAreMonotonicAndLateCallbacksAreInert() {
        var observed: [ContextCompactionPhase] = []
        let relay = CompactionPhaseRelay { observed.append($0) }
        relay.receive(.waiting)
        relay.receive(.preparing)
        relay.receive(.generating)
        relay.receive(.waiting)
        relay.receive(.preparing)
        relay.receive(.generating)
        #expect(observed == [.waitingForLocalWork, .preparingModel, .summarizing])
        relay.invalidate()
        relay.receive(.restoring)
        #expect(observed == [.waitingForLocalWork, .preparingModel, .summarizing])
    }

    @Test @MainActor func restorationIsShownOnlyAfterTheRealNotification() {
        var observed: [ContextCompactionPhase] = []
        let relay = CompactionPhaseRelay { observed.append($0) }
        relay.receive(.generating)
        #expect(observed == [.summarizing])
        relay.receive(.restoring)
        #expect(observed == [.summarizing, .restoringModel])
    }
}
