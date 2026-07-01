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
struct ChatResidencyLease: Sendable, Equatable {
    var unloadedModelNames: [String]
    static let empty = ChatResidencyLease(unloadedModelNames: [])
    var isEmpty: Bool { unloadedModelNames.isEmpty }
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

    enum HandoffError: Error, CustomStringConvertible {
        case chatBusy
        case insufficientMemory(neededGB: Double, availableGB: Double)
        case restoreFailed(models: [String])
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
            }
        }
    }

    /// Reclaimable physical memory (free + inactive + purgeable) in bytes.
    /// Inactive + purgeable pages are reclaimed under pressure, so they count
    /// as practically available for a new resident model.
    static func availableMemoryBytes() -> Int64 {
        var vmInfo = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        var rawPage: vm_size_t = 0
        host_page_size(mach_host_self(), &rawPage)
        let pageSize = Int64(rawPage)
        return
            (Int64(vmInfo.free_count) + Int64(vmInfo.inactive_count)
            + Int64(vmInfo.purgeable_count)) * pageSize
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
        let residentChatBytes = await ModelRuntime.shared.cachedModelSummaries()
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
    static func unloadResidentChatModels(
        maxElapsedSeconds: Int,
        onPhase: (_ phase: String, _ detail: String) -> Void = { _, _ in }
    ) async throws -> ChatResidencyLease {
        let waitMs = max(15, min(maxElapsedSeconds, 300)) * 1000
        onPhase("waiting_for_chat_idle", "waiting for local chat generation to become idle")
        let wentIdle = await InferenceLoadCoordinator.shared.waitForChatIdle(timeoutMs: waitMs)
        guard wentIdle else { throw HandoffError.chatBusy }

        let resident = await ModelRuntime.shared.cachedModelSummaries()
            .map(\.name)
            .sorted()
        guard !resident.isEmpty else { return .empty }

        onPhase("unloading_chat_models", resident.joined(separator: ", "))
        for name in resident {
            await ModelRuntime.shared.unload(name: name)
        }
        return ChatResidencyLease(unloadedModelNames: resident)
    }

    /// Reload the models that `unloadResidentChatModels` unloaded. Safe to call
    /// with `.empty` (no-op). Best-effort: callers should also call this on the
    /// failure path so the orchestrator is never left unloaded.
    @discardableResult
    static func restore(
        _ lease: ChatResidencyLease,
        onPhase: (_ phase: String, _ detail: String) -> Void = { _, _ in }
    ) async throws -> [String] {
        guard !lease.isEmpty else { return [] }
        onPhase("restoring_chat_models", lease.unloadedModelNames.joined(separator: ", "))

        // Surface the reload in the chat input's "Loading Model…" indicator.
        // `preload` bypasses `generateEventStream` (which is what normally bumps
        // this counter), so without this the post-job restore looks like a
        // frozen, empty chat while the orchestrator weights reload. Balanced by
        // the `defer` across every exit (success, retry, throw).
        InferenceProgressManager.shared.modelLoadWillStartAsync()
        defer { InferenceProgressManager.shared.modelLoadDidFinishAsync() }

        var restored: [String] = []
        var failures: [String] = []
        for name in lease.unloadedModelNames {
            if await reloadAndVerify(name) {
                restored.append(name)
                continue
            }
            // One retry before giving up: a transient reload failure (the GPU
            // still settling behind the just-released image/teardown lane, or a
            // racing evict) must not strand the orchestrator unloaded with no
            // resident model and only a log to show for it.
            onPhase("restoring_chat_models_retry", name)
            if await reloadAndVerify(name) {
                restored.append(name)
            } else {
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
    private static func reloadAndVerify(_ name: String) async -> Bool {
        do {
            try await ModelRuntime.shared.preload(name: name)
        } catch {
            logger.error(
                "Orchestrator restore: preload threw for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        let resident = await ModelRuntime.shared.cachedModelSummaries().map(\.name)
        return resident.contains(name)
    }
}
