import Foundation

/// Owns one host reservation across a real delegated chat and its auxiliary
/// local tools. A child must not queue behind the reservation of the parent
/// synchronously waiting for it. The child still uses normal admission/RAM
/// checks, but inside the parent's exclusive residency boundary.
actor SubagentAdmissionLease {
    private let controller: SubagentAdmission
    private let modelKey: String?
    private let parentInterrupt: InterruptToken
    private var admissionClass: SubagentAdmissionClass?
    private let slots: Int
    private let children = SubagentAdmission()
    private var activeChild: InterruptToken?
    private var closing = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        controller: SubagentAdmission,
        admissionClass: SubagentAdmissionClass,
        modelKey: String?,
        slots: Int,
        parentInterrupt: InterruptToken
    ) {
        self.controller = controller
        self.admissionClass = admissionClass
        self.modelKey = modelKey
        self.slots = slots
        self.parentInterrupt = parentInterrupt
    }

    func withNestedRun(
        interrupt: InterruptToken,
        onWait: @escaping @Sendable (String) -> Void,
        operation: @Sendable (SubagentAdmission) async -> String
    ) async throws -> String {
        var reportedWait = false
        while activeChild != nil {
            try checkCancellation(interrupt)
            if !reportedWait {
                reportedWait = true
                onWait("another local tool in this delegated chat")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        try checkCancellation(interrupt)
        activeChild = interrupt
        defer { finishChild() }

        if admissionClass == .localInPlace {
            // Release exactly this parent's shared slots before upgrading.
            // Two parents can therefore upgrade without holding each other's
            // read leases. The writer remains owned until parent cleanup.
            await controller.releaseLocalInPlace(modelKey: modelKey, slots: slots)
            admissionClass = nil
            let controller = controller
            let modelKey = modelKey
            // This transfers an ALREADY-OWNED resource, rather than starting
            // speculative child work. Even on Stop, reacquire ownership before
            // allowing parent continuation / residency restoration. A cancelled
            // admit here would leave that parent running outside the GPU gate.
            await Task.detached {
                while true {
                    let outcome = await controller.admit(
                        .localExclusive, modelKey: modelKey, onWait: onWait
                    )
                    if outcome == .admitted { return }
                }
            }.value
            admissionClass = .localExclusive
        }

        try checkCancellation(interrupt)
        return await operation(children)
    }

    /// Drain before the kind's residency handoff restores the parent model.
    /// A dispatched ChatSession is an unstructured task: terminal UI state
    /// alone must not allow an in-flight browser/desktop tool to outlive it.
    func drainChildren() async {
        closing = true
        activeChild?.interrupt()
        if activeChild != nil {
            // Continuations still wait in an already-cancelled parent task;
            // Task.sleep would immediately throw and spin during cleanup.
            await withCheckedContinuation { drainWaiters.append($0) }
        }
    }

    private func finishChild() {
        activeChild = nil
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func close() async {
        await drainChildren()
        guard let held = admissionClass else { return }
        admissionClass = nil
        if held == .localInPlace {
            await controller.releaseLocalInPlace(modelKey: modelKey, slots: slots)
        } else {
            await controller.release(held, modelKey: modelKey)
        }
    }

    private func checkCancellation(_ interrupt: InterruptToken) throws {
        if closing || parentInterrupt.isInterrupted || interrupt.isInterrupted || Task.isCancelled {
            throw CancellationError()
        }
    }
}
