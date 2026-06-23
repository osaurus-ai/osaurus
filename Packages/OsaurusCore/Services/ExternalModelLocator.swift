//
//  ExternalModelLocator.swift
//  osaurus
//
//  Read-only discovery of MLX/safetensors model bundles that live outside
//  Osaurus's own models directory — the Hugging Face Hub cache and LM
//  Studio. Discovered bundles are surfaced in the catalog and made
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

enum ExternalModelLocator {
    /// One discovered external bundle.
    struct Discovered: Codable, Equatable {
        /// Canonical `org/repo` id.
        let id: String
        /// Absolute path to the loadable bundle directory.
        let bundlePath: String
        /// Source revision when known (HF commit hash from `refs/main`).
        let revision: String?
        /// Human-readable provenance ("Hugging Face cache", "LM Studio").
        let source: String
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

    /// Test hook: override the scan roots so unit tests don't depend on a
    /// developer's real `~/.cache/huggingface`. When set, only these roots
    /// (paired with their source label) are scanned.
    nonisolated(unsafe) static var testRootsOverride: [(root: URL, source: Source)]?

    enum Source: String {
        case huggingFaceCache = "Hugging Face cache"
        case lmStudio = "LM Studio"
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

    /// Catalog entries for every registered external model.
    static func models() -> [MLXModel] {
        lock.lock()
        let entries = Array(loadedLocked().values)
        lock.unlock()
        return entries.map { entry in
            MLXModel(
                id: entry.id,
                name: ModelMetadataParser.friendlyName(from: entry.id),
                description: "Found in \(entry.source).",
                downloadURL: "https://huggingface.co/\(entry.id)",
                bundleDirectory: URL(fileURLWithPath: entry.bundlePath, isDirectory: true),
                externalSource: entry.source
            )
        }
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
        lock.unlock()
        if removed {
            persist(map)
            NotificationCenter.default.post(name: .localModelsChanged, object: nil)
        }
    }

    /// Drop registry entries whose bundle no longer exists on disk — e.g. the
    /// user deleted an external model's files directly in Finder. Cheap: just
    /// a `config.json` existence check per entry (no directory walk), so it's
    /// safe to call whenever a model list is about to be shown. Persists the
    /// trimmed manifest and posts `.localModelsChanged` if anything was
    /// removed, which rebuilds the picker cache and refreshes the Models grid.
    ///
    /// This exists because the in-memory `registry` (and the manifest) are
    /// loaded once and only fully re-derived by `rescan()` at launch. Closing
    /// and reopening the window reuses the cached registry, so a model deleted
    /// out from under us would otherwise linger in the UI until the next quit.
    @discardableResult
    static func pruneMissing() -> Bool {
        // Snapshot under the lock, then do the `fileExists` probes UNLOCKED.
        // Holding the lock across filesystem I/O would block any concurrent
        // (possibly main-thread) `models()` / `path(forId:)` caller for the
        // duration of the scan — the same reason `path` and `rescan` keep
        // their I/O outside the lock. Callers must still invoke this off the
        // main thread.
        lock.lock()
        let snapshot = loadedLocked()
        lock.unlock()

        let fm = FileManager.default
        var missing: [String: String] = [:]  // key -> probed bundlePath
        for (key, entry) in snapshot {
            let configPath = URL(fileURLWithPath: entry.bundlePath, isDirectory: true)
                .appendingPathComponent("config.json").path
            if !fm.fileExists(atPath: configPath) {
                missing[key] = entry.bundlePath
            }
        }
        guard !missing.isEmpty else { return false }

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
        if removed { registry = map }
        lock.unlock()

        if removed {
            persist(map)
            NotificationCenter.default.post(name: .localModelsChanged, object: nil)
        }
        return removed
    }

    // MARK: - Rescan

    /// Re-scan the enabled external roots, update the registry, persist the
    /// manifest, and post `.localModelsChanged` if the set changed. Safe to
    /// call from a background task; performs filesystem I/O.
    @discardableResult
    static func rescan() -> [MLXModel] {
        let report = scanEnabledSources()
        var discovered: [String: Discovered] = [:]
        for entry in report.discovered {
            discovered[entry.id.lowercased()] = entry
        }

        lock.lock()
        let changed = registry == nil || registry! != discovered
        registry = discovered
        lastReport = report
        lock.unlock()

        if changed {
            persist(discovered)
            NotificationCenter.default.post(name: .localModelsChanged, object: nil)
        }
        return models()
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
                }
            }
            return ScanReport(sources: reports)
        }

        if isHFCacheImportEnabled {
            reports.append(
                contentsOf: huggingFaceCacheRoots().map(scanHuggingFaceCacheReport(root:))
            )
        }
        if isLMStudioImportEnabled {
            reports.append(contentsOf: lmStudioRoots().map { scanReport(root: $0, source: .lmStudio) })
        }
        return ScanReport(sources: reports)
    }

    // MARK: - Roots

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

    private static func lmStudioRoots() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".lmstudio/models", isDirectory: true),
            home.appendingPathComponent(".cache/lm-studio/models", isDirectory: true),
        ].filter { fm.fileExists(atPath: $0.path) }
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
                    source: Source.huggingFaceCache.rawValue
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

    /// Scan a root with a nested `publisher/repo/` layout, registering any
    /// directory that validates as an MLX bundle. Bounded depth keeps the
    /// scan cheap on large model libraries.
    static func scan(root: URL, source: Source) -> [Discovered] {
        scanReport(root: root, source: source).discovered
    }

    static func scanReport(root: URL, source: Source) -> SourceScanReport {
        let fm = FileManager.default
        var results: [Discovered] = []
        var skipped: [Skipped] = []

        func walk(_ dir: URL, prefix: [String], depth: Int) {
            guard depth > 0,
                let entries = try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else { return }
            for entry in entries {
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
                            source: source.rawValue
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
        walk(root, prefix: [], depth: 3)
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

        enum Probe {
            case present
            case missing
            case escapesRoot
        }

        func probe(_ name: String) -> Probe {
            let url = dir.appendingPathComponent(name)
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
        if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
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
        lock.unlock()
    }
}
