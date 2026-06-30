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
    @Published public var legacyWhisperModelsExist: Bool = false
    @Published public var legacyWhisperModelsSizeString: String?

    // MARK: - Private Properties

    private var activeDownloadTasks: [String: Task<Void, Never>] = [:]

    nonisolated private static let legacyWhisperDirectories: [String] = [
        "models--argmaxinc--whisperkit-coreml",
        "models--argmaxinc--whisperkit-pro",
    ]

    // MARK: - Initialization

    private init() {
        availableModels = Self.curatedModels
        loadSelectedModel()

        // Seed cheap defaults synchronously so the `@Published` UI binds
        // immediately, then run the disk probes (FluidAudio cache existence
        // checks + the recursive legacy-Whisper `directorySize` enumerator —
        // unbounded on large legacy dirs) off the launch-critical main thread.
        // `.shared` is constructed during App-struct setup, before
        // `applicationDidFinishLaunching`, so this must not block launch.
        for model in availableModels where downloadStates[model.id] == nil {
            downloadStates[model.id] = .notStarted
        }
        Task { [weak self] in
            await self?.refreshDiskStateInBackground()
        }
    }

    /// Probe the FluidAudio cache and legacy-Whisper directories on a
    /// background thread, then publish the results on the main actor. Keeps
    /// the recursive directory-size enumerator off the launch path while the
    /// synchronous `refreshDownloadStates()` / `refreshLegacyWhisperState()`
    /// remain available for explicit refreshes (post-download / post-delete).
    public func refreshDiskStateInBackground() async {
        let probes: [(id: String, version: SpeechModelVersion)] =
            availableModels.map { ($0.id, $0.version) }

        let scan = await Task.detached(priority: .utility) {
            () -> (download: [String: Bool], legacyExists: Bool, legacySize: String?) in
            var download: [String: Bool] = [:]
            for probe in probes {
                let faVersion: AsrModelVersion = probe.version == .v2 ? .v2 : .v3
                let cacheDir = AsrModels.defaultCacheDirectory(for: faVersion)
                download[probe.id] = AsrModels.modelsExist(at: cacheDir, version: faVersion)
            }
            let dirs = Self.findLegacyWhisperDirectories()
            let legacyExists = !dirs.isEmpty
            let legacySize: String? =
                legacyExists
                ? Self.formatBytes(dirs.reduce(Int64(0)) { $0 + Self.directorySize($1) })
                : nil
            return (download, legacyExists, legacySize)
        }.value

        for (id, isDownloaded) in scan.download {
            // Don't clobber an in-flight download that started while we scanned.
            if case .downloading = downloadStates[id] { continue }
            downloadStates[id] = isDownloaded ? .completed : .notStarted
        }
        legacyWhisperModelsExist = scan.legacyExists
        legacyWhisperModelsSizeString = scan.legacySize
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
        if count == 0 { return L("No models") }
        return L("\(count) model\(count == 1 ? "" : "s") ready")
    }

    // MARK: - Download Methods

    /// Download a Parakeet model using FluidAudio's built-in download
    public func downloadModel(_ model: SpeechModel) {
        if case .downloading = downloadStates[model.id] { return }

        activeDownloadTasks[model.id]?.cancel()

        downloadStates[model.id] = .downloading(progress: 0.0)

        // Pin the download consumer to the main actor: it resumes after an
        // `await` on FluidAudio's downloader (off-main) and then mutates the
        // @Published `downloadStates` — an un-annotated Task would write them
        // off-main ("Updating ObservedObject from background threads").
        let task = Task { @MainActor [weak self] in
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

    // MARK: - Legacy WhisperKit Cleanup

    /// Refresh whether legacy WhisperKit model directories exist on disk
    public func refreshLegacyWhisperState() {
        let directories = Self.findLegacyWhisperDirectories()
        legacyWhisperModelsExist = !directories.isEmpty
        if legacyWhisperModelsExist {
            let totalBytes = directories.reduce(Int64(0)) { $0 + Self.directorySize($1) }
            legacyWhisperModelsSizeString = Self.formatBytes(totalBytes)
        } else {
            legacyWhisperModelsSizeString = nil
        }
    }

    /// Delete all legacy WhisperKit model directories from disk
    public func deleteLegacyWhisperModels() {
        let fm = FileManager.default
        for directory in Self.findLegacyWhisperDirectories() {
            try? fm.removeItem(at: directory)
        }
        refreshLegacyWhisperState()
    }

    nonisolated private static func findLegacyWhisperDirectories() -> [URL] {
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser
        let hubCache =
            homeDir
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)

        return legacyWhisperDirectories.compactMap { dirName in
            let url = hubCache.appendingPathComponent(dirName, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            return url
        }
    }

    nonisolated private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    nonisolated private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Curated Models

    private static let curatedModels: [SpeechModel] = [
        SpeechModel(
            id: SpeechModelVersion.v3.rawValue,
            name: "Parakeet TDT v3 (0.6B)",
            description: L("Multilingual model. Supports 25 European languages. Recommended for most users."),
            size: "~600 MB",
            isEnglishOnly: false,
            isRecommended: true,
            version: .v3
        ),
        SpeechModel(
            id: SpeechModelVersion.v2.rawValue,
            name: "Parakeet TDT v2 (0.6B)",
            description: L("English-only model. Highest recall for English transcription."),
            size: "~600 MB",
            isEnglishOnly: true,
            isRecommended: false,
            version: .v2
        ),
    ]
}
