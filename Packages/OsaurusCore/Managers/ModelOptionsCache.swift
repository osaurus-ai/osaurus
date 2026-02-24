//
//  ModelOptionsCache.swift
//  osaurus
//
//  Global cache for model options shared across all views.
//

import Foundation

@MainActor
final class ModelOptionsCache: ObservableObject {
    static let shared = ModelOptionsCache()

    @Published private(set) var modelOptions: [ModelOption] = []
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
                    await self?.buildModelOptions()
                }
            }
        }
    }

    @discardableResult
    func buildModelOptions() async -> [ModelOption] {
        var options: [ModelOption] = []

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

        modelOptions = options
        isLoaded = true
        return options
    }

    func prewarmModelCache() async {
        await buildModelOptions()
    }

    func prewarmLocalModelsOnly() {
        Task {
            let localModels = await Task.detached(priority: .userInitiated) {
                ModelManager.discoverLocalModels()
            }.value

            var options: [ModelOption] = []
            if AppConfiguration.shared.foundationModelAvailable {
                options.append(.foundation())
            }
            for model in localModels {
                options.append(.fromMLXModel(model))
            }

            modelOptions = options
            isLoaded = true
        }
    }

    func invalidateCache() {
        isLoaded = false
        modelOptions = []
    }
}
