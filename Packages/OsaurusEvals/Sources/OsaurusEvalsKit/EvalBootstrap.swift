//
//  EvalBootstrap.swift
//  OsaurusEvalsKit
//
//  Startup bootstrapping for the out-of-process eval CLI.
//

import CryptoKit
import Darwin
import Foundation
import OsaurusCore

/// Caller preference for loading installed native plugins before an eval run.
/// This is separate from index bootstrapping because index-only suites should
/// not pay the `dlopen` cost or inherit a bad local plugin's startup hang.
public enum EvalInstalledPluginBootstrapPreference: Sendable, Equatable {
    case automatic
    case force
    case disabled
}

/// Search-index lanes needed by the selected capability-search cases.
/// Keeping this scoped avoids making a method-only eval wait on tool
/// registry sync or SKILL.md rebuilds that cannot affect its verdict.
public struct EvalSearchIndexBootstrapScope: Sendable, Equatable {
    public let tools: Bool
    public let methods: Bool
    public let skills: Bool

    public init(tools: Bool = false, methods: Bool = false, skills: Bool = false) {
        self.tools = tools
        self.methods = methods
        self.skills = skills
    }

    public var isEmpty: Bool {
        !tools && !methods && !skills
    }

    public static let empty = EvalSearchIndexBootstrapScope()
}

/// Minimal bootstrap work needed before the first eval case can run.
/// The CLI uses this to bound expensive host-app setup without making pure
/// data suites depend on local plugin state.
public struct EvalBootstrapPlan: Sendable, Equatable {
    public let loadInstalledPlugins: Bool
    public let searchIndexScope: EvalSearchIndexBootstrapScope

    public init(
        loadInstalledPlugins: Bool,
        searchIndexScope: EvalSearchIndexBootstrapScope
    ) {
        self.loadInstalledPlugins = loadInstalledPlugins
        self.searchIndexScope = searchIndexScope
    }

    public init(loadInstalledPlugins: Bool, initializeSearchIndices: Bool) {
        self.init(
            loadInstalledPlugins: loadInstalledPlugins,
            searchIndexScope: initializeSearchIndices
                ? EvalSearchIndexBootstrapScope(tools: true, methods: true, skills: true)
                : .empty
        )
    }

    public var initializeSearchIndices: Bool {
        !searchIndexScope.isEmpty
    }

    public var requiresWork: Bool {
        loadInstalledPlugins || !searchIndexScope.isEmpty
    }

    /// True when the run will open/sync any of the shared search DBs
    /// (`tool_index`, `methods`, skill index) — i.e. whenever it loads
    /// installed plugins (`loadInstalledPlugins()` syncs all three) OR
    /// brings up a non-empty index scope. Those runs must stay hermetic:
    /// a developer (or CI) with the Osaurus host app running holds the
    /// real `~/.osaurus` SQLite DBs in WAL mode, so the eval's
    /// `ToolDatabase.open()` against the same files fails (→ silent
    /// registry fallback, `index=0`) or its `syncFromRegistry()` write
    /// deadlocks against the app. Isolating to a temp root sidesteps that;
    /// the plugin `Tools/` dir is symlinked back in so plugin discovery
    /// still works (see `configureIsolatedSearchStorageIfNeeded`).
    public var usesIsolatedSearchStorage: Bool {
        requiresWork
    }

    public static func make(
        suite: EvalSuite,
        filter: String?,
        preference: EvalInstalledPluginBootstrapPreference
    ) -> EvalBootstrapPlan {
        switch preference {
        case .force:
            return EvalBootstrapPlan(loadInstalledPlugins: true, searchIndexScope: .empty)
        case .automatic:
            // Auto-load installed native plugins when a selected case
            // explicitly requires one (`fixtures.requirePlugins`, e.g. the
            // capability_claims browser cases). Without this those cases skip
            // as "missing plugins" even when the plugin is installed on disk.
            // Plugin bootstrap (`EvalHostBootstrap.loadInstalledPlugins`) also
            // brings up the search indices, so no extra index scope is needed.
            // Suites with no plugin-required selected case keep avoiding the
            // dlopen cost and only bring up the index lanes they need.
            // `--bootstrap-plugins` (`.force`) still forces loading;
            // `--no-bootstrap-plugins` (`.disabled`) opts out even when cases
            // request plugins.
            if suite.selectedCasesRequireInstalledPlugins(filter: filter) {
                return EvalBootstrapPlan(loadInstalledPlugins: true, searchIndexScope: .empty)
            }
            return EvalBootstrapPlan(
                loadInstalledPlugins: false,
                searchIndexScope: suite.searchIndexBootstrapScopeWithoutPluginBootstrap(filter: filter)
            )
        case .disabled:
            return EvalBootstrapPlan(
                loadInstalledPlugins: false,
                searchIndexScope: suite.searchIndexBootstrapScopeWithoutPluginBootstrap(filter: filter)
            )
        }
    }
}

/// Runs the selected bootstrap plan. Full plugin bootstrap delegates to
/// `EvalHostBootstrap` so the eval CLI mirrors the host app when a run
/// forces plugin loading; index-only bootstrap deliberately avoids native
/// plugin loading.
@MainActor
public enum EvalBootstrap {
    /// Capability-search is an index-only eval lane, so automatic
    /// no-plugin runs should not touch the developer's real encrypted
    /// databases or wait on Keychain. The CLI calls this before startup
    /// bootstrap and keeps the override alive for the whole process.
    @discardableResult
    public static func configureIsolatedSearchStorageIfNeeded(
        for plan: EvalBootstrapPlan
    ) -> URL? {
        guard plan.usesIsolatedSearchStorage else { return nil }
        return isolateRootWithExternalModelsManifest(symlinkTools: plan.loadInstalledPlugins)
    }

    /// Isolate **configuration** storage for the `default_agent` domain.
    ///
    /// Default-agent eval cases drive the real multi-turn loop, which
    /// EXECUTES the consolidated configure write tools (`osaurus_agent`,
    /// `osaurus_provider`, `osaurus_mcp`, `osaurus_schedule`, …) through the
    /// live `ToolRegistry`. Run unguarded, an `osaurus_agent create` would
    /// add a junk agent to the developer's real `~/.osaurus`, an
    /// `osaurus_schedule create` would register a schedule that later fires,
    /// and so on. Isolating the root to a fresh temp dir keeps the real
    /// config pristine — every executed write lands in the throwaway root —
    /// while the external-models manifest symlink keeps the local MLX run
    /// model resolvable (Foundation needs no manifest).
    ///
    /// Must run AFTER `configureIsolatedSearchStorageIfNeeded` so a mixed
    /// suite that also loads plugins keeps that path's `Tools` symlink: when
    /// the root is already isolated this only installs the credential-sheet
    /// bypass and returns nil (no double-isolation).
    ///
    /// `MODEL` must be local MLX or `foundation`; a remote run/judge model
    /// would need provider credentials that live in the (now-isolated, empty)
    /// config root. That matches the plan's local-MLX + Foundation matrix.
    @discardableResult
    public static func configureIsolatedConfigStorageIfNeeded(isolate: Bool) -> URL? {
        guard isolate else { return nil }

        // `osaurus_provider` add / set_credentials open an AppKit credential
        // sheet via `ProviderCredentialPromptService`. A headless eval run
        // has no UI loop to dismiss it, so resolve every request as
        // `.cancelled`: the model's tool CALL (what the matrix scores) is
        // still recorded, and nothing is written to Keychain. Production code
        // leaves this hook nil; the eval CLI process is torn down after the
        // run, so the override never leaks into a real session.
        ProviderCredentialPromptService.bypassUI = { _ in .cancelled }

        return isolateRootWithExternalModelsManifest(symlinkTools: false)
    }

    /// Shared isolation primitive: create a fresh temp root, symlink the real
    /// external-models manifest in (so HF-cache / LM-Studio MLX models stay
    /// resolvable), optionally symlink the real `Tools` dir (plugin
    /// discovery), point `OsaurusPaths.root` at it, and seed the DEBUG
    /// storage key. Returns the temp root, or nil when the root is ALREADY
    /// overridden — the first isolation owns the symlinks; a second caller
    /// must not clobber them with a fresh (symlink-less) root.
    private static func isolateRootWithExternalModelsManifest(symlinkTools: Bool) -> URL? {
        guard OsaurusPaths.overrideRoot == nil else { return nil }

        // Resolve the REAL plugin install dir before overriding the root —
        // `OsaurusPaths.tools()` is `root()/Tools`, so we have to capture it
        // while `root()` still points at `~/.osaurus`.
        let realToolsDir = symlinkTools ? OsaurusPaths.tools() : nil

        // Same capture-before-override rule for the external-models manifest
        // (`root()/cache/external-models.json`): the id -> absolute bundle-path
        // registry that makes HF-cache / LM-Studio models resolvable via
        // ExternalModelLocator -> discoverLocalModels -> ChatEngine routing. An
        // eval whose `--model` lives only in `~/.cache/huggingface/hub` (e.g.
        // `mlx-community/Qwen3-4B-4bit`) is reachable ONLY through this manifest;
        // under the isolated temp root it is absent, so an LLM run on the
        // isolated path (CapabilityClaims / default_agent) would route the
        // model to `.none` and error every case with `modelNotFound`.
        let realExternalModelsManifest = OsaurusPaths.externalModelsManifestFile()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-evals-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        // Plugin discovery scans `root()/Tools`. When this run loads
        // installed plugins, symlink the real Tools dir into the isolated
        // root so `PluginManager.loadAll()` still finds (and registers the
        // tools/skills of) the user's installed plugins, while the derived
        // search DBs are created fresh in temp. Read-only dylib scan — no
        // lock contention with a running host app, unlike the DBs.
        if let realToolsDir,
            FileManager.default.fileExists(atPath: realToolsDir.path)
        {
            let linkedTools = root.appendingPathComponent("Tools", isDirectory: true)
            try? FileManager.default.createSymbolicLink(
                at: linkedTools,
                withDestinationURL: realToolsDir
            )
        }

        OsaurusPaths.overrideRoot = root

        // Symlink the real external-models manifest into the isolated cache so
        // HF-cache / LM-Studio MLX models stay resolvable on the isolated path.
        // The manifest records absolute bundle paths, so reads resolve in
        // place; read-only — the eval LLM path never rescans or rewrites it.
        if FileManager.default.fileExists(atPath: realExternalModelsManifest.path) {
            let isolatedManifest = OsaurusPaths.externalModelsManifestFile()
            try? FileManager.default.createDirectory(
                at: isolatedManifest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.createSymbolicLink(
                at: isolatedManifest,
                withDestinationURL: realExternalModelsManifest
            )
        }

        #if DEBUG
            StorageKeyManager.shared._setKeyForTesting(
                SymmetricKey(data: Data(repeating: 0xA5, count: 32))
            )
        #endif

        return root
    }

    public static func run(_ plan: EvalBootstrapPlan) async {
        // Make the self-declared KV-cache regime real before any model loads
        // (so a "memory-only" run truly disables the disk-L2 lane instead of
        // inheriting the disk-L2 default). Process-local; never persisted.
        applyKVRegimeOverrideIfRequested()

        // Colocate the MLX Metal shader library beside this CLI binary
        // before any local model load. No-op for remote-only runs and
        // when the metallib is already present (see MLXMetallibBootstrap).
        MLXMetallibBootstrap.ensureBesideExecutable()

        if plan.loadInstalledPlugins {
            await EvalHostBootstrap.loadInstalledPlugins()
            return
        }

        if !plan.searchIndexScope.isEmpty {
            await initializeSearchIndices(plan.searchIndexScope)
        }
    }

    /// Sentinel disk-KV directory that can never be a writable directory
    /// (`/dev/null` is a character device, so no subdirectory under it can be
    /// created or written). Pointing the cache disk dir here trips the
    /// documented memory-only degradation in
    /// `ModelRuntime.buildCacheCoordinatorConfig` (`!diskDirUsable` →
    /// `enableDiskCache = false`) WITHOUT disabling the in-memory prefix lane.
    static let memoryOnlyKVSentinelDir = "/dev/null/osaurus-evals-memory-only-kv"

    /// Wire the self-declared `OSAURUS_EVALS_KV_REGIME` provenance label to the
    /// ACTUAL runtime cache config so a "memory-only" run really runs
    /// memory-only (disk-L2 off) rather than silently inheriting the disk-L2
    /// default. Applied process-locally via `overrideSnapshotInMemory` so it
    /// never persists to the user's saved server settings. Unknown labels stay
    /// provenance-only (no runtime change). This keeps the recorded regime
    /// honest — the column in `history.jsonl` now matches what actually ran.
    ///
    /// IMPORTANT — why we move the disk *directory* rather than flip
    /// `blockDisk.enabled`: `buildCacheCoordinatorConfig` rebuilds the cache
    /// from `settings.resolvedMemorySafetyPlan(host:).cache`, and that resolved
    /// plan FORCES `blockDisk.enabled = true` whenever `prefix.enabled` is on
    /// (vmlx `ServerRuntimeSettings.resolvedMemorySafetyPlan`, the shipped
    /// prefix→L2-spillover coupling). So toggling the `.enabled` flag here is
    /// silently overwritten and the disk-L2 lane still writes `kv_v2`. The
    /// resolved plan does NOT touch the disk *directory*, so redirecting it to
    /// an unwritable sentinel is the only honest, prefix-preserving way to get
    /// the documented memory-only regime — the same regime the committed
    /// `perf-ram-baseline.md` (Qwen) was measured under.
    static func applyKVRegimeOverrideIfRequested() {
        let env = ProcessInfo.processInfo.environment
        let regimeRaw = env["OSAURUS_EVALS_KV_REGIME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Orthogonal paged-KV A/B knob: engages vmlx's paged prefix-cache lane
        // (`usePagedCache = prefix.enabled && pagedKV.enabled`). vmlx ships
        // `VMLXPagedKVCacheSettings.enabled = false`, so without this the eval
        // decode never exercises the paged path and the pagedStats prefix-hit
        // counters stay 0.
        //
        // NOTE: for rotating-window families (e.g. Gemma-4) this knob is a
        // structural no-op — `BatchEngine` flags the heterogeneous cache
        // `isPagedIncompatible`, the paged tier is skipped, and the prefix
        // counter reads 0/0 by design (their reuse lane is disk-L2, not paged).
        // Still effective for pure full-attention families. Full trace:
        // `perf-gemma4-12b-mxfp8-baseline.md` Lever 1.
        let pagedRaw = env["OSAURUS_EVALS_PAGED_KV"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Bounded disk-L2 cap A/B knob (GB). The disk-L2 lane is Gemma-4's only
        // reuse lane, but its resolved-default cap is 10 GB — too high for a
        // host without tens of GB free (Lever 2 wrote 9.6 GB in ~90 s before it
        // tripped the cap). `DiskCache._evictIfNeededLocked` enforces the cap
        // SYNCHRONOUSLY after every store, so a low cap (e.g. 2) bounds growth
        // to ≤ cap + one entry — making a SAFE disk-L2 reuse A/B possible.
        let diskCapRaw = env["OSAURUS_EVALS_DISK_L2_CAP_GB"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            (regimeRaw?.isEmpty == false) || (pagedRaw?.isEmpty == false)
                || (diskCapRaw?.isEmpty == false)
        else { return }

        var settings = ServerRuntimeSettingsStore.snapshot()
        let before = settings
        var notes: [String] = []

        switch regimeRaw {
        case "memory-only", "memory", "mem":
            // Redirect BOTH disk-KV lanes to an unwritable sentinel so the disk
            // dir resolves as non-writable and the coordinator degrades to
            // memory-only. `prefix.enabled` stays on, so in-memory prefix reuse
            // (the warm-prefill / TTFT-collapse signal) is preserved — this is
            // the supported "disk dir unwritable" degradation, not a settings
            // hack the resolved plan can undo.
            settings.cache.blockDisk.directory = Self.memoryOnlyKVSentinelDir
            settings.cache.legacyDisk.directory = Self.memoryOnlyKVSentinelDir
            notes.append("regime=memory-only (blockDisk.dir=\(Self.memoryOnlyKVSentinelDir))")
        case "disk-l2", "disk", "block-disk", "disk+memory":
            // Explicitly engage the disk-L2 spillover lane (this is also the
            // resolved-plan default when prefix is on, but stating it keeps the
            // provenance label honest against the runtime).
            settings.cache.blockDisk.enabled = true
            notes.append("regime=disk-l2 (blockDisk.enabled=true)")
        case .some(let other) where !other.isEmpty:
            notes.append("regime='\(other)' provenance-only (no runtime change)")
        default:
            break
        }

        switch pagedRaw {
        case "on", "1", "true", "enabled":
            settings.cache.pagedKV.enabled = true
            notes.append("pagedKV.enabled=true")
        case "off", "0", "false", "disabled":
            settings.cache.pagedKV.enabled = false
            notes.append("pagedKV.enabled=false")
        case .some(let other) where !other.isEmpty:
            notes.append("pagedKV='\(other)' ignored (use on/off)")
        default:
            break
        }

        if let diskCapRaw, !diskCapRaw.isEmpty {
            if let capGB = Double(diskCapRaw), capGB > 0 {
                // `blockDisk.maxSizeGB` flows to `CacheCoordinatorConfig.diskCacheMaxGB`
                // → `DiskCache.maxSizeBytes`, enforced after every store. Bounds
                // the disk-L2 lane for a safe reuse A/B on a constrained host.
                settings.cache.blockDisk.maxSizeGB = capGB
                notes.append("blockDisk.maxSizeGB=\(capGB)")
            } else {
                notes.append("diskL2Cap='\(diskCapRaw)' ignored (use a positive GB number)")
            }
        }

        guard settings != before else {
            if !notes.isEmpty {
                FileHandle.standardError.write(
                    Data("[evals] KV override (no-op): \(notes.joined(separator: "; "))\n".utf8)
                )
            }
            return
        }
        ServerRuntimeSettingsStore.overrideSnapshotInMemory(settings)
        FileHandle.standardError.write(
            Data("[evals] KV override → \(notes.joined(separator: "; ")) (process-local)\n".utf8)
        )
    }

    /// Bring up the search indices used by `CapabilitySearchEvaluator`
    /// without scanning or dlopen-ing installed native plugins.
    private static func initializeSearchIndices(_ scope: EvalSearchIndexBootstrapScope) async {
        // Every search lane needs the shared embedder; warn loudly up
        // front if it's missing rather than silently building empty
        // vector indices that make capability_search look broken.
        EmbeddingService.ensureModelPresent()

        if scope.tools {
            try? ToolDatabase.shared.open()
            await ToolSearchService.shared.initialize()
            await ToolIndexService.shared.syncFromRegistry()
        }

        if scope.methods {
            try? MethodDatabase.shared.open()
            await MethodSearchService.shared.initialize()
        }

        if scope.skills {
            await SkillManager.shared.refresh()
            await SkillSearchService.shared.initialize()
            await SkillSearchService.shared.rebuildIndex()
        }
    }

}

public extension EvalSuite {
    /// True when any selected case explicitly requires an installed native
    /// plugin (`fixtures.requirePlugins`). Drives the automatic plugin
    /// bootstrap so plugin-gated cases (e.g. the capability_claims browser
    /// cases) actually run instead of skipping as "missing plugins" when the
    /// plugin is installed on disk.
    func selectedCasesRequireInstalledPlugins(filter: String?) -> Bool {
        selectedCases(filter: filter).contains {
            !($0.fixtures.requirePlugins?.isEmpty ?? true)
        }
    }

    /// Search indices are only useful for cases that will reach the search
    /// evaluator. Without plugin bootstrap, plugin-required cases skip before
    /// searching, so a filtered run of those cases should not block on index IO.
    func needsSearchIndicesWithoutPluginBootstrap(filter: String?) -> Bool {
        !searchIndexBootstrapScopeWithoutPluginBootstrap(filter: filter).isEmpty
    }

    /// Returns the minimum search-index lanes needed by selected cases.
    /// Plugin-required cases are ignored here because they skip before
    /// `CapabilitySearchEvaluator.evaluate` when installed plugins were not
    /// loaded, so their expected lanes cannot affect the report.
    func searchIndexBootstrapScopeWithoutPluginBootstrap(
        filter: String?
    ) -> EvalSearchIndexBootstrapScope {
        var needsTools = false
        var needsMethods = false
        var needsSkills = false

        for testCase in selectedCases(filter: filter) {
            guard testCase.domain == "capability_search" else { continue }
            guard testCase.fixtures.requirePlugins?.isEmpty ?? true else { continue }

            let expect = testCase.expect.capabilitySearch
            needsTools = needsTools || expect?.expectedTools != nil
            needsMethods =
                needsMethods
                || expect?.expectedMethods != nil
                || !(testCase.fixtures.seedMethods?.isEmpty ?? true)
            needsSkills =
                needsSkills
                || expect?.expectedSkills != nil
                || !(testCase.fixtures.enableSkills?.isEmpty ?? true)
        }

        return EvalSearchIndexBootstrapScope(
            tools: needsTools,
            methods: needsMethods,
            skills: needsSkills
        )
    }

    /// True when any selected case targets the `default_agent` domain, which
    /// executes real configure write tools and therefore needs config-storage
    /// isolation (see `EvalBootstrap.configureIsolatedConfigStorageIfNeeded`).
    func selectedCasesIncludeDefaultAgent(filter: String?) -> Bool {
        selectedCases(filter: filter).contains { $0.domain == "default_agent" }
    }

    private func selectedCases(filter: String?) -> [EvalCase] {
        guard let filter else { return cases }
        return cases.filter { $0.id.contains(filter) }
    }
}
