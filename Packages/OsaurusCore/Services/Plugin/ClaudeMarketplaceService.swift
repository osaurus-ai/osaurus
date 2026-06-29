//
//  ClaudeMarketplaceService.swift
//  osaurus
//
//  Loads and caches the official Claude plugins marketplace catalog
//  (anthropics/claude-plugins-official) for the Plugins → Browse tab, and
//  installs individual entries on demand.
//
//  Design: the official marketplace lists 200+ plugins. We fetch just its
//  `marketplace.json` once per session (a single network request) and render
//  every entry as a card. The expensive per-plugin manifest resolution (and
//  its ~9 directory-probe round-trips) is deferred to `install(entry:)` so
//  browsing the whole catalog never burns through GitHub's unauthenticated
//  rate limit.
//

import Foundation
import SwiftUI

/// One discovery category derived from the marketplace entries, with the
/// number of plugins it contains. Drives the Browse-tab category chips.
public struct ClaudeMarketplaceCategory: Identifiable, Hashable, Sendable {
    /// Lowercased category key (`development`, `productivity`, …) or the
    /// sentinel `Self.otherKey` for entries that declared no category.
    public let id: String
    public let count: Int

    /// Sentinel id used for entries without a declared `category`.
    public static let otherKey = "__other__"

    /// Title-cased label for display. `Other` for the uncategorized bucket.
    public var displayName: String {
        if id == Self.otherKey { return "Other" }
        return id.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

@MainActor
public final class ClaudeMarketplaceService: ObservableObject {
    public static let shared = ClaudeMarketplaceService()

    /// Official, Anthropic-managed marketplace.
    public static let officialURL = "https://github.com/anthropics/claude-plugins-official"
    public static let officialRepo = GitHubRepo(owner: "anthropics", name: "claude-plugins-official")

    @Published public private(set) var entries: [MarketplacePlugin] = []
    @Published public private(set) var repo: GitHubRepo?
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: String?
    /// True once a successful catalog load has populated `entries`.
    @Published public private(set) var hasLoaded = false

    private let github: GitHubSkillService

    /// Precomputed classification used to hide plugins Osaurus can't import.
    /// Injected for tests; defaults to the bundled catalog.
    private let importabilityCatalog: ClaudeMarketplaceImportabilityCatalog

    public init(
        github: GitHubSkillService = .shared,
        importabilityCatalog: ClaudeMarketplaceImportabilityCatalog = .bundled
    ) {
        self.github = github
        self.importabilityCatalog = importabilityCatalog
    }

    // MARK: - Categories

    /// Categories present in the catalog, sorted by descending plugin count
    /// then alphabetically, with the uncategorized bucket pushed to the end.
    public var categories: [ClaudeMarketplaceCategory] {
        var counts: [String: Int] = [:]
        for entry in entries {
            let key = Self.categoryKey(for: entry)
            counts[key, default: 0] += 1
        }
        return
            counts
            .map { ClaudeMarketplaceCategory(id: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.id == ClaudeMarketplaceCategory.otherKey { return false }
                if rhs.id == ClaudeMarketplaceCategory.otherKey { return true }
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.displayName < rhs.displayName
            }
    }

    /// Normalized category key for an entry, falling back to the
    /// uncategorized sentinel.
    nonisolated public static func categoryKey(for entry: MarketplacePlugin) -> String {
        let raw = entry.category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let raw, !raw.isEmpty else { return ClaudeMarketplaceCategory.otherKey }
        return raw
    }

    // MARK: - Loading

    /// Load the catalog if it hasn't been loaded yet (or a prior attempt
    /// failed). Safe to call on every appear.
    public func loadIfNeeded() {
        guard !hasLoaded, !isLoading else { return }
        Task { await load() }
    }

    /// Force a fresh fetch of the marketplace catalog.
    public func refresh() async {
        await load()
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            let catalog = try await github.fetchMarketplaceCatalog(from: Self.officialURL)
            repo = catalog.repo
            // Filter on load (before publishing) using the precomputed
            // catalog so the grid renders the final set immediately — no
            // per-display classification, no "countdown" as entries vanish,
            // and no extra GitHub requests.
            entries = catalog.entries.filter {
                !importabilityCatalog.isNonImportable(name: $0.name)
            }
            hasLoaded = true
        } catch let err as GitHubSkillError {
            lastError = err.localizedDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Installed-state matching

    /// Stable plugin id an entry would receive once installed from this
    /// marketplace. Matches `InstalledClaudePluginsAggregator` ids so the
    /// browse cards can show an "Installed" state.
    public func pluginId(for entry: MarketplacePlugin) -> String? {
        guard let repo else { return nil }
        return ClaudePluginInstaller.pluginId(repo: repo, pluginName: entry.name)
    }

    public func trustPreview(for entry: MarketplacePlugin) -> ClaudeMarketplaceTrustPreview {
        importabilityCatalog.trustPreview(for: entry, marketplaceRepo: repo ?? Self.officialRepo)
    }

    // MARK: - Install

    /// Resolve a single entry's full manifest and install it. Returns the
    /// install report, or `nil` if the catalog repo isn't loaded yet.
    /// Throws `ClaudeMarketplaceInstallPreviewError` before manifest resolution
    /// when the bundled preview says the entry is blocked.
    /// Unclassified entries still resolve the live manifest so new upstream
    /// plugins are not blocked until the bundled catalog refreshes.
    /// Still validates the resolved manifest as defense-in-depth for catalog
    /// drift, so callers surface a clear message instead of creating an empty
    /// bundle.
    @discardableResult
    public func install(entry: MarketplacePlugin) async throws -> ClaudePluginInstallReport? {
        guard let repo else { return nil }
        let preview = trustPreview(for: entry)
        if let guardError = preview.installGuardError {
            throw guardError
        }
        let manifest = try await github.resolveManifest(rootRepo: repo, entry: entry)
        guard manifest.hasImportableComponents else {
            throw ClaudeMarketplaceInstallPreviewError.blocked(
                pluginName: entry.name,
                reason:
                    "The resolved plugin manifest has no importable skills, agents, commands, or MCP servers."
            )
        }
        let selection = ClaudePluginSelection(manifest: manifest)
        let report = await SkillManager.shared.batchUpdates {
            await ClaudePluginInstaller.shared.install(
                selections: [selection],
                from: repo
            )
        }
        return report
    }
}
