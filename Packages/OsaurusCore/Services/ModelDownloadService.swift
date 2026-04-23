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
    private var downloadTokens: [String: UUID] = [:]
    private var progressSamples: [String: [(timestamp: TimeInterval, completed: Int64)]] = [:]
    private var lastKnownSpeed: [String: Double] = [:]
    private var hasRunTopUp = false

    // MARK: - Download Methods

    func download(_ model: MLXModel) {
        if model.isDownloaded {
            downloadStates[model.id] = .completed
            return
        }
        let state = downloadStates[model.id] ?? .notStarted
        if case .downloading = state { return }

        activeDownloadTasks[model.id]?.cancel()
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

        do {
            try FileManager.default.createDirectory(
                at: model.localDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            downloadStates[model.id] = .failed(
                error: "Failed to create directory: \(error.localizedDescription)"
            )
            clearDownloadTracking(for: model.id)
            return
        }

        let task = Task { [weak self] in
            guard let self = self else { return }

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
                        if self.downloadTokens[model.id] == token {
                            self.downloadStates[model.id] = .failed(
                                error: "Could not retrieve file list from Hugging Face"
                            )
                            self.clearDownloadTracking(for: model.id)
                        }
                    }
                    return
                }

                let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
                var completedFileBytes: Int64 = 0

                var filesToDownload: [HuggingFaceService.MatchedFile] = []
                for file in files {
                    let dest = model.localDirectory.appendingPathComponent(file.path)
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
                        if self.downloadTokens[model.id] == token {
                            self.downloadStates[model.id] = .failed(error: refusal)
                            self.clearDownloadTracking(for: model.id)
                        }
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

                let downloader = DirectDownloader()
                defer { downloader.invalidate() }

                for file in filesToDownload {
                    try Task.checkCancellation()

                    guard let downloadURL = Self.resolveURL(repoId: model.id, path: file.path)
                    else { continue }
                    let destination = model.localDirectory.appendingPathComponent(file.path)

                    let baseCompleted = completedFileBytes
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

                    try await downloader.download(
                        from: downloadURL,
                        to: destination,
                        expectedSize: file.size,
                        onProgress: onProgress
                    )
                    completedFileBytes += file.size
                }

                let completed = model.isDownloaded
                await MainActor.run {
                    if self.downloadTokens[model.id] == token {
                        self.downloadStates[model.id] =
                            completed ? .completed : .failed(error: "Download incomplete")
                        self.clearDownloadTracking(for: model.id)
                        if completed {
                            NotificationService.shared.postModelReady(
                                modelId: model.id,
                                modelName: model.name
                            )
                            ModelManager.invalidateLocalModelsCache()
                            NotificationCenter.default.post(name: .localModelsChanged, object: nil)
                        }
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    if self.downloadTokens[model.id] == token {
                        self.downloadStates[model.id] = .notStarted
                        self.clearDownloadTracking(for: model.id)
                    }
                }
            } catch {
                await MainActor.run {
                    if self.downloadTokens[model.id] == token {
                        self.downloadStates[model.id] = .failed(error: error.localizedDescription)
                        self.clearDownloadTracking(for: model.id)
                    }
                }
            }
        }

        activeDownloadTasks[model.id] = task
    }

    func cancel(_ modelId: String) {
        activeDownloadTasks[modelId]?.cancel()
        activeDownloadTasks[modelId] = nil
        clearDownloadTracking(for: modelId)
        downloadStates[modelId] = .notStarted
    }

    func delete(_ model: MLXModel) {
        activeDownloadTasks[model.id]?.cancel()
        activeDownloadTasks[model.id] = nil
        clearDownloadTracking(for: model.id)

        let fm = FileManager.default
        let localPath = model.localDirectory.path
        if fm.fileExists(atPath: localPath) {
            do {
                try fm.removeItem(atPath: localPath)
            } catch {
                downloadStates[model.id] = .failed(
                    error: "Could not delete model: \(error.localizedDescription)"
                )
                return
            }
        }

        let cacheDirName = "models--\(model.id.replacingOccurrences(of: "/", with: "--"))"
        for cacheRoot in Self.hfCacheRoots() {
            let cacheModelDir = cacheRoot.appendingPathComponent(cacheDirName)
            if fm.fileExists(atPath: cacheModelDir.path) {
                try? fm.removeItem(at: cacheModelDir)
            }
        }

        downloadStates[model.id] = .notStarted
        ModelManager.invalidateLocalModelsCache()
        NotificationCenter.default.post(name: .localModelsChanged, object: nil)
    }

    func estimateSize(for model: MLXModel) async -> Int64? {
        await HuggingFaceService.shared.estimateTotalSize(
            repoId: model.id,
            patterns: Self.downloadFilePatterns,
            excludedFiles: Self.downloadExcludedFiles
        )
    }

    // MARK: - Query Methods

    func effectiveState(for model: MLXModel) -> DownloadState {
        if case .downloading = downloadStates[model.id] {
            return downloadStates[model.id] ?? .notStarted
        }
        return model.isDownloaded ? .completed : (downloadStates[model.id] ?? .notStarted)
    }

    func progress(for modelId: String) -> Double {
        switch downloadStates[modelId] {
        case .downloading(let progress): return progress
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

    var totalDownloadedSize: Int64 {
        let models = ModelManager.discoverLocalModels()
        return
            models
            .filter { $0.isDownloaded }
            .reduce(Int64(0)) { partial, model in
                partial + (Self.directoryAllocatedSize(at: model.localDirectory) ?? 0)
            }
    }

    var totalDownloadedSizeString: String {
        ByteCountFormatter.string(fromByteCount: totalDownloadedSize, countStyle: .file)
    }

    // MARK: - State Management

    /// Sync download states for models, skipping any with active downloads.
    func syncStates(for models: [MLXModel]) {
        for model in models where activeDownloadTasks[model.id] == nil {
            downloadStates[model.id] = model.isDownloaded ? .completed : .notStarted
        }
    }

    // MARK: - Private Helpers

    private func clearDownloadTracking(for modelId: String) {
        downloadTokens[modelId] = nil
        downloadMetrics[modelId] = nil
        progressSamples[modelId] = nil
        lastKnownSpeed[modelId] = nil
    }

    static func resolveURL(repoId: String, path: String) -> URL? {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(encoded)")
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
    /// hosts `url`. Falls back to the older `.systemFreeSize` query if the
    /// modern `.volumeAvailableCapacityForImportantUsageKey` is unavailable.
    /// Returns `nil` if both queries fail — callers should treat `nil` as
    /// "unknown, proceed" rather than "zero, block".
    static func freeBytesOnVolume(containing url: URL) -> Int64? {
        let probe = url
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        if let values = try? probe.resourceValues(forKeys: keys),
            let capacity = values.volumeAvailableCapacityForImportantUsage
        {
            return capacity
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: probe.path),
            let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value
        {
            return free
        }
        return nil
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
            let local = directory.appendingPathComponent(file.path)
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
            guard let url = resolveURL(repoId: model.id, path: file.path) else { continue }
            let dest = directory.appendingPathComponent(file.path)
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
        let candidates = models.filter { $0.isDownloaded && !isActiveDownload($0.id) }
        guard !candidates.isEmpty else { return }

        for model in candidates {
            await Self.downloadMissingFiles(for: model, to: model.localDirectory)
        }
    }

    static func directoryAllocatedSize(at url: URL) -> Int64? {
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
/// per-byte progress reporting.
private final class DirectDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var currentContinuation: CheckedContinuation<Void, Error>?
    private var currentDestination: URL?
    private var currentExpectedSize: Int64?
    private var onProgress: (@Sendable (Int64, Int64) -> Void)?
    private var lastProgressTime: CFAbsoluteTime = 0
    private static let progressInterval: CFAbsoluteTime = 0.25

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    func download(
        from url: URL,
        to destination: URL,
        expectedSize: Int64,
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
            lock.unlock()
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    func invalidate() { session.invalidateAndCancel() }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
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
        currentDestination = nil
        currentExpectedSize = nil
        onProgress = nil
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
        let continuation = currentContinuation
        currentContinuation = nil
        currentDestination = nil
        currentExpectedSize = nil
        onProgress = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}
