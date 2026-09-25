// Keep-warm is an optional delay of an already-authorized swap's restore leg.
// It must not enable swapping, transfer a lease to another parent/session, or
// discard the ownership needed to release the child and restore the parent.

import Foundation
import os

struct AppleScriptWarmResidencyOwner: Sendable, Equatable {
    let sessionId: String
    let agentId: UUID
    let parentModelName: String?

    init(scope: SubagentScope) {
        sessionId = scope.sessionId
        agentId = scope.agentId
        parentModelName = scope.parentModelName.map {
            (ModelManager.findInstalledModel(named: $0)?.name ?? $0).lowercased()
        }
    }
}

actor AppleScriptWarmResidencyCoordinator {
    static let shared = AppleScriptWarmResidencyCoordinator()
    private static let logger = Logger(subsystem: "com.dinoki.osaurus", category: "AppleScriptWarmResidency")

    private struct Hold: Sendable {
        let lease: ChatResidencyLease
        let model: String
        let owner: AppleScriptWarmResidencyOwner
    }

    private struct Restoration {
        let id = UUID()
        let task: Task<Void, Error>
    }

    private var hold: Hold?
    private var timer: Task<Void, Never>?
    private var timerGeneration = 0
    /// Every waiter joins the same owned restore. Cancelling a run or timer
    /// cannot cancel cleanup, and a reentrant waiter cannot start it twice.
    private var restoration: Restoration?
    private var restoreNeedsRetry = false
    private let restore: @Sendable (ChatResidencyLease) async throws -> Void
    private let canAdopt: @Sendable (ChatResidencyLease, String) async -> Bool
    private let sleep: @Sendable (Int) async -> Void

    init(
        restore: @escaping @Sendable (ChatResidencyLease) async throws -> Void = {
            _ = try await ChatResidencyHandoff.restore($0)
        },
        canAdopt: @escaping @Sendable (ChatResidencyLease, String) async -> Bool = { lease, model in
            let canonical = ModelManager.findInstalledModel(named: model)?.name ?? model
            let owned = await ModelRuntime.shared.childOwnedResidentNames(by: lease.childOwnershipToken)
            guard owned.contains(where: { $0.caseInsensitiveCompare(canonical) == .orderedSame }) else {
                return false
            }
            let residents = await ModelRuntime.shared.cachedModelSummaries()
            return !residents.contains { resident in
                lease.restoreModelNames.contains { $0.caseInsensitiveCompare(resident.name) == .orderedSame }
            }
        },
        sleep: @escaping @Sendable (Int) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(max(0, seconds)))
        }
    ) {
        self.restore = restore
        self.canAdopt = canAdopt
        self.sleep = sleep
    }

    /// Called under the kind's exclusive admission lease, before refreshing
    /// residency. A changed toggle, parent/session, model or warm policy must
    /// settle the previous restore first, then price the actual resident set.
    func prepareForRun(model: String, owner: AppleScriptWarmResidencyOwner, allowAdoption: Bool) async throws {
        if restoration != nil || restoreNeedsRetry { try await restoreHeld() }
        guard let candidate = hold else { return }
        if allowAdoption, candidate.owner == owner,
            candidate.model.caseInsensitiveCompare(model) == .orderedSame,
            await canAdopt(candidate.lease, model),
            hold?.lease.childOwnershipToken == candidate.lease.childOwnershipToken,
            restoration == nil
        {
            return
        }
        try await flush()
    }

    func beginRun(
        model: String,
        owner: AppleScriptWarmResidencyOwner,
        allowAdoption: Bool
    ) async throws -> ChatResidencyLease? {
        try await prepareForRun(model: model, owner: owner, allowAdoption: allowAdoption)
        cancelTimer()
        // prepareForRun only leaves a matching, owned hold. A timer that
        // started restoring during its runtime checks has been joined above.
        if restoration != nil { try await restoreHeld() }
        guard let candidate = hold else { return nil }
        hold = nil
        return candidate.lease
    }

    func endRun(
        lease: ChatResidencyLease,
        model: String,
        owner: AppleScriptWarmResidencyOwner,
        keepWarmSeconds: Int
    ) async throws {
        // Never overwrite another pending or failed restore receipt.
        try await flush()
        guard !lease.isEmpty else { return }
        hold = Hold(lease: lease, model: model, owner: owner)
        guard keepWarmSeconds > 0 else {
            try await restoreHeld()
            return
        }
        let generation = timerGeneration
        timer = Task { [weak self, sleep] in
            await sleep(keepWarmSeconds)
            await self?.fireDeferredRestore(generation)
        }
    }

    private func fireDeferredRestore(_ generation: Int) async {
        guard generation == timerGeneration else { return }
        timer = nil
        do {
            try await restoreHeld()
        } catch {
            // Retain the lease for an explicit flush/next-run retry. A log is
            // not a successful restore and must not erase the repair handle.
            Self.logger.error(
                "Deferred AppleScript parent restore failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func cancelTimer() {
        timerGeneration += 1
        timer?.cancel()
        timer = nil
    }

    func flush() async throws {
        cancelTimer()
        try await restoreHeld()
    }

    private func restoreHeld() async throws {
        guard let candidate = hold else { return }
        let operation: Restoration
        if let restoration {
            operation = restoration
        } else {
            operation = Restoration(
                task: Task.detached(priority: .userInitiated) { [restore] in
                    try await restore(candidate.lease)
                }
            )
            restoration = operation
        }
        do {
            try await operation.task.value
            if restoration?.id == operation.id {
                hold = nil
                restoration = nil
                restoreNeedsRetry = false
            }
        } catch {
            if restoration?.id == operation.id {
                restoration = nil
                restoreNeedsRetry = true
            }
            throw error
        }
    }

    func heldModelForTesting() -> String? { hold?.model }
}

/// Uses the same cold-path preflight, exact-parent unload, child ownership and
/// cancellation-independent restore as ordinary text delegation. Only the
/// successful restore leg is allowed to be deferred by the keep-warm policy.
struct AppleScriptWarmResidencyHandoff: SubagentHandoff {
    let plan: ResidencyPlan
    let model: String
    let keepWarmSeconds: Int
    let coordinator: AppleScriptWarmResidencyCoordinator
    let preflight: ResidencyHandoff.Preflight
    let unload: ResidencyHandoff.Unload
    var postUnloadPreflight: ResidencyHandoff.Preflight? = nil

    static func production(
        plan: ResidencyPlan,
        model: String,
        keepWarmSeconds: Int,
        coordinator: AppleScriptWarmResidencyCoordinator = .shared
    ) -> AppleScriptWarmResidencyHandoff {
        let standard = ResidencyHandoff.production(plan: { _ in plan })
        return AppleScriptWarmResidencyHandoff(
            plan: plan,
            model: model,
            keepWarmSeconds: keepWarmSeconds,
            coordinator: coordinator,
            preflight: { requiredBytes, enabled, onPhase in
                try await ChatResidencyHandoff.memoryPreflight(
                    requiredBytes: requiredBytes,
                    enabled: enabled,
                    physicalCapacityOnly: plan.shouldUnload,
                    onPhase: onPhase
                )
            },
            unload: standard.unload,
            postUnloadPreflight: standard.postUnloadPreflight
        )
    }

    func around(
        scope: SubagentScope,
        resolved: ResolvedModel,
        feed: SubagentFeed,
        run body: () async throws -> SubagentResult
    ) async throws -> SubagentResult {
        let owner = AppleScriptWarmResidencyOwner(scope: scope)
        let adopted = try await coordinator.beginRun(
            model: model,
            owner: owner,
            allowAdoption: plan.shouldUnload && keepWarmSeconds > 0
        )
        guard plan.shouldUnload else {
            if !plan.coexists {
                try await preflight(plan.requiredBytes, plan.ramSafetyEnabled) { phase, detail in
                    feed.emitPhase(phase, detail: detail.isEmpty ? nil : detail)
                }
            }
            return try await SubagentResidency.handoff(for: plan).around(
                scope: scope,
                resolved: resolved,
                feed: feed,
                run: body
            )
        }
        if adopted != nil { feed.emitPhase("reusing_applescript_model", detail: model) }
        let emit: (String, String) -> Void = { phase, detail in
            feed.emitPhase(phase, detail: detail.isEmpty ? nil : detail)
        }
        if adopted == nil { try await preflight(plan.requiredBytes, plan.ramSafetyEnabled, emit) }
        let lease: ChatResidencyLease
        if let adopted {
            lease = adopted
        } else {
            lease = try await unload(scope.parentModelName, plan.maxElapsedSeconds, emit)
        }
        let result: SubagentResult
        do {
            if adopted == nil {
                try await postUnloadPreflight?(plan.requiredBytes, plan.ramSafetyEnabled, emit)
            }
            try Task.checkCancellation()
            result = try await ModelResidencyOwnershipContext.$childOwnershipToken.withValue(lease.childOwnershipToken)
            {
                try await body()
            }
        } catch {
            do {
                try await coordinator.endRun(lease: lease, model: model, owner: owner, keepWarmSeconds: 0)
            } catch let restoreError {
                throw ResidencyHandoffFailure.bodyAndRestoreFailed(
                    body: error.localizedDescription,
                    restore: restoreError.localizedDescription
                )
            }
            throw error
        }
        try await coordinator.endRun(
            lease: lease,
            model: model,
            owner: owner,
            keepWarmSeconds: Task.isCancelled ? 0 : keepWarmSeconds
        )
        return result
    }
}
