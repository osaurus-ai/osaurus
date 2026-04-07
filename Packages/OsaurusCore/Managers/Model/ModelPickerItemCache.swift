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

    @Published private(set) var items: [ModelPickerItem] = []
    @Published private(set) var isLoaded = false

    private var observersRegistered = false

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
                    self?.invalidateCache()
                    await self?.buildModelPickerItems()
                }
            }
        }
    }

    @discardableResult
    func buildModelPickerItems(includeRemote: Bool = true) async -> [ModelPickerItem] {
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

        if includeRemote {
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
        }

        items = options
        isLoaded = true
        return options
    }

    func prewarmModelCache() async {
        await buildModelPickerItems()
    }

    func prewarmLocalModelsOnly() {
        Task { await buildModelPickerItems(includeRemote: false) }
    }

    func invalidateCache() {
        isLoaded = false
        items = []
    }
}
