import Testing

@testable import OsaurusCore

struct GenerationAllocatorWindowsTests {
    @Test func drainedProducerAndOuterCleanupReleaseOnlyOnce() {
        var windows = GenerationAllocatorWindows()
        let request = windows.begin()
        let returnedPool1 = windows.end(request)
        #expect(returnedPool1)
        let returnedPool2 = windows.end(request)
        #expect(!returnedPool2)
    }

    @Test func previousOuterCleanupCannotReturnNextRequestsPool() {
        var windows = GenerationAllocatorWindows()
        let previous = windows.begin()
        let returnedPool3 = windows.end(previous)
        #expect(returnedPool3)
        let next = windows.begin()
        let returnedPool4 = windows.end(previous)
        #expect(!returnedPool4)
        let returnedPool5 = windows.end(next)
        #expect(returnedPool5)
        let returnedPool6 = windows.end(next)
        #expect(!returnedPool6)
    }

    @Test func queuedRequestRemainsOwnerAfterAnotherRequestsTwoCallbacks() {
        var windows = GenerationAllocatorWindows()
        let running = windows.begin()
        let queued = windows.begin()
        let returnedPool7 = windows.end(running)
        #expect(!returnedPool7)
        let returnedPool8 = windows.end(running)
        #expect(!returnedPool8)
        let returnedPool9 = windows.end(queued)
        #expect(returnedPool9)
        let returnedPool10 = windows.end(queued)
        #expect(!returnedPool10)
    }

    @Test func cancellationBackstopCannotFinishAnotherWarmup() {
        var windows = GenerationAllocatorWindows()
        let cancelled = windows.begin()
        let warmup = windows.begin()
        let returnedPool11 = windows.end(cancelled)
        #expect(!returnedPool11)
        let returnedPool12 = windows.end(cancelled)
        #expect(!returnedPool12)
        let returnedPool13 = windows.end(warmup)
        #expect(returnedPool13)
    }

    @Test func preparationFailureReturnsPoolAndRepeatedCleanupIsInert() {
        var windows = GenerationAllocatorWindows()
        let failed = windows.begin()
        let returnedPool14 = windows.end(failed)
        #expect(returnedPool14)
        let returnedPool15 = windows.end(failed)
        #expect(!returnedPool15)
    }

    @Test func nonMTPRequestDoesNotReleaseAnActiveWindow() {
        var windows = GenerationAllocatorWindows()
        let active = windows.begin()
        let returnedPool16 = windows.end(nil)
        #expect(!returnedPool16)
        let returnedPool17 = windows.end(active)
        #expect(returnedPool17)
    }

    @Test func aForeignWindowCannotReleaseThisRegistrysPool() {
        var first = GenerationAllocatorWindows()
        var second = GenerationAllocatorWindows()
        let owner = first.begin()
        let foreign = second.begin()
        let foreignRelease = first.end(foreign)
        #expect(!foreignRelease)
        let ownerRelease = first.end(owner)
        #expect(ownerRelease)
        let ownForeignRelease = second.end(foreign)
        #expect(ownForeignRelease)
    }

    @Test func reverseCompletionOrderStillReleasesOnlyLastUniqueOwner() {
        var windows = GenerationAllocatorWindows()
        let first = windows.begin()
        let second = windows.begin()
        let firstSecondCallback = windows.end(second)
        #expect(!firstSecondCallback)
        let duplicateSecondCallback = windows.end(second)
        #expect(!duplicateSecondCallback)
        let firstCallback = windows.end(first)
        #expect(firstCallback)
        let repeatedSecondCallback = windows.end(second)
        #expect(!repeatedSecondCallback)
        let repeatedFirstCallback = windows.end(first)
        #expect(!repeatedFirstCallback)
    }
}
