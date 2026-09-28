import Foundation
import Testing

@testable import OsaurusCore

@Suite("Residency idle wait cancellation")
struct ResidencyIdleCancellationTests {
    @Test(arguments: [false, true])
    func swapIdleWaitPreservesCancellation(cancel: Bool) async {
        let outcome = await Task {
            do {
                _ = try await ChatResidencyHandoff.unloadResidentChatModels(
                    maxElapsedSeconds: 1,
                    waitForIdle: { _ in
                        await Task.yield()
                        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                        return false
                    }
                )
                return "unexpected-success"
            } catch is CancellationError {
                return "cancelled"
            } catch ChatResidencyHandoff.HandoffError.chatBusy {
                return "busy"
            } catch { return "unexpected-error: \(error)" }
        }.value
        #expect(outcome == (cancel ? "cancelled" : "busy"))
    }

    @Test(arguments: [0, 1, 2])
    func coexistenceIdleWaitPreservesCancellation(scenario: Int) async {
        let cancel = scenario != 0
        let wentIdle = scenario == 2
        let outcome = await Task {
            let handoff = CoexistenceHandoff(
                maxElapsedSeconds: 1,
                waitForIdle: { _ in
                    await Task.yield()
                    if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                    return wentIdle
                },
                retain: { _, _ in
                    Issue.record("A failed idle wait must not retain the parent")
                    throw CancellationError()
                },
                finish: { _ in Issue.record("No retained parent exists to finish") }
            )
            do {
                let _: String = try await handoff.withRetainedParent(
                    scope: SubagentScope(sessionId: "idle", toolCallId: "idle", agentId: Agent.defaultId),
                    resolved: ResolvedModel(name: "unused", id: "unused", isLocal: true),
                    feed: SubagentFeed(toolCallId: "idle", kindId: "test", title: "Idle wait")
                ) {
                    Issue.record("A failed idle wait must not start a child")
                    return "unexpected-body"
                }
                return "unexpected-success"
            } catch is CancellationError {
                return "cancelled"
            } catch SubagentError.unavailable {
                return "busy"
            } catch { return "unexpected-error: \(error)" }
        }.value
        #expect(outcome == (cancel ? "cancelled" : "busy"))
    }
}
