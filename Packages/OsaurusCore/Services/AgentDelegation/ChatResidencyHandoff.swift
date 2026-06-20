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
//  performs for image jobs; `LocalTextDelegateTool` uses it for the text path.
//

import Foundation

/// Models unloaded by a handoff, to be reloaded when the job finishes.
struct ChatResidencyLease: Sendable, Equatable {
    var unloadedModelNames: [String]
    static let empty = ChatResidencyLease(unloadedModelNames: [])
    var isEmpty: Bool { unloadedModelNames.isEmpty }
}

enum ChatResidencyHandoff {
    enum HandoffError: Error, CustomStringConvertible {
        case chatBusy
        var description: String {
            switch self {
            case .chatBusy:
                return "local chat generation did not become idle before the subagent memory handoff"
            }
        }
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
        var restored: [String] = []
        for name in lease.unloadedModelNames {
            try await ModelRuntime.shared.preload(name: name)
            restored.append(name)
        }
        return restored
    }
}
