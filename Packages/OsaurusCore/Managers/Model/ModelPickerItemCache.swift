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

    /// Whether at least one ready text-to-image model is installed. A synchronous
    /// read off the already-warmed picker cache, used by the subagent gate to
    /// decide whether the `image` tool is injected at all (no image model ->
    /// no tool, so the model is never told it can make images it can't).
    var hasReadyImageGenerationModel: Bool {
        items.contains(where: \.isImageGenerationDelegateCandidate)
    }

    /// Whether at least one ready image-EDIT model is installed. Gates the edit
    /// affordance specifically (the tool's `source_paths`/`strength` schema, the
    /// edit guidance, and the post-generation edit nudge); generation stays
    /// available via `hasReadyImageGenerationModel` even when this is false.
    var hasReadyImageEditModel: Bool {
        items.contains(where: \.isImageEditDelegateCandidate)
    }

    /// Whether any ready image model (generation or edit) is installed — the
    /// coarse gate for whether the `image` tool is injected at all. Both
    /// `image`-surfacing paths read this instead of re-OR'ing the two flags.
    var hasReadyImageModel: Bool {
        hasReadyImageGenerationModel || hasReadyImageEditModel
    }

    /// Whether at least one curated AppleScript model is installed. AppleScript
    /// bundles are discovered as ordinary `.local` MLX models (so they sit in
    /// `items`) but are hidden from the chat picker via the grouping helpers;
    /// this reads them off the already-warmed `items` so the `applescript`
    /// subagent gate can withhold the tool until a model exists — the model is
    /// never offered automation the runtime can't satisfy.
    var hasReadyAppleScriptModel: Bool {
        items.contains(where: \.isAppleScriptCatalogModel)
    }

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

    #if DEBUG
        /// Test seam: inject picker items directly so unit tests can exercise the
        /// image-availability gates (and other readers) without staging real
        /// on-device bundles. Returns the previous items so the caller can
        /// restore them and avoid leaking seeded state across the shared
        /// singleton into other suites.
        @discardableResult
        func _setItemsForTesting(_ newItems: [ModelPickerItem]) -> [ModelPickerItem] {
            let previous = items
            items = newItems
            isLoaded = true
            return previous
        }
    #endif

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
            // Exclude embedding/encoder-only bundles (e.g. potion-base-4M
            // pulled into the HF cache by the memory feature): they can't
            // generate chat completions. They remain visible in the Models
            // management UI and usable via /v1/embeddings. Reading
            // `isEmbedding` here also warms its memoized verdict off the
            // main actor, like the `isVLM` warm-up below.
            let models = ModelManager.discoverLocalModels()
                .filter { !$0.isEmbedding }
            // Warm the memoized VLM + MLX-format verdicts while still off the
            // main actor: `fromMLXModel` below reads both `isVLM` and
            // `isMLXFormat` on the MainActor, and a cold cache would otherwise
            // fault config.json / safetensors-header reads per model there.
            for model in models {
                _ = model.isVLM
                _ = model.isMLXFormat
            }
            return models
        }.value

        for model in localModels {
            options.append(.fromMLXModel(model))
        }

        // On-device image-generation models (vMLXFlux). Only surface bundles
        // that are fully staged/loadable; incomplete ones stay hidden until
        // their weights are present.
        let imageModels = (try? await ImageGenerationService.shared.availableModels()) ?? []
        for model in imageModels where model.ready {
            options.append(.fromImageModel(model))
        }

        let manager = RemoteProviderManager.shared
        let remoteModels = manager.cachedAvailableModels()
        for providerInfo in remoteModels {
            let isOsaurusRouter = providerInfo.providerId == RemoteProviderManager.osaurusRouterProviderId
            for modelId in providerInfo.models {
                // Osaurus Router models carry pricing/provider/context metadata;
                // enrich the picker row when we have it, otherwise fall back to a
                // plain remote item (e.g. before the catalog has loaded).
                if isOsaurusRouter,
                    let metadata = manager.osaurusRouterMetadata(for: unprefixedRouterModelId(modelId))
                {
                    options.append(
                        .fromOsaurusRouterModel(
                            prefixedId: modelId,
                            providerName: providerInfo.providerName,
                            providerId: providerInfo.providerId,
                            metadata: metadata
                        )
                    )
                } else {
                    options.append(
                        .fromRemoteModel(
                            modelId: modelId,
                            providerName: providerInfo.providerName,
                            providerId: providerInfo.providerId
                        )
                    )
                }
            }
        }

        return options
    }

    /// Strip the provider-name prefix that `cachedAvailableModels()` prepends
    /// (e.g. "osaurus/<upstream>/model-b" -> "<upstream>/model-b") so it matches the
    /// catalog key, which is the model's unprefixed id.
    private static func unprefixedRouterModelId(_ prefixedId: String) -> String {
        guard let slashIndex = prefixedId.firstIndex(of: "/") else { return prefixedId }
        return String(prefixedId[prefixedId.index(after: slashIndex)...])
    }
}
