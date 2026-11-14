import Foundation

/// One host's existing admission, inherited by its real delegated chat.
/// This is ownership of a slot already granted by SubagentAdmission, not a
/// bypass: a nested handoff yields only this slot and admits normally against
/// all peers. A soft-cancelled owner cannot release a borrower's GPU tail.
actor SubagentAdmissionLease {
    private let gate: SubagentAdmission
    private let modelKey: String?
    private let requiresCleanupAdmission: Bool
    private var admissionClass: SubagentAdmissionClass
    private var slots: Int
    private var held = true
    private var borrowing = false
    private var closing = false
    private var finished = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var reclaimTask: Task<SubagentAdmission.Outcome, Never>?

    init(gate: SubagentAdmission, admissionClass: SubagentAdmissionClass, modelKey: String?, slots: Int, requiresCleanupAdmission: Bool) {
        self.gate = gate
        self.admissionClass = admissionClass
        self.modelKey = modelKey
        self.requiresCleanupAdmission = requiresCleanupAdmission
        self.slots = slots
    }

    func belongs(to controller: SubagentAdmission) -> Bool { gate === controller }

    /// Only one nested operation yields this owner at a time. Parallel image
    /// calls must not each refund the same in-place reservation.
    func suspending<Value: Sendable>(
        cancellationRequested: @escaping @Sendable () -> Bool,
        onWait: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async -> Value
    ) async throws -> Value {
        var signalledWait = false
        while borrowing {
            if closing || Task.isCancelled || cancellationRequested() { throw CancellationError() }
            if !signalledWait { signalledWait = true; onWait() }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard !closing, held, !Task.isCancelled, !cancellationRequested() else { throw CancellationError() }
        borrowing = true
        held = false
        if slots > 0 {
            await gate.releaseLocalInPlace(modelKey: modelKey, slots: slots)
        } else {
            await gate.release(admissionClass, modelKey: modelKey)
        }

        let result = await operation()
        // Task cancellation belongs to the aborted chat/owned runner. A leaf
        // InterruptToken alone does not: that chat may continue after the tool.
        if Task.isCancelled { closing = true }

        // Do not resume the child's next model step without admission, even
        // after Stop. As with the existing in-place -> exclusive upgrade, keep
        // the stronger writer lease for the remainder of this owner run.
        // The cancellation-independent waiter performs no model/GPU work.
        let controller = gate
        let key = modelKey
        while !closing {
            let reclaim = Task.detached {
                await controller.admit(.localExclusive, modelKey: key)
            }
            reclaimTask = reclaim
            let outcome = await withTaskCancellationHandler {
                await reclaim.value
            } onCancel: {
                reclaim.cancel()
            }
            reclaimTask = nil
            if Task.isCancelled { closing = true }
            if outcome == .admitted {
                admissionClass = .localExclusive
                slots = 0
                held = true
                break
            }
        }
        // A terminal owner cannot resume its model. Once the borrower drains,
        // cleanup need not queue behind a peer just to refund this old slot.
        // Closing can race an immediately successful acquire; release that
        // actual writer lease once before completing the owner drain.
        if closing, held {
            held = false
            await gate.release(admissionClass, modelKey: modelKey)
        }
        borrowing = false
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if closing || Task.isCancelled { throw CancellationError() }
        return result
    }

    /// Called INSIDE the handoff body, before its success/error cleanup can
    /// unload or restore anything. Keep this writer until around() returns.
    func prepareForCleanup(onWait: @escaping @Sendable () -> Void) async {
        closing = true
        reclaimTask?.cancel()
        if borrowing {
            onWait()
            await withCheckedContinuation { drainWaiters.append($0) }
        }
        guard requiresCleanupAdmission else { return }
        if held, admissionClass == .localExclusive { return }
        if held {
            held = false
            if slots > 0 {
                await gate.releaseLocalInPlace(modelKey: modelKey, slots: slots)
            } else {
                await gate.release(admissionClass, modelKey: modelKey)
            }
        }
        let controller = gate
        let key = modelKey
        // This is mandatory owned residency cleanup, not cancelled child work.
        // A cancelled passthrough run never enters this waiter.
        let cleanupAdmission = Task.detached {
            while true {
                let outcome = await controller.admit(.localExclusive, modelKey: key, onWait: { _ in onWait() })
                if outcome == .admitted { return }
            }
        }
        await cleanupAdmission.value
        admissionClass = .localExclusive
        slots = 0
        held = true
    }

    /// The dispatched chat can publish cancelled before its owned tool has
    /// drained. Closing prevents new borrows and waits for that exact tail.
    func finish() async {
        closing = true
        reclaimTask?.cancel()
        if borrowing { await withCheckedContinuation { drainWaiters.append($0) } }
        guard !finished else { return }
        finished = true
        if held {
            held = false
            if slots > 0 {
                await gate.releaseLocalInPlace(modelKey: modelKey, slots: slots)
            } else {
                await gate.release(admissionClass, modelKey: modelKey)
            }
        }
    }
}

enum SubagentAdmissionContext {
    @TaskLocal static var current: SubagentAdmissionLease?
}
