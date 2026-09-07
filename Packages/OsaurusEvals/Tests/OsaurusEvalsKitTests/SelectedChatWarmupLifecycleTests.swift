import Foundation
import Testing

@testable import OsaurusCore

/// Deterministic lifecycle gate for the live regression where an already
/// selected chat retained a stale green claim after the runtime evicted its
/// model. Under lazy chat loading the controller is a residency observer:
/// selecting or focusing a chat never loads anything, an idle eviction turns
/// the dot grey without scheduling a replacement load, and nothing is ever
/// "warming". This belongs in the eval package as a release preflight, but is
/// intentionally not a CacheProof JSON case: that runner owns request/session
/// cache telemetry and has no window-focus or ChatSession activation surface.
@Suite("Selected-chat idle-eviction residency lifecycle")
@MainActor
struct SelectedChatWarmupLifecycleTests {
    @Test("eviction observed during activation turns the dot grey and loads nothing")
    func evictionDuringActivationLoadsNothing() async {
        let session = EvalWarmupSession()
        let controller = ChatWarmupController()

        // Selecting the model only records the choice.
        controller.handleModelSelectionChange(session: session, to: "org/test-model")
        #expect(controller.state == .cold)
        #expect(controller.selectedModelResident == false)

        let snapshots = EvalResidentSnapshotSequence([
            evalResidencySnapshot(names: ["test-model"], revision: 1),
            evalResidencySnapshot(
                names: [],
                revision: 2,
                reason: .idlePolicy,
                idleDecisionID: 41
            ),
        ])
        controller.chatActivationResidencySnapshot = { _ in
            ModelRuntimeChatActivationResidencySnapshot(
                residency: await snapshots.next(),
                recoverableIdleDecisionID: nil
            )
        }
        controller.runtimeResidencySnapshot = { await snapshots.next() }

        // Focus: the atomic activation snapshot says resident -> green.
        controller.handleSessionBecameActive(session: session, debounce: .seconds(30))
        await controller.awaitSessionActivation()
        #expect(await snapshots.callCount() == 1)
        #expect(controller.selectedModelResident == true)
        #expect(controller.state == .cold)

        // The runtime then publishes the idle removal -> grey, no replacement.
        controller.handleRuntimeResidencyChanged(
            session: session,
            snapshot: await snapshots.next(),
            isSessionActive: true
        )
        await controller.awaitInFlightWarmup()
        #expect(controller.selectedModelResident == false)
        #expect(controller.state == .cold)
        #expect(controller.needsPreSendHandshake == false)
        #expect(controller.sessionActivationTaskForTests == nil)
    }

    @Test("matching idle-decision removal after activation never claims green again")
    func postCoalesceRemovalStaysGrey() async {
        let session = EvalWarmupSession()
        let controller = ChatWarmupController()
        controller.handleModelSelectionChange(session: session, to: "org/test-model")

        // Match ChatWindowManager.windowDidBecomeKey -> ChatSession activation.
        // Both residency snapshots still contain the selected model, so the
        // activation legitimately coalesces. The runtime publishes removal
        // only afterwards — the final TOCTOU a second snapshot cannot close.
        let snapshots = EvalResidentSnapshotSequence([
            evalResidencySnapshot(names: ["test-model"], revision: 10),
            evalResidencySnapshot(names: ["test-model"], revision: 10),
        ])
        controller.chatActivationResidencySnapshot = { _ in
            ModelRuntimeChatActivationResidencySnapshot(
                residency: await snapshots.next(),
                recoverableIdleDecisionID: 71
            )
        }
        controller.runtimeResidencySnapshot = { await snapshots.next() }

        controller.handleSessionBecameActive(session: session, debounce: .seconds(30))
        await controller.awaitSessionActivation()
        #expect(controller.selectedModelResident == true)

        // Duplicate revision from the focus path is accepted (allowDuplicateRevision).
        controller.handleSessionBecameActive(session: session, debounce: .zero)
        await controller.awaitSessionActivation()
        #expect(await snapshots.callCount() == 2)
        #expect(controller.selectedModelResident == true)

        controller.handleRuntimeResidencyChanged(
            session: session,
            snapshot: evalResidencySnapshot(
                names: [],
                revision: 11,
                reason: .idlePolicy,
                idleDecisionID: 71
            ),
            isSessionActive: true
        )
        await controller.awaitInFlightWarmup()
        #expect(controller.selectedModelResident == false)
        #expect(controller.state == .cold)

        // A stale (older-revision) "resident" snapshot cannot resurrect green.
        controller.handleRuntimeResidencyChanged(
            session: session,
            snapshot: evalResidencySnapshot(names: ["test-model"], revision: 10),
            isSessionActive: true
        )
        #expect(controller.selectedModelResident == false)

        // Only a newer load makes it green again — and still without any
        // controller-initiated work.
        controller.handleRuntimeResidencyChanged(
            session: session,
            snapshot: evalResidencySnapshot(names: ["test-model"], revision: 12),
            isSessionActive: true
        )
        #expect(controller.selectedModelResident == true)
        #expect(controller.state == .cold)
        #expect(controller.sessionActivationTaskForTests == nil)
    }

    @Test("no entry point schedules a load, a switch, or a warm state")
    func noEntryPointSchedulesWork() async {
        let session = EvalWarmupSession()
        let controller = ChatWarmupController()

        controller.handleModelSelectionChange(session: session, to: "org/test-model")
        controller.scheduleWarmup(session: session, debounce: .zero)
        controller.handleContextShapeChange(session: session)
        controller.handleRunCompleted(
            session: session, wasCancelled: false, hadError: false, hadToolActivity: true)
        controller.handleSessionBecameActive(session: session, debounce: .zero)
        await controller.awaitSessionActivation()
        await controller.awaitActiveModelSwitch()
        await controller.awaitRetiringWork()
        await controller.awaitInFlightWarmup()
        await controller.awaitRequiredContextWarmup()

        #expect(controller.state == .cold)
        #expect(controller.isWarmForDisplay == false)
        #expect(controller.needsPreSendHandshake == false)
        #expect(controller.sessionActivationTaskForTests == nil)
    }
}

private func evalResidencySnapshot(
    names: [String],
    revision: UInt64,
    reason: ModelRuntimeResidencyChangeReason = .load,
    idleDecisionID: UInt64? = nil
) -> ModelRuntimeResidencySnapshot {
    ModelRuntimeResidencySnapshot(
        names: names,
        revision: revision,
        reason: reason,
        idleDecisionID: idleDecisionID
    )
}

private actor EvalResidentSnapshotSequence {
    private var snapshots: [ModelRuntimeResidencySnapshot]
    private var calls = 0

    init(_ snapshots: [ModelRuntimeResidencySnapshot]) {
        self.snapshots = snapshots
    }

    func next() -> ModelRuntimeResidencySnapshot {
        calls += 1
        precondition(!snapshots.isEmpty, "unexpected residency snapshot request")
        return snapshots.removeFirst()
    }

    func callCount() -> Int { calls }
}

@MainActor
private final class EvalWarmupSession: ChatWarmupSessionContext {
    var selectedModel: String? = "org/test-model"
    var selectedModelIsLocal = true
    var isRemoteAgentTarget = false
    var isStreaming = false

    func isImageGenerationModel(_ id: String?) -> Bool { false }
}
