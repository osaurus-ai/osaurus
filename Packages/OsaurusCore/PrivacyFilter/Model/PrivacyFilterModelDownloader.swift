//
//  PrivacyFilterModelDownloader.swift
//  osaurus / PrivacyFilter
//
//  Drives the download of the converted detection model bundle
//  (`mlx-community/openai-privacy-filter-bf16`) into Application
//  Support / Osaurus / aux-models / <version>/, then synthesizes a
//  local `osaurus-manifest.json` from Hugging Face's tree metadata
//  so subsequent `reverify` calls can detect corruption or partial
//  writes.
//
//  We intentionally don't reuse `ModelDownloadService` here because
//  the bundle is structurally different from an MLX LLM bundle and
//  must not appear in the chat model picker.
//

import Foundation

/// Download / verify lifecycle state visible to SwiftUI.
public enum PrivacyFilterDownloadState: Equatable, Sendable {
    case idle
    case enumerating
    /// `bytesDownloaded` / `bytesTotal` are aggregated across every
    /// file in the bundle so the UI can render a single progress bar.
    case downloading(
        fileIndex: Int,
        fileCount: Int,
        fileName: String,
        bytesDownloaded: Int64,
        bytesTotal: Int64
    )
    case verifying
    case ready
    case failed(String)
}

@MainActor
public final class PrivacyFilterModelDownloader: NSObject, ObservableObject {
    public static let shared = PrivacyFilterModelDownloader()

    /// Hugging Face repo id hosting the converted bundle. Configurable
    /// for tests / future re-hosts. Defaults to the official
    /// mlx-community conversion of `openai/privacy-filter`.
    public static var repoId: String = "mlx-community/openai-privacy-filter-bf16"

    /// File patterns we fetch from the repo. Matches the actual upload
    /// layout — `mlx-community/openai-privacy-filter-bf16` ships a
    /// single safetensors blob alongside its tokenizer.
    private static let filePatterns: [String] = [
        "config.json",
        "model.safetensors",
        "model.safetensors.index.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "viterbi_calibration.json",
    ]

    @Published public private(set) var state: PrivacyFilterDownloadState

    private var currentTask: Task<Void, Never>?
    private var session: URLSession?
    /// Maps the temporary `URLSessionDownloadTask.taskIdentifier` to the
    /// continuation that's waiting for the final destination URL.
    private var inflightContinuations: [Int: CheckedContinuation<URL, Error>] = [:]
    /// Progress observers keyed by task id so we don't leak KVO subscriptions.
    private var inflightObservers: [Int: NSKeyValueObservation] = [:]

    private override init() {
        let directory = PrivacyFilterModelBundle.directoryURL()
        if PrivacyFilterModelBundle.exists(at: directory) {
            self.state = .ready
        } else {
            self.state = .idle
        }
        super.init()

        // If the bundle is on disk, warm the engine in the background
        // so the first chat after launch doesn't see an unloaded
        // engine. We don't block init — the chat pipeline has a
        // lazy-load fallback that catches the rare case where the
        // first chat fires before this background load completes.
        if case .ready = state {
            Task { [weak self] in
                do {
                    try await PrivacyFilterEngine.shared.loadIfNeeded(bundle: directory)
                    print("[PrivacyFilter] Engine warmed at startup from \(directory.lastPathComponent).")
                } catch {
                    print(
                        "[PrivacyFilter] Engine warm-up failed: \(error.localizedDescription). Falling back to lazy load."
                    )
                    // Don't downgrade the UI state — the bundle is still
                    // present and verifiable; the user can hit Re-verify
                    // to retry, or the next chat will lazy-load.
                    _ = self
                }
            }
        }
    }

    // MARK: - Public API

    public func startDownload() {
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.runDownload()
        }
    }

    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
        if case .downloading = state { state = .idle }
        if case .enumerating = state { state = .idle }
        if case .verifying = state { state = .idle }
    }

    public func reverify() {
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.runVerify()
        }
    }

    /// Delete the on-disk bundle and reset state back to `.idle`. The
    /// next call to `startDownload()` will fetch a fresh copy from
    /// Hugging Face. Used by the "Remove model bundle" affordance in
    /// the Model settings tab.
    ///
    /// Synchronously transitions the published state so the UI
    /// updates without waiting for an async task. `clean()` is a
    /// single `removeItem` call on a directory we own, so blocking
    /// the main actor here is microseconds.
    public func remove() {
        currentTask?.cancel()
        currentTask = nil
        try? PrivacyFilterModelBundle.clean()
        state = .idle
    }

    // MARK: - Download pipeline

    private func runDownload() async {
        let directory = PrivacyFilterModelBundle.directoryURL()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            state = .failed("Could not create bundle directory: \(error.localizedDescription)")
            return
        }

        state = .enumerating

        // Fetch HF's tree metadata so we know sizes (for progress) +
        // LFS sha256s (for our local manifest).
        guard
            let files = await HuggingFaceTreeService.fetchTree(repoId: Self.repoId),
            !files.isEmpty
        else {
            state = .failed("Could not list \(Self.repoId) on Hugging Face. Check your connection.")
            return
        }

        // Filter to files we actually want.
        let wanted = files.filter { node in
            let name = (node.path as NSString).lastPathComponent
            return Self.filePatterns.contains(name)
        }
        if wanted.isEmpty {
            state = .failed("\(Self.repoId) does not contain the expected bundle files.")
            return
        }

        // Bytes total powers the single aggregated progress bar.
        let bytesTotal = wanted.reduce(Int64(0)) { $0 + $1.size }
        var bytesDownloaded: Int64 = 0

        let session = Self.makeDownloadSession(delegate: self)
        self.session = session

        for (index, file) in wanted.enumerated() {
            if Task.isCancelled { state = .idle; cleanupSession(); return }
            guard let url = Self.resolveURL(repoId: Self.repoId, path: file.path) else {
                state = .failed("Could not build download URL for \(file.path).")
                cleanupSession()
                return
            }
            let destination = directory.appendingPathComponent(
                (file.path as NSString).lastPathComponent
            )
            let snapshotBytes = bytesDownloaded
            state = .downloading(
                fileIndex: index,
                fileCount: wanted.count,
                fileName: (file.path as NSString).lastPathComponent,
                bytesDownloaded: snapshotBytes,
                bytesTotal: bytesTotal
            )

            do {
                let tempURL = try await downloadWithProgress(
                    session: session,
                    url: url,
                    fileName: (file.path as NSString).lastPathComponent,
                    fileIndex: index,
                    fileCount: wanted.count,
                    bytesAlreadyDownloaded: snapshotBytes,
                    bytesTotal: bytesTotal
                )
                if FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempURL, to: destination)
                bytesDownloaded += file.size
            } catch is CancellationError {
                state = .idle
                cleanupSession()
                return
            } catch {
                state = .failed("Download failed for \(file.path): \(error.localizedDescription)")
                cleanupSession()
                return
            }
        }

        cleanupSession()

        // Synthesize the local manifest from the HF tree response so
        // re-verify has something to hash against.
        var entries: [String: PrivacyFilterModelBundle.ManifestEntry] = [:]
        for file in wanted {
            let key = (file.path as NSString).lastPathComponent
            entries[key] = PrivacyFilterModelBundle.ManifestEntry(
                size: file.size,
                sha256: file.lfsSha256
            )
        }
        do {
            try PrivacyFilterModelBundle.writeManifest(
                PrivacyFilterModelBundle.Manifest(
                    repoId: Self.repoId,
                    revision: "main",
                    files: entries
                ),
                at: directory
            )
        } catch {
            state = .failed("Could not write local manifest: \(error.localizedDescription)")
            return
        }

        await verifyAndFinalize(at: directory)
    }

    private func cleanupSession() {
        session?.invalidateAndCancel()
        session = nil
        for (_, observer) in inflightObservers { observer.invalidate() }
        inflightObservers.removeAll()
        inflightContinuations.removeAll()
    }

    nonisolated static func makeDownloadSession(delegate: URLSessionDownloadDelegate) -> URLSession {
        GlobalProxySettings.makeSession(base: .default, delegate: delegate, delegateQueue: nil)
    }

    private func runVerify() async {
        await verifyAndFinalize(at: PrivacyFilterModelBundle.directoryURL())
    }

    private func verifyAndFinalize(at directory: URL) async {
        state = .verifying
        do {
            // `verify` streams SHA-256 over every bundle file, including the
            // multi-GB safetensors weights. That hashing must not run on the
            // main actor — it blocks the UI for seconds on finalize.
            try await Task.detached(priority: .userInitiated) {
                try PrivacyFilterModelBundle.verify(at: directory)
            }.value
        } catch {
            state = .failed("Bundle verification failed: \(error.localizedDescription)")
            return
        }
        do {
            try await PrivacyFilterEngine.shared.loadIfNeeded(bundle: directory)
        } catch {
            state = .failed("Bundle loaded but engine init failed: \(error.localizedDescription)")
            return
        }
        state = .ready
    }

    // MARK: - URL builder

    private static func resolveURL(repoId: String, path: String) -> URL? {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(encoded)")
    }

    // MARK: - Per-file download with KVO progress

    private func downloadWithProgress(
        session: URLSession,
        url: URL,
        fileName: String,
        fileIndex: Int,
        fileCount: Int,
        bytesAlreadyDownloaded: Int64,
        bytesTotal: Int64
    ) async throws -> URL {
        let task = session.downloadTask(with: url)
        let observer = task.progress.observe(\.fractionCompleted, options: [.new]) {
            [weak self] progress, _ in
            guard let self else { return }
            // Hop to MainActor explicitly because KVO fires off-actor.
            let received = progress.completedUnitCount
            Task { @MainActor in
                self.state = .downloading(
                    fileIndex: fileIndex,
                    fileCount: fileCount,
                    fileName: fileName,
                    bytesDownloaded: bytesAlreadyDownloaded + received,
                    bytesTotal: bytesTotal
                )
            }
        }
        inflightObservers[task.taskIdentifier] = observer

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                inflightContinuations[task.taskIdentifier] = continuation
                task.resume()
            }
        } onCancel: { [weak task] in
            task?.cancel()
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension PrivacyFilterModelDownloader: URLSessionDownloadDelegate {
    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temp file lives only until this delegate returns, so
        // move it somewhere stable before yielding control back to the
        // suspended task.
        let stash = FileManager.default.temporaryDirectory.appendingPathComponent(
            "privacy-filter-\(UUID().uuidString)"
        )
        do {
            try FileManager.default.moveItem(at: location, to: stash)
        } catch {
            Task { @MainActor [weak self] in
                self?.resumeContinuation(taskId: downloadTask.taskIdentifier, with: .failure(error))
            }
            return
        }

        // Reject HTTP errors here too — `URLSessionDownloadTask` reports
        // them via the response, not as a throwing error.
        if let response = downloadTask.response as? HTTPURLResponse,
            !(200 ..< 300).contains(response.statusCode)
        {
            try? FileManager.default.removeItem(at: stash)
            let err = NSError(
                domain: "PrivacyFilterModelDownloader",
                code: response.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(response.statusCode)"]
            )
            Task { @MainActor [weak self] in
                self?.resumeContinuation(taskId: downloadTask.taskIdentifier, with: .failure(err))
            }
            return
        }

        Task { @MainActor [weak self] in
            self?.resumeContinuation(taskId: downloadTask.taskIdentifier, with: .success(stash))
        }
    }

    public nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            self?.resumeContinuation(taskId: task.taskIdentifier, with: .failure(error))
        }
    }

    private func resumeContinuation(taskId: Int, with result: Result<URL, Error>) {
        guard let continuation = inflightContinuations.removeValue(forKey: taskId) else { return }
        inflightObservers.removeValue(forKey: taskId)?.invalidate()
        continuation.resume(with: result)
    }
}

// MARK: - HF tree fetcher (privacy-filter specific)

/// Privacy-filter–local view of the HF tree response so we can capture
/// `lfs.oid` (real sha256) for the giant safetensors blob. The shared
/// `HuggingFaceService.fetchMatchingFiles` strips that field, so we
/// re-implement the minimal call here rather than widen its public
/// `MatchedFile` shape just for this caller.
private enum HuggingFaceTreeService {
    struct TreeFile {
        let path: String
        let size: Int64
        let lfsSha256: String?
    }

    static func fetchTree(repoId: String) async -> [TreeFile]? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "huggingface.co"
        comps.path = "/api/models/\(repoId)/tree/main"
        comps.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        guard let url = comps.url else { return nil }

        struct Node: Decodable {
            let path: String
            let type: String?
            let size: Int64?
            let lfs: LFS?
            struct LFS: Decodable { let oid: String?; let size: Int64? }
        }

        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await GlobalProxySettings.sharedSession().data(for: req)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                return nil
            }
            let nodes = try JSONDecoder().decode([Node].self, from: data)
            return nodes.compactMap { node in
                guard node.type != "directory" else { return nil }
                let size = node.size ?? node.lfs?.size ?? 0
                guard size > 0 else { return nil }
                return TreeFile(
                    path: node.path,
                    size: size,
                    lfsSha256: node.lfs?.oid
                )
            }
        } catch {
            return nil
        }
    }
}
