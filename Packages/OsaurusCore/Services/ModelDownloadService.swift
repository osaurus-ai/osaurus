//
//  ModelDownloadService.swift
//  osaurus
//
//  Manages MLX model file downloads, cancellation, deletion, and progress tracking.
//  Extracted from ModelManager to separate download orchestration from catalog management.
//

import Foundation
import os

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
                    "Couldn't reach this model on Hugging Face. The repo may be private, gated, removed, or temporarily unreachable. Adding a Hugging Face token from the Catalog tab helps with gated repos and rate limits."
                )
        } else if lower.hasPrefix("http ") {
            title = L("Repository unavailable")
            message =
                L(
                    "Hugging Face responded with \(rawError). For a gated or private repo, add a Hugging Face access token from the Catalog tab; otherwise try again in a moment."
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

    /// How a download's file URLs are obtained. `.direct` is the plain
    /// anonymous `huggingface.co/resolve` URL. `.onboardingProxy` resolves
    /// presigned CDN URLs through the Osaurus model download proxy — used only for the
    /// onboarding flow, where the user hasn't had a chance to add their own
    /// HF token yet and anonymous throttling drives drop-off.
    enum DownloadRoute {
        case direct
        case onboardingProxy
    }

    private var activeDownloadTasks: [String: Task<Void, Never>] = [:]
    /// Route chosen when the download started; survives pause/resume so a
    /// paused onboarding download keeps its fast path.
    private var downloadRoutes: [String: DownloadRoute] = [:]
    /// Commit each proxy-routed model was pinned to by its first resolve, so
    /// a mid-download repo update can't mix shards from different revisions.
    private var proxyPinnedCommits: [String: String] = [:]
    /// Models whose proxy route failed; their remaining files silently fall
    /// back to the direct anonymous URL — slow beats failed in onboarding.
    private var proxyDisabledModels: Set<String> = []
    /// Live downloaders keyed by model id, then by remote file path — one
    /// per in-flight file, since several files transfer concurrently.
    private var activeDownloaders: [String: [String: DirectDownloader]] = [:]
    private var downloadTokens: [String: UUID] = [:]
    private var progressSamples: [String: [(timestamp: TimeInterval, completed: Int64)]] = [:]
    private var lastKnownSpeed: [String: Double] = [:]
    /// Per-model transfer accounting for aggregate progress: bytes from
    /// files already fully on disk (`fileTransferBase`), live per-file byte
    /// counts (`fileTransferProgress`), and the manifest total.
    private var fileTransferProgress: [String: [String: Int64]] = [:]
    private var fileTransferBase: [String: Int64] = [:]
    private var fileTransferTotal: [String: Int64] = [:]
    /// Models whose user-initiated pause is in flight. Transfers sleeping in
    /// a retry backoff have no URLSession task to cancel, so they check this
    /// flag at their next loop iteration instead.
    private var pauseRequestedModels: Set<String> = []
    /// In-memory pause snapshot. Survives a pause within an app session, but
    /// is intentionally not persisted across launches in v1 — `URLSession`
    /// resume data references temporary cache files that don't necessarily
    /// outlive the process. Coarse per-file resume (skip files whose on-disk
    /// size matches the expected size) covers the cross-launch case.
    private var pausedDownloads: [String: PausedSnapshot] = [:]
    private var hasRunTopUp = false

    /// Snapshot captured at the moment the user paused, used by `resume(_:)`
    /// to feed each in-flight file's `cancelByProducingResumeData` blob back
    /// into a fresh `URLSession` download task so the download continues
    /// from the same byte offset.
    private struct PausedSnapshot {
        let resumeDataByFile: [String: Data]
    }

    /// Result of one file's transfer inside the download task group.
    private enum FileTransferOutcome {
        case completed
        case paused(path: String, resumeData: Data?)
        case failed(path: String, error: Error)
    }

    init() {
        HuggingFaceAuth.preloadInBackground()
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

    func download(_ model: MLXModel, route: DownloadRoute = .direct) {
        downloadRoutes[model.id] = route
        proxyPinnedCommits[model.id] = nil
        proxyDisabledModels.remove(model.id)
        startOrchestration(model: model, resuming: nil)
    }

    /// Resumes a previously paused download, picking up each in-flight file
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
        invalidateDownloaders(for: model.id)
        pauseRequestedModels.remove(model.id)
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

            defer {
                Task { @MainActor [weak self] in
                    self?.activeDownloadTasks[model.id] = nil
                }
            }

            // Proxy route: signing needs the wallet identity, which onboarding
            // normally creates only at completion. On a fresh install
            // `OsaurusIdentity.setup()` is silent (no biometric prompt); the
            // later `configureImplicitDefaults` gates on `exists()` and no-ops.
            // If the identity still isn't available, disable the proxy up
            // front so every file takes the anonymous fallback.
            if await MainActor.run(body: { self.downloadRoutes[model.id] }) == .onboardingProxy {
                // `exists()` is a synchronous keychain query (blocks on
                // securityd's mutex) and `setup()` does key generation plus
                // iCloud keychain writes — keep the whole probe off the main
                // actor, which this orchestration Task otherwise inherits.
                // The probe races a 10s timeout: a wedged securityd or slow
                // attestation must degrade to the anonymous route, never
                // stall the download itself.
                let identityReady = await Self.firstResult(timeoutSeconds: 10, fallback: false) {
                    if OsaurusIdentity.exists() { return true }
                    _ = try? await OsaurusIdentity.setup()
                    return OsaurusIdentity.exists()
                }
                if !identityReady {
                    await MainActor.run { _ = self.proxyDisabledModels.insert(model.id) }
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
                    self.fileTransferBase[model.id] = completedFileBytes
                    self.fileTransferProgress[model.id] = [:]
                    self.fileTransferTotal[model.id] = totalBytes
                    let fraction = totalBytes > 0 ? Double(completedFileBytes) / Double(totalBytes) : 0
                    self.downloadStates[model.id] = .downloading(progress: fraction)
                    self.downloadMetrics[model.id] = DownloadMetrics(
                        bytesReceived: completedFileBytes > 0 ? completedFileBytes : 0,
                        totalBytes: totalBytes,
                        bytesPerSecond: nil,
                        etaSeconds: nil
                    )
                }

                // Transfer up to three files at once. Per-connection
                // throughput to the Hugging Face CDN is the bottleneck on
                // most links, and the multi-shard repos are the ones users
                // wait on. Completion order stops mattering — the manifest
                // check below is authoritative.
                let maxConcurrentFiles = 3
                var pausedFiles: [(path: String, resumeData: Data?)] = []
                var firstFailure: (path: String, error: Error)? = nil

                await withTaskGroup(of: FileTransferOutcome.self) { group in
                    var nextIndex = 0
                    var stopScheduling = false

                    while nextIndex < min(maxConcurrentFiles, filesToDownload.count) {
                        let file = filesToDownload[nextIndex]
                        nextIndex += 1
                        let resumeData = resuming?.resumeDataByFile[file.path]
                        group.addTask {
                            await self.transferFile(
                                file,
                                model: model,
                                token: token,
                                resumeData: resumeData
                            )
                        }
                    }

                    while let outcome = await group.next() {
                        switch outcome {
                        case .completed:
                            break
                        case .paused(let path, let resumeData):
                            pausedFiles.append((path, resumeData))
                            stopScheduling = true
                        case .failed(let path, let error):
                            stopScheduling = true
                            if firstFailure == nil, !(error is CancellationError) {
                                firstFailure = (path, error)
                                // Abort the sister transfers promptly; they
                                // surface as cancellations, which the
                                // aggregation above ignores.
                                await MainActor.run {
                                    self.invalidateDownloaders(for: model.id)
                                }
                            }
                        }
                        if !stopScheduling, nextIndex < filesToDownload.count {
                            let file = filesToDownload[nextIndex]
                            nextIndex += 1
                            let resumeData = resuming?.resumeDataByFile[file.path]
                            group.addTask {
                                await self.transferFile(
                                    file,
                                    model: model,
                                    token: token,
                                    resumeData: resumeData
                                )
                            }
                        }
                    }
                }

                try Task.checkCancellation()

                if !pausedFiles.isEmpty {
                    var resumeDataByFile: [String: Data] = [:]
                    for paused in pausedFiles {
                        if let data = paused.resumeData {
                            resumeDataByFile[paused.path] = data
                        }
                    }
                    await MainActor.run {
                        self.commitPause(
                            modelId: model.id,
                            token: token,
                            resumeDataByFile: resumeDataByFile
                        )
                    }
                    return
                }

                if let firstFailure {
                    await MainActor.run {
                        self.finalizeOrchestration(
                            modelId: model.id,
                            token: token,
                            finalState: .failed(
                                error: firstFailure.error.localizedDescription
                            ),
                            failureStage: "file-transfer",
                            failureFilePath: firstFailure.path
                        )
                    }
                    return
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
            } catch is CancellationError {
                await MainActor.run {
                    self.finalizeOrchestration(
                        modelId: model.id,
                        token: token,
                        finalState: .notStarted
                    )
                }
            } catch {
                await MainActor.run {
                    self.finalizeOrchestration(
                        modelId: model.id,
                        token: token,
                        finalState: .failed(error: error.localizedDescription),
                        failureStage: "orchestration"
                    )
                }
            }
        }

        activeDownloadTasks[model.id] = task
    }

    /// Downloads one manifest file, retrying transient failures. Runs as a
    /// task-group child; being a method on this `@MainActor` service keeps
    /// every touch of the shared accounting state serialized.
    private func transferFile(
        _ file: HuggingFaceService.MatchedFile,
        model: MLXModel,
        token: UUID,
        resumeData: Data?
    ) async -> FileTransferOutcome {
        guard
            let destination = HuggingFaceService.destinationURL(
                forRemotePath: file.path,
                under: model.localDirectory
            ),
            let directURL = Self.resolveURL(repoId: model.id, path: file.path)
        else {
            // Unresolvable path: skip; the manifest completion check reports it.
            return .completed
        }

        let downloader = DirectDownloader()
        activeDownloaders[model.id, default: [:]][file.path] = downloader
        defer {
            activeDownloaders[model.id]?[file.path] = nil
            downloader.invalidate()
        }

        let onProgress: @Sendable (Int64, Int64) -> Void = { [weak self] bytesWritten, _ in
            Task { @MainActor [weak self] in
                self?.recordFileProgress(
                    modelId: model.id,
                    token: token,
                    path: file.path,
                    bytes: bytesWritten
                )
            }
        }

        var attempt = 1
        var resumeDataForAttempt = resumeData
        while true {
            if pauseRequestedModels.contains(model.id) {
                return .paused(path: file.path, resumeData: resumeDataForAttempt)
            }
            guard downloadTokens[model.id] == token else {
                return .failed(path: file.path, error: CancellationError())
            }
            let proxyRoute =
                downloadRoutes[model.id] == .onboardingProxy
                && !proxyDisabledModels.contains(model.id)
            var downloadURL = directURL
            // Resume data continues the previous attempt's URL, so a fresh
            // resolve is only needed when starting the file from scratch.
            if proxyRoute, resumeDataForAttempt == nil {
                // Same orphaning timeout as the identity probe: the signing
                // step reads the master key, and a keychain wedged behind a
                // pending ACL dialog must degrade to the anonymous URL, not
                // freeze the transfer.
                let revision = proxyPinnedCommits[model.id] ?? "main"
                let repoId = model.id
                let filePath = file.path
                if let resolved = await Self.firstResult(timeoutSeconds: 15, fallback: nil, operation: {
                    await OnboardingModelsProxy.shared.resolve(
                        repoId: repoId,
                        revision: revision,
                        path: filePath
                    )
                }) {
                    downloadURL = resolved.url
                    if proxyPinnedCommits[model.id] == nil, let commit = resolved.commit {
                        proxyPinnedCommits[model.id] = commit
                    }
                } else {
                    proxyDisabledModels.insert(model.id)
                }
            }
            do {
                try await downloader.download(
                    from: downloadURL,
                    to: destination,
                    expectedSize: file.size,
                    resumeData: resumeDataForAttempt,
                    onProgress: onProgress
                )
                finishFileTransfer(modelId: model.id, token: token, path: file.path, size: file.size)
                return .completed
            } catch let pauseInfo as DirectDownloader.PauseInfo {
                notePausedFileBytes(
                    modelId: model.id,
                    token: token,
                    path: file.path,
                    bytes: pauseInfo.bytesDownloaded
                )
                return .paused(path: file.path, resumeData: pauseInfo.resumeData)
            } catch {
                // A failed attempt's URLSession temp file is gone; any retry
                // restarts this file from byte zero.
                resumeDataForAttempt = nil
                // Presigned proxy URLs expire after hours; a CDN 403 on the
                // proxy route just means "re-resolve on the next attempt",
                // not a real failure.
                let isExpiredProxyURL =
                    proxyRoute
                    && (error as? DirectDownloader.HTTPStatusError)?.statusCode == 403
                guard
                    attempt < Self.maxTransferAttempts,
                    isExpiredProxyURL || Self.isRetryableTransferError(error)
                else {
                    // The proxy is an accelerator, not a gatekeeper: never
                    // surface a proxy-routed failure. Disable the proxy for
                    // this model and restart the file on the plain anonymous
                    // HF URL with a fresh retry budget.
                    if proxyRoute {
                        proxyDisabledModels.insert(model.id)
                        attempt = 1
                        continue
                    }
                    return .failed(path: file.path, error: error)
                }
                let delay = Self.transferRetryDelay(attempt: attempt, error: error)
                attempt += 1
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return .failed(path: file.path, error: CancellationError())
                }
            }
        }
    }

    /// Record live byte progress for one in-flight file and republish the
    /// model's aggregate progress.
    private func recordFileProgress(modelId: String, token: UUID, path: String, bytes: Int64) {
        guard downloadTokens[modelId] == token else { return }
        fileTransferProgress[modelId, default: [:]][path] = bytes
        guard !pauseRequestedModels.contains(modelId) else { return }
        publishAggregateProgress(modelId: modelId, token: token)
    }

    /// Freeze a paused file's byte count without republishing `.downloading`
    /// state — `commitPause` reads it for the final paused metrics.
    private func notePausedFileBytes(modelId: String, token: UUID, path: String, bytes: Int64) {
        guard downloadTokens[modelId] == token else { return }
        fileTransferProgress[modelId, default: [:]][path] = bytes
    }

    /// Fold a finished file into the completed-bytes base.
    private func finishFileTransfer(modelId: String, token: UUID, path: String, size: Int64) {
        guard downloadTokens[modelId] == token else { return }
        fileTransferProgress[modelId]?[path] = nil
        fileTransferBase[modelId, default: 0] += size
        guard !pauseRequestedModels.contains(modelId) else { return }
        publishAggregateProgress(modelId: modelId, token: token)
    }

    private func publishAggregateProgress(modelId: String, token: UUID) {
        let completed =
            (fileTransferBase[modelId] ?? 0)
            + (fileTransferProgress[modelId]?.values.reduce(0, +) ?? 0)
        updateDownloadProgress(
            modelId: modelId,
            token: token,
            completedBytes: completed,
            totalBytes: fileTransferTotal[modelId] ?? 0
        )
    }

    private func invalidateDownloaders(for modelId: String) {
        activeDownloaders[modelId]?.values.forEach { $0.invalidate() }
        activeDownloaders[modelId] = nil
    }

    /// Token-guarded transition from `.downloading` → `.paused`. Freezes
    /// `downloadMetrics` (clears speed/ETA, keeps received/total bytes so
    /// the user still sees "X / Y"), drops the live downloaders/task, and
    /// stashes each in-flight file's resume-data blob so a later
    /// `resume(_:)` can hand them to fresh `URLSessionDownloadTask`s.
    private func commitPause(
        modelId: String,
        token: UUID,
        resumeDataByFile: [String: Data]
    ) {
        guard downloadTokens[modelId] == token else { return }
        let total = fileTransferTotal[modelId] ?? downloadMetrics[modelId]?.totalBytes ?? 0
        let completed =
            (fileTransferBase[modelId] ?? 0)
            + (fileTransferProgress[modelId]?.values.reduce(0, +) ?? 0)
        let fraction =
            total > 0
            ? min(1.0, max(0.0, Double(completed) / Double(total)))
            : 0
        downloadStates[modelId] = .paused(progress: fraction)
        downloadMetrics[modelId] = DownloadMetrics(
            bytesReceived: completed,
            totalBytes: total > 0 ? total : nil,
            bytesPerSecond: nil,
            etaSeconds: nil
        )
        progressSamples[modelId] = []
        lastKnownSpeed[modelId] = nil
        fileTransferProgress[modelId] = nil
        fileTransferBase[modelId] = nil
        fileTransferTotal[modelId] = nil
        pauseRequestedModels.remove(modelId)
        pausedDownloads[modelId] = PausedSnapshot(resumeDataByFile: resumeDataByFile)
        invalidateDownloaders(for: modelId)
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

        if let downloaders = activeDownloaders[modelId], !downloaders.isEmpty {
            // Flag first: transfers waiting in a retry backoff have no live
            // URLSession task for `pause()` to cancel, and pick the flag up
            // at their next loop iteration instead.
            pauseRequestedModels.insert(modelId)
            for downloader in downloaders.values {
                downloader.pause()
            }
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
        fileTransferProgress[modelId] = nil
        fileTransferBase[modelId] = nil
        fileTransferTotal[modelId] = nil
        pauseRequestedModels.remove(modelId)
        if let metrics = downloadMetrics[modelId] {
            downloadMetrics[modelId] = DownloadMetrics(
                bytesReceived: metrics.bytesReceived,
                totalBytes: metrics.totalBytes,
                bytesPerSecond: nil,
                etaSeconds: nil
            )
        }
        pausedDownloads[modelId] = PausedSnapshot(resumeDataByFile: [:])
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
        fileTransferProgress[modelId] = nil
        fileTransferBase[modelId] = nil
        fileTransferTotal[modelId] = nil
        pauseRequestedModels.remove(modelId)
    }

    /// Cancels the orchestration `Task` and tears down the per-model
    /// `DirectDownloader`. Safe to call from any path before transitioning
    /// to a terminal state. Doesn't touch `downloadStates` /
    /// `downloadMetrics` / `pausedDownloads` so callers stay in control of
    /// the published surface.
    private func releaseOrchestrationResources(for modelId: String) {
        activeDownloadTasks[modelId]?.cancel()
        activeDownloadTasks[modelId] = nil
        invalidateDownloaders(for: modelId)
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
        invalidateDownloaders(for: modelId)
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

    // MARK: - Transfer retry policy

    /// Attempts per file: one initial try plus up to three retries. Transient
    /// failures (Hugging Face rate limiting, connection blips) otherwise kill
    /// a multi-GB download that's 90% done and force a manual Retry.
    nonisolated static let maxTransferAttempts = 4

    nonisolated static func isRetryableTransferError(_ error: Error) -> Bool {
        if error is DirectDownloader.PauseInfo || error is CancellationError { return false }
        if let status = error as? DirectDownloader.HTTPStatusError {
            return status.statusCode == 408 || status.statusCode == 429
                || (500 ... 599).contains(status.statusCode)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
                .cannotDecodeContentData:
                // .cannotDecodeContentData is the downloader's size-mismatch
                // error: a truncated transfer, which a fresh attempt fixes.
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Delay before retry number `attempt` (1-based): the server's
    /// `Retry-After` when it sent one (capped at 120s), otherwise
    /// exponential backoff capped at 15s.
    nonisolated static func transferRetryDelay(attempt: Int, error: Error) -> TimeInterval {
        if let status = error as? DirectDownloader.HTTPStatusError,
            let after = status.retryAfterSeconds, after > 0
        {
            return min(after, 120)
        }
        return min(pow(2.0, Double(attempt - 1)), 15)
    }

    /// Run `operation` detached and return its result, or `fallback` if it
    /// hasn't finished within `timeoutSeconds`. Unlike a task group, this
    /// never waits on the operation after the deadline: a child stuck in an
    /// uncancellable syscall (e.g. a keychain read blocked behind a pending
    /// ACL permission dialog) is simply orphaned, and the caller moves on.
    nonisolated static func firstResult<T: Sendable>(
        timeoutSeconds: UInt64,
        fallback: T,
        operation: @escaping @Sendable () async -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func resumeOnce(_ value: T) {
                let shouldResume = resumed.withLock { alreadyResumed -> Bool in
                    if alreadyResumed { return false }
                    alreadyResumed = true
                    return true
                }
                if shouldResume { continuation.resume(returning: value) }
            }
            Task.detached(priority: .userInitiated) {
                resumeOnce(await operation())
            }
            Task.detached(priority: .userInitiated) {
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                resumeOnce(fallback)
            }
        }
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

    /// Non-2xx terminal response, carrying enough for the retry policy to
    /// distinguish transient throttling (429/5xx, optional `Retry-After`)
    /// from permanent failures (404/401/403).
    struct HTTPStatusError: LocalizedError {
        let statusCode: Int
        let retryAfterSeconds: Double?
        var errorDescription: String? { "HTTP \(statusCode)" }
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
    /// Set under `lock` before `invalidateAndCancel()`. Creating a task on an
    /// invalidated `URLSession` raises an uncatchable NSGenericException, and
    /// orchestration teardown (`invalidate()` in a `defer` / pause + cancel)
    /// races with the next `download(...)` call; the flag turns that race
    /// into a thrown `URLError(.cancelled)` instead of a crash.
    private var isInvalidated = false
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
            if self.isInvalidated {
                lock.unlock()
                continuation.resume(throwing: URLError(.cancelled))
                return
            }
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
                var request = URLRequest(url: url)
                // Presigned CDN URLs (the onboarding proxy route) carry their
                // auth in the query string; same token-hygiene rule as the
                // redirect handler below — the user's HF token only ever
                // travels to huggingface.co itself.
                if url.host == "huggingface.co" {
                    HuggingFaceAuth.authorize(&request)
                }
                task = session.downloadTask(with: request)
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

    func invalidate() {
        lock.lock()
        isInvalidated = true
        lock.unlock()
        session.invalidateAndCancel()
    }

    /// Terminal session teardown. Flush any continuation the per-task
    /// callbacks didn't get to (e.g. a task cancelled by
    /// `invalidateAndCancel()` racing the flag set above) so the awaiting
    /// downloader never deadlocks.
    func urlSession(_: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock()
        isInvalidated = true
        let continuation = currentContinuation
        currentContinuation = nil
        currentDownloadTask = nil
        currentDestination = nil
        currentExpectedSize = nil
        onProgress = nil
        pauseRequested = false
        lock.unlock()
        continuation?.resume(throwing: error ?? URLError(.cancelled))
    }

    /// `resolve/main` URLs 302-redirect to Hugging Face's CDN. Don't leak the
    /// user's access token to that (or any other) third-party host: the
    /// Authorization header only travels while the request stays on the host
    /// it was originally sent to. Mirrors what `huggingface_hub` does.
    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirected = request
        if redirected.url?.host != task.originalRequest?.url?.host {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirected)
    }

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
                throwing: HTTPStatusError(
                    statusCode: http.statusCode,
                    retryAfterSeconds: http.value(forHTTPHeaderField: "Retry-After")
                        .flatMap(Double.init)
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
