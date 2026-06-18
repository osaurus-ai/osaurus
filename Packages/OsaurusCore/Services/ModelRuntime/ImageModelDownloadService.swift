//
//  ImageModelDownloadService.swift
//  osaurus
//
//  Stages full mflux image-model bundles (HuggingFace diffusers repos with
//  nested transformer/ text_encoder/ vae/ tokenizer/ subdirs) into the image
//  models root so the engine — which never downloads silently — can load them.
//
//  Reuses the existing download machinery (`HuggingFaceService` for the file
//  manifest, `DirectDownloader` for per-file fetch with subdir-preserving
//  destinations) but keeps image concerns separate from the LLM `MLXModel`
//  catalog (whose `isDownloaded`/manifest logic assumes a flat LLM layout).
//

import Foundation

/// A downloadable image model. `id` is the local bundle directory name (and the
/// request id used everywhere else); it's derived from the repo's last path
/// component so the store's fuzzy resolver maps it to a canonical family.
public struct ImageModelDownload: Identifiable, Sendable, Hashable {
    public let id: String
    public let repoId: String
    public let displayName: String
    public let note: String?

    public init(repoId: String, displayName: String, note: String? = nil) {
        self.id = ImageModelDownload.directoryName(forRepoId: repoId)
        self.repoId = repoId
        self.displayName = displayName
        self.note = note
    }

    /// Local directory name for a repo id: its last path component.
    public static func directoryName(forRepoId repoId: String) -> String {
        repoId.split(separator: "/").last.map(String.init) ?? repoId
    }
}

@MainActor
final class ImageModelDownloadService: ObservableObject {
    static let shared = ImageModelDownloadService()

    @Published private(set) var states: [String: DownloadState] = [:]
    @Published private(set) var metrics: [String: ModelDownloadService.DownloadMetrics] = [:]

    /// Curated, known-public mirrors. Most users will paste a repo id via the
    /// UI's custom field instead — any mflux bundle works as long as its repo
    /// name carries a recognizable family token (z-image, flux1-schnell,
    /// qwen-image, ideogram, …). Seeded with the Ideogram mirrors named in the
    /// vMLX integration spec; extend as more public mflux repos are verified.
    static let catalog: [ImageModelDownload] = [
        ImageModelDownload(
            repoId: "cocktailpeanut/ideogram-4-fp8",
            displayName: "Ideogram 4 (fp8)",
            note: "Strong typography renderer."
        ),
        ImageModelDownload(
            repoId: "cocktailpeanut/ideogram-4-nf4",
            displayName: "Ideogram 4 (NF4)",
            note: "4-bit; smaller footprint."
        ),
    ]

    /// File patterns to stage. Matched against each file's name across all
    /// subdirectories, so nested `transformer/*.safetensors` etc. are included.
    private static let patterns = [
        "*.safetensors", "*.json", "*.txt", "*.model", "*.jinja", "*.bin", "*.merges",
    ]
    private static let excluded: Set<String> = ["README.md", ".gitattributes"]

    /// Hidden marker written into each staged bundle recording the source HF
    /// repo id, so a later re-download knows where to fetch from (installed
    /// bundles otherwise only carry the local directory name).
    private static let sourceMarkerName = ".osaurus-source"

    /// Max files staged in parallel. A single HTTPS connection to the HF CDN is
    /// throttled well below a fast link, so serial per-file fetches leave most
    /// of the pipe idle; mflux bundles are several large files, so fetching a
    /// handful at once keeps the connection saturated.
    private static let maxConcurrentFiles = 4

    private var tasks: [String: Task<Void, Never>] = [:]
    /// All in-flight downloaders for a bundle, so `cancel` can stop every lane.
    private var downloaders: [String: [DirectDownloader]] = [:]
    /// Live absolute bytes received per file, keyed `[dirName][remotePath]`. The
    /// sum across a bundle's files drives its aggregate progress while several
    /// download concurrently.
    private var liveBytes: [String: [String: Int64]] = [:]
    /// Trailing throughput samples per bundle for a stable speed/ETA readout.
    private var speedSamples: [String: [(t: TimeInterval, bytes: Int64)]] = [:]

    /// True when a bundle directory for `id` already exists on disk.
    func isInstalled(_ id: String) -> Bool {
        let dir = ImageGenerationService.imageModelsRoot().appendingPathComponent(id, isDirectory: true)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Source HF repo a staged bundle was downloaded from. Reads the hidden
    /// marker; falls back to a curated catalog entry with the same id. `nil`
    /// when neither is known (e.g. an old imported bundle), in which case
    /// re-download is unavailable and only delete is offered.
    func sourceRepoId(for id: String) -> String? {
        let marker = ImageGenerationService.imageModelsRoot()
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(Self.sourceMarkerName)
        if let raw = try? String(contentsOf: marker, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return Self.catalog.first { $0.id == id }?.repoId
    }

    /// Delete a staged bundle from disk, cancel any in-flight download, and
    /// refresh listeners + the picker cache so it disappears everywhere.
    func delete(_ id: String) {
        cancel(id)
        let dir = ImageGenerationService.imageModelsRoot()
            .appendingPathComponent(id, isDirectory: true)
        states[id] = nil
        metrics[id] = nil
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: dir)
            await MainActor.run {
                NotificationCenter.default.post(name: .localModelsChanged, object: nil)
            }
            await ModelPickerItemCache.shared.buildModelPickerItems()
        }
    }

    /// Record the source repo for a bundle so it can be re-downloaded later.
    /// Runs off the main actor to keep file I/O off the UI thread.
    private func writeSourceMarker(repoId: String, root: URL) {
        let sourceMarkerName = Self.sourceMarkerName
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
            try? repoId.write(
                to: root.appendingPathComponent(sourceMarkerName),
                atomically: true, encoding: .utf8)
        }
    }

    /// Heuristic: does this HF repo look like a diffusers/mflux image bundle?
    /// Used by the global Import flow to route image repos here instead of the
    /// LLM path (which rejects them and would stage to the wrong directory).
    /// Detects the diffusers layout — a top-level `model_index.json`, or a
    /// `vae/` alongside a `transformer/`/`unet/` subdir — which mflux mirrors
    /// preserve. Returns `false` on any listing failure so the caller falls
    /// back to the existing LLM compatibility check.
    static func isImageRepo(_ repoId: String) async -> Bool {
        guard
            let files = await HuggingFaceService.shared.fetchMatchingFiles(
                repoId: repoId, patterns: patterns, excludedFiles: excluded)
        else { return false }
        let paths = files.map { $0.path.lowercased() }
        let hasModelIndex = paths.contains { $0 == "model_index.json" }
        let hasVAE = paths.contains { $0.hasPrefix("vae/") || $0.contains("/vae/") }
        let hasTransformer = paths.contains { path in
            path.hasPrefix("transformer/") || path.contains("/transformer/")
                || path.hasPrefix("unet/") || path.contains("/unet/")
        }
        return hasModelIndex || (hasVAE && hasTransformer)
    }

    func download(_ entry: ImageModelDownload) {
        download(repoId: entry.repoId, displayName: entry.displayName)
    }

    /// Start downloading any HuggingFace mflux repo into the image models root.
    func download(repoId: String, displayName: String) {
        let trimmed = repoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let dirName = ImageModelDownload.directoryName(forRepoId: trimmed)
        if case .downloading = states[dirName, default: .notStarted] { return }
        states[dirName] = .downloading(progress: 0)
        metrics[dirName] = nil
        liveBytes[dirName] = [:]
        speedSamples[dirName] = []
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(repoId: trimmed, dirName: dirName)
        }
        tasks[dirName] = task
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        downloaders[id]?.forEach { $0.pause() }
        downloaders[id] = nil
        liveBytes[id] = nil
        speedSamples[id] = nil
        states[id] = .notStarted
        metrics[id] = nil
    }

    private func run(repoId: String, dirName: String) async {
        let root = ImageGenerationService.imageModelsRoot()
            .appendingPathComponent(dirName, isDirectory: true)

        guard
            let files = await HuggingFaceService.shared.fetchMatchingFiles(
                repoId: repoId, patterns: Self.patterns, excludedFiles: Self.excluded),
            !files.isEmpty
        else {
            states[dirName] = .failed(error: "Could not list files for \(repoId)")
            tasks[dirName] = nil
            return
        }

        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        liveBytes[dirName] = [:]
        downloaders[dirName] = []
        writeSourceMarker(repoId: repoId, root: root)

        do {
            // Fetch up to `maxConcurrentFiles` at once, refilling a lane as each
            // file completes so the connection stays saturated end to end.
            try await withThrowingTaskGroup(of: Void.self) { group in
                var iterator = files.makeIterator()
                func addNext() -> Bool {
                    guard let file = iterator.next() else { return false }
                    group.addTask { [weak self] in
                        try await self?.downloadFile(
                            file, repoId: repoId, root: root, dirName: dirName, total: totalBytes)
                    }
                    return true
                }
                for _ in 0 ..< Self.maxConcurrentFiles where addNext() {}
                while try await group.next() != nil { _ = addNext() }
            }
            states[dirName] = .completed
            metrics[dirName] = nil
            // Refresh the picker catalog + any listeners so the freshly staged
            // bundle becomes selectable without a relaunch.
            NotificationCenter.default.post(name: .localModelsChanged, object: nil)
            await ModelPickerItemCache.shared.buildModelPickerItems()
        } catch is CancellationError {
            states[dirName] = .notStarted
            metrics[dirName] = nil
        } catch is DirectDownloader.PauseInfo {
            // A lane was paused by `cancel` while others were still in flight.
            states[dirName] = .notStarted
            metrics[dirName] = nil
        } catch {
            states[dirName] = .failed(error: String(describing: error))
            metrics[dirName] = nil
        }
        downloaders[dirName] = nil
        liveBytes[dirName] = nil
        speedSamples[dirName] = nil
        tasks[dirName] = nil
    }

    /// Stage a single file. Runs on the main actor for bookkeeping, but the
    /// network transfer awaits inside `DirectDownloader`, releasing the actor so
    /// sibling lanes transfer concurrently.
    private func downloadFile(
        _ file: HuggingFaceService.MatchedFile,
        repoId: String,
        root: URL,
        dirName: String,
        total: Int64
    ) async throws {
        try Task.checkCancellation()
        guard
            let destination = HuggingFaceService.destinationURL(forRemotePath: file.path, under: root),
            let url = ModelDownloadService.resolveURL(repoId: repoId, path: file.path)
        else { return }

        // Skip files already present at the expected size (resume).
        if let existing = try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]
            as? Int64, existing == file.size
        {
            liveBytes[dirName, default: [:]][file.path] = file.size
            updateProgress(dirName, total: total)
            return
        }

        let downloader = DirectDownloader()
        downloaders[dirName, default: []].append(downloader)
        try await downloader.download(
            from: url, to: destination, expectedSize: file.size
        ) { [weak self] received, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.liveBytes[dirName, default: [:]][file.path] = received
                self.updateProgress(dirName, total: total)
            }
        }
        liveBytes[dirName, default: [:]][file.path] = file.size
        updateProgress(dirName, total: total)
    }

    /// Recompute aggregate progress + throughput from the live per-file byte
    /// counts and a short trailing sample window.
    private func updateProgress(_ id: String, total: Int64) {
        let received = liveBytes[id]?.values.reduce(0, +) ?? 0

        let now = CFAbsoluteTimeGetCurrent()
        var window = speedSamples[id] ?? []
        window.append((now, received))
        window.removeAll { now - $0.t > 3 }  // ~3s trailing window
        speedSamples[id] = window

        var speed: Double?
        var eta: Double?
        if let first = window.first, window.count > 1, now - first.t > 0.001 {
            let bps = Double(received - first.bytes) / (now - first.t)
            if bps > 0 {
                speed = bps
                if total > received { eta = Double(total - received) / bps }
            }
        }

        let fraction = total > 0 ? min(1.0, Double(received) / Double(total)) : 0
        states[id] = .downloading(progress: fraction)
        metrics[id] = ModelDownloadService.DownloadMetrics(
            bytesReceived: received, totalBytes: total, bytesPerSecond: speed, etaSeconds: eta)
    }
}
