//
//  ChatResidencyHandoff.swift
//  osaurus
//
//  Shared single-residency model handoff for agent-spawned subagent jobs
//  (image generation/edit and local text delegation). When a LOCAL orchestrator
//  chat model is resident, it must be unloaded so the subagent/task model can
//  take the GPU exclusively, then reloaded after the job so the original turn
//  continues. Cloud/API orchestrators never trigger this — nothing is resident
//  to unload.
//
//  This is the reusable core of the flow `NativeImageJobCoordinator` already
//  performs for image jobs; `TextSubagentKind` (the `spawn` tool) uses it for
//  the text path via the shared `ResidencyHandoff` middleware.
//

import Darwin
import Foundation
import os

/// Models unloaded by a handoff, to be reloaded when the job finishes.
///
/// `restoreModelNames` is the list the restore leg reloads. It defaults to
/// `unloadedModelNames`, and differs only for a RESTORE-ONLY lease: the
/// delegation sequence found the invoking chat model not loaded (evicted by
/// memory pressure, a prior API request, or never warmed) — nothing to
/// unload, but the sequence still ends with the chat model loaded back so
/// the chat turn continues on its own model either way.
struct ChatResidencyLease: Sendable, Equatable {
    var unloadedModelNames: [String]
    var restoreModelNames: [String]
    var unloadedParentIdentity: ModelResidencyIdentity?
    let childOwnershipToken: ModelResidencyOwnershipToken

    init(
        unloadedModelNames: [String],
        restoreModelNames: [String]? = nil,
        unloadedParentIdentity: ModelResidencyIdentity? = nil,
        childOwnershipToken: ModelResidencyOwnershipToken = ModelResidencyOwnershipToken()
    ) {
        self.unloadedModelNames = unloadedModelNames
        self.restoreModelNames = restoreModelNames ?? unloadedModelNames
        self.unloadedParentIdentity = unloadedParentIdentity
        self.childOwnershipToken = childOwnershipToken
    }

    static var empty: ChatResidencyLease {
        ChatResidencyLease(unloadedModelNames: [])
    }
    /// True when there is nothing to reload afterwards.
    var isEmpty: Bool { restoreModelNames.isEmpty }
    /// True when the chat model was NOT loaded when the sequence began and
    /// the lease only carries the restore leg.
    var isRestoreOnly: Bool { unloadedModelNames.isEmpty && !restoreModelNames.isEmpty }
}

enum ChatResidencyHandoff {
    private static let logger = Logger(
        subsystem: "com.dinoki.osaurus",
        category: "ChatResidencyHandoff"
    )

    /// Restore the orchestrator, logging (not swallowing) a failure. Use on the
    /// cleanup / failure paths where the caller can't propagate — a reload
    /// failure leaves the chat model unloaded, which must be diagnosable rather
    /// than silently lost (was `try? await restore(...)`).
    @discardableResult
    static func restoreBestEffort(
        _ lease: ChatResidencyLease,
        onPhase: (_ phase: String, _ detail: String) -> Void = { _, _ in }
    ) async -> [String] {
        do {
            return try await restore(lease, onPhase: onPhase)
        } catch {
            logger.error(
                "Orchestrator restore failed after a subagent job — chat model left unloaded: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    enum HandoffError: Error, CustomStringConvertible, LocalizedError {
        case chatBusy
        case insufficientMemory(neededGB: Double, availableGB: Double)
        case restoreFailed(models: [String])
        case parentNotReclaimable(String)
        case restoreBlocked(parent: String, protectedResidents: [String])
        case ownedChildCleanupFailed(models: [String])
        var description: String {
            switch self {
            case .chatBusy:
                return "local chat generation did not become idle before the subagent memory handoff"
            case let .insufficientMemory(neededGB, availableGB):
                return String(
                    format:
                        "RAM-safety preflight refused the job: the spawn model needs ~%.1f GB but only ~%.1f GB would be available after freeing the chat model. Use a smaller spawn model, free memory, or disable the RAM-safety preflight in Agent Delegation settings.",
                    neededGB,
                    availableGB
                )
            case let .restoreFailed(models):
                return
                    "failed to reload the chat model(s) after the subagent job (the orchestrator may need to be re-selected): "
                    + models.joined(separator: ", ")
            case let .parentNotReclaimable(model):
                return
                    "the exact invoking parent model '\(model)' was no longer owned by "
                    + "the current turn's inference surface, so the handoff refused to "
                    + "unload another process resident"
            case let .restoreBlocked(parent, protectedResidents):
                return
                    "restore of invoking parent '\(parent)' was blocked because unrelated "
                    + "resident model(s) are protected: "
                    + protectedResidents.joined(separator: ", ")
            case let .ownedChildCleanupFailed(models):
                return
                    "the handoff could not safely release its owned child model(s): "
                    + models.joined(separator: ", ")
            }
        }

        /// Preserve the typed handoff reason when this error crosses the
        /// generic tool-envelope boundary. Without `LocalizedError`, Swift's
        /// NSError bridge replaces these actionable messages with an opaque
        /// `HandoffError error N`, leaving the parent model to guess why the
        /// spawn failed.
        var errorDescription: String? { description }
    }

    /// Physical memory macOS can reclaim without swapping non-purgeable
    /// anonymous state. This deliberately matches ModelRuntime's normal-load
    /// estimator: mmap-backed model/file-cache pages can sit on the ACTIVE
    /// queue after a child run and are still reclaimable. Counting only
    /// free+inactive+purgeable made the exact same resident model look as if it
    /// had lost all child capacity after its first delegated turn.
    static func availableMemoryBytes() -> Int64 {
        var vmInfo = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let kr = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        var rawPage: vm_size_t = 0
        host_page_size(host, &rawPage)
        return reclaimableMemoryBytes(
            physicalBytes: Int64(ProcessInfo.processInfo.physicalMemory),
            pageSize: Int64(rawPage),
            wiredPages: Int64(vmInfo.wire_count),
            compressorPages: Int64(vmInfo.compressor_page_count),
            internalPages: Int64(vmInfo.internal_page_count),
            purgeablePages: Int64(vmInfo.purgeable_count)
        )
    }

    /// Pure arithmetic seam for the shared host estimator. Saturating math is
    /// fail-closed: malformed/overflowing kernel counters produce zero
    /// reclaimable bytes rather than an enormous wrapped capacity.
    static func reclaimableMemoryBytes(
        physicalBytes: Int64,
        pageSize: Int64,
        wiredPages: Int64,
        compressorPages: Int64,
        internalPages: Int64,
        purgeablePages: Int64
    ) -> Int64 {
        guard physicalBytes > 0, pageSize > 0 else { return 0 }
        let nonPurgeableInternal = max(0, internalPages - max(0, purgeablePages))
        let (first, overflow1) = max(0, wiredPages).addingReportingOverflow(
            max(0, compressorPages))
        guard !overflow1 else { return 0 }
        let (unreclaimablePages, overflow2) = first.addingReportingOverflow(
            nonPurgeableInternal)
        guard !overflow2 else { return 0 }
        let (unreclaimableBytes, overflow3) = unreclaimablePages
            .multipliedReportingOverflow(by: pageSize)
        guard !overflow3 else { return 0 }
        return max(0, physicalBytes - unreclaimableBytes)
    }

    /// Refuse-before-evict preflight. With `requiredBytes` (the spawn model's
    /// on-disk size) and the bytes that unloading the resident chat models will
    /// free, decide whether the spawn model fits BEFORE anything is unloaded —
    /// so a too-large job never leaves the user with the orchestrator evicted
    /// and nothing loaded. `requiredBytes <= 0` or `enabled == false` skips the
    /// check. Throws `.insufficientMemory` when it won't fit.
    static func memoryPreflight(
        requiredBytes: Int64,
        enabled: Bool,
        onPhase: (_ phase: String, _ detail: String) -> Void = { _, _ in }
    ) async throws {
        guard enabled, requiredBytes > 0 else { return }
        // Models occupy more resident RAM than their on-disk weights (KV +
        // activations + framework overhead); inflate the on-disk estimate.
        let inflation = 1.3
        let headroom: Int64 = 3 * 1024 * 1024 * 1024  // keep 3 GB for the OS/app
        let needed = Int64(Double(requiredBytes) * inflation) + headroom
        let residentChatBytes = await ModelRuntime.shared.chatOwnedCachedModelSummaries()
            .reduce(Int64(0)) { $0 + $1.bytes }
        let projected = availableMemoryBytes() + residentChatBytes
        if projected < needed {
            let neededGB = Double(needed) / 1_073_741_824
            let availableGB = Double(projected) / 1_073_741_824
            onPhase(
                "ram_preflight_refused",
                String(format: "need ~%.1f GB, ~%.1f GB available", neededGB, availableGB)
            )
            throw HandoffError.insufficientMemory(neededGB: neededGB, availableGB: availableGB)
        }
    }

    /// Best-effort on-disk size (bytes) of an installed chat model, used as the
    /// spawn-model `requiredBytes` for the text/spawn RAM preflight. Falls back to
    /// summing the model directory when the catalog has no size estimate (e.g. a
    /// manually-placed bundle). Returns 0 when unknown → the preflight is skipped.
    static func estimatedChatModelBytes(named name: String) -> Int64 {
        let models = ModelManager.discoverLocalModels()
        guard let model = models.first(where: { $0.name == name || $0.id == name }) else {
            return 0
        }
        if let bytes = model.totalSizeEstimateBytes { return bytes }
        return directorySizeBytes(model.localDirectory)
    }

    private static func directorySizeBytes(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// Wait for chat generation to go idle, then unload every resident chat model
    /// so the subagent/task model is the single resident GPU producer. Returns the
    /// lease of unloaded names (empty when nothing was resident — e.g. a cloud
    /// orchestrator).
    ///
    /// `restoreParentWhenNotResident` is the delegation sequence's parity leg:
    /// when the invoking parent is an INSTALLED local model that is simply not
    /// loaded right now, return a restore-only lease (nothing unloaded, parent
    /// queued for reload) instead of refusing, so the sequence ends with the
    /// chat model loaded back whether or not it was loaded at the start.
    /// Image jobs keep the default (`false`) and their historical behaviour.
    static func unloadResidentChatModels(
        parentModelName: String? = nil,
        maxElapsedSeconds: Int,
        restoreParentWhenNotResident: Bool = false,
        onPhase: (_ phase: String, _ detail: String) -> Void = { _, _ in }
    ) async throws -> ChatResidencyLease {
        let waitMs = max(15, min(maxElapsedSeconds, 300)) * 1000
        onPhase("waiting_for_chat_idle", "waiting for local chat generation to become idle")
        let wentIdle = await InferenceLoadCoordinator.shared.waitForChatIdle(timeoutMs: waitMs)
        guard wentIdle else { throw HandoffError.chatBusy }

        let requestedParent =
            parentModelName ?? ChatExecutionContext.currentModelName
        guard let requestedParent,
            !requestedParent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .empty
        }
        let currentInferenceSource =
            ChatExecutionContext.currentSessionSource?.inferenceSource
        let parentIsOwned: Bool
        if let currentInferenceSource {
            parentIsOwned = await ModelRuntime.shared.isResident(
                named: requestedParent,
                ownedBy: currentInferenceSource
            )
        } else {
            // Bare/direct callers predate typed session provenance. Preserve
            // their legacy chat-owned behavior without widening it.
            parentIsOwned = await ModelRuntime.shared.isChatOwnedResident(
                named: requestedParent
            )
        }
        let parentIdentity = await ModelRuntime.shared.residencyIdentity(
            named: requestedParent
        )
        if parentIdentity == nil, restoreParentWhenNotResident {
            // Main chat model NOT loaded: skip the unload leg, keep the restore
            // leg. Only an installed local bundle can be reloaded; a cloud or
            // unknown parent has nothing to restore and gets an empty lease.
            guard let installed = ModelManager.findInstalledModel(named: requestedParent)
            else {
                return .empty
            }
            onPhase(
                "chat_model_not_loaded",
                "\(installed.name) is not loaded; it will be loaded back after the delegate runs"
            )
            return ChatResidencyLease(
                unloadedModelNames: [],
                restoreModelNames: [installed.name],
                unloadedParentIdentity: nil,
                childOwnershipToken: ModelResidencyOwnershipToken()
            )
        }
        guard let identity = parentIdentity, parentIsOwned else {
            throw HandoffError.parentNotReclaimable(requestedParent)
        }

        let token = ModelResidencyOwnershipToken()
        onPhase("unloading_chat_models", identity.modelName)
        let result = await ModelRuntime.shared.unloadExact(
            identity,
            leaseDrainTimeoutSeconds: Double(max(15, min(maxElapsedSeconds, 300)))
        )
        guard result == .unloaded else {
            throw HandoffError.parentNotReclaimable(requestedParent)
        }
        return ChatResidencyLease(
            unloadedModelNames: [identity.modelName],
            unloadedParentIdentity: identity,
            childOwnershipToken: token
        )
    }

    /// Reload the models that `unloadResidentChatModels` unloaded (or queued
    /// for reload in a restore-only lease). Safe to call with `.empty`
    /// (no-op). Best-effort: callers should also call this on the failure
    /// path so the orchestrator is never left unloaded.
    ///
    /// Two ordered legs of the delegation RAM-safety sequence: first
    /// `releaseOwnedChildModels` (unload the delegate model this handoff
    /// cold-loaded), then `reloadParent` (load the chat model back). Kept as
    /// one call for the image coordinator and other single-step callers; the
    /// spawn handoff drives the two legs separately so the order is visible.
    @discardableResult
    static func restore(
        _ lease: ChatResidencyLease,
        onPhase: (_ phase: String, _ detail: String) -> Void = { _, _ in }
    ) async throws -> [String] {
        _ = try await releaseOwnedChildModels(lease, onPhase: onPhase)
        return try await reloadParent(lease, onPhase: onPhase)
    }

    /// Sequence leg "unload the delegate model": release every model whose
    /// residency this handoff cold-loaded (tracked by the lease's ownership
    /// token). Pre-existing residents are never touched. Returns the names
    /// released.
    @discardableResult
    static func releaseOwnedChildModels(
        _ lease: ChatResidencyLease,
        onPhase: (_ phase: String, _ detail: String) -> Void = { _, _ in }
    ) async throws -> [String] {
        let ownedChildren = await ModelRuntime.shared.childOwnedResidentNames(
            by: lease.childOwnershipToken
        )
        guard !ownedChildren.isEmpty else { return [] }
        onPhase("releasing_delegate_model", ownedChildren.joined(separator: ", "))
        var cleanupFailures: [String] = []
        var released: [String] = []
        for child in ownedChildren {
            let result = await ModelRuntime.shared.unloadChildOwned(
                name: child,
                by: lease.childOwnershipToken,
                leaseDrainTimeoutSeconds: 5
            )
            if result != .unloaded && result != .notResident {
                cleanupFailures.append(child)
            } else {
                released.append(child)
            }
        }
        guard cleanupFailures.isEmpty else {
            throw HandoffError.ownedChildCleanupFailed(models: cleanupFailures)
        }
        return released
    }

    /// Sequence leg "load the main chat model back": reload every name in the
    /// lease's restore list through the normal warm load path (prefix cache
    /// intact; `.handoffRestore` intent). Verified resident after the load.
    @discardableResult
    static func reloadParent(
        _ lease: ChatResidencyLease,
        onPhase: (_ phase: String, _ detail: String) -> Void = { _, _ in }
    ) async throws -> [String] {
        guard !lease.isEmpty else { return [] }
        onPhase("restoring_chat_models", lease.restoreModelNames.joined(separator: ", "))

        // Surface the reload in the chat input's "Loading Model…" indicator.
        // `preload` bypasses `generateEventStream` (which is what normally bumps
        // this counter), so without this the post-job restore looks like a
        // frozen, empty chat while the orchestrator weights reload. Balanced by
        // the `defer` across every exit (success, retry, throw).
        InferenceProgressManager.shared.modelLoadWillStartAsync()
        defer { InferenceProgressManager.shared.modelLoadDidFinishAsync() }

        var restored: [String] = []
        var failures: [String] = []
        for name in lease.restoreModelNames {
            do {
                try await reloadAndVerify(name, ownershipToken: lease.childOwnershipToken)
                restored.append(name)
                continue
            } catch let error as ModelRuntime.HandoffRestoreBlockedError {
                throw HandoffError.restoreBlocked(
                    parent: name,
                    protectedResidents: [error.protectedResident]
                )
            } catch {
                logger.error(
                    "Orchestrator restore: preload threw for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            // One retry before giving up: a transient reload failure (the GPU
            // still settling behind the just-released image/teardown lane, or a
            // racing evict) must not strand the orchestrator unloaded with no
            // resident model and only a log to show for it.
            onPhase("restoring_chat_models_retry", name)
            do {
                try await reloadAndVerify(name, ownershipToken: lease.childOwnershipToken)
                restored.append(name)
            } catch let error as ModelRuntime.HandoffRestoreBlockedError {
                throw HandoffError.restoreBlocked(
                    parent: name,
                    protectedResidents: [error.protectedResident]
                )
            } catch {
                failures.append(name)
            }
        }

        guard failures.isEmpty else {
            onPhase("restore_failed", failures.joined(separator: ", "))
            throw HandoffError.restoreFailed(models: failures)
        }
        return restored
    }

    /// Preload `name` and confirm it is actually resident afterwards. A bare
    /// `preload` that throws — or silently loads nothing — would otherwise be
    /// reported as a successful restore while the chat window has no model
    /// loaded. Returns `true` only when the model is in the live runtime cache
    /// after the load. Never throws: callers branch on the Bool and retry.
    private static func reloadAndVerify(
        _ name: String,
        ownershipToken: ModelResidencyOwnershipToken
    ) async throws {
        try await ModelResidencyOwnershipContext.$childOwnershipToken.withValue(nil) {
            // This decision must be made atomically inside ModelRuntime.
            // `hasLoadInFlight() + preload()` is explicitly diagnostics-only:
            // the observation is stale after the actor hop. The restore intent
            // waits for an already-started cold load instead of cancelling it,
            // then regains the orchestrator in actor order.
            try await ModelRuntime.shared.preload(
                name: name,
                intent: .handoffRestore,
                restoreOwnershipToken: ownershipToken
            )
        }
        let resident = await ModelRuntime.shared.cachedModelSummaries().map(\.name)
        guard resident.contains(where: {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw HandoffError.restoreFailed(models: [name])
        }
    }
}
