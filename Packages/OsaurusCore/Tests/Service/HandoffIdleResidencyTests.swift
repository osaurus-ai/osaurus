import Foundation
import Testing

@testable import OsaurusCore

@Suite("Handoff-owned model idle residency")
struct HandoffIdleResidencyTests {
    @Test("an owned helper survives between steps and during its explicit warm interval")
    func ownedHelperHasNoIdleDeadline() async {
        let manager = ModelResidencyManager()
        for configured in [ModelIdleResidencyPolicy.immediately, .defaultWarm, .never] {
            let policy = ModelRuntime.resolvedIdleResidencyPolicy(
                configured: configured,
                source: .chatUI,
                referencedByChat: false,
                hasHandoffOwner: true
            )
            #expect(policy == .never)
            await manager.scheduleIdleUnload(
                modelName: "dedicated-helper",
                policy: policy,
                unload: { _ in Issue.record("Idle policy must not tear down a handoff-owned child") },
                leaseCount: { _ in 0 },
                isResident: { _ in true }
            )
            let entry = await manager.snapshots().first
            #expect(entry?.policy == .never)
            #expect(entry?.unloadAt == nil)
        }
        await manager.cancelAll()
    }

    @Test("revoked ownership restores chat close, normal idle and keep-loaded policies")
    func ordinaryResidencyStillFollowsSettings() {
        #expect(resolve(.defaultWarm, .chatUI, false) == .immediately)
        #expect(resolve(.defaultWarm, .chatUI, true) == .defaultWarm)
        #expect(resolve(.defaultWarm, nil, false) == .defaultWarm)
        #expect(resolve(.never, .chatUI, false) == .never)
        #expect(resolve(.immediately, .chatUI, true) == .immediately)
    }

    private func resolve(
        _ configured: ModelIdleResidencyPolicy,
        _ source: RequestSource?,
        _ referenced: Bool
    ) -> ModelIdleResidencyPolicy {
        ModelRuntime.resolvedIdleResidencyPolicy(
            configured: configured,
            source: source,
            referencedByChat: referenced,
            hasHandoffOwner: false
        )
    }
}
