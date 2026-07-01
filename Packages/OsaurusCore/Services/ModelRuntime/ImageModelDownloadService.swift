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
    /// Image bundles shown in the Available list: the curated set (see
    /// `curatedCatalog`) merged with the OsaurusAI HF org listing fetched at
    /// runtime. Seeded with `curatedCatalog` so those entries render
    /// immediately and survive a failed/empty org fetch (which leaves the
    /// previously-loaded listing intact). Users can still stage any other mflux
    /// bundle by pasting its repo id via the UI's Import field.
    @Published private(set) var fetchedCatalog: [ImageModelDownload] =
        ImageModelDownloadService.curatedCatalog
    /// True while the OsaurusAI org listing fetch is in flight.
    @Published private(set) var isLoadingCatalog = false

    /// HF org whose published image bundles populate the Available list.
    static let osaurusOrgAuthor = "OsaurusAI"
    /// HF `pipeline_tag` values that denote a runnable on-device image bundle
    /// (excludes `image-text-to-text` VLMs/LLMs published in the same org).
    private static let imagePipelineTags: Set<String> = ["text-to-image", "image-to-image"]

    /// Curated image bundles that aren't published under the OsaurusAI org, so
    /// they'd otherwise never appear in Available. These are mflux mirrors the
    /// engine's family registry recognizes; users can still Import any other
    /// repo. The official `ideogram-ai` fp8/nf4 repos are CUDA/PyTorch
    /// checkpoints (no diffusers/MLX support) and are deliberately excluded
    /// because they would not load in the MLX engine.
    static let curatedCatalog: [ImageModelDownload] = [
        ImageModelDownload(
            repoId: "cocktailpeanut/ideogram-4-fp8",
            displayName: "Ideogram 4 (fp8)",
            note: "Text-to-image · mflux · strong typography"
        ),
        ImageModelDownload(
            repoId: "cocktailpeanut/ideogram-4-nf4",
            displayName: "Ideogram 4 (NF4)",
            note: "Text-to-image · mflux · 4-bit"
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
    /// marker; falls back to a fetched- or curated-catalog entry with the same
    /// id. `nil` when neither is known (e.g. an old imported bundle), in which
    /// case re-download is unavailable and only delete is offered.
    func sourceRepoId(for id: String) -> String? {
        let marker = ImageGenerationService.imageModelsRoot()
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(Self.sourceMarkerName)
        if let raw = try? String(contentsOf: marker, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return (fetchedCatalog + Self.curatedCatalog).first { $0.id == id }?.repoId
    }

    /// Best-effort total download size for a catalog repo, mirroring
    /// `ModelDownloadService.estimateSize`: read-through `ModelSizeCache` first
    /// (honoring its TTL for revision-less entries) so re-opening the tab
    /// doesn't re-hit the network, then sum the staged files' sizes via the HF
    /// tree API and persist the result. Uses the same `patterns`/`excluded`
    /// set the downloader stages, so the figure matches what actually lands on
    /// disk. Returns `nil` on any listing failure.
    func estimateDownloadSize(repoId: String) async -> Int64? {
        let trimmed = repoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let cached = ModelSizeCache.bytes(forId: trimmed) {
            return cached
        }
        let fetched = await HuggingFaceService.shared.estimateTotalSize(
            repoId: trimmed,
            patterns: Self.patterns,
            excludedFiles: Self.excluded
        )
        if let fetched {
            ModelSizeCache.record(id: trimmed, bytes: fetched, revision: nil)
        }
        return fetched
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
                at: root,
                withIntermediateDirectories: true
            )
            try? repoId.write(
                to: root.appendingPathComponent(sourceMarkerName),
                atomically: true,
                encoding: .utf8
            )
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
                repoId: repoId,
                patterns: patterns,
                excludedFiles: excluded
            )
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

    /// Fetch the OsaurusAI org listing from Hugging Face and refresh
    /// `fetchedCatalog` with the curated set merged with the org's image
    /// bundles (text-to-image / image-to-image pipelines). Best-effort: a
    /// failed or empty fetch leaves the existing (curated + previously-loaded)
    /// listing intact rather than blanking the list.
    func refreshCatalog() async {
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        let rows = await HuggingFaceService.shared.fetchModels(author: Self.osaurusOrgAuthor)
        guard !rows.isEmpty else { return }
        let orgEntries =
            rows
            .filter { Self.imagePipelineTags.contains(($0.pipelineTag ?? "").lowercased()) }
            .map(Self.makeCatalogEntry(from:))
        // Curated entries first, then the OsaurusAI org listing (already sorted
        // by downloads, most popular first), deduped by id.
        fetchedCatalog = Self.dedupedByID(Self.curatedCatalog + orgEntries)
    }

    /// Map an HF org listing row to a downloadable catalog entry. The display
    /// name is the repo's last path component (the quant pill in the row is
    /// derived from the repo id separately).
    private static func makeCatalogEntry(
        from row: HuggingFaceService.OrgModelListing
    ) -> ImageModelDownload {
        let isEdit = (row.pipelineTag ?? "").lowercased() == "image-to-image"
        let tail = row.id.split(separator: "/").last.map(String.init) ?? row.id
        return ImageModelDownload(
            repoId: row.id,
            displayName: tail,
            note: isEdit ? "Image edit · mflux" : "Text-to-image · mflux"
        )
    }

    /// Dedupe catalog entries by `id`, keeping the first occurrence (so curated
    /// entries win over org rows sharing a directory name) and preserving order.
    private static func dedupedByID(_ entries: [ImageModelDownload]) -> [ImageModelDownload] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.id).inserted }
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
                repoId: repoId,
                patterns: Self.patterns,
                excludedFiles: Self.excluded
            ),
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
                            file,
                            repoId: repoId,
                            root: root,
                            dirName: dirName,
                            total: totalBytes
                        )
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
            from: url,
            to: destination,
            expectedSize: file.size
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
            bytesReceived: received,
            totalBytes: total,
            bytesPerSecond: speed,
            etaSeconds: eta
        )
    }
}
