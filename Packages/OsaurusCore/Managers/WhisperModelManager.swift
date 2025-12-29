//
//  WhisperModelManager.swift
//  osaurus
//
//  Manages WhisperKit CoreML model downloads and selection.
//

import Combine
import Foundation
import SwiftUI

@preconcurrency import WhisperKit

/// Download state for a WhisperKit model
public enum WhisperDownloadState: Equatable {
    case notStarted
    case downloading(progress: Double)
    case completed
    case failed(error: String)
}

/// Represents a WhisperKit model available for download
public struct WhisperModel: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let size: String
    public let isEnglishOnly: Bool
    public let isQuantized: Bool
    public let isRecommended: Bool

    /// Check if the model is downloaded locally
    public var isDownloaded: Bool {
        let fm = FileManager.default
        // WhisperKit downloads to: {baseDir}/models/argmaxinc/whisperkit-coreml/{modelId}/
        let modelDir = WhisperModelManager.whisperModelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        // Check for key CoreML model files
        let melSpectrogramPath = modelDir.appendingPathComponent("MelSpectrogram.mlmodelc").path
        let audioEncoderPath = modelDir.appendingPathComponent("AudioEncoder.mlmodelc").path
        // Model is downloaded if CoreML bundles exist
        return fm.fileExists(atPath: melSpectrogramPath) && fm.fileExists(atPath: audioEncoderPath)
    }

    /// Local directory where this model would be stored
    public var localDirectory: URL {
        // WhisperKit downloads to: {baseDir}/models/argmaxinc/whisperkit-coreml/{modelId}/
        WhisperModelManager.whisperModelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }
}

/// Manages WhisperKit CoreML model downloads from HuggingFace
@MainActor
public final class WhisperModelManager: ObservableObject {
    public static let shared = WhisperModelManager()

    // MARK: - Published Properties

    @Published public var availableModels: [WhisperModel] = []
    @Published public var downloadStates: [String: WhisperDownloadState] = [:]
    @Published public var isLoading: Bool = false
    @Published public var selectedModelId: String?

    // MARK: - Download Metrics

    public struct DownloadMetrics: Equatable {
        public let bytesReceived: Int64?
        public let totalBytes: Int64?
        public let bytesPerSecond: Double?
        public let etaSeconds: Double?
    }

    @Published public var downloadMetrics: [String: DownloadMetrics] = [:]

    // MARK: - Private Properties

    private var activeDownloadTasks: [String: Task<Void, Never>] = [:]
    private var downloadTokens: [String: UUID] = [:]
    private var progressSamples: [String: [(timestamp: TimeInterval, completed: Int64)]] = [:]

    // MARK: - Directories

    /// Directory where WhisperKit models are stored
    public nonisolated static var whisperModelsDirectory: URL {
        let fm = FileManager.default
        let homeURL = fm.homeDirectoryForCurrentUser
        return homeURL.appendingPathComponent(".osaurus/whisper-models", isDirectory: true)
    }

    // MARK: - Initialization

    private init() {
        loadAvailableModels()
        loadSelectedModel()
    }

    // MARK: - Public Methods

    /// Load the curated list of available WhisperKit models
    public func loadAvailableModels() {
        availableModels = Self.curatedModels
        // Initialize download states
        for model in availableModels {
            downloadStates[model.id] = model.isDownloaded ? .completed : .notStarted
        }
    }

    /// Load persisted selected model
    private func loadSelectedModel() {
        let config = WhisperConfigurationStore.load()
        selectedModelId = config.defaultModel
    }

    /// Set the default model and persist
    public func setDefaultModel(_ modelId: String?) {
        selectedModelId = modelId
        var config = WhisperConfigurationStore.load()
        config.defaultModel = modelId
        WhisperConfigurationStore.save(config)
    }

    /// Get the currently selected model (or first downloaded)
    public var selectedModel: WhisperModel? {
        if let id = selectedModelId, let model = availableModels.first(where: { $0.id == id }) {
            return model
        }
        // Fallback to first downloaded model
        return availableModels.first { $0.isDownloaded }
    }

    /// Total size of downloaded Whisper models
    public var totalDownloadedSize: Int64 {
        let fm = FileManager.default
        let baseDir = Self.whisperModelsDirectory
        guard fm.fileExists(atPath: baseDir.path) else { return 0 }

        var total: Int64 = 0
        if let enumerator = fm.enumerator(
            at: baseDir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                do {
                    let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if values.isRegularFile == true, let size = values.fileSize {
                        total += Int64(size)
                    }
                } catch {
                    continue
                }
            }
        }
        return total
    }

    public var totalDownloadedSizeString: String {
        ByteCountFormatter.string(fromByteCount: totalDownloadedSize, countStyle: .file)
    }

    /// Number of active downloads
    public var activeDownloadsCount: Int {
        downloadStates.values.filter {
            if case .downloading = $0 { return true }
            return false
        }.count
    }

    /// Number of downloaded models
    public var downloadedModelsCount: Int {
        availableModels.filter { $0.isDownloaded }.count
    }

    // MARK: - Download Methods

    /// Download a WhisperKit model using WhisperKit's built-in download
    public func downloadModel(_ model: WhisperModel) {
        guard downloadStates[model.id] != .downloading(progress: 0) else { return }
        if model.isDownloaded {
            downloadStates[model.id] = .completed
            return
        }

        // Cancel any previous task
        activeDownloadTasks[model.id]?.cancel()

        let token = UUID()
        downloadTokens[model.id] = token

        downloadStates[model.id] = .downloading(progress: 0.0)
        downloadMetrics[model.id] = DownloadMetrics(
            bytesReceived: nil,
            totalBytes: nil,
            bytesPerSecond: nil,
            etaSeconds: nil
        )
        progressSamples[model.id] = []

        // Ensure base directory exists
        let baseDir = Self.whisperModelsDirectory
        do {
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        } catch {
            downloadStates[model.id] = .failed(error: "Failed to create directory: \(error.localizedDescription)")
            return
        }

        let task = Task { [weak self] in
            guard let self = self else { return }

            do {
                // Use WhisperKit's built-in download functionality
                let modelId = model.id
                let modelFolder = Self.whisperModelsDirectory

                // Download using WhisperKit's download method
                let downloadedFolder = try await WhisperKit.download(
                    variant: modelId,
                    downloadBase: modelFolder,
                    useBackgroundSession: false
                ) { @Sendable progress in
                    Task { @MainActor in
                        WhisperModelManager.shared.downloadStates[modelId] = .downloading(
                            progress: progress.fractionCompleted
                        )
                    }
                }

                print("[WhisperModelManager] Downloaded to: \(downloadedFolder)")

                await MainActor.run {
                    if self.downloadTokens[model.id] == token {
                        // Refresh the model state
                        self.downloadStates[model.id] = .completed
                        self.downloadTokens[model.id] = nil
                        self.downloadMetrics[model.id] = nil
                        self.progressSamples[model.id] = nil
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    if self.downloadTokens[model.id] == token {
                        self.downloadStates[model.id] = .notStarted
                        self.downloadTokens[model.id] = nil
                        self.downloadMetrics[model.id] = nil
                        self.progressSamples[model.id] = nil
                    }
                }
            } catch {
                await MainActor.run {
                    if self.downloadTokens[model.id] == token {
                        self.downloadStates[model.id] = .failed(error: error.localizedDescription)
                        self.downloadTokens[model.id] = nil
                        self.downloadMetrics[model.id] = nil
                        self.progressSamples[model.id] = nil
                    }
                }
            }

            await MainActor.run {
                self.activeDownloadTasks[model.id] = nil
            }
        }

        activeDownloadTasks[model.id] = task
    }

    /// Cancel a download
    public func cancelDownload(_ modelId: String) {
        activeDownloadTasks[modelId]?.cancel()
        activeDownloadTasks[modelId] = nil
        downloadTokens[modelId] = nil
        downloadStates[modelId] = .notStarted
        downloadMetrics[modelId] = nil
        progressSamples[modelId] = nil
    }

    /// Delete a downloaded model
    public func deleteModel(_ model: WhisperModel) {
        cancelDownload(model.id)

        let fm = FileManager.default
        let modelDir = model.localDirectory
        if fm.fileExists(atPath: modelDir.path) {
            do {
                try fm.removeItem(at: modelDir)
            } catch {
                print("[WhisperModelManager] Failed to delete model: \(error)")
            }
        }
        downloadStates[model.id] = .notStarted

        // Clear selection if deleted
        if selectedModelId == model.id {
            setDefaultModel(nil)
        }
    }

    /// Effective download state for a model
    public func effectiveDownloadState(for model: WhisperModel) -> WhisperDownloadState {
        if case .downloading = downloadStates[model.id] {
            return downloadStates[model.id] ?? .notStarted
        }
        return model.isDownloaded ? .completed : (downloadStates[model.id] ?? .notStarted)
    }

    // MARK: - Curated Models

    /// Curated list of WhisperKit CoreML models with descriptions
    private static let curatedModels: [WhisperModel] = [
        // Recommended
        WhisperModel(
            id: "openai_whisper-large-v3-v20240930",
            name: "Whisper Large V3",
            description: "Best quality. Accurate multilingual transcription.",
            size: "~3 GB",
            isEnglishOnly: false,
            isQuantized: false,
            isRecommended: true
        ),
        WhisperModel(
            id: "openai_whisper-large-v3-v20240930_turbo",
            name: "Whisper Large V3 Turbo",
            description: "Fast + accurate. Great balance for most users.",
            size: "~1.5 GB",
            isEnglishOnly: false,
            isQuantized: false,
            isRecommended: true
        ),
        WhisperModel(
            id: "openai_whisper-small.en",
            name: "Whisper Small (English)",
            description: "Compact English-only model. Fast and efficient.",
            size: "~500 MB",
            isEnglishOnly: true,
            isQuantized: false,
            isRecommended: true
        ),

        // Large models
        WhisperModel(
            id: "openai_whisper-large-v3",
            name: "Whisper Large V3 (Original)",
            description: "Original large model. High accuracy.",
            size: "~3 GB",
            isEnglishOnly: false,
            isQuantized: false,
            isRecommended: false
        ),
        WhisperModel(
            id: "openai_whisper-large-v2",
            name: "Whisper Large V2",
            description: "Previous generation large model.",
            size: "~3 GB",
            isEnglishOnly: false,
            isQuantized: false,
            isRecommended: false
        ),

        // Quantized variants
        WhisperModel(
            id: "openai_whisper-large-v3-v20240930_626MB",
            name: "Whisper Large V3 (Quantized)",
            description: "Compressed large model. Good quality, smaller size.",
            size: "~626 MB",
            isEnglishOnly: false,
            isQuantized: true,
            isRecommended: false
        ),
        WhisperModel(
            id: "openai_whisper-small_216MB",
            name: "Whisper Small (Quantized)",
            description: "Compressed small model. Very efficient.",
            size: "~216 MB",
            isEnglishOnly: false,
            isQuantized: true,
            isRecommended: false
        ),

        // Medium models
        WhisperModel(
            id: "openai_whisper-medium",
            name: "Whisper Medium",
            description: "Balanced multilingual model.",
            size: "~1.5 GB",
            isEnglishOnly: false,
            isQuantized: false,
            isRecommended: false
        ),
        WhisperModel(
            id: "openai_whisper-medium.en",
            name: "Whisper Medium (English)",
            description: "English-only medium model.",
            size: "~1.5 GB",
            isEnglishOnly: true,
            isQuantized: false,
            isRecommended: false
        ),

        // Small models
        WhisperModel(
            id: "openai_whisper-small",
            name: "Whisper Small",
            description: "Compact multilingual model.",
            size: "~500 MB",
            isEnglishOnly: false,
            isQuantized: false,
            isRecommended: false
        ),

        // Base models
        WhisperModel(
            id: "openai_whisper-base",
            name: "Whisper Base",
            description: "Basic multilingual model. Very fast.",
            size: "~150 MB",
            isEnglishOnly: false,
            isQuantized: false,
            isRecommended: false
        ),
        WhisperModel(
            id: "openai_whisper-base.en",
            name: "Whisper Base (English)",
            description: "Basic English-only model. Fastest.",
            size: "~150 MB",
            isEnglishOnly: true,
            isQuantized: false,
            isRecommended: false
        ),

        // Tiny models
        WhisperModel(
            id: "openai_whisper-tiny",
            name: "Whisper Tiny",
            description: "Smallest multilingual model. Ultra-fast.",
            size: "~75 MB",
            isEnglishOnly: false,
            isQuantized: false,
            isRecommended: false
        ),
        WhisperModel(
            id: "openai_whisper-tiny.en",
            name: "Whisper Tiny (English)",
            description: "Smallest English-only model. Instant.",
            size: "~75 MB",
            isEnglishOnly: true,
            isQuantized: false,
            isRecommended: false
        ),

        // Distil models
        WhisperModel(
            id: "distil-whisper_distil-large-v3",
            name: "Distil Whisper Large V3",
            description: "Distilled large model. Fast with good quality.",
            size: "~750 MB",
            isEnglishOnly: false,
            isQuantized: false,
            isRecommended: false
        ),
    ]
}
