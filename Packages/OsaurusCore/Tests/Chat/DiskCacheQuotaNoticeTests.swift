import Foundation
import Testing
@testable import OsaurusCore

@Suite struct DiskCacheQuotaNoticeTests {
    private func snapshot(
        used: Int,
        limit: Int = 100,
        evictions: Int = 0,
        disabled: Bool = false,
        root: String = "/cache/shared"
    ) -> DiskCacheQuotaSnapshot {
        DiskCacheQuotaSnapshot(
            directory: URL(fileURLWithPath: root),
            usage: DiskCacheUsage(
                usedBytes: used,
                maxBytes: limit,
                evictions: evictions,
                isDisabled: disabled
            )
        )
    }

    @Test func belowLimitUnknownAndDisabledDoNotConsumeNotice() {
        var policy = DiskCacheQuotaNoticePolicy()
        #expect(!policy.claim(snapshot(used: 99)))
        #expect(!policy.claim(snapshot(used: 100, limit: 0, evictions: 1)))
        #expect(!policy.claim(snapshot(used: 100, evictions: 1, disabled: true)))
        #expect(policy.claim(snapshot(used: 100)))
    }

    @Test func janitorEvictionStillNotifiesAfterUsageDropsBelowLimit() {
        var policy = DiskCacheQuotaNoticePolicy()
        #expect(policy.claim(snapshot(used: 40, evictions: 1)))
        #expect(!policy.claim(snapshot(used: 20, evictions: 2)))
        #expect(!policy.claim(snapshot(used: 101, evictions: 3)))
    }

    @Test func sharedRootDeduplicatesAcrossViewsAndModelsAfterClearAndRefill() {
        var policy = DiskCacheQuotaNoticePolicy()
        #expect(policy.claim(snapshot(used: 100)))
        #expect(!policy.claim(snapshot(used: 0)))
        #expect(!policy.claim(snapshot(used: 100, root: "/cache/other/../shared")))
        #expect(policy.claim(snapshot(used: 200, limit: 200)))
        #expect(policy.claim(snapshot(used: 100, root: "/cache/second")))
    }

    @Test func aNewAppSessionCanRemindAgain() {
        var oldSession = DiskCacheQuotaNoticePolicy()
        var newSession = DiskCacheQuotaNoticePolicy()
        #expect(oldSession.claim(snapshot(used: 100)))
        #expect(newSession.claim(snapshot(used: 100)))
    }
}
