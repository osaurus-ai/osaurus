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

}
