import Foundation
import Testing

@testable import OsaurusCore

struct CompactionDeadlineTests {
    private enum ProbeError: Error, Equatable { case upstream }

    private func uncancellableSleep(_ seconds: Double) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }

    @Test func admissionTimeDoesNotConsumeGenerationBudget() async throws {
        let value = try await CompactionDeadline.run(waitingSeconds: 3) { enter in
            try await Task.sleep(for: .milliseconds(250))
            enter(.preparing, 3)
            enter(.generating, 0.2)
            try await Task.sleep(for: .milliseconds(50))
            return "summary"
        }
        #expect(value == "summary")
    }

    @Test func restorationHasItsOwnBudget() async throws {
        let value = try await CompactionDeadline.run(waitingSeconds: 3) { enter in
            enter(.generating, 0.2)
            try await Task.sleep(for: .milliseconds(120))
            enter(.restoring, 1)
            try await Task.sleep(for: .milliseconds(180))
            return "summary after parent restoration"
        }
        #expect(value == "summary after parent restoration")
    }

    @Test func waitingTimeoutDoesNotClaimGenerationFailed() async throws {
        do {
            _ = try await CompactionDeadline.run(waitingSeconds: 0.05) { _ in
                try await Task.sleep(for: .seconds(2))
                return "not reached"
            }
            Issue.record("waiting should time out")
        } catch let error as CompactionDeadline.Expired {
            #expect(error.phase == .waiting)
            #expect(error.seconds == 0.05)
        }
    }

    @Test(arguments: [CompactionDeadline.Phase.preparing, .generating, .restoring])
    func timeoutIdentifiesActualPhase(_ phase: CompactionDeadline.Phase) async throws {
        do {
            _ = try await CompactionDeadline.run(waitingSeconds: 3) { enter in
                enter(phase, 0.05)
                try await Task.sleep(for: .seconds(2))
                return "not reached"
            }
            Issue.record("phase should time out")
        } catch let error as CompactionDeadline.Expired {
            #expect(error.phase == phase)
            #expect(error.seconds == 0.05)
        }
    }

    @Test func duplicateAndBackwardPhasesCannotExtendDeadline() async throws {
        do {
            _ = try await CompactionDeadline.run(waitingSeconds: 3) { enter in
                enter(.generating, 0.1)
                try await Task.sleep(for: .milliseconds(30))
                enter(.generating, 300)
                enter(.waiting, 300)
                enter(.preparing, 300)
                try await Task.sleep(for: .seconds(2))
                return "not reached"
            }
            Issue.record("duplicate phases must not postpone expiry")
        } catch let error as CompactionDeadline.Expired {
            #expect(error.phase == .generating)
            #expect(error.seconds == 0.1)
        }
    }

    @Test func immediateCallerCancellationCannotBeLostBeforeContinuationInstall() async throws {
        for _ in 0 ..< 100 {
            let task = Task {
                try await CompactionDeadline.run(waitingSeconds: 10) { _ in
                    try await Task.sleep(for: .seconds(10))
                    return 1
                }
            }
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("cancelled compaction returned a value")
            } catch is CancellationError {
                // Expected; no ten-second parked continuation.
            }
        }
    }

    @Test func upstreamErrorIsPreserved() async throws {
        do {
            _ = try await CompactionDeadline.run(waitingSeconds: 3) { enter -> String in
                enter(.generating, 3)
                throw ProbeError.upstream
            }
            Issue.record("upstream failure should be preserved")
        } catch let error as ProbeError {
            #expect(error == .upstream)
        }
    }

    @Test func noncooperativeCleanupCanDrainWithoutRejoiningTimedOutCaller() async throws {
        actor Probe {
            var drained = false
            func finish() { drained = true }
        }
        let probe = Probe()
        let started = Date()
        do {
            _ = try await CompactionDeadline.run(waitingSeconds: 3) { enter in
                enter(.restoring, 0.05)
                await uncancellableSleep(0.4)
                await probe.finish()
                return 1
            }
            Issue.record("restore should exceed its budget")
        } catch let error as CompactionDeadline.Expired {
            #expect(error.phase == .restoring)
            #expect(Date().timeIntervalSince(started) < 0.35)
            #expect(await probe.drained == false)
        }
        await uncancellableSleep(0.5)
        #expect(await probe.drained)
    }

    @Test func completedOperationDoesNotReceiveLateTimerCancellation() async throws {
        let answer = try await CompactionDeadline.run(waitingSeconds: 0.1) { _ in "done" }
        #expect(answer == "done")
        try await Task.sleep(for: .milliseconds(150))
        #expect(!Task.isCancelled)
    }

    @Test(arguments: [0.0, -1.0, Double.nan, Double.infinity])
    func invalidOrElapsedBudgetCannotBeRescuedByANewStage(_ seconds: Double) async throws {
        do {
            _ = try await CompactionDeadline.run(waitingSeconds: seconds) { enter in
                enter(.generating, 100)
                return "late result"
            }
            Issue.record("an expired admission budget was extended")
        } catch let error as CompactionDeadline.Expired {
            #expect(error.phase == .waiting)
            #expect(error.seconds == 0)
        }
    }
}
