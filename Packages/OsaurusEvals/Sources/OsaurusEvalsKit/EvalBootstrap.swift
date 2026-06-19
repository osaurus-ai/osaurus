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

        // Resolve the REAL plugin install dir before overriding the root —
        // `OsaurusPaths.tools()` is `root()/Tools`, so we have to capture it
        // while `root()` still points at `~/.osaurus`.
        let realToolsDir = plan.loadInstalledPlugins ? OsaurusPaths.tools() : nil

        // Same capture-before-override rule for the external-models manifest
        // (`root()/cache/external-models.json`): the id -> absolute bundle-path
        // registry that makes HF-cache / LM-Studio models resolvable via
        // ExternalModelLocator -> discoverLocalModels -> ChatEngine routing. An
        // eval whose `--model` lives only in `~/.cache/huggingface/hub` (e.g.
        // `mlx-community/Qwen3-4B-4bit`) is reachable ONLY through this manifest;
        // under the isolated temp root it is absent, so an LLM run on the
        // isolated path (CapabilityClaims) would route the model to `.none` and
        // error every case with `modelNotFound`.
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

    private func selectedCases(filter: String?) -> [EvalCase] {
        guard let filter else { return cases }
        return cases.filter { $0.id.contains(filter) }
    }
}
