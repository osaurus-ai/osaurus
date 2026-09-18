import Foundation
import Testing
@testable import OsaurusCore

@Suite struct DiskCacheQuotaNoticeTests {
    @Test func pollingRestartsForFreshSameModelChatsAndPresentationGates() {
        let session = UUID()
        let idle = SSDQuotaNoticePollContext(model: "shared-model", session: session, eligible: true)
        #expect(idle != SSDQuotaNoticePollContext(model: "shared-model", session: UUID(), eligible: true))
        #expect(idle != SSDQuotaNoticePollContext(model: "shared-model", session: session, eligible: false))
        #expect(idle != SSDQuotaNoticePollContext(model: "different-model", session: session, eligible: true))
        #expect(idle == SSDQuotaNoticePollContext(model: "shared-model", session: session, eligible: true))
        var changed = idle
        changed.cacheSettings.blockDisk.maxSizePercent = 2
        #expect(idle != changed)
        changed = idle
        changed.cacheSettings.blockDisk.enabled.toggle()
        #expect(idle != changed)
    }

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
        let claimed1 = policy.claim(snapshot(used: 99))
        #expect(!claimed1)
        let claimed2 = policy.claim(snapshot(used: 100, limit: 0, evictions: 1))
        #expect(!claimed2)
        let claimed3 = policy.claim(snapshot(used: 100, evictions: 1, disabled: true))
        #expect(!claimed3)
        let claimed4 = policy.claim(snapshot(used: 100))
        #expect(claimed4)
    }

    @Test func janitorEvictionStillNotifiesAfterUsageDropsBelowLimit() {
        var policy = DiskCacheQuotaNoticePolicy()
        let claimed5 = policy.claim(snapshot(used: 40, evictions: 1))
        #expect(claimed5)
        let claimed6 = policy.claim(snapshot(used: 20, evictions: 2))
        #expect(!claimed6)
        let claimed7 = policy.claim(snapshot(used: 101, evictions: 3))
        #expect(!claimed7)
    }

    @Test func sharedRootDeduplicatesAcrossViewsAndModelsAfterClearAndRefill() {
        var policy = DiskCacheQuotaNoticePolicy()
        let claimed8 = policy.claim(snapshot(used: 100))
        #expect(claimed8)
        let claimed9 = policy.claim(snapshot(used: 0))
        #expect(!claimed9)
        let claimed10 = policy.claim(snapshot(used: 100, root: "/cache/other/../shared"))
        #expect(!claimed10)
        let claimed11 = policy.claim(snapshot(used: 200, limit: 200))
        #expect(claimed11)
        let claimed12 = policy.claim(snapshot(used: 100, root: "/cache/second"))
        #expect(claimed12)
    }

    @Test func dontShowAgainPersistsAcrossLaunches() throws {
        let suite = "disk-cache-quota-notice-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!DiskCacheQuotaNoticeSuppression.isSuppressed(defaults: defaults))
        DiskCacheQuotaNoticeSuppression.suppress(defaults: defaults)
        let relaunched = try #require(UserDefaults(suiteName: suite))
        #expect(DiskCacheQuotaNoticeSuppression.isSuppressed(defaults: relaunched))
    }

    @Test func aNewAppSessionCanRemindAgain() {
        var oldSession = DiskCacheQuotaNoticePolicy()
        var newSession = DiskCacheQuotaNoticePolicy()
        let claimed13 = oldSession.claim(snapshot(used: 100))
        #expect(claimed13)
        let claimed14 = newSession.claim(snapshot(used: 100))
        #expect(claimed14)
    }
}
