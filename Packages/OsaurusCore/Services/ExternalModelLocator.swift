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

    /// On-disk envelope. Versioned so format changes reject cleanly.
    private struct Persisted: Codable {
        static let currentSchemaVersion: Int = 1
        var schemaVersion: Int
        var models: [Discovered]
    }

    // MARK: - Settings keys

    static let importHFCacheDefaultsKey = "ExternalModelImportHFCache"
    static let importLMStudioDefaultsKey = "ExternalModelImportLMStudio"

    /// Both sources default ON so models from other tools are picked up
    /// automatically — the explicitly-requested "use models in all
    /// locations" behavior. Toggleable in Settings.
    static var isHFCacheImportEnabled: Bool {
        UserDefaults.standard.object(forKey: importHFCacheDefaultsKey) as? Bool ?? true
    }
    static var isLMStudioImportEnabled: Bool {
        UserDefaults.standard.object(forKey: importLMStudioDefaultsKey) as? Bool ?? true
    }

    // MARK: - Registry state

    private static let lock = NSLock()
    private static nonisolated(unsafe) var registry: [String: Discovered]?

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

    // MARK: - Rescan

    /// Re-scan the enabled external roots, update the registry, persist the
    /// manifest, and post `.localModelsChanged` if the set changed. Safe to
    /// call from a background task; performs filesystem I/O.
    @discardableResult
    static func rescan() -> [MLXModel] {
        var discovered: [String: Discovered] = [:]

        if let overrides = testRootsOverride {
            for (root, source) in overrides {
                let found: [Discovered]
                switch source {
                case .huggingFaceCache: found = scanHuggingFaceCache(root: root)
                case .lmStudio: found = scan(root: root, source: .lmStudio)
                }
                for d in found { discovered[d.id.lowercased()] = d }
            }
        } else {
            if isHFCacheImportEnabled {
                for root in huggingFaceCacheRoots() {
                    for d in scanHuggingFaceCache(root: root) {
                        discovered[d.id.lowercased()] = d
                    }
                }
            }
            if isLMStudioImportEnabled {
                for root in lmStudioRoots() {
                    for d in scan(root: root, source: .lmStudio) {
                        discovered[d.id.lowercased()] = d
                    }
                }
            }
        }

        lock.lock()
        let changed = registry == nil || registry! != discovered
        registry = discovered
        lock.unlock()

        if changed {
            persist(discovered)
            NotificationCenter.default.post(name: .localModelsChanged, object: nil)
        }
        return models()
    }

    // MARK: - Roots

    private static func huggingFaceCacheRoots() -> [URL] {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        var roots: [URL] = []
        func add(_ url: URL) {
            let standardized = url.standardizedFileURL
            if !roots.contains(standardized) { roots.append(standardized) }
        }
        if let hubCache = env["HF_HUB_CACHE"], !hubCache.isEmpty {
            add(URL(fileURLWithPath: (hubCache as NSString).expandingTildeInPath, isDirectory: true))
        }
        if let hfHome = env["HF_HOME"], !hfHome.isEmpty {
            add(
                URL(fileURLWithPath: (hfHome as NSString).expandingTildeInPath, isDirectory: true)
                    .appendingPathComponent("hub", isDirectory: true)
            )
        }
        add(
            fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        )
        return roots.filter { fm.fileExists(atPath: $0.path) }
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
    private static func scanHuggingFaceCache(root: URL) -> [Discovered] {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        var results: [Discovered] = []
        for entry in entries {
            let folder = entry.lastPathComponent
            guard folder.hasPrefix("models--") else { continue }
            guard let repoId = Self.repoId(fromCacheFolder: folder) else { continue }

            // Resolve refs/main -> commit hash -> snapshots/<hash>.
            let (snapshotDir, revision) = resolveSnapshot(in: entry)
            guard let snapshotDir,
                isContained(snapshotDir, in: root),
                isMLXBundle(snapshotDir, root: root)
            else { continue }

            results.append(
                Discovered(
                    id: repoId,
                    bundlePath: snapshotDir.standardizedFileURL.path,
                    revision: revision,
                    source: Source.huggingFaceCache.rawValue
                )
            )
        }
        return results
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
        if let revData = try? Data(contentsOf: refsMain),
            let rev = String(data: revData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !rev.isEmpty
        {
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
        let fm = FileManager.default
        var results: [Discovered] = []

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
                if isMLXBundle(resolved, root: root) {
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
                if depth > 1 {
                    walk(resolved, prefix: components, depth: depth - 1)
                }
            }
        }
        walk(root, prefix: [], depth: 3)
        return results
    }

    // MARK: - Validation

    /// True when `dir` looks like a loadable MLX bundle: `config.json`, a
    /// recognized tokenizer, and at least one `*.safetensors` file. GGUF
    /// directories (no safetensors) fail this check and are skipped. Any
    /// symlinked file must resolve to a target under `root`.
    static func isMLXBundle(_ dir: URL, root: URL) -> Bool {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool {
            let url = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { return false }
            // Reject symlinks that escape the scan root.
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            return isContained(resolved, in: root)
        }

        guard exists("config.json") else { return false }

        let hasTokenizer =
            exists("tokenizer.json")
            || (exists("merges.txt") && (exists("vocab.json") || exists("vocab.txt")))
            || exists("tokenizer.model")
            || exists("spiece.model")
        guard hasTokenizer else { return false }

        // Weights: a single/sharded safetensors. Cheap sentinel first, then
        // fall back to scanning the directory for any `*.safetensors` (covers
        // arbitrary shard counts and HF's symlinked blob names).
        if exists("model.safetensors") || exists("model.safetensors.index.json") { return true }
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return false }
        return items.contains { item in
            guard item.pathExtension == "safetensors" else { return false }
            let resolved = item.resolvingSymlinksInPath().standardizedFileURL
            return isContained(resolved, in: root)
        }
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
        lock.unlock()
    }
}
