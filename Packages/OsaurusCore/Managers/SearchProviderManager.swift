//
//  SearchProviderManager.swift
//  osaurus
//
//  MainActor owner of the native search-provider stack: configuration
//  (ranked providers + per-category routing), custom definitions, Keychain
//  writes, and test/status state for the Search settings tab. The cascade
//  itself runs in `SearchEngine`; the manager hands it immutable snapshots.
//

import Foundation
import Combine

@MainActor
public final class SearchProviderManager: ObservableObject {
    public static let shared = SearchProviderManager()

    public enum ProviderTestStatus: Equatable {
        case testing
        case ok(hitCount: Int, elapsed: TimeInterval)
        case failed(String)
    }

    /// Snapshot of the most recent full-cascade search this session — from a
    /// live tool call or the Try-it playground. The Search tab's hub panel
    /// uses it to show real health ("last search succeeded via …") instead of
    /// claiming search works based purely on configuration. In-memory only:
    /// per-session freshness is exactly what a health signal wants.
    public struct LastSearchOutcome: Equatable {
        public let date: Date
        public let ok: Bool
        /// Winning provider id (nil when every attempt failed).
        public let providerId: String?
        public let hitCount: Int
    }

    @Published public private(set) var configuration: SearchProviderConfiguration
    @Published public private(set) var customDefinitions: [SearchProviderDefinition]
    /// Per-provider result of the most recent pinned test run.
    @Published public private(set) var testStatus: [String: ProviderTestStatus] = [:]
    /// Providers whose declared secrets are all present in Keychain.
    /// Cached so schema composition doesn't hit Keychain per request.
    @Published public private(set) var configuredProviderIds: Set<String> = []
    /// Most recent full-cascade outcome this session (nil until one runs).
    @Published public private(set) var lastOutcome: LastSearchOutcome?

    private let engine: SearchEngine

    init(engine: SearchEngine = .shared) {
        self.engine = engine
        self.configuration = SearchProviderConfigurationStore.load()
        self.customDefinitions = SearchProviderDefinitionStore.loadCustom()
        migratePluginKeysIfNeeded()
        refreshConfiguredProviderIds()
    }

    // MARK: - Definitions

    /// Every known definition: bundled catalog + user-created customs.
    public var definitions: [SearchProviderDefinition] {
        SearchProviderCatalog.bundled + customDefinitions
    }

    public func definition(id: String) -> SearchProviderDefinition? {
        definitions.first { $0.id == id }
    }

    /// Definitions not yet added to the user's provider list, for the
    /// Add Provider gallery (free scrapers are seeded by default and
    /// excluded here).
    public var addableDefinitions: [SearchProviderDefinition] {
        let installed = Set(configuration.providers.map { $0.definitionId })
        return (SearchProviderCatalog.apiProviders + customDefinitions)
            .filter { !installed.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.recommended != rhs.recommended { return lhs.recommended }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// The user's providers in rank order, paired with their definitions.
    /// Providers whose definition disappeared (deleted custom) are skipped.
    public var rankedProviders: [(provider: SearchProvider, definition: SearchProviderDefinition)] {
        configuration.providers.compactMap { provider in
            definition(id: provider.definitionId).map { (provider, $0) }
        }
    }

    // MARK: - Mutations

    public func addProvider(definitionId: String, enabled: Bool = true) {
        guard definition(id: definitionId) != nil else { return }
        guard configuration.provider(id: definitionId) == nil else { return }
        // New API providers rank above the free scrapers (which stay the
        // always-available backstop), below existing API providers.
        var providers = configuration.providers
        let firstFreeIndex =
            providers.firstIndex { SearchProviderCatalog.freeProviderIds.contains($0.definitionId) }
            ?? providers.endIndex
        providers.insert(SearchProvider(definitionId: definitionId, enabled: enabled), at: firstFreeIndex)
        configuration.providers = providers
        persist()
    }

    public func removeProvider(definitionId: String) {
        configuration.remove(definitionId: definitionId)
        testStatus[definitionId] = nil
        persist()
    }

    public func setEnabled(_ enabled: Bool, for definitionId: String) {
        configuration.setEnabled(enabled, for: definitionId)
        persist()
    }

    /// Replace the default ranking with `ids` (unknown ids dropped, missing
    /// providers appended in their previous relative order).
    public func setDefaultRanking(_ ids: [String]) {
        var byId: [String: SearchProvider] = [:]
        for p in configuration.providers { byId[p.definitionId] = p }
        var out: [SearchProvider] = []
        var seen = Set<String>()
        for id in ids {
            guard let p = byId[id], seen.insert(id).inserted else { continue }
            out.append(p)
        }
        for p in configuration.providers where seen.insert(p.definitionId).inserted {
            out.append(p)
        }
        configuration.providers = out
        persist()
    }

    public func moveProvider(fromOffsets: IndexSet, toOffset: Int) {
        var providers = configuration.providers
        providers.move(fromOffsets: fromOffsets, toOffset: toOffset)
        configuration.providers = providers
        persist()
    }

    /// Set (or clear with nil/empty) the ranking override for one category.
    public func setRouting(category: String, order: [String]?) {
        if let order, !order.isEmpty {
            configuration.routing[category] = order
        } else {
            configuration.routing.removeValue(forKey: category)
        }
        persist()
    }

    // MARK: - Secrets

    public func saveSecret(_ value: String, field: String, for definitionId: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            SearchProviderKeychain.deleteSecret(field: field, for: definitionId)
        } else {
            SearchProviderKeychain.saveSecret(trimmed, field: field, for: definitionId)
        }
        refreshConfiguredProviderIds()
    }

    public func hasSecret(field: String, for definitionId: String) -> Bool {
        let value = SearchProviderKeychain.getSecret(field: field, for: definitionId)
        return value?.isEmpty == false
    }

    // MARK: - Custom definitions

    public func saveCustomDefinition(_ definition: SearchProviderDefinition) throws {
        try SearchProviderDefinitionStore.save(definition)
        customDefinitions = SearchProviderDefinitionStore.loadCustom()
        if configuration.provider(id: definition.id) == nil {
            addProvider(definitionId: definition.id)
        } else {
            refreshConfiguredProviderIds()
        }
    }

    public func deleteCustomDefinition(id: String) {
        SearchProviderDefinitionStore.delete(definitionId: id)
        customDefinitions = SearchProviderDefinitionStore.loadCustom()
        if configuration.provider(id: id) != nil {
            removeProvider(definitionId: id)
        }
    }

    // MARK: - Snapshots / categories

    /// Ranked, enabled provider snapshots for a category (routing override
    /// applied). This is what the engine consumes.
    public func snapshots(for category: String) -> [SearchProviderSnapshot] {
        let byId = Dictionary(
            uniqueKeysWithValues: rankedProviders.map { ($0.provider.definitionId, $0) })
        return configuration.ranking(for: category).compactMap { id -> SearchProviderSnapshot? in
            guard let entry = byId[id], entry.provider.enabled,
                entry.definition.supports(category: category)
            else { return nil }
            return snapshot(definition: entry.definition, enabled: true)
        }
    }

    public func snapshot(for definitionId: String) -> SearchProviderSnapshot? {
        guard let def = definition(id: definitionId) else { return nil }
        let enabled = configuration.provider(id: definitionId)?.enabled ?? false
        return snapshot(definition: def, enabled: enabled)
    }

    private func snapshot(definition: SearchProviderDefinition, enabled: Bool) -> SearchProviderSnapshot {
        SearchProviderSnapshot(
            definition: definition,
            enabled: enabled,
            secrets: definition.resolvedSecrets()
        )
    }

    /// Categories that at least one enabled + configured provider can serve,
    /// in stable display order. Drives the `web_search` schema's category enum.
    public func availableCategories() -> [String] {
        var out: Set<String> = []
        for (provider, def) in rankedProviders where provider.enabled {
            guard def.isKeyless || configuredProviderIds.contains(def.id) else { continue }
            out.formUnion(def.supportedCategories)
        }
        return out.sorted {
            let (a, b) = (SearchCategory.sortIndex($0), SearchCategory.sortIndex($1))
            return a == b ? $0 < $1 : a < b
        }
    }

    /// True when any enabled API-key provider is configured (used for the
    /// NO_RESULTS hint and the settings upsell card).
    public var hasConfiguredAPIProvider: Bool {
        rankedProviders.contains { provider, def in
            provider.enabled && !def.isKeyless && configuredProviderIds.contains(def.id)
        }
    }

    // MARK: - Search entry points

    /// Full cascade for a request (used by the tools and the Try-it playground).
    public func runSearch(_ request: SearchRequest) async -> SearchEngineOutcome {
        let providers = snapshots(for: request.category)
        let outcome = await engine.run(request: request, providers: providers)
        lastOutcome = LastSearchOutcome(
            date: Date(),
            ok: !outcome.hits.isEmpty,
            providerId: outcome.provider,
            hitCount: outcome.hits.count
        )
        return outcome
    }

    /// Pinned single-provider run; updates the published `testStatus` so
    /// provider cards can show live verification results.
    @discardableResult
    public func testProvider(
        definitionId: String,
        query: String = "test search"
    ) async -> SearchEngineOutcome? {
        guard let snap = snapshot(for: definitionId) else { return nil }
        testStatus[definitionId] = .testing
        let request = SearchRequest(query: query, category: preferredTestCategory(for: snap.definition))
        let outcome = await engine.runPinned(request: request, provider: snap)
        if let error = outcome.attempts.first(where: { !$0.ok })?.error {
            testStatus[definitionId] = .failed(error)
        } else if outcome.hits.isEmpty {
            testStatus[definitionId] = .failed("No results returned")
        } else {
            testStatus[definitionId] = .ok(hitCount: outcome.hits.count, elapsed: outcome.elapsed)
        }
        return outcome
    }

    private func preferredTestCategory(for definition: SearchProviderDefinition) -> String {
        definition.supports(category: SearchCategory.web)
            ? SearchCategory.web
            : (definition.supportedCategories.first ?? SearchCategory.web)
    }

    // MARK: - Internals

    private func persist() {
        SearchProviderConfigurationStore.save(configuration)
        refreshConfiguredProviderIds()
    }

    private func refreshConfiguredProviderIds() {
        var configured = Set<String>()
        for (_, def) in rankedProviders where def.hasAllSecrets() {
            configured.insert(def.id)
        }
        configuredProviderIds = configured
        SearchToolSchemaState.update(
            categories: availableCategoriesForSchema(configured: configured))
    }

    /// Same as `availableCategories()` but with an explicit configured set so
    /// it can run before the published property lands.
    private func availableCategoriesForSchema(configured: Set<String>) -> [String] {
        var out: Set<String> = []
        for (provider, def) in rankedProviders where provider.enabled {
            guard def.isKeyless || configured.contains(def.id) else { continue }
            out.formUnion(def.supportedCategories)
        }
        return out.sorted {
            let (a, b) = (SearchCategory.sortIndex($0), SearchCategory.sortIndex($1))
            return a == b ? $0 < $1 : a < b
        }
    }

    // MARK: - Plugin key migration

    /// Plugin secret key -> (definition id, secret field) for the retired
    /// osaurus.search plugin.
    static let pluginKeyMap: [String: (definitionId: String, field: String)] = [
        "TAVILY_API_KEY": ("tavily", "api_key"),
        "BRAVE_SEARCH_API_KEY": ("brave_api", "api_key"),
        "SERPER_API_KEY": ("serper", "api_key"),
        "GOOGLE_CSE_API_KEY": ("google_cse", "api_key"),
        "GOOGLE_CSE_CX": ("google_cse", "cx"),
        "KAGI_API_KEY": ("kagi", "api_key"),
        "YOU_API_KEY": ("you", "api_key"),
    ]

    /// One-time copy of API keys the user configured on the osaurus.search
    /// plugin into the native search Keychain + provider list. Skipped when
    /// Keychain access is disabled (tests) so the marker isn't burned before
    /// a real run can migrate.
    private func migratePluginKeysIfNeeded() {
        guard !configuration.pluginKeysMigrated else { return }
        guard !KeychainQueryHelpers.disablesKeychainForProcess else { return }

        var migratedDefinitionIds = Set<String>()
        for (pluginKey, target) in Self.pluginKeyMap {
            guard
                let value = ToolSecretsKeychain.getSecret(
                    id: pluginKey, for: "osaurus.search", agentId: Agent.defaultId),
                !value.isEmpty
            else { continue }
            SearchProviderKeychain.saveSecret(value, field: target.field, for: target.definitionId)
            migratedDefinitionIds.insert(target.definitionId)
        }

        // Only add providers whose full secret set made it across
        // (google_cse needs both the key and the cx).
        for id in migratedDefinitionIds {
            guard let def = SearchProviderCatalog.definition(id: id), def.hasAllSecrets() else { continue }
            if configuration.provider(id: id) == nil {
                var providers = configuration.providers
                let firstFreeIndex =
                    providers.firstIndex {
                        SearchProviderCatalog.freeProviderIds.contains($0.definitionId)
                    } ?? providers.endIndex
                providers.insert(SearchProvider(definitionId: id, enabled: true), at: firstFreeIndex)
                configuration.providers = providers
            }
        }

        configuration.pluginKeysMigrated = true
        // Persist the marker only when there was something to migrate or a
        // config file already exists; otherwise stay lazy (default config is
        // reconstructed identically on every launch).
        let configFileExists = FileManager.default.fileExists(
            atPath: OsaurusPaths.searchProviderConfigFile().path)
        if !migratedDefinitionIds.isEmpty || configFileExists {
            SearchProviderConfigurationStore.save(configuration)
        }
    }
}

// MARK: - Schema state bridge

/// Lock-protected snapshot of the categories available to `web_search`,
/// readable from nonisolated tool-schema getters (tool `parameters` are
/// computed off the MainActor). Updated by `SearchProviderManager` whenever
/// configuration or secrets change.
enum SearchToolSchemaState {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var categories: [String] = [SearchCategory.web]

    static func update(categories new: [String]) {
        lock.lock()
        categories = new.isEmpty ? [SearchCategory.web] : new
        lock.unlock()
    }

    static func availableCategories() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return categories
    }
}
