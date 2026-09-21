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
        root: String = "/cache/shared",
        pressure: (kind: String, chat: String, seq: Int)? = nil
    ) -> DiskCacheQuotaSnapshot {
        DiskCacheQuotaSnapshot(
            directory: URL(fileURLWithPath: root),
            usage: DiskCacheUsage(
                usedBytes: used,
                maxBytes: limit,
                evictions: evictions,
                isDisabled: disabled,
                pressureKind: pressure?.kind,
                pressureChainId: pressure?.chat,
                pressureSeq: pressure?.seq ?? 0
            )
        )
    }

    /// Fullness and trims are not sufficient evidence of a capacity problem.
    @Test func onlyAnOversizedSnapshotConsumesTheNotice() {
        var policy = DiskCacheQuotaNoticePolicy()
        let me = UUID().uuidString, other = UUID().uuidString
        func expectClaim(_ expected: Bool, _ reading: DiskCacheQuotaSnapshot, session: String?) {
            let claimed = policy.claim(reading, session: session)
            #expect(claimed == expected)
        }
        expectClaim(false, snapshot(used: 100), session: me)
        expectClaim(false, snapshot(used: 40, evictions: 7), session: me)
        expectClaim(false, snapshot(used: 100, pressure: ("activeChainTrimmed", me, 1)), session: me)
        expectClaim(false, snapshot(used: 100, pressure: ("activeTipDropped", other, 2)), session: me)
        expectClaim(false, snapshot(used: 100, pressure: ("activeTipDropped", me, 3)), session: nil)
        expectClaim(false, snapshot(used: 100, disabled: true, pressure: ("activeTipDropped", me, 3)), session: me)
        expectClaim(false, snapshot(used: 100, limit: 0, pressure: ("activeTipDropped", me, 3)), session: me)
        expectClaim(true, snapshot(used: 100, pressure: ("activeTipDropped", me, 3)), session: me)
        expectClaim(false, snapshot(used: 100, pressure: ("activeTipDropped", me, 4)), session: me)
        expectClaim(true, snapshot(used: 100, pressure: ("activeTipDropped", other, 5)), session: other)
        expectClaim(true, snapshot(used: 100, root: "/cache/second", pressure: ("activeTipDropped", me, 6)), session: me)
    }

    @Test func aVisibleNoticeSurvivesOtherChatsAndUpdatesUntilConfirmedResolution() {
        var policy = DiskCacheQuotaNoticePolicy()
        let a = snapshot(used: 0, pressure: ("activeTipDropped", "a", 1))
        let b = snapshot(used: 0, pressure: ("activeTipDropped", "b", 2))
        #expect(policy.presentation(for: a, session: "a")?.usage.pressureSeq == 1)
        #expect(policy.presentation(for: b, session: "b")?.usage.pressureSeq == 2)
        // A newly created view can recover the same already-claimed notice.
        #expect(policy.presentation(for: a, session: "a")?.usage.pressureSeq == 1)
        let updated = snapshot(used: 20, limit: 200, pressure: ("activeTipDropped", "a", 3))
        #expect(policy.presentation(for: updated, session: "a")?.usage.maxBytes == 200)
        #expect(policy.presentation(for: updated, session: "a")?.usage.pressureSeq == 3)
        #expect(policy.presentation(for: snapshot(used: 20, limit: 1000), session: "a") == nil)
        #expect(policy.presentation(for: updated, session: "a") == nil, "one notice per launch, no renewed nag")
        #expect(policy.presentation(for: b, session: "b")?.usage.pressureSeq == 2)
    }

    @Test func theNoticeNamesTheCapWithoutClaimingAllReuseIsLost() {
        let me = UUID().uuidString
        let dropped = snapshot(used: 0, limit: 4_000_000_000, pressure: ("activeTipDropped", me, 1)).usage
        let trimmed = snapshot(used: 100, pressure: ("activeChainTrimmed", me, 1)).usage
        #expect(dropped.pressureAffects(session: me))
        #expect(!trimmed.pressureAffects(session: me), "a trim is not a warning")
        #expect(dropped.pressureText.contains("3.7 GB"), "names the cap that is too small")
        #expect(dropped.pressureText.contains("Increase Disk Cache Size"))
        #expect(!dropped.pressureText.contains("starts from scratch"))
        #expect(!dropped.pressureAffects(session: UUID().uuidString))
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
        let me = UUID().uuidString
        let oldClaim = oldSession.claim(snapshot(used: 100, pressure: ("activeTipDropped", me, 1)), session: me)
        #expect(oldClaim)
        let newClaim = newSession.claim(snapshot(used: 100, pressure: ("activeTipDropped", me, 1)), session: me)
        #expect(newClaim)
    }
}
