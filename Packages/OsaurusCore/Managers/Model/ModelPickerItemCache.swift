//
//  ModelPickerItemCache.swift
//  osaurus
//
//  Global cache for model picker items shared across all views.
//

import Foundation

@MainActor
final class ModelPickerItemCache: ObservableObject {
    static let shared = ModelPickerItemCache()

    /// The latest known set of picker items.
    ///
    /// Invariant: `items` is monotonic-ish — it always reflects the result of the
    /// last completed rebuild and is never transiently emptied while a rebuild is
    /// in flight. Concurrent rebuild requests are coalesced through a single
    /// in-flight Task so that the "last writer wins" race that previously caused
    /// remote-provider models to disappear at launch can no longer occur.
    @Published private(set) var items: [ModelPickerItem] = []
    @Published private(set) var isLoaded = false

    private var observersRegistered = false

    /// The currently running rebuild Task, if any. All callers join this task
    /// rather than each spawning their own concurrent build that could race to
    /// assign `items` last.
    private var rebuildTask: Task<[ModelPickerItem], Never>?

    /// Set to `true` while a rebuild is in flight to indicate that another
    /// rebuild should run as soon as the current one completes. This coalesces
    /// bursts of `.remoteProviderModelsChanged` / `.localModelsChanged`
    /// notifications into at most one extra rebuild.
    private var pendingRebuild: Bool = false

    private init() {
        registerObservers()
    }

    private func registerObservers() {
        guard !observersRegistered else { return }
        observersRegistered = true
        for name: Notification.Name in [.localModelsChanged, .remoteProviderModelsChanged] {
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    // Note: do NOT call `invalidateCache()` here. Blanking
                    // `items` mid-rebuild created a window where readers
                    // (e.g. ChatView.init) could observe an empty list. The
                    // serialized rebuild below atomically replaces `items`
                    // when finished and coalesces concurrent requests.
                    await self?.buildModelPickerItems()
                }
            }
        }
    }

    /// Rebuilds the picker items, coalescing concurrent callers. Returns the
    /// latest items computed by the rebuild that this call awaited.
    @discardableResult
    func buildModelPickerItems() async -> [ModelPickerItem] {
        if let existing = rebuildTask {
            // A rebuild is already running — request another pass after it
            // finishes (so we pick up state that changed since it started),
            // then await the same task to avoid a parallel build that could
            // race on assigning `items`.
            pendingRebuild = true
            return await existing.value
        }

        let task = Task<[ModelPickerItem], Never> { @MainActor [weak self] in
            guard let self else { return [] }
            var latest: [ModelPickerItem] = []
            repeat {
                self.pendingRebuild = false
                let options = await Self.computeItems()
                self.items = options
                self.isLoaded = true
                latest = options
            } while self.pendingRebuild
            self.rebuildTask = nil
            return latest
        }
        rebuildTask = task
        return await task.value
    }

    /// Kick off a rebuild without awaiting it. Safe to call at app launch for a
    /// fast first paint — when no remote providers are connected yet this
    /// naturally produces `[foundation + local + 0 remote]`, and a subsequent
    /// notification-driven rebuild adds remote models when they arrive.
    func prewarm() {
        Task { await buildModelPickerItems() }
    }

    /// Await a rebuild. Used by AppDelegate after auto-connecting remote
    /// providers to ensure the cache reflects connected providers even if
    /// notifications were missed for any reason.
    func prewarmModelCache() async {
        await buildModelPickerItems()
    }

    /// Hard reset of the cache. This DOES blank `items` and is intended only
    /// for explicit invalidation paths (e.g. completing onboarding) where the
    /// caller will immediately trigger a rebuild.
    func invalidateCache() {
        isLoaded = false
        items = []
    }

    // MARK: - Private

    /// Computes a fresh list of picker items by combining the foundation model
    /// (if available), discovered local MLX models, and currently connected
    /// remote provider models. Always reads remote provider state lazily, so
    /// the result reflects whatever providers are connected at the time the
    /// detached local-discovery task resumes on the MainActor.
    @MainActor
    private static func computeItems() async -> [ModelPickerItem] {
        var options: [ModelPickerItem] = []

        if AppConfiguration.shared.foundationModelAvailable {
            options.append(.foundation())
        }

        let localModels = await Task.detached(priority: .userInitiated) {
            ModelManager.discoverLocalModels()
        }.value

        for model in localModels {
            options.append(.fromMLXModel(model))
        }

        let remoteModels = RemoteProviderManager.shared.cachedAvailableModels()
        for providerInfo in remoteModels {
            for modelId in providerInfo.models {
                options.append(
                    .fromRemoteModel(
                        modelId: modelId,
                        providerName: providerInfo.providerName,
                        providerId: providerInfo.providerId
                    )
                )
            }
        }

        return options
    }
}
