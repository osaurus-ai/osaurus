//
//  LocalSetupBridge.swift
//  osaurus
//
//  The temporary Osaurus Cloud model that stands in for a pinned local
//  model while its download is still in flight, paused, or failed. The
//  first-run chat runs on it (`ChatSession`); delegated agents and
//  workflow slots resolve through it too, so a teammate pinned to the same
//  model does not fail on a bundle that is not on disk yet. Nothing is
//  persisted: once the bundle lands every consumer is back on it.
//

import Foundation

@MainActor
enum LocalSetupBridge {
    /// Workflows behind the first run's asks that read nothing personal
    /// (Scout's Research Brief). Their local-only writer may run on the
    /// stand-in; every other local-only slot waits for the private model.
    static let bridgeableTemplateIDs: Set<UUID> = Set(
        OnboardingPaths.all.flatMap(\.asks).filter { !$0.readsPersonalData }.compactMap(\.workflowId))

    /// Whether `model` is a local model that is not usable yet: absent from
    /// `availableIds` with its download in flight, paused, or failed.
    static func isPending(
        _ model: String?,
        availableIds: [String],
        downloadState: (String) -> DownloadState? = { ModelManager.shared.downloadStates[$0] }
    ) -> Bool {
        guard let model, !model.isEmpty, !availableIds.contains(model) else { return false }
        switch downloadState(model) {
        case .downloading, .paused, .failed:
            return true
        case .completed, .notStarted, nil:
            return false
        }
    }

    /// The Osaurus Router model to run on while `model` downloads, or nil
    /// when `model` is not pending or no Router model is listed.
    static func standIn(
        for model: String?,
        items: [ModelPickerItem] = ModelPickerItemCache.shared.items,
        downloadState: (String) -> DownloadState? = { ModelManager.shared.downloadStates[$0] }
    ) -> String? {
        guard isPending(model, availableIds: items.map(\.id), downloadState: downloadState) else { return nil }
        return ChatSession.osaurusRouterValueCandidate(in: items)?.id
    }

    /// The model to run `model`'s work on now: its stand-in while it
    /// downloads, else `model` itself.
    static func runModel(
        for model: String?,
        items: [ModelPickerItem] = ModelPickerItemCache.shared.items,
        downloadState: (String) -> DownloadState? = { ModelManager.shared.downloadStates[$0] }
    ) -> String? {
        standIn(for: model, items: items, downloadState: downloadState) ?? model
    }

    /// The model an agent's delegated work runs on now. An agent locked to
    /// its model runs on it or fails; it never moves to the stand-in.
    static func runModel(
        forAgent id: UUID,
        items: [ModelPickerItem] = ModelPickerItemCache.shared.items,
        downloadState: (String) -> DownloadState? = { ModelManager.shared.downloadStates[$0] }
    ) -> String? {
        let model = AgentManager.shared.effectiveModel(for: id)
        guard AgentManager.shared.lockedModel(for: id) == nil else { return model }
        return runModel(for: model, items: items, downloadState: downloadState)
    }
}
