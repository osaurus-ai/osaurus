import Foundation
import Testing

@testable import OsaurusCore

@Suite("Cross-kind queued residency planning")
struct CrossKindResidencyPlanningTests {
    @Test("all local text-producing subagent kinds participate in post-admission refresh")
    func nonTextKindsRefreshRemoteWithoutTouchingResidency() async throws {
        let kinds: [any SubagentPostAdmissionResidencyPlanning] = [
            BrowserUseKind(goal: "read", evalModel: "remote/test"),
            ComputerUseKind(goal: "read", limits: RunLimits()),
            AppleScriptKind(task: "read", limits: RunLimits()),
        ]
        for kind in kinds {
            let remote = ResolvedModel(name: "remote/test", isLocal: false)
            let plan = try await kind.refreshedResidencyPlanAfterAdmission(for: remote)
            #expect(plan.mode == "in_place")
            #expect(kind.admissionClass(remote) == .remote)
        }
    }

    @Test("post-queue refresh rejects a removed local model instead of falling back to another basename")
    func removedLocalFailsClosed() async {
        let removed = ResolvedModel(
            name: "remote/test",
            id: "removed-\(UUID().uuidString)/model",
            isLocal: true
        )
        await #expect(throws: SubagentError.self) {
            _ = try await SubagentResidency.refreshedPlan(
                for: removed,
                invokingParentModelName: "parent",
                idleWaitSeconds: 120,
                deniedMessage: "no handoff"
            )
        }
    }
}
