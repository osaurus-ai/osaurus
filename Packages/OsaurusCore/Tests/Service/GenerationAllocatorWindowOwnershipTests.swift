import Testing

@testable import OsaurusCore

/// Exercise the real ownership state used by ModelRuntime, without submitting
/// GPU work. The restore callback is the production synchronization/clear boundary.
@Suite("Generation allocator window ownership")
struct GenerationAllocatorWindowOwnershipTests {
    @Test func duplicateOuterCleanupCannotRestoreOutsideTheFirstRequestsGate() {
        var windows = ModelRuntimeGenerationAllocatorWindows()
        let requestA = windows.begin()
        var effects: [String] = []
        var gateOwner = "A"
        let acceptedA = windows.finish(requestA) {
            #expect(gateOwner == "A")
            effects += ["sync:A", "clear:A", "restore:A"]
        }
        #expect(acceptedA)
        #expect(windows.count == 0)

        // B acquires the gate after A's engine has drained. A's outer task
        // resumes afterwards; it must neither drain B nor restore A's limit.
        let requestB = windows.begin()
        #expect(requestA != requestB)
        gateOwner = "B"
        let duplicateA = windows.finish(requestA) {
            Issue.record("A's fallback restored the allocator after releasing its gate")
            effects += ["sync:stale-A", "clear:stale-A", "restore:stale-A"]
        }
        #expect(!duplicateA)
        #expect(windows.count == 1)
        #expect(effects == ["sync:A", "clear:A", "restore:A"])
        let acceptedB = windows.finish(requestB) {
            #expect(gateOwner == "B")
            effects += ["sync:B", "clear:B", "restore:B"]
        }
        #expect(acceptedB)
        #expect(windows.count == 0)
        #expect(effects == ["sync:A", "clear:A", "restore:A", "sync:B", "clear:B", "restore:B"])
    }

    @Test func queuedRequestCannotBeRemovedByThePreviousRequestsSecondFinish() {
        var windows = ModelRuntimeGenerationAllocatorWindows()
        let requestA = windows.begin()
        let queuedB = windows.begin()
        var restores = 0
        #expect(windows.count == 2)
        windows.finish(requestA) { restores += 1 }
        #expect(windows.count == 1)
        #expect(restores == 0)
        windows.finish(requestA) {
            Issue.record("Duplicate A cleanup consumed queued B's ownership")
            restores += 1
        }
        #expect(windows.count == 1)
        #expect(restores == 0)
        windows.finish(queuedB) { restores += 1 }
        #expect(windows.count == 0)
        #expect(restores == 1)
    }

    @Test func earlyErrorFallbackStillRestoresExactlyOnce() {
        var windows = ModelRuntimeGenerationAllocatorWindows()
        let request = windows.begin()
        var restores = 0
        // No adapter stream was returned, so the catch/fallback owns cleanup.
        windows.finish(request) { restores += 1 }
        #expect(windows.count == 0)
        #expect(restores == 1)
        windows.finish(request) { restores += 1 }
        #expect(windows.count == 0)
        #expect(restores == 1)
    }

    @Test func warmupAndRequestWindowsRemainIndependentlyOwned() {
        var windows = ModelRuntimeGenerationAllocatorWindows()
        let warmup = windows.begin()
        let request = windows.begin()
        var restores = 0
        windows.finish(warmup) { restores += 1 }
        windows.finish(warmup) { restores += 1 }
        #expect(windows.count == 1)
        #expect(restores == 0)
        windows.finish(request) { restores += 1 }
        #expect(windows.count == 0)
        #expect(restores == 1)
    }

    @Test func absentAndForeignTokensCannotChangeOwnershipOrRestore() {
        var windows = ModelRuntimeGenerationAllocatorWindows()
        var foreignWindows = ModelRuntimeGenerationAllocatorWindows()
        let foreign = foreignWindows.begin()
        let request = windows.begin()
        var restores = 0
        let absent = windows.finish(nil) { restores += 1 }
        let unowned = windows.finish(foreign) { restores += 1 }
        #expect(!absent)
        #expect(!unowned)
        #expect(windows.count == 1)
        #expect(restores == 0)
        #expect(foreignWindows.count == 1)
        windows.finish(request) { restores += 1 }
        #expect(windows.count == 0)
        #expect(restores == 1)
    }
}
