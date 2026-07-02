//
//  ModelDownloadService.swift
//  osaurus
//
//  Manages MLX model file downloads, cancellation, deletion, and progress tracking.
//  Extracted from ModelManager to separate download orchestration from catalog management.
//

import Foundation

/// Manages MLX model file downloads, cancellation, deletion, and progress tracking.
@MainActor
final class ModelDownloadService: ObservableObject {
    static let shared = ModelDownloadService()

    /// Detailed metrics for an in-flight download
    struct DownloadMetrics: Equatable {
        let bytesReceived: Int64?
        let totalBytes: Int64?
        let bytesPerSecond: Double?
        let etaSeconds: Double?

        var formattedLine: String? {
            var parts: [String] = []

            if let received = bytesReceived {
                let receivedStr = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                if let total = totalBytes, total > 0 {
                    let totalStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                    parts.append("\(receivedStr) / \(totalStr)")
                } else {
                    parts.append(receivedStr)
                }
            }

            if let bps = bytesPerSecond {
                let speedStr = ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file)
                parts.append("\(speedStr)/s")
            }

            if let eta = etaSeconds, eta.isFinite, eta > 0 {
                parts.append("ETA \(Self.formatETA(seconds: eta))")
            }

            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: " • ")
        }

        static func formatETA(seconds: Double) -> String {
            let total = Int(seconds.rounded())
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            let secs = total % 60
            if hours > 0 {
                return String(format: "%d:%02d:%02d", hours, minutes, secs)
            } else {
                return String(format: "%d:%02d", minutes, secs)
            }
        }
    }

    // MARK: - Published Properties

    @Published var downloadStates: [String: DownloadState] = [:]
    @Published var downloadMetrics: [String: DownloadMetrics] = [:]
    /// Last download failure surfaced to the UI.
    @Published var downloadAlert: DownloadAlertInfo?

    /// Cached total on-disk size of downloaded models. Computed off the main
    /// thread by `refreshTotalDownloadedSize` (a recursive filesystem walk) and
    /// published here so the header can read it without blocking the UI.
    @Published private(set) var totalDownloadedSizeBytes: Int64 = 0

    /// Keeps the cached size fresh when models are added/removed.
    private var localModelsObserver: NSObjectProtocol?

    /// Categorised failure info shown in the alert. The `title` describes
    /// the kind of failure, `message` is the human-readable cause, and
    /// `details` is a copyable diagnostic line users can paste into bug
    /// reports. `modelId` names the affected model so surfaces that render
    /// alerts inline (onboarding) can attribute them without parsing
    /// `details`.
    struct DownloadAlertInfo: Equatable, Identifiable {
        let id = UUID()
        let modelId: String
        let title: String
        let message: String
        let details: String
    }

    /// Build a categorised alert from a raw error message and the affected
    /// model. Routes well-known patterns (disk, network, gated, etc.) to
    /// friendlier titles. falls back to a generic one.
    private static func makeAlert(
        modelId: String,
        rawError: String,
        stage: String,
        filePath: String? = nil
    ) -> DownloadAlertInfo {
        let lower = rawError.lowercased()
        let isCompatibilityPreflight =
            lower.contains("compatibility preflight")
            || lower.contains("unsupported local model type")
            || lower.contains("speculative decoding")
        let title: String
        let message: String
        if lower.contains("not enough disk space") || lower.contains("no space") {
            title = L("Not enough disk space")
            message = rawError
        } else if lower.contains("hugging face") || lower.contains("file list") {
            title = L("Repository unavailable")
            message =
                L(
                    "Couldn't reach this model on Hugging Face. The repo may be private, gated, removed, or temporarily unreachable."
                )
        } else if lower.hasPrefix("http ") {
            title = L("Repository unavailable")
            message =
                L(
                    "Hugging Face responded with \(rawError). Private or gated repos aren't supported yet; otherwise try again in a moment."
                )
        } else if lower.contains("offline") || lower.contains("internet connection")
            || lower.contains("network") || lower.contains("timed out")
        {
            title = L("Network error")
            message = rawError
        } else if isCompatibilityPreflight {
            title = L("Model not runnable")
            message = rawError
        } else if lower.contains("size mismatch") {
            title = L("Downloaded file corrupted")
            message =
                L(
                    "A file came back at the wrong size, which usually means the connection was interrupted. Retrying should fix this."
                )
        } else if lower.contains("download incomplete") {
            title = L("Download incomplete")
            message = rawError
        } else if lower.contains("create directory") || lower.contains("couldn't")
            || lower.contains("permission") || lower.contains("read-only")
        {
            title = L("Couldn't save files")
            message = rawError
        } else {
            title = L("Model download failed")
            message = rawError
        }

        var detailParts: [String] = [
            "model=\(modelId)",
            "stage=\(stage)",
        ]
        if let filePath { detailParts.append("file=\(filePath)") }
        detailParts.append("raw=\(rawError)")
        let details = detailParts.joined(separator: " | ")
        return DownloadAlertInfo(modelId: modelId, title: title, message: message, details: details)
    }

    // MARK: - Properties

    static let downloadFilePatterns: [String] = [
        "*.json",
        "*.jinja",
        "*.txt",
        "*.model",
        "*.safetensors",
    ]

    /// Filenames excluded from download even when they match a glob pattern.
    static let downloadExcludedFiles: Set<String> = [
        "README.md",
        ".gitattributes",
    ]

    private var activeDownloadTasks: [String: Task<Void, Never>] = [:]
    private var activeDownloaders: [String: DirectDownloader] = [:]
    private var downloadTokens: [String: UUID] = [:]
    private var progressSamples: [String: [(timestamp: TimeInterval, completed: Int64)]] = [:]
    private var lastKnownSpeed: [String: Double] = [:]
    /// In-memory pause snapshot. Survives a pause within an app session, but
    /// is intentionally not persisted across launches in v1 — `URLSession`
    /// resume data references temporary cache files that don't necessarily
    /// outlive the process. Coarse per-file resume (skip files whose on-disk
    /// size matches the expected size) covers the cross-launch case.
    private var pausedDownloads: [String: PausedSnapshot] = [:]
    private var hasRunTopUp = false

    /// Snapshot captured at the moment the user paused, used by `resume(_:)`
    /// to feed the in-flight file's `cancelByProducingResumeData` blob back
    /// into a fresh `URLSession` download task so the download continues
    /// from the same byte offset.
    private struct PausedSnapshot {
        let inFlightFilePath: String?
        let resumeData: Data?
    }

    init() {
        refreshTotalDownloadedSize()
        // Recompute whenever a download completes, a model is deleted, or the
        // models directory changes — all of which already post this.
        localModelsObserver = NotificationCenter.default.addObserver(
            forName: .localModelsChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in ModelDownloadService.shared.refreshTotalDownloadedSize() }
        }
    }

    // MARK: - Download Methods

    func download(_ model: MLXModel) {
        startOrchestration(model: model, resuming: nil)
    }

    /// Resumes a previously paused download, picking up the in-flight file
    /// from its exact byte offset when `URLSession` resume data is available
    /// and falling back to the per-file skip-if-already-on-disk path
    /// otherwise.
    func resume(_ model: MLXModel) {
        let snapshot = pausedDownloads.removeValue(forKey: model.id)
        startOrchestration(model: model, resuming: snapshot)
    }

    private func startOrchestration(model: MLXModel, resuming: PausedSnapshot?) {
        // `model.isDownloaded` is satisfied by config + tokenizer + any single
        // shard so don't short-circuit on it. the per-file size check below
        // is authoritative
        let state = downloadStates[model.id] ?? .notStarted
        if case .downloading = state { return }

        // upfront disk-space preflight so we alert instead of flashing a
        // progress bar that the in-task check would rip down ~300ms later.
        if let needed = model.totalSizeEstimateBytes,
            let probePath = Self.existingAncestor(of: model.localDirectory),
            let freeBytes = OsaurusPaths.volumeFreeBytes(forPath: probePath.path),
            let refusal = Self.storageRefusalMessage(neededBytes: needed, freeBytes: freeBytes)
        {
            downloadAlert = Self.makeAlert(
                modelId: model.id,
                rawError: refusal,
                stage: "preflight"
            )
            return
        }

        activeDownloadTasks[model.id]?.cancel()
        activeDownloaders[model.id]?.invalidate()
        let token = UUID()
        downloadTokens[model.id] = token

        downloadStates[model.id] = .downloading(progress: 0.0)
        downloadMetrics[model.id] = DownloadMetrics(
            bytesReceived: 0,
            totalBytes: nil,
            bytesPerSecond: nil,
            etaSeconds: nil
        )
        progressSamples[model.id] = []

        let downloader = DirectDownloader()
        activeDownloaders[model.id] = downloader

        let task = Task { [weak self, resuming] in
            guard let self = self else { return }

            // Create the model directory off the main thread before any other
            // work. `mkdir` on a slow or contended volume otherwise blocks the
            // main thread on the synchronous download-button path.
            do {
                let directory = model.localDirectory
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(
                        at: directory,
                        withIntermediateDirectories: true
                    )
                }.value
            } catch {
                await MainActor.run {
                    let message = "Failed to create directory: \(error.localizedDescription)"
                    self.downloadStates[model.id] = .failed(error: message)
                    self.downloadAlert = Self.makeAlert(
                        modelId: model.id,
                        rawError: message,
                        stage: "create-directory"
                    )
                    self.clearDownloadTracking(for: model.id)
                }
                return
            }

            // Mutable window into the orchestration loop so the catch
            // handlers (pause / cancel / failure) know which file was
            // mid-flight and how many bytes had completed before it.
            var inFlightFilePath: String? = nil
            var inFlightFileBaseBytes: Int64 = 0

            defer {
                Task { @MainActor [weak self] in
                    self?.activeDownloadTasks[model.id] = nil
                }
            }

            do {
                guard
                    let files = await HuggingFaceService.shared.fetchMatchingFiles(
                        repoId: model.id,
                        patterns: Self.downloadFilePatterns,
                        excludedFiles: Self.downloadExcludedFiles
                    ), !files.isEmpty
                else {
                    await MainActor.run {
                        self.finalizeOrchestration(
                            modelId: model.id,
                            token: token,
                            finalState: .failed(
                                error: "Could not retrieve file list from Hugging Face"
                            ),
                            failureStage: "fetch-manifest"
                        )
                    }
                    return
                }

                let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
                var completedFileBytes: Int64 = 0

                var filesToDownload: [HuggingFaceService.MatchedFile] = []
                for file in files {
                    guard
                        let dest = HuggingFaceService.destinationURL(
                            forRemotePath: file.path,
                            under: model.localDirectory
                        )
                    else {
                        continue
                    }
                    let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
                    let existingSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                    if existingSize == file.size {
                        completedFileBytes += file.size
                    } else {
                        filesToDownload.append(file)
                    }
                }

                // Preflight disk-space check. Runs on the filesystem that hosts
                // `model.localDirectory` — which may be an external drive when
                // the user has pointed `DirectoryPickerService` at one — so we
                // can't assume boot-volume capacity. If the query itself fails
                // we proceed with the download; a stale estimate is worse than
                // none, and the ordinary write-path error handling still fires.
                let bytesToDownload = totalBytes - completedFileBytes
                if bytesToDownload > 0,
                    let freeBytes = Self.freeBytesOnVolume(containing: model.localDirectory),
                    let refusal = Self.storageRefusalMessage(
                        neededBytes: bytesToDownload,
                        freeBytes: freeBytes
                    )
                {
                    await MainActor.run {
                        self.finalizeOrchestration(
                            modelId: model.id,
                            token: token,
                            finalState: .failed(error: refusal),
                            failureStage: "preflight-in-task"
                        )
                    }
                    return
                }

                await MainActor.run {
                    guard self.downloadTokens[model.id] == token else { return }
                    let fraction = totalBytes > 0 ? Double(completedFileBytes) / Double(totalBytes) : 0
                    self.downloadStates[model.id] = .downloading(progress: fraction)
                    self.downloadMetrics[model.id] = DownloadMetrics(
                        bytesReceived: completedFileBytes > 0 ? completedFileBytes : 0,
                        totalBytes: totalBytes,
                        bytesPerSecond: nil,
                        etaSeconds: nil
                    )
                }

                for file in filesToDownload {
                    try Task.checkCancellation()

                    guard
                        let destination = HuggingFaceService.destinationURL(
                            forRemotePath: file.path,
                            under: model.localDirectory
                        )
                    else {
                        continue
                    }
                    guard let downloadURL = Self.resolveURL(repoId: model.id, path: file.path)
                    else { continue }

                    let baseCompleted = completedFileBytes
                    inFlightFilePath = file.path
                    inFlightFileBaseBytes = baseCompleted

                    let onProgress: @Sendable (Int64, Int64) -> Void = {
                        [weak self] bytesWritten, _ in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.updateDownloadProgress(
                                modelId: model.id,
                                token: token,
                                completedBytes: baseCompleted + bytesWritten,
                                totalBytes: totalBytes
                            )
                        }
                    }

                    // Only the file that was actually mid-flight when the
                    // user paused gets URLSession resume data. Other files
                    // start fresh — with the per-file skip path above
                    // having already short-circuited fully-downloaded ones.
                    let resumeDataForFile: Data? =
                        (resuming?.inFlightFilePath == file.path) ? resuming?.resumeData : nil

                    try await downloader.download(
                        from: downloadURL,
                        to: destination,
                        expectedSize: file.size,
                        resumeData: resumeDataForFile,
                        onProgress: onProgress
                    )
                    completedFileBytes += file.size
                    inFlightFilePath = nil
                }

                // Manifest driven completion check. `model.isDownloaded` only
                // looks for config + tokenizer + ≥1 shard on disc so a
                // multi shard download with a silently skipped file would
                // still pass that test. Verify every manifest entry is on
                // disk at its expected size and report which are missing
                let fm = FileManager.default
                let missing: [String] = files.compactMap { file in
                    guard
                        let dest = HuggingFaceService.destinationURL(
                            forRemotePath: file.path,
                            under: model.localDirectory
                        )
                    else {
                        return file.path
                    }
                    let attrs = try? fm.attributesOfItem(atPath: dest.path)
                    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                    return size == file.size ? nil : file.path
                }
                let isComplete = missing.isEmpty
                let finalState: DownloadState
                if isComplete {
                    finalState = .completed
                } else if missing.count == 1 {
                    finalState = .failed(
                        error: "Download incomplete: \(missing[0]) is missing or has wrong size"
                    )
                } else {
                    finalState = .failed(
                        error:
                            "Download incomplete: \(missing.count) of \(files.count) files are missing or have wrong size"
                    )
                }
                let compatibilityReport =
                    isComplete
                    ? ModelCompatibilityDiagnostics.report(
                        modelId: model.id,
                        modelName: model.name,
                        modelTypeHint: model.modelType,
                        bundleURL: model.localDirectory,
                        externalSource: model.externalSource
                    )
                    : nil
                await MainActor.run {
                    let didFinalize = self.finalizeOrchestration(
                        modelId: model.id,
                        token: token,
                        finalState: finalState,
                        failureStage: "completion-check",
                        failureFilePath: missing.first
                    )
                    if didFinalize && isComplete {
                        if let compatibilityReport {
                            if compatibilityReport.preflight.blocksRuntimeLoad {
                                self.downloadAlert = Self.makeAlert(
                                    modelId: model.id,
                                    rawError:
                                        "Compatibility preflight: \(compatibilityReport.preflight.title). \(compatibilityReport.preflight.detail)",
                                    stage: "compatibility-preflight"
                                )
                                ModelManager.invalidateLocalModelsCache()
                                NotificationCenter.default.post(name: .localModelsChanged, object: nil)
                                return
                            }
                        }
                        NotificationService.shared.postModelReady(
                            modelId: model.id,
                            modelName: model.name
                        )
                        // KPI: a curated-catalog model finished downloading.
                        // The id is from the catalog, so it is safe to send.
                        FeatureTelemetry.modelDownloaded(
                            model: model.id,
                            parameterCount: model.parameterCount,
                            quantization: model.quantization,
                            isVLM: model.isVLM
                        )
                        ModelManager.invalidateLocalModelsCache()
                        NotificationCenter.default.post(name: .localModelsChanged, object: nil)
                    }
                }
            } catch let pauseInfo as DirectDownloader.PauseInfo {
                let snapshotPath = inFlightFilePath
                let baseBytes = inFlightFileBaseBytes
                await MainActor.run {
                    self.commitPause(
                        modelId: model.id,
                        token: token,
                        bytesDownloadedInFile: pauseInfo.bytesDownloaded,
                        baseBytesBeforeFile: baseBytes,
                        inFlightFilePath: snapshotPath,
                        resumeData: pauseInfo.resumeData
                    )
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.finalizeOrchestration(
                        modelId: model.id,
                        token: token,
                        finalState: .notStarted
                    )
                }
            } catch {
                let snapshotPath = inFlightFilePath
                await MainActor.run {
                    self.finalizeOrchestration(
                        modelId: model.id,
                        token: token,
                        finalState: .failed(error: error.localizedDescription),
                        failureStage: snapshotPath != nil ? "file-transfer" : "orchestration",
                        failureFilePath: snapshotPath
                    )
                }
            }
        }

        activeDownloadTasks[model.id] = task
    }

    /// Token-guarded transition from `.downloading` → `.paused`. Freezes
    /// `downloadMetrics` (clears speed/ETA, keeps received/total bytes so
    /// the user still sees "X / Y"), drops the live downloader/task, and
    /// stashes the in-flight file's resume-data blob so a later
    /// `resume(_:)` can hand it to a fresh `URLSessionDownloadTask`.
    private func commitPause(
        modelId: String,
        token: UUID,
        bytesDownloadedInFile: Int64,
        baseBytesBeforeFile: Int64,
        inFlightFilePath: String?,
        resumeData: Data?
    ) {
        guard downloadTokens[modelId] == token else { return }
        let metrics = downloadMetrics[modelId]
        let total = metrics?.totalBytes ?? 0
        let completed = baseBytesBeforeFile + bytesDownloadedInFile
        let fraction =
            total > 0
            ? min(1.0, max(0.0, Double(completed) / Double(total)))
            : 0
        downloadStates[modelId] = .paused(progress: fraction)
        downloadMetrics[modelId] = DownloadMetrics(
            bytesReceived: completed,
            totalBytes: metrics?.totalBytes,
            bytesPerSecond: nil,
            etaSeconds: nil
        )
        progressSamples[modelId] = []
        lastKnownSpeed[modelId] = nil
        pausedDownloads[modelId] = PausedSnapshot(
            inFlightFilePath: inFlightFilePath,
            resumeData: resumeData
        )
        activeDownloaders[modelId]?.invalidate()
        activeDownloaders[modelId] = nil
        activeDownloadTasks[modelId] = nil
    }

    /// Suspends the in-flight download for `modelId` and transitions state to
    /// `.paused`. When there's an active `URLSessionDownloadTask` the
    /// downloader's pause path produces resume data so a later `resume(_:)`
    /// continues from the same byte offset. In the rare between-files
    /// window with no in-flight task, falls back to a coarse pause that
    /// relies on the per-file skip path to make the eventual resume cheap.
    func pause(_ modelId: String) {
        guard case .downloading(let progress) = downloadStates[modelId] else { return }

        if let downloader = activeDownloaders[modelId] {
            downloader.pause()
            return
        }

        // Coarse fallback: no live URLSession task to capture resume data
        // from. Tear down the orchestration, freeze metrics, and stash an
        // empty pause snapshot so resume() takes the orchestration-restart
        // path with per-file skip-if-on-disk-size-matches resume.
        releaseOrchestrationResources(for: modelId)
        downloadTokens[modelId] = nil
        progressSamples[modelId] = nil
        lastKnownSpeed[modelId] = nil
        if let metrics = downloadMetrics[modelId] {
            downloadMetrics[modelId] = DownloadMetrics(
                bytesReceived: metrics.bytesReceived,
                totalBytes: metrics.totalBytes,
                bytesPerSecond: nil,
                etaSeconds: nil
            )
        }
        pausedDownloads[modelId] = PausedSnapshot(inFlightFilePath: nil, resumeData: nil)
        downloadStates[modelId] = .paused(progress: progress)
    }

    func cancel(_ modelId: String) {
        releaseOrchestrationResources(for: modelId)
        pausedDownloads[modelId] = nil
        clearDownloadTracking(for: modelId)
        downloadStates[modelId] = .notStarted
    }

    func delete(_ model: MLXModel) async {
        // Use-after-free guard: free any resident GPU buffers and drain
        // in-flight per-request leases for this model BEFORE removing its
        // on-disk weights. `ModelRuntime.unload` shuts the BatchEngine, waits
        // for the lease count to hit zero, and frees the container. Deleting
        // the files out from under a live `ModelContainer` would let Metal
        // touch freed-then-reused memory (the `notifyExternalReferencesNonZero
        // OnDealloc` class). `unload` is a no-op when the model isn't resident.
        // Some callers (the "remove old id" migration notice) pass a synthetic
        // model with an empty name; skip the unload there since the runtime is
        // keyed by name and there's nothing to drain.
        if !model.name.isEmpty {
            await ModelRuntime.shared.unload(name: model.name)
        }

        releaseOrchestrationResources(for: model.id)
        pausedDownloads[model.id] = nil
        clearDownloadTracking(for: model.id)

        // Externally-discovered bundles (HF cache, LM Studio) are read-only
        // references — Osaurus never owns those files. "Deleting" one only
        // forgets it from the catalog; the source on disk is left untouched.
        if model.bundleDirectory != nil || model.externalSource != nil {
            ExternalModelLocator.forget(id: model.id)
            downloadStates[model.id] = .notStarted
            ModelManager.invalidateLocalModelsCache()
            NotificationCenter.default.post(name: .localModelsChanged, object: nil)
            return
        }

        // Off the main actor: removing a downloaded model unlinks every
        // weight file in the tree, which blocks for seconds on multi-GB
        // models. Only the resulting state is published back here.
        let localPath = model.localDirectory.path
        let cacheDirName = "models--\(model.id.replacingOccurrences(of: "/", with: "--"))"
        let cacheRoots = Self.hfCacheRoots()
        let removalError: (any Error)? = await Task.detached(priority: .userInitiated) {
            () -> (any Error)? in
            let fm = FileManager.default
            if fm.fileExists(atPath: localPath) {
                do {
                    try fm.removeItem(atPath: localPath)
                } catch {
                    return error
                }
            }
            for cacheRoot in cacheRoots {
                let cacheModelDir = cacheRoot.appendingPathComponent(cacheDirName)
                if fm.fileExists(atPath: cacheModelDir.path) {
                    try? fm.removeItem(at: cacheModelDir)
                }
            }
            return nil
        }.value

        if let removalError {
            downloadStates[model.id] = .failed(
                error: "Could not delete model: \(removalError.localizedDescription)"
            )
            return
        }

        downloadStates[model.id] = .notStarted
        ModelManager.invalidateLocalModelsCache()
        NotificationCenter.default.post(name: .localModelsChanged, object: nil)
    }

    func estimateSize(for model: MLXModel) async -> Int64? {
        // Read-through the on-disk size cache first (honoring its TTL for
        // revision-less entries) so re-opening the detail modal doesn't
        // re-hit the network. On a miss, fetch the tree-sum and write it
        // back so the value persists across launches.
        if let cached = ModelSizeCache.bytes(forId: model.id) {
            return cached
        }
        let fetched = await HuggingFaceService.shared.estimateTotalSize(
            repoId: model.id,
            patterns: Self.downloadFilePatterns,
            excludedFiles: Self.downloadExcludedFiles
        )
        if let fetched {
            ModelSizeCache.record(id: model.id, bytes: fetched, revision: nil)
        }
        return fetched
    }

    // MARK: - Query Methods

    func effectiveState(for model: MLXModel) -> DownloadState {
        switch downloadStates[model.id] {
        case .downloading, .paused:
            return downloadStates[model.id] ?? .notStarted
        default:
            return model.isDownloaded ? .completed : (downloadStates[model.id] ?? .notStarted)
        }
    }

    func progress(for modelId: String) -> Double {
        switch downloadStates[modelId] {
        case .downloading(let progress), .paused(let progress): return progress
        case .completed: return 1.0
        default: return 0.0
        }
    }

    var activeDownloadsCount: Int {
        downloadStates.values.filter {
            if case .downloading = $0 { return true }
            return false
        }.count
    }

    func isActiveDownload(_ modelId: String) -> Bool {
        activeDownloadTasks[modelId] != nil
    }

    var totalDownloadedSize: Int64 { totalDownloadedSizeBytes }

    var totalDownloadedSizeString: String {
        ByteCountFormatter.string(fromByteCount: totalDownloadedSizeBytes, countStyle: .file)
    }

    /// Recompute the on-disk size of all downloaded models off the main thread,
    /// then publish it. The walk (`discoverLocalModels` plus a recursive size
    /// sum per model) is far too expensive to run synchronously in a SwiftUI
    /// body, which is where the header reads `totalDownloadedSizeString`.
    func refreshTotalDownloadedSize() {
        Task { @MainActor [weak self] in
            let bytes = await Task.detached(priority: .utility) { () -> Int64 in
                ModelManager.discoverLocalModels()
                    .filter { $0.isDownloaded }
                    .reduce(Int64(0)) { partial, model in
                        partial + (ModelDownloadService.directoryAllocatedSize(at: model.localDirectory) ?? 0)
                    }
            }.value
            self?.totalDownloadedSizeBytes = bytes
        }
    }

    // MARK: - State Management

    /// Sync download states for models, skipping any with active downloads.
    ///
    /// `isDownloaded` walks each model's directory on disk (`fileExists` plus a
    /// `contentsOfDirectory` enumeration). For a large list — notably the ~100
    /// OsaurusAI repos folded in by `applyOsaurusOrgFetch` — running that on the
    /// main actor blocks the UI, so the probe is done off-main and the resulting
    /// states are published back. This also warms `MLXModelDownloadCache`.
    func syncStates(for models: [MLXModel]) {
        let pending = models.filter { activeDownloadTasks[$0.id] == nil }
        guard !pending.isEmpty else { return }
        Task { @MainActor [weak self] in
            let states: [String: DownloadState] = await Task.detached(priority: .utility) {
                var result: [String: DownloadState] = [:]
                for model in pending {
                    result[model.id] = model.isDownloaded ? .completed : .notStarted
                }
                return result
            }.value
            guard let self else { return }
            // Re-check active downloads on apply: one may have started while the
            // off-main probe was in flight, and that live state must win.
            for (id, state) in states where self.activeDownloadTasks[id] == nil {
                self.downloadStates[id] = state
            }
        }
    }

    // MARK: - Private Helpers

    private func clearDownloadTracking(for modelId: String) {
        downloadTokens[modelId] = nil
        downloadMetrics[modelId] = nil
        progressSamples[modelId] = nil
        lastKnownSpeed[modelId] = nil
    }

    /// Cancels the orchestration `Task` and tears down the per-model
    /// `DirectDownloader`. Safe to call from any path before transitioning
    /// to a terminal state. Doesn't touch `downloadStates` /
    /// `downloadMetrics` / `pausedDownloads` so callers stay in control of
    /// the published surface.
    private func releaseOrchestrationResources(for modelId: String) {
        activeDownloadTasks[modelId]?.cancel()
        activeDownloadTasks[modelId] = nil
        activeDownloaders[modelId]?.invalidate()
        activeDownloaders[modelId] = nil
    }

    /// Token-guarded terminal cleanup. Used by the orchestration `Task`'s
    /// completion / cancellation / failure paths so a concurrent
    /// `cancel(_:)` on the main path can't be silently overwritten by a
    /// stale completion. Returns `true` when the write actually landed —
    /// callers can use that to gate post-success side effects (notifications,
    /// cache invalidation, etc.).
    @discardableResult
    private func finalizeOrchestration(
        modelId: String,
        token: UUID,
        finalState: DownloadState,
        failureStage: String = "download",
        failureFilePath: String? = nil
    ) -> Bool {
        guard downloadTokens[modelId] == token else { return false }
        downloadStates[modelId] = finalState
        clearDownloadTracking(for: modelId)
        pausedDownloads[modelId] = nil
        activeDownloaders[modelId]?.invalidate()
        activeDownloaders[modelId] = nil
        if case .failed(let error) = finalState {
            downloadAlert = Self.makeAlert(
                modelId: modelId,
                rawError: error,
                stage: failureStage,
                filePath: failureFilePath
            )
        }
        return true
    }

    nonisolated static func resolveURL(repoId: String, path: String) -> URL? {
        guard let safePath = HuggingFaceService.normalizedRemoteFilePath(path) else { return nil }
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "huggingface.co"
        comps.path = "/\(repoId)/resolve/main/\(safePath)"
        return comps.url
    }

    // MARK: - Disk-space preflight

    /// Safety margin on top of the raw byte count, to cover Hugging Face LFS
    /// pointers that can under-report file size and the OS's need for a small
    /// amount of headroom during the atomic rename at the tail of each file.
    static let storageSafetyMarginBytes: Int64 = 256 * 1024 * 1024  // 256 MB

    /// Returns a user-visible refusal message if the download should be
    /// blocked, or `nil` if `freeBytes` is sufficient for `neededBytes`
    /// plus the safety margin.
    ///
    /// Extracted so the comparison can be unit-tested without mocking the
    /// filesystem.
    static func storageRefusalMessage(
        neededBytes: Int64,
        freeBytes: Int64
    ) -> String? {
        // No new bytes to write (e.g. every file is already on disk from a
        // prior successful download) — never block on volume capacity.
        guard neededBytes > 0 else { return nil }
        guard neededBytes + storageSafetyMarginBytes > freeBytes else { return nil }
        let needed = ByteCountFormatter.string(fromByteCount: neededBytes, countStyle: .file)
        let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        return
            "Not enough disk space to finish this download: need \(needed) free, only \(free) available."
    }

    /// Returns the free-for-important-usage byte count on the volume that
    /// hosts `url`. Delegates to `OsaurusPaths.volumeFreeBytes(forPath:)`
    /// so this service and `SystemMonitorService` share one query path —
    /// preventing the kind of drift that produced bug #964 (the system
    /// monitor reported 0 GB free while the downloader correctly saw
    /// tens of GB free, because the two used different APIs).
    /// Returns `nil` if both queries fail — callers should treat `nil` as
    /// "unknown, proceed" rather than "zero, block".
    static func freeBytesOnVolume(containing url: URL) -> Int64? {
        OsaurusPaths.volumeFreeBytes(forPath: url.path)
    }

    /// Nearest ancestor of `url` that exists on disk, so volume-capacity
    /// queries have a statable path before the per-model dir is created.
    static func existingAncestor(of url: URL) -> URL? {
        var current = url
        let fm = FileManager.default
        while !fm.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
        return current
    }

    private func updateDownloadProgress(
        modelId: String,
        token: UUID,
        completedBytes: Int64,
        totalBytes: Int64
    ) {
        guard downloadTokens[modelId] == token else { return }

        let fraction =
            totalBytes > 0
            ? min(1.0, Double(completedBytes) / Double(totalBytes)) : 0
        downloadStates[modelId] = .downloading(progress: fraction)

        let now = Date().timeIntervalSince1970
        var samples = progressSamples[modelId] ?? []
        samples.append((timestamp: now, completed: completedBytes))
        let window: TimeInterval = 5.0
        samples = samples.filter { now - $0.timestamp <= window }
        progressSamples[modelId] = samples

        var speed: Double? = nil
        if let first = samples.first, let last = samples.last,
            last.timestamp > first.timestamp
        {
            let bytesDelta = Double(last.completed - first.completed)
            let timeDelta = last.timestamp - first.timestamp
            if timeDelta > 0 { speed = max(0, bytesDelta / timeDelta) }
        }
        if let speed, speed > 0 {
            lastKnownSpeed[modelId] = speed
        } else {
            speed = lastKnownSpeed[modelId]
        }

        var eta: Double? = nil
        if let speed, speed > 0, totalBytes > 0 {
            let remaining = Double(totalBytes - completedBytes)
            if remaining > 0 { eta = remaining / speed }
        }

        downloadMetrics[modelId] = DownloadMetrics(
            bytesReceived: completedBytes,
            totalBytes: totalBytes,
            bytesPerSecond: speed,
            etaSeconds: eta
        )
    }

    // MARK: - Background Top-Up

    private static let sentinelFilename = ".topup_done"

    /// Checks for missing files and downloads them if the sentinel is absent.
    /// Writes the sentinel only when the remote check succeeds. Passing
    /// `clearSentinel: true` forces a fresh remote check (used by Repair).
    @discardableResult
    static func ensureComplete(
        for model: MLXModel,
        directory: URL,
        clearSentinel: Bool = false
    ) async -> Bool {
        let sentinel = directory.appendingPathComponent(sentinelFilename)
        if clearSentinel {
            try? FileManager.default.removeItem(at: sentinel)
        }
        guard !FileManager.default.fileExists(atPath: sentinel.path) else { return true }
        let success = await downloadMissingFiles(for: model, to: directory)
        if success {
            FileManager.default.createFile(atPath: sentinel.path, contents: nil)
        }
        return success
    }

    /// Downloads any missing config/tokenizer files for a model into `directory`.
    /// Returns `true` if the remote file list was successfully fetched
    /// (regardless of whether anything was missing), `false` on network failure.
    @discardableResult
    static func downloadMissingFiles(for model: MLXModel, to directory: URL) async -> Bool {
        let remoteFiles = await HuggingFaceService.shared.fetchMatchingFiles(
            repoId: model.id,
            patterns: downloadFilePatterns,
            excludedFiles: downloadExcludedFiles
        )
        guard let remoteFiles else { return false }

        let fm = FileManager.default
        let missing = remoteFiles.filter { file in
            guard
                let local = HuggingFaceService.destinationURL(
                    forRemotePath: file.path,
                    under: directory
                )
            else {
                return true
            }
            guard let attrs = try? fm.attributesOfItem(atPath: local.path),
                let localSize = (attrs[.size] as? NSNumber)?.int64Value
            else { return true }
            return localSize != file.size
        }
        guard !missing.isEmpty else { return true }

        let downloader = DirectDownloader()
        defer { downloader.invalidate() }
        var allSucceeded = true
        for file in missing {
            // Honor cancellation between shard fetches so a cancelled load /
            // app shutdown doesn't keep pulling a long tail of missing files.
            if Task.isCancelled { return false }
            guard
                let url = resolveURL(repoId: model.id, path: file.path),
                let dest = HuggingFaceService.destinationURL(
                    forRemotePath: file.path,
                    under: directory
                )
            else {
                allSucceeded = false
                continue
            }
            do {
                try await downloader.download(
                    from: url,
                    to: dest,
                    expectedSize: file.size,
                    onProgress: { _, _ in }
                )
            } catch {
                allSucceeded = false
            }
        }
        return allSucceeded
    }

    /// Silently downloads missing config/tokenizer files for models that are
    /// already considered "downloaded". Runs sequentially to avoid hammering
    /// the HF API. Does not mutate `downloadStates` so the UI stays stable.
    /// Only runs once per app lifecycle.
    func topUpCompletedModels(_ models: [MLXModel]) async {
        guard !hasRunTopUp else { return }
        hasRunTopUp = true
        // `isDownloaded` walks each model's directory on a cache miss — a
        // synchronous scan that, run inline on this @MainActor type, tripped
        // the main-thread hang watchdog at launch with many models. Resolve
        // the disk check off the main actor, then apply the main-actor
        // `isActiveDownload` filter back here.
        let downloaded = await Task.detached(priority: .utility) {
            models.filter { $0.isDownloaded }
        }.value
        let candidates = downloaded.filter { !isActiveDownload($0.id) }
        guard !candidates.isEmpty else { return }

        for model in candidates {
            // Stop the (best-effort, lifecycle-once) top-up sweep promptly if
            // the surrounding task is cancelled (e.g. app teardown) instead of
            // walking the full candidate list.
            if Task.isCancelled { return }
            await Self.downloadMissingFiles(for: model, to: model.localDirectory)
        }
    }

    nonisolated static func directoryAllocatedSize(at url: URL) -> Int64? {
        let fileManager = FileManager.default
        var total: Int64 = 0
        guard
            let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [
                    .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey,
                ],
                options: [],
                errorHandler: nil
            )
        else { return nil }
        for case let fileURL as URL in enumerator {
            do {
                let rv = try fileURL.resourceValues(forKeys: [
                    .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
                ])
                guard rv.isRegularFile == true else { continue }
                if let allocated = rv.totalFileAllocatedSize ?? rv.fileAllocatedSize {
                    total += Int64(allocated)
                } else if let size = rv.fileSize {
                    total += Int64(size)
                }
            } catch { continue }
        }
        return total
    }

    private static func hfCacheRoots() -> [URL] {
        let fm = FileManager.default
        var roots: [URL] = []
        if let envCache = ProcessInfo.processInfo.environment["HF_HUB_CACHE"], !envCache.isEmpty {
            roots.append(
                URL(
                    fileURLWithPath: (envCache as NSString).expandingTildeInPath,
                    isDirectory: true
                )
            )
        }
        if let envHome = ProcessInfo.processInfo.environment["HF_HOME"], !envHome.isEmpty {
            let expanded = (envHome as NSString).expandingTildeInPath
            roots.append(
                URL(fileURLWithPath: expanded, isDirectory: true).appendingPathComponent("hub")
            )
        }
        let home = fm.homeDirectoryForCurrentUser
        roots.append(home.appendingPathComponent(".cache/huggingface/hub"))
        if let appCaches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            roots.append(appCaches.appendingPathComponent("huggingface/hub"))
        }
        return roots
    }
}

// MARK: - Direct file downloader with session-level delegate

/// Downloads files using a session-level URLSessionDownloadDelegate for reliable
/// per-byte progress reporting. Supports per-file pause / resume via
/// `URLSessionDownloadTask.cancel(byProducingResumeData:)` so a paused
/// download can pick up from the same byte offset on resume.
final class DirectDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// Thrown by `download(...)` when the user paused the in-flight task via
    /// `pause()`. Carries the resume-data blob (when the server cooperates
    /// with HTTP Range; nil otherwise) plus the highest byte count seen so
    /// far so the orchestration can compute global progress for `.paused`.
    struct PauseInfo: Error {
        let resumeData: Data?
        let bytesDownloaded: Int64
    }

    private let lock = NSLock()
    private var currentContinuation: CheckedContinuation<Void, Error>?
    private var currentDownloadTask: URLSessionDownloadTask?
    private var currentDestination: URL?
    private var currentExpectedSize: Int64?
    private var onProgress: (@Sendable (Int64, Int64) -> Void)?
    private var lastProgressTime: CFAbsoluteTime = 0
    private var lastBytesWritten: Int64 = 0
    /// Set by `pause()` so the `didCompleteWithError(NSURLErrorCancelled)`
    /// delegate callback knows to swallow the cancellation — the
    /// `cancelByProducingResumeData` callback owns the continuation
    /// resumption with `PauseInfo`.
    private var pauseRequested = false
    private static let progressInterval: CFAbsoluteTime = 0.25

    private lazy var session: URLSession = {
        GlobalProxySettings.makeSession(base: .default, delegate: self, delegateQueue: nil)
    }()

    func download(
        from url: URL,
        to destination: URL,
        expectedSize: Int64,
        resumeData: Data? = nil,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            self.currentContinuation = continuation
            self.currentDestination = destination
            self.currentExpectedSize = expectedSize
            self.onProgress = onProgress
            self.lastProgressTime = 0
            self.lastBytesWritten = 0
            self.pauseRequested = false
            let task: URLSessionDownloadTask
            if let resumeData {
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                task = session.downloadTask(with: url)
            }
            self.currentDownloadTask = task
            lock.unlock()
            task.resume()
        }
    }

    /// Suspends the in-flight download, capturing `URLSession`-level resume
    /// data so a future `download(...resumeData:)` call can continue from
    /// the same byte offset. If no download is in flight, this is a no-op.
    func pause() {
        lock.lock()
        guard let task = self.currentDownloadTask else {
            lock.unlock()
            return
        }
        self.pauseRequested = true
        lock.unlock()
        task.cancel(byProducingResumeData: { [weak self] data in
            self?.handlePauseCompletion(resumeData: data)
        })
    }

    private func handlePauseCompletion(resumeData: Data?) {
        lock.lock()
        // Race-guard: `didCompleteWithError(NSURLErrorCancelled)` may have
        // also fired and already cleared the continuation. In that case
        // there's nothing to resume — the swallow-on-pause path in the
        // delegate kept things consistent.
        guard let continuation = self.currentContinuation, self.pauseRequested else {
            lock.unlock()
            return
        }
        let bytes = self.lastBytesWritten
        self.currentContinuation = nil
        self.currentDownloadTask = nil
        self.currentDestination = nil
        self.currentExpectedSize = nil
        self.onProgress = nil
        self.pauseRequested = false
        lock.unlock()
        continuation.resume(throwing: PauseInfo(resumeData: resumeData, bytesDownloaded: bytes))
    }

    func invalidate() { session.invalidateAndCancel() }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes _: Int64
    ) {
        // URLSession reports cumulative `totalBytesWritten` across resumes,
        // so we just seed `lastBytesWritten` with the offset and the next
        // `didWriteData` callback will report the absolute total.
        lock.lock()
        self.lastBytesWritten = fileOffset
        lock.unlock()
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        self.lastBytesWritten = totalBytesWritten
        let elapsed = now - lastProgressTime
        let isFileComplete =
            totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
        guard elapsed >= Self.progressInterval || isFileComplete else {
            lock.unlock()
            return
        }
        lastProgressTime = now
        let progress = onProgress
        lock.unlock()
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let continuation = currentContinuation
        let destination = currentDestination
        let expectedSize = currentExpectedSize
        currentContinuation = nil
        currentDownloadTask = nil
        currentDestination = nil
        currentExpectedSize = nil
        onProgress = nil
        pauseRequested = false
        lock.unlock()
        guard let continuation, let destination else { return }

        if let http = downloadTask.response as? HTTPURLResponse,
            !(200 ..< 300).contains(http.statusCode)
        {
            continuation.resume(
                throwing: URLError(
                    .badServerResponse,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
                )
            )
            return
        }

        do {
            let fm = FileManager.default
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
            if let expectedSize, expectedSize > 0 {
                let attrs = try fm.attributesOfItem(atPath: destination.path)
                let actualSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                if actualSize != expectedSize {
                    try? fm.removeItem(at: destination)
                    continuation.resume(
                        throwing: URLError(
                            .cannotDecodeContentData,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Size mismatch: expected \(expectedSize), got \(actualSize)"
                            ]
                        )
                    )
                    return
                }
            }
            continuation.resume()
        } catch {
            continuation.resume(throwing: error)
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.lock()
        // When pause is in flight the `cancelByProducingResumeData` callback
        // will resume the continuation with `PauseInfo`. Swallow the
        // cancellation here so we don't double-resume.
        if pauseRequested {
            lock.unlock()
            return
        }
        let continuation = currentContinuation
        currentContinuation = nil
        currentDownloadTask = nil
        currentDestination = nil
        currentExpectedSize = nil
        onProgress = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}
