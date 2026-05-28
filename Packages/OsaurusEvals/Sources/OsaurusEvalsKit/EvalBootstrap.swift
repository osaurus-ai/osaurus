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

    /// True when the selected cases only need derived search indices.
    /// Those runs should stay hermetic so fixture writes cannot touch
    /// the developer's real method database or block on Keychain.
    public var usesIsolatedSearchStorage: Bool {
        !loadInstalledPlugins && !searchIndexScope.isEmpty
    }

    public static func make(
        suite: EvalSuite,
        filter: String?,
        preference: EvalInstalledPluginBootstrapPreference
    ) -> EvalBootstrapPlan {
        switch preference {
        case .force:
            return EvalBootstrapPlan(loadInstalledPlugins: true, searchIndexScope: .empty)
        case .disabled:
            return EvalBootstrapPlan(
                loadInstalledPlugins: false,
                searchIndexScope: suite.searchIndexBootstrapScopeWithoutPluginBootstrap(filter: filter)
            )
        case .automatic:
            let needsPreflight = suite.containsCase(domain: "preflight", filter: filter)
            return EvalBootstrapPlan(
                loadInstalledPlugins: needsPreflight,
                searchIndexScope: needsPreflight
                    ? .empty
                    : suite.searchIndexBootstrapScopeWithoutPluginBootstrap(filter: filter)
            )
        }
    }
}

/// Runs the selected bootstrap plan. Full plugin bootstrap delegates to
/// `PreflightEvaluator` so the eval CLI mirrors the host app for preflight
/// suites; index-only bootstrap deliberately avoids native plugin loading.
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

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-evals-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        OsaurusPaths.overrideRoot = root

        #if DEBUG
            StorageMigrationCoordinator.shared._setReadyForTesting()
            StorageKeyManager.shared._setKeyForTesting(
                SymmetricKey(data: Data(repeating: 0xA5, count: 32))
            )
        #endif

        return root
    }

    public static func run(_ plan: EvalBootstrapPlan) async {
        if plan.loadInstalledPlugins {
            await withHeadlessStorageMigrationGate {
                await PreflightEvaluator.loadInstalledPlugins()
            }
            return
        }

        if !plan.searchIndexScope.isEmpty {
            await initializeSearchIndices(plan.searchIndexScope)
        }
    }

    /// Bring up the search indices used by `CapabilitySearchEvaluator`
    /// without scanning or dlopen-ing installed native plugins.
    private static func initializeSearchIndices(_ scope: EvalSearchIndexBootstrapScope) async {
        await withHeadlessStorageMigrationGate {
            await StorageMigrationCoordinator.shared.awaitReady()
        }

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

    /// The eval executable is a headless CLI, but `awaitReady()` is shared with
    /// the app and normally creates a SwiftUI migration panel when work is
    /// needed. Temporarily marking the process as CI reuses the existing
    /// Core-side no-panel branch while still running the real migrator and
    /// preserving the storage gate's fail-closed behaviour.
    private static func withHeadlessStorageMigrationGate(
        _ operation: @escaping @MainActor () async -> Void
    ) async {
        let previousCI = getenv("CI").map { String(cString: $0) }
        setenv("CI", "true", 1)
        defer {
            if let previousCI {
                setenv("CI", previousCI, 1)
            } else {
                unsetenv("CI")
            }
        }
        await operation()
    }
}

public extension EvalSuite {
    /// Domain presence after applying the same substring filter the CLI applies
    /// to case execution. Bootstrap should match the cases that will actually run.
    func containsCase(domain: String, filter: String?) -> Bool {
        if let filter {
            return cases.contains { $0.domain == domain && $0.id.contains(filter) }
        }
        return cases.contains { testCase in
            testCase.domain == domain
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
            if testCase.domain == "preflight" {
                needsTools = true
                needsMethods = true
                needsSkills = true
                continue
            }

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
