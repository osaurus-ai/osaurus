//
//  RunProgressEvaluatorTests.swift
//  osaurusTests
//
//  Pins the composer slow/stalled chip contract: stalled-first, discrete
//  events reset previous then follow 30/120, loading phase suppresses
//  `.slow` only, stream latch needs a burst.
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
        loading: Bool = false
    ) -> RunProgressState {
        RunProgressEvaluator.state(
            idle: idle,
            previous: previous,
            isSustainedStreamBurst: burst,
            clearsLatch: clearsLatch,
            hasVisibleLoadingPhase: loading
        )
    }

    @Test func idleUnderSlowThresholdIsActive() {
        #expect(evaluate(idle: 0) == .active)
        #expect(evaluate(idle: 29) == .active)
    }

    @Test func idleThirtySecondsWithoutActivityIsSlow() {
        #expect(evaluate(idle: 30, previous: .active) == .slow)
    }

    @Test func idleOneTwentyIsStalledEvenDuringLoadingPhase() {
        #expect(evaluate(idle: 120, previous: .active) == .stalled)
        #expect(evaluate(idle: 120, previous: .slow) == .stalled)
        #expect(evaluate(idle: 180, previous: .active, loading: true) == .stalled)
        #expect(evaluate(idle: 180, previous: .slow, loading: true) == .stalled)
    }

    @Test func streamLatchKeepsSlowAfterOneToken() {
        #expect(
            evaluate(idle: 0, previous: .slow, burst: false, clearsLatch: false)
                == .slow
        )
    }

    @Test func streamBurstClearsSlow() {
        #expect(
            evaluate(idle: 0, previous: .slow, burst: true, clearsLatch: false)
                == .active
        )
    }

    @Test func streamLatchKeepsStalledUntilBurst() {
        #expect(
            evaluate(idle: 0, previous: .stalled, burst: false, clearsLatch: false)
                == .stalled
        )
        #expect(
            evaluate(idle: 0, previous: .stalled, burst: true, clearsLatch: false)
                == .active
        )
    }

    @Test func discreteToolCommitUnlatchesStalledWhenIdleIsFresh() {
        #expect(
            evaluate(idle: 0, previous: .stalled, clearsLatch: true)
                == .active
        )
    }

    @Test func discreteDoesNotSkipSlow() {
        #expect(
            evaluate(idle: 60, previous: .stalled, clearsLatch: true, loading: false)
                == .slow
        )
        #expect(
            evaluate(idle: 60, previous: .active, clearsLatch: true, loading: false)
                == .slow
        )
    }

    @Test func discreteExecDripUnlatchesWhenIdleIsUnderSlow() {
        #expect(
            evaluate(idle: 8, previous: .stalled, clearsLatch: true)
                == .active
        )
    }

    @Test func silentToolWithNoOpenToolFlagIsStalled() {
        #expect(
            evaluate(idle: 120, previous: .slow, burst: false, clearsLatch: false)
                == .stalled
        )
    }

    @Test func loadingPhaseSuppressesSlowOnly() {
        #expect(
            evaluate(idle: 45, previous: .active, loading: true)
                == .active
        )
        #expect(
            evaluate(idle: 180, previous: .active, loading: true)
                == .stalled
        )
    }

    @Test func loadingStartClearsPreviousAndDoesNotSnapBack() {
        let afterBootStart = evaluate(
            idle: 0,
            previous: .stalled,
            clearsLatch: true,
            loading: true
        )
        #expect(afterBootStart == .active)

        let afterBootFinishes = evaluate(
            idle: 5,
            previous: afterBootStart,
            clearsLatch: false,
            loading: false
        )
        #expect(afterBootFinishes == .active)
    }

    @Test func burstHelperRequiresThreeStreamTimestampsInWindow() {
        let now = Date()
        let two = [
            now.addingTimeInterval(-2),
            now.addingTimeInterval(-1),
        ]
        #expect(
            !RunProgressEvaluator.isSustainedStreamBurst(timestamps: two, now: now)
        )

        let three = two + [now]
        #expect(
            RunProgressEvaluator.isSustainedStreamBurst(timestamps: three, now: now)
        )

        let stale = [
            now.addingTimeInterval(-20),
            now.addingTimeInterval(-15),
            now.addingTimeInterval(-12),
        ]
        #expect(
            !RunProgressEvaluator.isSustainedStreamBurst(timestamps: stale, now: now)
        )
    }
}
