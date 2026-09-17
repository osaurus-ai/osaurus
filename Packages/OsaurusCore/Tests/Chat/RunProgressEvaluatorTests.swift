//
//  RunProgressEvaluatorTests.swift
//  osaurusTests
//
//  Pins the composer slow/stalled chip contract.
//

import Foundation
import Testing

@testable import OsaurusCore

struct RunProgressEvaluatorTests {

    private func evaluate(
        idle: TimeInterval,
        previous: RunProgressState = .active,
        burst: Bool = false,
        clearsLatch: Bool = false,
        loading: RunProgressLoadingPhase = .none
    ) -> RunProgressState {
        RunProgressEvaluator.state(
            idle: idle,
            previous: previous,
            isSustainedStreamBurst: burst,
            clearsLatch: clearsLatch,
            loadingPhase: loading
        )
    }

    @Test func idleUnderSlowThresholdIsActive() {
        #expect(evaluate(idle: 0) == .active)
        #expect(evaluate(idle: 29) == .active)
    }

    @Test func idleThirtySecondsWithoutActivityIsSlow() {
        #expect(evaluate(idle: 30, previous: .active) == .slow)
    }

    @Test func idleOneTwentyIsStalledEvenDuringPrefillOrSandbox() {
        #expect(evaluate(idle: 120, previous: .active) == .stalled)
        #expect(evaluate(idle: 120, previous: .slow) == .stalled)
        #expect(evaluate(idle: 180, previous: .active, loading: .prefill) == .stalled)
        #expect(evaluate(idle: 180, previous: .slow, loading: .sandbox) == .stalled)
    }

    @Test func streamLatchKeepsSlowAfterOneToken() {
        #expect(evaluate(idle: 0, previous: .slow) == .slow)
    }

    @Test func streamBurstClearsSlow() {
        #expect(evaluate(idle: 0, previous: .slow, burst: true) == .active)
    }

    @Test func streamLatchKeepsStalledUntilBurst() {
        #expect(evaluate(idle: 0, previous: .stalled) == .stalled)
        #expect(evaluate(idle: 0, previous: .stalled, burst: true) == .active)
    }

    @Test func discreteToolCommitUnlatchesStalledWhenIdleIsFresh() {
        #expect(evaluate(idle: 0, previous: .stalled, clearsLatch: true) == .active)
    }

    @Test func discreteDoesNotSkipSlow() {
        #expect(evaluate(idle: 60, previous: .stalled, clearsLatch: true) == .slow)
        #expect(evaluate(idle: 60, previous: .active, clearsLatch: true) == .slow)
    }

    @Test func discreteExecDripUnlatchesWhenIdleIsUnderSlow() {
        #expect(evaluate(idle: 8, previous: .stalled, clearsLatch: true) == .active)
    }

    @Test func silentToolIsStalled() {
        #expect(evaluate(idle: 120, previous: .slow) == .stalled)
    }

    @Test func loadingPhaseSuppressesSlowOnly() {
        #expect(evaluate(idle: 45, previous: .active, loading: .prefill) == .active)
        #expect(evaluate(idle: 180, previous: .active, loading: .prefill) == .stalled)
    }

    @Test func opaqueModelLoadUsesLongerStallCeiling() {
        #expect(evaluate(idle: 180, previous: .active, loading: .modelLoad) == .active)
        #expect(evaluate(idle: 599, previous: .active, loading: .modelLoad) == .active)
        #expect(evaluate(idle: 600, previous: .active, loading: .modelLoad) == .stalled)
        #expect(evaluate(idle: 180, previous: .active, loading: .prefill) == .stalled)
    }

    @Test func loadingStartClearsPreviousAndDoesNotSnapBack() {
        let afterBootStart = evaluate(
            idle: 0,
            previous: .stalled,
            clearsLatch: true,
            loading: .sandbox
        )
        #expect(afterBootStart == .active)
        #expect(evaluate(idle: 5, previous: afterBootStart) == .active)
    }

    @Test func burstHelperRequiresThreeStreamTimestampsInWindow() {
        let now = Date()
        let two = [now.addingTimeInterval(-2), now.addingTimeInterval(-1)]
        #expect(!RunProgressEvaluator.isSustainedStreamBurst(timestamps: two, now: now))
        #expect(RunProgressEvaluator.isSustainedStreamBurst(timestamps: two + [now], now: now))

        let stale = [
            now.addingTimeInterval(-20),
            now.addingTimeInterval(-15),
            now.addingTimeInterval(-12),
        ]
        #expect(!RunProgressEvaluator.isSustainedStreamBurst(timestamps: stale, now: now))
    }

    @Test func recordStreamTimestampDropsEntriesOutsideTheWindow() {
        var stamps: [Date] = []
        let now = Date()
        RunProgressEvaluator.recordStreamTimestamp(&stamps, at: now.addingTimeInterval(-20))
        RunProgressEvaluator.recordStreamTimestamp(&stamps, at: now)
        #expect(stamps.count == 1)
        #expect(stamps[0] == now)
    }
}
