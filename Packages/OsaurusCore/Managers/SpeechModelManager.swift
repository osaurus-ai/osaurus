//
//  SpeechModelManager.swift
//  osaurus
//
//  Manages FluidAudio Parakeet CoreML model downloads and selection.
//

import Combine
@preconcurrency import FluidAudio
import Foundation
import SwiftUI

/// Download state for a speech model
public enum SpeechDownloadState: Equatable {
    case notStarted
    case downloading(progress: Double)
    case completed
    case failed(error: String)
}

/// Represents a Parakeet ASR model available for use
public struct SpeechModel: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let size: String
    public let isEnglishOnly: Bool
    public let isRecommended: Bool
    public let version: SpeechModelVersion
}

/// Manages FluidAudio Parakeet CoreML model downloads
@MainActor
public final class SpeechModelManager: ObservableObject {
    public static let shared = SpeechModelManager()

    // MARK: - Published Properties

    @Published public var availableModels: [SpeechModel] = []
    @Published public var downloadStates: [String: SpeechDownloadState] = [:]
    @Published public var selectedModelId: String?

    // MARK: - Private Properties

    private var activeDownloadTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Initialization

    private init() {
        availableModels = Self.curatedModels
        loadSelectedModel()
        refreshDownloadStates()
    }

    // MARK: - Public Methods

    /// Refresh download states by checking if models exist in FluidAudio's cache
    public func refreshDownloadStates() {
        for model in availableModels {
            if case .downloading = downloadStates[model.id] {
                continue
            }
            let faVersion: AsrModelVersion = model.version == .v2 ? .v2 : .v3
            let cacheDir = AsrModels.defaultCacheDirectory(for: faVersion)
            let isDownloaded = AsrModels.modelsExist(at: cacheDir, version: faVersion)
            downloadStates[model.id] = isDownloaded ? .completed : .notStarted
        }
    }

    private func loadSelectedModel() {
        let config = SpeechConfigurationStore.load()
        selectedModelId = config.modelVersion.rawValue
    }

    /// Set the default model version and persist
    public func setDefaultModel(_ modelId: String?) {
        selectedModelId = modelId
        var config = SpeechConfigurationStore.load()
        if let modelId, let version = SpeechModelVersion(rawValue: modelId) {
            config.modelVersion = version
        }
        SpeechConfigurationStore.save(config)
    }

    /// Get the currently selected model
    public var selectedModel: SpeechModel? {
        if let id = selectedModelId, let model = availableModels.first(where: { $0.id == id }) {
            return model
        }
        return availableModels.first { $0.isRecommended }
    }

    /// Number of active downloads
    public var activeDownloadsCount: Int {
        downloadStates.values.filter {
            if case .downloading = $0 { return true }
            return false
        }.count
    }

    /// Number of models with completed downloads
    public var downloadedModelsCount: Int {
        downloadStates.values.filter { $0 == .completed }.count
    }

    /// FluidAudio manages its own model cache, so report a nominal size
    public var totalDownloadedSizeString: String {
        let count = downloadedModelsCount
        if count == 0 { return "No models" }
        return "\(count) model\(count == 1 ? "" : "s") ready"
    }

    // MARK: - Download Methods

    /// Download a Parakeet model using FluidAudio's built-in download
    public func downloadModel(_ model: SpeechModel) {
        if case .downloading = downloadStates[model.id] { return }

        activeDownloadTasks[model.id]?.cancel()

        downloadStates[model.id] = .downloading(progress: 0.0)

        let task = Task { [weak self] in
            guard let self else { return }

            do {
                let faVersion: AsrModelVersion = model.version == .v2 ? .v2 : .v3
                _ = try await AsrModels.downloadAndLoad(version: faVersion)
                self.downloadStates[model.id] = .completed
            } catch is CancellationError {
                self.downloadStates[model.id] = .notStarted
            } catch {
                self.downloadStates[model.id] = .failed(error: error.localizedDescription)
            }

            self.activeDownloadTasks[model.id] = nil
        }

        activeDownloadTasks[model.id] = task
    }

    /// Cancel a download
    public func cancelDownload(_ modelId: String) {
        activeDownloadTasks[modelId]?.cancel()
        activeDownloadTasks[modelId] = nil
        downloadStates[modelId] = .notStarted
    }

    /// Reset a model's download state (FluidAudio manages its own cache)
    public func deleteModel(_ model: SpeechModel) {
        cancelDownload(model.id)
        downloadStates[model.id] = .notStarted
        if selectedModelId == model.id {
            setDefaultModel(nil)
        }
    }

    /// Effective download state for a model
    public func effectiveDownloadState(for model: SpeechModel) -> SpeechDownloadState {
        downloadStates[model.id] ?? .notStarted
    }

    // MARK: - Curated Models

    private static let curatedModels: [SpeechModel] = [
        SpeechModel(
            id: SpeechModelVersion.v3.rawValue,
            name: "Parakeet TDT v3 (0.6B)",
            description: "Multilingual model. Supports 25 European languages. Recommended for most users.",
            size: "~600 MB",
            isEnglishOnly: false,
            isRecommended: true,
            version: .v3
        ),
        SpeechModel(
            id: SpeechModelVersion.v2.rawValue,
            name: "Parakeet TDT v2 (0.6B)",
            description: "English-only model. Highest recall for English transcription.",
            size: "~600 MB",
            isEnglishOnly: true,
            isRecommended: false,
            version: .v2
        ),
    ]
}
