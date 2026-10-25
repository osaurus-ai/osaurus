import Testing

@testable import OsaurusCore

struct GenerationAllocatorWindowsTests {
    @Test func drainedProducerAndOuterCleanupReleaseOnlyOnce() {
        var windows = GenerationAllocatorWindows()
        let request = windows.begin()
        #expect(windows.end(request))
        #expect(!windows.end(request))
    }

    @Test func previousOuterCleanupCannotReturnNextRequestsPool() {
        var windows = GenerationAllocatorWindows()
        let previous = windows.begin()
        #expect(windows.end(previous))
        let next = windows.begin()
        #expect(!windows.end(previous))
        #expect(windows.end(next))
        #expect(!windows.end(next))
    }

    @Test func queuedRequestRemainsOwnerAfterAnotherRequestsTwoCallbacks() {
        var windows = GenerationAllocatorWindows()
        let running = windows.begin()
        let queued = windows.begin()
        #expect(!windows.end(running))
        #expect(!windows.end(running))
        #expect(windows.end(queued))
        #expect(!windows.end(queued))
    }

    @Test func cancellationBackstopCannotFinishAnotherWarmup() {
        var windows = GenerationAllocatorWindows()
        let cancelled = windows.begin()
        let warmup = windows.begin()
        #expect(!windows.end(cancelled))
        #expect(!windows.end(cancelled))
        #expect(windows.end(warmup))
    }

    @Test func preparationFailureReturnsPoolAndRepeatedCleanupIsInert() {
        var windows = GenerationAllocatorWindows()
        let failed = windows.begin()
        #expect(windows.end(failed))
        #expect(!windows.end(failed))
    }

    @Test func nonMTPRequestDoesNotReleaseAnActiveWindow() {
        var windows = GenerationAllocatorWindows()
        let active = windows.begin()
        #expect(!windows.end(nil))
        #expect(windows.end(active))
    }
}
