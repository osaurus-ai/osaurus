//
//  ExternalModelLocator.swift
//  osaurus
//
//  Read-only discovery of MLX/safetensors model bundles that live outside
//  Osaurus's own models directory — the Hugging Face Hub cache, LM
//  Studio, and user-selected model folders. Discovered bundles are surfaced in the catalog and made
//  runnable in place via an id -> absolute-path registry the runtime path
//  resolvers consult; nothing is ever copied, symlinked, or mutated in the
//  source location.
//
//  Design (per docs/MODEL_COMPATIBILITY_RESEARCH.md §"Hugging Face Cache
//  Import"):
//  - Scan only known roots, validate the same minimum shape as
//    `MLXModel.isDownloaded` (config.json + tokenizer + *.safetensors).
//  - Follow symlinks only when the resolved target stays under the scan
//    root; reject `..`/absolute escapes.
//  - GGUF-only directories are skipped — the MLX runtime can't load them.
//  - Persist a manifest so the catalog can show external models on launch
//    before the background rescan finishes.
//
//  Concurrency: a process-wide registry guarded by an `NSLock`, mirroring
//  the other static caches in this module. `path(forId:)` is synchronous so
//  the nonisolated runtime path resolvers can call it on the hot load path.
//

import Foundation
import Darwin

enum ExternalModelLocator {
    /// One discovered external bundle.
    struct Discovered: Codable, Equatable {
        /// Canonical `org/repo` id.
        let id: String
        /// Absolute path to the loadable bundle directory.
        let bundlePath: String
        /// Source revision when known (HF commit hash from `refs/main`).
        let revision: String?
        /// Human-readable provenance ("Hugging Face cache", "LM Studio",
        /// "Custom model folder").
        let source: String
        /// Configured scan root, before symlink resolution. Optional for older manifests.
        let scanRootPath: String?

        init(id: String, bundlePath: String, revision: String?, source: String, scanRootPath: String? = nil) {
            self.id = id
            self.bundlePath = bundlePath
            self.revision = revision
            self.source = source
            self.scanRootPath = scanRootPath
        }
    }

    /// Validation or scan reason for a bundle that was not registered.
    enum SkipReason: String, Equatable {
        case unreadableRoot
        case malformedCacheFolder
        case missingSnapshot
        case snapshotEscapesRoot
        case missingConfig
        case missingTokenizer
        case missingSafetensors
        case ggufOnly
        case symlinkEscapesRoot

        var title: String {
            switch self {
            case .unreadableRoot: return L("Root unreadable")
            case .malformedCacheFolder: return L("Malformed cache folder")
            case .missingSnapshot: return L("Snapshot missing")
            case .snapshotEscapesRoot: return L("Snapshot outside root")
            case .missingConfig: return L("config.json missing")
            case .missingTokenizer: return L("Tokenizer missing")
            case .missingSafetensors: return L("Safetensors missing")
            case .ggufOnly: return L("GGUF-only bundle")
            case .symlinkEscapesRoot: return L("Symlink escapes root")
            }
        }
    }

    struct BundleDiagnostic: Equatable {
        let isValid: Bool
        let reason: SkipReason?
        let detail: String?
        let isCandidate: Bool
    }

    struct Skipped: Equatable {
        let repoId: String?
        let path: String
        let reason: SkipReason
        let detail: String
    }

    struct SourceScanReport: Equatable {
        let source: Source
        let rootPath: String
        let discovered: [Discovered]
        let skipped: [Skipped]
    }

    struct ScanReport: Equatable {
        let sources: [SourceScanReport]

        var discovered: [Discovered] {
            sources.flatMap(\.discovered)
        }

        var skipped: [Skipped] {
            sources.flatMap(\.skipped)
        }
    }

    /// On-disk envelope. Versioned so format changes reject cleanly.
    private struct Persisted: Codable {
        static let currentSchemaVersion: Int = 1
        var schemaVersion: Int
        var models: [Discovered]
    }

    // MARK: - Settings keys

    static let importHFCacheDefaultsKey = "ExternalModelImportHFCache"
    static let importLMStudioDefaultsKey = "ExternalModelImportLMStudio"
    static let customHFCachePathDefaultsKey = "ExternalModelCustomHFCachePath"

    /// Both sources default ON so models from other tools are picked up
    /// automatically — the explicitly-requested "use models in all
    /// locations" behavior. Toggleable in Settings.
    static var isHFCacheImportEnabled: Bool {
        UserDefaults.standard.object(forKey: importHFCacheDefaultsKey) as? Bool ?? true
    }
    static var isLMStudioImportEnabled: Bool {
        UserDefaults.standard.object(forKey: importLMStudioDefaultsKey) as? Bool ?? true
    }

    static var customHFCachePath: String? {
        let raw = UserDefaults.standard.string(forKey: customHFCachePathDefaultsKey) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Registry state

    private static let lock = NSLock()
    nonisolated(unsafe) private static var registry: [String: Discovered]?
    nonisolated(unsafe) private static var lastReport: ScanReport?
    /// Bumped on registry mutation and explicit availability refresh so read-side
    /// memo caches invalidate even when outage/recovery leaves identity unchanged.
    nonisolated(unsafe) private static var registryGen: UInt64 = 0

    /// Monotonic version of registry contents and refreshed availability.
    static func registryGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return registryGen
    }

    /// Version both the registry and the catalog exposed by the nonblocking
    /// reader. A registry can stay unchanged while its asynchronous catalog
    /// changes from an empty/stale snapshot to the completed build.
    struct CatalogGeneration: Equatable {
        let registry: UInt64
        let snapshot: UInt64
    }

    static func catalogGeneration() -> CatalogGeneration {
        lock.lock()
        defer { lock.unlock() }
        return CatalogGeneration(registry: registryGen, snapshot: modelsMemoGen)
    }

    /// Test hook: override the scan roots so unit tests don't depend on a
    /// developer's real `~/.cache/huggingface`. When set, only these roots
    /// (paired with their source label) are scanned.
    nonisolated(unsafe) static var testRootsOverride: [(root: URL, source: Source)]?

    enum Source: String {
        case huggingFaceCache = "Hugging Face cache"
        case lmStudio = "LM Studio"
        case customModelFolder = "Custom model folder"
    }

    // MARK: - Public read API (hot path)

    /// Absolute bundle directory for `id`, if a still-valid external model
    /// is registered. Cheap: only re-confirms `config.json` exists so a
    /// stale manifest entry (source deleted out from under us) doesn't
    /// resolve to a missing path.
    static func path(forId id: String) -> URL? {
        lock.lock()
        let entry = loadedLocked()[id.lowercased()]
        lock.unlock()
        guard let entry else { return nil }
        let url = URL(fileURLWithPath: entry.bundlePath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path)
        else { return nil }
        return url
    }

    /// Memoized result of `models()` for the registry generation it was built
    /// from. `models()` is on the 2s RAM-feasibility tick's call path (via
    /// `ModelManager.localModelsSnapshotNonBlocking`), and rebuilding it reads
    /// each bundle's `config.json` for `model_type` and re-parses every
    /// friendly name — repeated main-thread work that shows up in app-hang
    /// reports under memory pressure.
    nonisolated(unsafe) private static var modelsMemo: [MLXModel]?
    nonisolated(unsafe) private static var modelsMemoGen: UInt64 = .max
    nonisolated(unsafe) private static var modelsRebuildInFlight = false
    nonisolated(unsafe) static var beforeModelsBuildForTests: (@Sendable () -> Void)?

    /// Catalog entries without waiting on disk. On a cold or stale memo this
    /// returns the previous build (or []) immediately and rebuilds in the
    /// background, then posts `.localModelsChanged` so consumers re-render
    /// from the finished catalog. The memoized `models()` build reads each
    /// bundle's `config.json` and walks its weight files for sizes, which is
    /// seconds of I/O right after launch — too slow for the view-body call
    /// path through `ModelManager.localModelsSnapshotNonBlocking`.
    static func modelsSnapshotNonBlocking() -> [MLXModel] {
        lock.lock()
        let entriesLoaded = !loadedLocked().isEmpty
        let gen = registryGen
        if modelsMemoGen == gen, let memo = modelsMemo {
            lock.unlock()
            return memo
        }
        let stale = modelsMemo ?? []
        // Nothing registered: the memo miss is vacuous, skip the rebuild hop.
        if !entriesLoaded {
            lock.unlock()
            return stale
        }
        let shouldKick = !modelsRebuildInFlight
        if shouldKick { modelsRebuildInFlight = true }
        lock.unlock()

        if shouldKick {
            DispatchQueue.global(qos: .utility).async {
                _ = models()
                lock.lock()
                modelsRebuildInFlight = false
                lock.unlock()
                // Same completion signal as the local-models scan: without it
                // a launch-time consumer keeps its empty/stale snapshot until
                // an unrelated event triggers a refresh.
                NotificationCenter.default.post(name: .localModelsChanged, object: nil)
            }
        }
        return stale
    }

    /// Available catalog entries, materialized off-main by discovery/refresh.
    /// The registry may retain unavailable identities; consumers of this list
    /// (including the picker) treat every returned entry as installed.
    static func models() -> [MLXModel] {
        lock.lock()
        // Load first: the lazy first-load inside `loadedLocked()` bumps
        // `registryGen`, so the gen must be captured after it.
        let entries = Array(loadedLocked().values)
        let gen = registryGen
        if modelsMemoGen == gen, let memo = modelsMemo {
            lock.unlock()
            return memo
        }
        lock.unlock()
        beforeModelsBuildForTests?()
        let built = entries.compactMap { entry -> MLXModel? in
            let bundleDirectory = URL(fileURLWithPath: entry.bundlePath, isDirectory: true)
            let candidate = MLXModel(
                id: entry.id, name: "", description: "", downloadURL: "", bundleDirectory: bundleDirectory)
            // Recheck only when materializing a new catalog, never in a view
            // getter. A retained registration is not evidence of readiness.
            let ready = bundlePresence(at: bundleDirectory) == .present && candidate.computeIsDownloadedFromDisk()
            MLXModelDownloadCache.set(ready, for: candidate.downloadCacheKey)
            guard ready else { return nil }
            return MLXModel(
                id: entry.id,
                name: ModelMetadataParser.friendlyName(from: entry.id),
                description: "Found in \(entry.source).",
                downloadURL: "https://huggingface.co/\(entry.id)",
                downloadSizeBytes: MLXModel.localBundleWeightSizeBytes(at: bundleDirectory),
                ssdResidentBytes: ModelSSDResidency.localSSDResidentBytes(at: bundleDirectory),
                // The persisted external registry intentionally stores only
                // identity/path/provenance. Rehydrate architecture from the
                // authoritative bundle here; otherwise an external model is
                // local and loadable but loses `model_type` in the picker.
                // Chat-family routing and structural agent contracts would
                // then silently differ from the same bundle installed under
                // Osaurus's managed model directory.
                modelType: VLMDetection.readModelType(at: bundleDirectory),
                bundleDirectory: bundleDirectory,
                externalSource: entry.source
            )
        }
        lock.lock()
        // Store only if the registry didn't move while we were building
        // (the build reads disk outside the lock); a stale build is simply
        // not cached and the next caller rebuilds against the newer gen.
        if registryGen == gen {
            modelsMemo = built
            modelsMemoGen = gen
        }
        lock.unlock()
        return built
    }

    /// Most recent external-model scan report, including skipped candidates.
    /// This is a UI/diagnostic surface only; runtime path resolution continues
    /// to use the validated registry above.
    static func lastScanReport() -> ScanReport? {
        lock.lock()
        let report = lastReport
        lock.unlock()
        return report
    }

    /// Forget a single external model so it no longer appears in the
    /// catalog. Never touches the source files — this only removes the
    /// registry/manifest entry. A later `rescan()` will rediscover it if
    /// the bundle still exists and its source is still enabled.
    static func forget(id: String) {
        lock.lock()
        var map = loadedLocked()
        let removed = map.removeValue(forKey: id.lowercased()) != nil
        registry = map
        if removed { registryGen &+= 1 }
        lock.unlock()
        if removed {
            persist(map)
            NotificationCenter.default.post(name: .localModelsChanged, object: nil)
        }
    }

    /// Explicit discovery boundaries refresh availability even when the registry
    /// is unchanged. Publish one completion event after the off-main materialized
    /// catalog is current; ordinary getters keep their existing memoized path.
    @discardableResult
    private static func refreshAvailability() -> [MLXModel] {
        lock.lock()
        registryGen &+= 1
        lock.unlock()
        MLXModelDownloadCache.invalidateAll()
        let available = models()
        NotificationCenter.default.post(name: .localModelsChanged, object: nil)
        return available
    }

    enum BundlePresence: Equatable {
        case present
        case missingConfig
        case missingDirectory
        case unavailable
    }

    /// Keep uncertainty distinct from deletion. Opening the bundle first means
    /// ENOENT for config.json is evidence about a reachable directory, not an
    /// unplugged volume or an inaccessible ancestor. Do not follow a config
    /// symlink's absent target as deletion: it may live on an unavailable source.
    static func bundlePresence(at directory: URL) -> BundlePresence {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missingDirectory : .unavailable
        }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        if fstatat(descriptor, "config.json", &info, AT_SYMLINK_NOFOLLOW) == 0 {
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK),
                fstatat(descriptor, "config.json", &info, 0) != 0
            {
                return .unavailable
            }
            return .present
        }
        return errno == ENOENT ? .missingConfig : .unavailable
    }

    /// Remove a positively missing config in a reachable bundle. A whole missing
    /// directory is indeterminate here; a healthy source rescan handles actual
    /// directory deletions. Temporary access failures never erase the manifest.
    @discardableResult
    static func pruneMissing(
        probe: (URL) -> BundlePresence = { bundlePresence(at: $0) }
    ) -> Bool {
        lock.lock()
        let snapshot = loadedLocked()
        lock.unlock()

        var missing: [String: String] = [:]
        for (key, entry) in snapshot {
            let directory = URL(fileURLWithPath: entry.bundlePath, isDirectory: true)
            if probe(directory) == .missingConfig { missing[key] = entry.bundlePath }
        }
        guard !missing.isEmpty else {
            refreshAvailability()
            return false
        }

        // Re-acquire briefly to apply. Only drop the exact entry we probed:
        // a concurrent `rescan()` may have re-registered the id at a new,
        // still-valid path while we were probing, and that must survive.
        lock.lock()
        var map = loadedLocked()
        var removed = false
        for (key, probedPath) in missing where map[key]?.bundlePath == probedPath {
            map.removeValue(forKey: key)
            removed = true
        }
        if removed {
            registry = map
            registryGen &+= 1
        }
        lock.unlock()

        if removed { persist(map) }
        refreshAvailability()
        return removed
    }

    // MARK: - Rescan

    /// Re-scan the enabled external roots, update the registry, persist the
    /// manifest, and post `.localModelsChanged` if the set changed. Safe to
    /// call from a background task; performs filesystem I/O.
    @discardableResult
    static func rescan(
        probe: (URL) -> BundlePresence = { bundlePresence(at: $0) }
    ) -> [MLXModel] {
        lock.lock()
        let previous = loadedLocked()
        lock.unlock()
        let report = scanEnabledSources()
        var discovered = reconciledRegistry(
            previous: previous, report: report, configuredRoots: configuredSourceRoots(), probe: probe)

        lock.lock()
        let current = loadedLocked()
        let foundIds = Set(report.discovered.map { $0.id.lowercased() })
        // A retained old entry must not resurrect a concurrent explicit forget,
        // or replace an id that was rebound while its filesystem probe ran.
        for (key, entry) in previous where !foundIds.contains(key) && discovered[key] == entry {
            if current[key] != entry { discovered[key] = current[key] }
        }
        let changed = current != discovered
        registry = discovered
        if changed { registryGen &+= 1 }
        lastReport = report
        lock.unlock()

        if changed { persist(discovered) }
        return refreshAvailability()
    }

    /// A failed or partial scan cannot prove deletion. Retention preserves only
    /// registry identity; path(forId:) and isDownloaded still require live files.
    static func reconciledRegistry(
        previous: [String: Discovered],
        report: ScanReport,
        configuredRoots: [(root: URL, source: Source)],
        probe: (URL) -> BundlePresence = { bundlePresence(at: $0) }
    ) -> [String: Discovered] {
        var result: [String: Discovered] = [:]
        for entry in report.discovered { result[entry.id.lowercased()] = entry }
        for (key, entry) in previous where result[key] == nil {
            let enabled = configuredRoots.filter { $0.source.rawValue == entry.source }
            guard !enabled.isEmpty else { continue } // Explicitly disabled sources stay removed without probing.
            if let recorded = entry.scanRootPath,
                !enabled.contains(where: { $0.root.standardizedFileURL.path == recorded })
            {
                continue // An explicit root replacement must not retain or probe the old root.
            }
            let directory = URL(fileURLWithPath: entry.bundlePath, isDirectory: true)
            let presence = probe(directory)
            if presence == .missingConfig { continue }
            func owns(_ root: URL) -> Bool {
                if let recorded = entry.scanRootPath {
                    return URL(fileURLWithPath: recorded).standardizedFileURL.path == root.standardizedFileURL.path
                }
                return isContained(directory, in: root)
            }
            let owners = enabled.filter { owns($0.root) }
            if owners.isEmpty {
                // Old manifests have no root provenance. An unavailable legacy
                // path cannot safely be assigned to a different healthy root.
                if entry.scanRootPath == nil, presence == .unavailable || presence == .missingDirectory {
                    result[key] = entry
                }
                continue
            }
            let scans = report.sources.filter { scan in
                scan.source.rawValue == entry.source
                    && owners.contains { $0.root.standardizedFileURL.path == scan.rootPath }
            }
            let incomplete = scans.isEmpty || scans.contains { scan in
                scan.skipped.contains { skipped in
                    skipped.reason == .unreadableRoot
                        && (skipped.path == scan.rootPath
                            || isContained(directory, in: URL(fileURLWithPath: skipped.path, isDirectory: true)))
                }
            }
            if presence == .unavailable || incomplete { result[key] = entry }
        }
        return result
    }

    private static func configuredSourceRoots() -> [(root: URL, source: Source)] {
        if let overrides = testRootsOverride { return overrides }
        var roots: [(root: URL, source: Source)] = []
        if isHFCacheImportEnabled {
            roots += huggingFaceCacheRoots(fileExists: { _ in true }).map { ($0, .huggingFaceCache) }
            roots += customModelFolderRoots(fileExists: { _ in true }).map { ($0, .customModelFolder) }
        }
        if isLMStudioImportEnabled {
            roots += lmStudioRoots(requireExisting: false).map { ($0, .lmStudio) }
        }
        return roots
    }

    static func scanEnabledSources() -> ScanReport {
        var reports: [SourceScanReport] = []
        if let overrides = testRootsOverride {
            for (root, source) in overrides {
                switch source {
                case .huggingFaceCache:
                    reports.append(scanHuggingFaceCacheReport(root: root))
                case .lmStudio:
                    reports.append(scanReport(root: root, source: .lmStudio))
                case .customModelFolder:
                    reports.append(scanCustomModelFolderReport(root: root))
                }
            }
            return ScanReport(sources: reports)
        }

        if isHFCacheImportEnabled {
            reports.append(
                contentsOf: huggingFaceCacheRoots().map(scanHuggingFaceCacheReport(root:))
            )
            reports.append(
                contentsOf: customModelFolderRoots().map(scanCustomModelFolderReport(root:))
            )
        }
        if isLMStudioImportEnabled {
            reports.append(contentsOf: lmStudioRoots().map { scanReport(root: $0, source: .lmStudio) })
        }
        return ScanReport(sources: reports)
    }

    // MARK: - Roots

    /// Plain model-library roots. `~/models` is a durable convention, not a
    /// transient UI preference: many existing Osaurus/vMLX users keep large
    /// publisher/repo libraries there and must not lose them when a bookmark
    /// or defaults domain changes across an app update. A user-selected root
    /// remains first, and equivalent paths are deduplicated.
    static func customModelFolderRoots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        customPath: String? = ExternalModelLocator.customHFCachePath,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [URL] {
        var roots: [URL] = []

        func add(_ url: URL, requireExisting: Bool) {
            let standardized = url.standardizedFileURL
            if requireExisting, !fileExists(standardized.path) { return }
            if !roots.contains(standardized) { roots.append(standardized) }
        }

        if let customPath {
            add(Self.fileURL(fromUserPath: customPath, homeDirectory: homeDirectory), requireExisting: true)
        }
        add(homeDirectory.appendingPathComponent("models", isDirectory: true), requireExisting: true)
        return roots
    }

    static func huggingFaceCacheRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        customPath: String? = ExternalModelLocator.customHFCachePath,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [URL] {
        var roots: [URL] = []

        func add(_ url: URL, requireExisting: Bool = true) {
            let standardized = url.standardizedFileURL
            if requireExisting, !fileExists(standardized.path) { return }
            if !roots.contains(standardized) { roots.append(standardized) }
        }

        if let customPath {
            add(Self.fileURL(fromUserPath: customPath, homeDirectory: homeDirectory), requireExisting: false)
        }
        if let hubCache = environment["HF_HUB_CACHE"], !hubCache.isEmpty {
            add(Self.fileURL(fromUserPath: hubCache, homeDirectory: homeDirectory))
        }
        if let hfHome = environment["HF_HOME"], !hfHome.isEmpty {
            add(
                Self.fileURL(fromUserPath: hfHome, homeDirectory: homeDirectory)
                    .appendingPathComponent("hub", isDirectory: true)
            )
        }
        add(
            homeDirectory
                .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        )
        return roots
    }

    private static func fileURL(fromUserPath path: String, homeDirectory: URL) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" {
            return homeDirectory
        }
        if trimmed.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(trimmed.dropFirst(2)), isDirectory: true)
        }
        return URL(
            fileURLWithPath: (trimmed as NSString).expandingTildeInPath,
            isDirectory: true
        )
    }

    private static func lmStudioRoots(requireExisting: Bool = true) -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".lmstudio/models", isDirectory: true),
            home.appendingPathComponent(".cache/lm-studio/models", isDirectory: true),
        ].filter { !requireExisting || fm.fileExists(atPath: $0.path) }
    }

    // MARK: - Hugging Face cache scanner

    /// Scan a single HF hub root for `models--org--repo` snapshots.
    private static func scanHuggingFaceCacheReport(root: URL) -> SourceScanReport {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return SourceScanReport(
                source: .huggingFaceCache,
                rootPath: root.path,
                discovered: [],
                skipped: [
                    Skipped(
                        repoId: nil,
                        path: root.path,
                        reason: .unreadableRoot,
                        detail: "The Hugging Face cache root could not be read."
                    )
                ]
            )
        }

        var results: [Discovered] = []
        var skipped: [Skipped] = []
        for entry in entries {
            let folder = entry.lastPathComponent
            guard folder.hasPrefix("models--") else { continue }
            guard let repoId = Self.repoId(fromCacheFolder: folder) else {
                skipped.append(
                    Skipped(
                        repoId: nil,
                        path: entry.path,
                        reason: .malformedCacheFolder,
                        detail: "Expected a cache folder named models--<org>--<repo>."
                    )
                )
                continue
            }

            // Resolve refs/main -> commit hash -> snapshots/<hash>.
            let (snapshotDir, revision) = resolveSnapshot(in: entry)
            guard let snapshotDir else {
                skipped.append(
                    Skipped(
                        repoId: repoId,
                        path: entry.path,
                        reason: .missingSnapshot,
                        detail: "No readable snapshots directory or refs/main target was found."
                    )
                )
                continue
            }
            guard isContained(snapshotDir, in: root) else {
                skipped.append(
                    Skipped(
                        repoId: repoId,
                        path: snapshotDir.path,
                        reason: .snapshotEscapesRoot,
                        detail: "The resolved snapshot points outside the configured cache root."
                    )
                )
                continue
            }
            let diagnostic = bundleDiagnostic(at: snapshotDir, root: root)
            guard diagnostic.isValid else {
                skipped.append(
                    Skipped(
                        repoId: repoId,
                        path: snapshotDir.path,
                        reason: diagnostic.reason ?? .missingSafetensors,
                        detail: diagnostic.detail ?? "The snapshot does not look like an MLX safetensors bundle."
                    )
                )
                continue
            }

            results.append(
                Discovered(
                    id: repoId,
                    bundlePath: snapshotDir.standardizedFileURL.path,
                    revision: revision,
                    source: Source.huggingFaceCache.rawValue,
                    scanRootPath: root.standardizedFileURL.path
                )
            )
        }
        return SourceScanReport(
            source: .huggingFaceCache,
            rootPath: root.path,
            discovered: results,
            skipped: skipped
        )
    }

    /// `models--<org>--<repo>` -> `org/repo`. Returns nil for non-model
    /// caches (e.g. `datasets--`) or malformed names.
    static func repoId(fromCacheFolder folder: String) -> String? {
        guard folder.hasPrefix("models--") else { return nil }
        let body = String(folder.dropFirst("models--".count))
        let parts = body.components(separatedBy: "--").filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        let org = parts[0]
        let repo = parts[1...].joined(separator: "/")
        return "\(org)/\(repo)"
    }

    /// Resolves `<modelDir>/refs/main` to a concrete `snapshots/<rev>` dir.
    /// Falls back to the most recently modified snapshot when `refs/main`
    /// is missing. Returns the dir and the revision string (when known).
    private static func resolveSnapshot(in modelDir: URL) -> (URL?, String?) {
        let fm = FileManager.default
        let snapshotsDir = modelDir.appendingPathComponent("snapshots", isDirectory: true)

        let refsMain = modelDir.appendingPathComponent("refs/main")
        let mainRevision = (try? Data(contentsOf: refsMain))
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let rev = mainRevision, !rev.isEmpty {
            let candidate = snapshotsDir.appendingPathComponent(rev, isDirectory: true)
            if fm.fileExists(atPath: candidate.path) { return (candidate, rev) }
        }

        // No usable refs/main — pick the newest snapshot directory.
        guard
            let snapshots = try? fm.contentsOfDirectory(
                at: snapshotsDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return (nil, nil) }

        let newest = snapshots.max { a, b in
            let da =
                (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db =
                (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
        return (newest, newest?.lastPathComponent)
    }

    // MARK: - Generic nested-layout scanner (LM Studio + tests)

    static func scanCustomModelFolderReport(root: URL) -> SourceScanReport {
        let rootDiagnostic = bundleDiagnostic(at: root, root: root)
        if rootDiagnostic.isValid {
            return SourceScanReport(
                source: .customModelFolder,
                rootPath: root.path,
                discovered: [
                    Discovered(
                        id: root.lastPathComponent,
                        bundlePath: root.standardizedFileURL.path,
                        revision: nil,
                        source: Source.customModelFolder.rawValue,
                        scanRootPath: root.standardizedFileURL.path
                    )
                ],
                skipped: []
            )
        }

        var report = scanReport(
            root: root,
            source: .customModelFolder,
            skipTopLevelHuggingFaceCacheFolders: true
        )
        if rootDiagnostic.isCandidate, let reason = rootDiagnostic.reason {
            report = SourceScanReport(
                source: report.source,
                rootPath: report.rootPath,
                discovered: report.discovered,
                skipped: [
                    Skipped(
                        repoId: root.lastPathComponent,
                        path: root.path,
                        reason: reason,
                        detail: rootDiagnostic.detail
                            ?? "The selected folder is not a complete MLX safetensors bundle."
                    )
                ] + report.skipped
            )
        }
        return report
    }

    /// Scan a root with a nested `publisher/repo/` layout, registering any
    /// directory that validates as an MLX bundle. Bounded depth keeps the
    /// scan cheap on large model libraries.
    static func scan(root: URL, source: Source) -> [Discovered] {
        scanReport(root: root, source: source).discovered
    }

    static func scanReport(
        root: URL,
        source: Source,
        skipTopLevelHuggingFaceCacheFolders: Bool = false
    ) -> SourceScanReport {
        let fm = FileManager.default
        var results: [Discovered] = []
        var skipped: [Skipped] = []

        func walk(_ dir: URL, prefix: [String], depth: Int) {
            guard depth > 0 else { return }
            let entries: [URL]
            do {
                entries = try fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                skipped.append(Skipped(repoId: nil, path: prefix.isEmpty ? root.path : dir.path,
                    reason: .unreadableRoot, detail: "Could not enumerate model folder: \(error.localizedDescription)"))
                return
            }
            for entry in entries {
                if skipTopLevelHuggingFaceCacheFolders, prefix.isEmpty,
                    entry.lastPathComponent.hasPrefix("models--")
                {
                    continue
                }
                let resolved = entry.resolvingSymlinksInPath()
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue
                else { continue }
                let components = prefix + [entry.lastPathComponent]
                let diagnostic = bundleDiagnostic(at: resolved, root: root)
                if diagnostic.isValid {
                    let id = components.joined(separator: "/")
                    results.append(
                        Discovered(
                            id: id,
                            bundlePath: resolved.standardizedFileURL.path,
                            revision: nil,
                            source: source.rawValue,
                            scanRootPath: root.standardizedFileURL.path
                        )
                    )
                    continue  // a bundle dir doesn't itself contain bundles
                }
                if diagnostic.isCandidate {
                    skipped.append(
                        Skipped(
                            repoId: components.count >= 2 ? components.joined(separator: "/") : nil,
                            path: resolved.path,
                            reason: diagnostic.reason ?? .missingSafetensors,
                            detail: diagnostic.detail ?? "The directory is not a complete MLX safetensors bundle."
                        )
                    )
                }
                if depth > 1 {
                    walk(resolved, prefix: components, depth: depth - 1)
                }
            }
        }
        // Foundation can return ENOTDIR for a directory URL naming a symlink
        // (e.g. ~/models -> an external volume). Child entries already resolve
        // symlinks; the starting root must obey the same contract.
        walk(root.resolvingSymlinksInPath(), prefix: [], depth: 3)
        return SourceScanReport(
            source: source,
            rootPath: root.path,
            discovered: results,
            skipped: skipped
        )
    }

    // MARK: - Validation

    /// True when `dir` looks like a loadable MLX bundle: `config.json`, a
    /// recognized tokenizer, and at least one `*.safetensors` file. GGUF
    /// directories (no safetensors) fail this check and are skipped. Any
    /// symlinked file must resolve to a target under `root`.
    static func isMLXBundle(_ dir: URL, root: URL) -> Bool {
        bundleDiagnostic(at: dir, root: root).isValid
    }

    static func bundleDiagnostic(
        at dir: URL,
        root: URL,
        enforceSymlinkContainment: Bool = true
    ) -> BundleDiagnostic {
        let fm = FileManager.default
        // Directory enumeration can return ENOTDIR for a URL naming a symlink,
        // even though individual config/tokenizer probes succeed through it.
        // Resolve the bundle itself just as discovery resolves its scan root.
        let directory = dir.resolvingSymlinksInPath().standardizedFileURL

        enum Probe {
            case present
            case missing
            case escapesRoot
        }

        func probe(_ name: String) -> Probe {
            let url = directory.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { return .missing }
            // Reject symlinks that escape the scan root.
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard enforceSymlinkContainment else { return .present }
            return isContained(resolved, in: root) ? .present : .escapesRoot
        }

        func hasAny(_ probes: [Probe]) -> Bool {
            probes.contains { $0 == .present || $0 == .escapesRoot }
        }

        let config = probe("config.json")
        let tokenizerJSON = probe("tokenizer.json")
        let merges = probe("merges.txt")
        let vocabJSON = probe("vocab.json")
        let vocabTXT = probe("vocab.txt")
        let tokenizerModel = probe("tokenizer.model")
        let spieceModel = probe("spiece.model")
        let tokenizerProbes = [
            tokenizerJSON, merges, vocabJSON, vocabTXT, tokenizerModel, spieceModel,
        ]

        var sawSafetensors = false
        var sawGGUF = false
        var weightEscapesRoot = false
        if let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for item in items {
                if item.pathExtension == "gguf" {
                    sawGGUF = true
                    continue
                }
                guard item.pathExtension == "safetensors" else { continue }
                let resolved = item.resolvingSymlinksInPath().standardizedFileURL
                if !enforceSymlinkContainment || isContained(resolved, in: root) {
                    sawSafetensors = true
                } else {
                    weightEscapesRoot = true
                }
            }
        }

        let isCandidate =
            hasAny([config])
            || hasAny(tokenizerProbes)
            || sawSafetensors
            || sawGGUF
            || weightEscapesRoot

        if config == .escapesRoot {
            return BundleDiagnostic(
                isValid: false,
                reason: .symlinkEscapesRoot,
                detail: "config.json resolves outside the scan root.",
                isCandidate: true
            )
        }
        guard config == .present else {
            return BundleDiagnostic(
                isValid: false,
                reason: .missingConfig,
                detail: "config.json is required for MLX bundle discovery.",
                isCandidate: isCandidate
            )
        }

        if tokenizerProbes.contains(.escapesRoot) {
            return BundleDiagnostic(
                isValid: false,
                reason: .symlinkEscapesRoot,
                detail: "A tokenizer file resolves outside the scan root.",
                isCandidate: true
            )
        }
        let hasTokenizer =
            tokenizerJSON == .present
            || (merges == .present && (vocabJSON == .present || vocabTXT == .present))
            || tokenizerModel == .present
            || spieceModel == .present
        guard hasTokenizer else {
            return BundleDiagnostic(
                isValid: false,
                reason: .missingTokenizer,
                detail:
                    "Expected tokenizer.json, BPE merges/vocab files, tokenizer.model, or spiece.model.",
                isCandidate: true
            )
        }

        if weightEscapesRoot {
            return BundleDiagnostic(
                isValid: false,
                reason: .symlinkEscapesRoot,
                detail: "A safetensors file resolves outside the scan root.",
                isCandidate: true
            )
        }
        if sawSafetensors {
            return BundleDiagnostic(isValid: true, reason: nil, detail: nil, isCandidate: true)
        }
        if sawGGUF {
            return BundleDiagnostic(
                isValid: false,
                reason: .ggufOnly,
                detail: "GGUF files are present, but the MLX runtime requires safetensors weights.",
                isCandidate: true
            )
        }
        return BundleDiagnostic(
            isValid: false,
            reason: .missingSafetensors,
            detail: "Expected at least one .safetensors weight file.",
            isCandidate: true
        )
    }

    /// True when `url` is the same as, or nested under, `directory` after
    /// standardization. Used for symlink-escape rejection.
    static func isContained(_ url: URL, in directory: URL) -> Bool {
        // Standardize first (resolves `..` lexically, even for paths that
        // don't exist) then resolve symlinks to the real on-disk location.
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let dirPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
        return path == dirPath || path.hasPrefix(dirPath + "/")
    }

    // MARK: - Persistence

    private static func loadedLocked() -> [String: Discovered] {
        if let registry { return registry }
        let loaded = loadFromDisk()
        registry = loaded
        registryGen &+= 1
        return loaded
    }

    private static func loadFromDisk() -> [String: Discovered] {
        let url = OsaurusPaths.externalModelsManifestFile()
        guard FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let payload = try? JSONDecoder().decode(Persisted.self, from: data),
            payload.schemaVersion == Persisted.currentSchemaVersion
        else { return [:] }
        var map: [String: Discovered] = [:]
        for model in payload.models { map[model.id.lowercased()] = model }
        return map
    }

    private static func persist(_ map: [String: Discovered]) {
        let url = OsaurusPaths.externalModelsManifestFile()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        let payload = Persisted(
            schemaVersion: Persisted.currentSchemaVersion,
            models: Array(map.values).sorted { $0.id < $1.id }
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    // MARK: - Test support

    static func invalidateInMemory() {
        lock.lock()
        registry = nil
        lastReport = nil
        registryGen &+= 1
        lock.unlock()
    }
}
