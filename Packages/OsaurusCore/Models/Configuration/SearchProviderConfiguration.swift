//
//  SearchProviderConfiguration.swift
//  osaurus
//
//  Configuration model for native web-search providers.
//
//  Providers are data, not code: a `SearchProviderDefinition` is a declarative
//  JSON document that describes any REST search API (auth, endpoints per
//  category, request parameter templates, and response key-path mappings).
//  The bundled catalog (`SearchProviderCatalog`) ships Tavily, Exa, Brave,
//  Serper, Parallel, Google CSE, Kagi, and You.com in this exact format; users
//  can add any other API as a custom definition without an app update. Free
//  scrapers (Brave HTML / Bing HTML / DuckDuckGo) are `runtime: native`
//  definitions whose implementation lives in `NativeSearchBackends`.
//

import Foundation

// MARK: - Categories

/// Well-known search categories. Categories are open-ended strings so custom
/// definitions can introduce provider-specific ones (e.g. "academic"); these
/// constants cover the built-in verticals.
public enum SearchCategory {
    public static let web = "web"
    public static let news = "news"
    public static let images = "images"

    /// Stable display ordering for known categories; unknown ones sort after.
    public static func sortIndex(_ category: String) -> Int {
        switch category {
        case web: return 0
        case news: return 1
        case images: return 2
        default: return 3
        }
    }
}

// MARK: - Definition: secrets

/// One secret (API key / engine id / ...) a provider needs. All declared
/// secrets are required for the provider to be considered configured.
public struct SearchSecretField: Codable, Sendable, Equatable, Identifiable {
    /// Stable identifier referenced from endpoint templates as `{{secret.<id>}}`
    /// and used as the Keychain account suffix.
    public var id: String
    /// Human-readable label shown in the UI (e.g. "Tavily API key").
    public var label: String
    /// Optional short help text (plain language, may mention where to find it).
    public var help: String?
    /// URL where the user can obtain this secret.
    public var url: String?

    public init(id: String, label: String, help: String? = nil, url: String? = nil) {
        self.id = id
        self.label = label
        self.help = help
        self.url = url
    }
}

// MARK: - Definition: request mapping

/// One request parameter (query-string or JSON-body) of a declarative endpoint.
///
/// `value` is a template resolved against the current `SearchRequest`:
///   {{query}}        augmented query (site:/filetype: operators appended)
///   {{raw_query}}    query without appended operators
///   {{max_results}}  clamped result count
///   {{offset}}       zero-based pagination offset
///   {{page}}         1-based page number (offset / max_results + 1)
///   {{start}}        1-based result index (offset + 1)
///   {{time_range}}   canonical recency filter: d | w | m | y (empty when unset)
///   {{after_date}}   time range as an absolute yyyy-MM-dd start date (empty when unset)
///   {{region}}       region code like "us-en" (empty when unset)
///   {{secret.<id>}}  secret field value from Keychain
/// Literal text is passed through unchanged, so `"basic"` is a constant.
public struct SearchRequestParam: Codable, Sendable, Equatable {
    /// Parameter name in the target API.
    public var name: String
    /// Value template (see above).
    public var value: String
    /// Value encoding for POST bodies. Default (nil / "string") sends a string.
    ///   "int"          JSON number (clamped via `clampMax`)
    ///   "json"         value is a JSON literal (after template substitution)
    ///                  embedded as-is, e.g. Exa's `contents` object
    ///   "string_array" resolved value wrapped in a one-element JSON array,
    ///                  e.g. Parallel's required `search_queries`
    public var type: String?
    /// Skip this parameter entirely when the resolved value is empty
    /// (e.g. `time_range` when the caller didn't ask for a recency filter).
    public var omitIfEmpty: Bool?
    /// Optional value map applied after template resolution. Used to translate
    /// the canonical time-range codes into provider-specific ones
    /// (e.g. Brave: "w" -> "pw", Serper: "w" -> "qdr:w"). A resolved value
    /// missing from the map yields empty (combine with `omitIfEmpty`).
    public var map: [String: String]?
    /// Upper clamp for integer parameters (e.g. Google CSE caps `num` at 10).
    public var clampMax: Int?

    public init(
        name: String,
        value: String,
        type: String? = nil,
        omitIfEmpty: Bool? = nil,
        map: [String: String]? = nil,
        clampMax: Int? = nil
    ) {
        self.name = name
        self.value = value
        self.type = type
        self.omitIfEmpty = omitIfEmpty
        self.map = map
        self.clampMax = clampMax
    }
}

// MARK: - Definition: response mapping

/// Key paths (dot-separated, with `|` fallback alternatives per segment list)
/// that extract normalized hit fields from one result item.
public struct SearchHitFieldPaths: Codable, Sendable, Equatable {
    public var title: String?
    public var url: String?
    /// Supports fallbacks: "description|snippet" tries `description` first.
    public var snippet: String?
    public var publishedDate: String?
    public var sourceDomain: String?
    /// Image-category endpoints: full-size image and thumbnail URLs.
    public var imageURL: String?
    public var thumbnailURL: String?

    public init(
        title: String? = nil,
        url: String? = nil,
        snippet: String? = nil,
        publishedDate: String? = nil,
        sourceDomain: String? = nil,
        imageURL: String? = nil,
        thumbnailURL: String? = nil
    ) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.publishedDate = publishedDate
        self.sourceDomain = sourceDomain
        self.imageURL = imageURL
        self.thumbnailURL = thumbnailURL
    }
}

/// Optional per-item filter: keep only items whose `path` value stringifies to
/// `equals` (e.g. Kagi mixes result types and organic hits carry `t == 0`).
public struct SearchItemFilter: Codable, Sendable, Equatable {
    public var path: String
    public var equals: String

    public init(path: String, equals: String) {
        self.path = path
        self.equals = equals
    }
}

public struct SearchResponseMapping: Codable, Sendable, Equatable {
    /// Dot path to the results array (e.g. "web.results", "organic").
    /// Supports `|` fallbacks: "news.results|hits".
    public var resultsPath: String
    /// Field extraction paths applied to each item.
    public var item: SearchHitFieldPaths
    /// Optional per-item filter.
    public var filter: SearchItemFilter?

    public init(resultsPath: String, item: SearchHitFieldPaths, filter: SearchItemFilter? = nil) {
        self.resultsPath = resultsPath
        self.item = item
        self.filter = filter
    }
}

// MARK: - Definition: endpoint

/// One HTTP endpoint of a declarative provider, keyed by category in
/// `SearchProviderDefinition.endpoints`.
public struct SearchEndpoint: Codable, Sendable, Equatable {
    /// Absolute URL without query string (query params are declared in `query`).
    public var url: String
    /// "GET" or "POST".
    public var method: String
    /// Header templates (values support the same placeholders as params).
    public var headers: [String: String]
    /// Query-string parameters.
    public var query: [SearchRequestParam]
    /// JSON body parameters (POST only).
    public var body: [SearchRequestParam]
    /// Response -> normalized hits mapping.
    public var response: SearchResponseMapping
    /// Per-request timeout in seconds (default 15).
    public var timeout: Double?

    public init(
        url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        query: [SearchRequestParam] = [],
        body: [SearchRequestParam] = [],
        response: SearchResponseMapping,
        timeout: Double? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.query = query
        self.body = body
        self.response = response
        self.timeout = timeout
    }
}

// MARK: - Definition

/// How a provider executes: `declarative` runs through the generic REST
/// executor; `native` maps to hand-written Swift (HTML scrapers) by id.
public enum SearchProviderRuntime: String, Codable, Sendable {
    case declarative
    case native
}

/// Declarative description of one search provider. Bundled and custom
/// providers share this exact schema; custom ones are stored as JSON files
/// under `~/.osaurus/providers/search-definitions/`.
public struct SearchProviderDefinition: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var runtime: SearchProviderRuntime
    /// One-line plain-English pitch shown on the preset card.
    public var summary: String?
    /// Pricing in human terms ("Free: 1,000 searches/month").
    public var pricingNote: String?
    /// Numbered plain-language connect steps shown in the connect sheet.
    public var instructions: [String]?
    /// Where the user signs up / gets a key.
    public var signupURL: String?
    public var homepage: String?
    /// Sorted first in the preset gallery.
    public var recommended: Bool
    /// Last-resort providers run in the free race but never trigger the early
    /// exit, and their hits are used only when no other provider produced any.
    /// Set on scrapers known to degrade deceptively (DDG serves decoy results
    /// to clients its anti-bot layer has flagged).
    public var lastResort: Bool
    /// Secrets required for this provider to be usable. Empty/nil = keyless.
    public var secrets: [SearchSecretField]?
    /// Category -> endpoint (declarative runtime only).
    public var endpoints: [String: SearchEndpoint]?
    /// Explicit category list for native providers (declarative providers
    /// may omit this; categories derive from `endpoints` keys).
    public var categories: [String]?

    public init(
        id: String,
        name: String,
        runtime: SearchProviderRuntime = .declarative,
        summary: String? = nil,
        pricingNote: String? = nil,
        instructions: [String]? = nil,
        signupURL: String? = nil,
        homepage: String? = nil,
        recommended: Bool = false,
        lastResort: Bool = false,
        secrets: [SearchSecretField]? = nil,
        endpoints: [String: SearchEndpoint]? = nil,
        categories: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.runtime = runtime
        self.summary = summary
        self.pricingNote = pricingNote
        self.instructions = instructions
        self.signupURL = signupURL
        self.homepage = homepage
        self.recommended = recommended
        self.lastResort = lastResort
        self.secrets = secrets
        self.endpoints = endpoints
        self.categories = categories
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.runtime = try c.decodeIfPresent(SearchProviderRuntime.self, forKey: .runtime) ?? .declarative
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary)
        self.pricingNote = try c.decodeIfPresent(String.self, forKey: .pricingNote)
        self.instructions = try c.decodeIfPresent([String].self, forKey: .instructions)
        self.signupURL = try c.decodeIfPresent(String.self, forKey: .signupURL)
        self.homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
        self.recommended = try c.decodeIfPresent(Bool.self, forKey: .recommended) ?? false
        self.lastResort = try c.decodeIfPresent(Bool.self, forKey: .lastResort) ?? false
        self.secrets = try c.decodeIfPresent([SearchSecretField].self, forKey: .secrets)
        self.endpoints = try c.decodeIfPresent([String: SearchEndpoint].self, forKey: .endpoints)
        self.categories = try c.decodeIfPresent([String].self, forKey: .categories)
    }

    /// True when the provider needs no API key (free scrapers).
    public var isKeyless: Bool { (secrets ?? []).isEmpty }

    /// Categories this provider can serve, in stable display order.
    public var supportedCategories: [String] {
        let raw = categories ?? endpoints.map { Array($0.keys) } ?? []
        return raw.sorted {
            let (a, b) = (SearchCategory.sortIndex($0), SearchCategory.sortIndex($1))
            return a == b ? $0 < $1 : a < b
        }
    }

    public func supports(category: String) -> Bool {
        supportedCategories.contains(category)
    }

    /// All declared secrets have Keychain values.
    public func hasAllSecrets() -> Bool {
        for field in secrets ?? [] {
            let value = SearchProviderKeychain.getSecret(field: field.id, for: id)
            if value == nil || value?.isEmpty == true { return false }
        }
        return true
    }

    /// Resolved secret values keyed by field id (missing entries omitted).
    public func resolvedSecrets() -> [String: String] {
        var out: [String: String] = [:]
        for field in secrets ?? [] {
            if let value = SearchProviderKeychain.getSecret(field: field.id, for: id), !value.isEmpty {
                out[field.id] = value
            }
        }
        return out
    }
}

// MARK: - Provider instance

/// The user's enabled/disabled record for one definition. The order of the
/// `providers` array in `SearchProviderConfiguration` is the default fallback
/// ranking (first enabled + configured provider = primary).
public struct SearchProvider: Codable, Identifiable, Sendable, Equatable {
    public var definitionId: String
    public var enabled: Bool

    public var id: String { definitionId }

    public init(definitionId: String, enabled: Bool = true) {
        self.definitionId = definitionId
        self.enabled = enabled
    }
}

// MARK: - Configuration

public struct SearchProviderConfiguration: Codable, Sendable {
    /// Ordered provider list; order = default fallback ranking.
    public var providers: [SearchProvider]
    /// Per-category ranking overrides (category -> ordered definition ids).
    /// Categories without an entry use the default `providers` order.
    public var routing: [String: [String]]
    /// One-time migration marker: keys copied from the osaurus.search plugin.
    public var pluginKeysMigrated: Bool

    public init(
        providers: [SearchProvider] = [],
        routing: [String: [String]] = [:],
        pluginKeysMigrated: Bool = false
    ) {
        self.providers = providers
        self.routing = routing
        self.pluginKeysMigrated = pluginKeysMigrated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.providers = try c.decodeIfPresent([SearchProvider].self, forKey: .providers) ?? []
        self.routing = try c.decodeIfPresent([String: [String]].self, forKey: .routing) ?? [:]
        self.pluginKeysMigrated = try c.decodeIfPresent(Bool.self, forKey: .pluginKeysMigrated) ?? false
    }

    /// Default configuration: the three free scrapers enabled, so search
    /// works out of the box with zero setup.
    public static func makeDefault() -> SearchProviderConfiguration {
        SearchProviderConfiguration(
            providers: SearchProviderCatalog.freeProviderIds.map {
                SearchProvider(definitionId: $0, enabled: true)
            }
        )
    }

    public func provider(id: String) -> SearchProvider? {
        providers.first { $0.definitionId == id }
    }

    public mutating func add(_ provider: SearchProvider) {
        guard !providers.contains(where: { $0.definitionId == provider.definitionId }) else { return }
        providers.append(provider)
    }

    public mutating func remove(definitionId: String) {
        SearchProviderKeychain.deleteAllSecrets(for: definitionId)
        providers.removeAll { $0.definitionId == definitionId }
        for (category, order) in routing {
            routing[category] = order.filter { $0 != definitionId }
        }
    }

    public mutating func setEnabled(_ enabled: Bool, for definitionId: String) {
        if let index = providers.firstIndex(where: { $0.definitionId == definitionId }) {
            providers[index].enabled = enabled
        }
    }

    /// Ranked provider ids for a category: the per-category override when
    /// present (ids unknown to `providers` dropped, missing enabled providers
    /// appended so new additions are never silently unroutable), otherwise
    /// the default `providers` order.
    public func ranking(for category: String) -> [String] {
        let defaultOrder = providers.map { $0.definitionId }
        guard let override = routing[category], !override.isEmpty else { return defaultOrder }
        var seen = Set<String>()
        var out: [String] = []
        let known = Set(defaultOrder)
        for id in override where known.contains(id) && seen.insert(id).inserted {
            out.append(id)
        }
        for id in defaultOrder where seen.insert(id).inserted {
            out.append(id)
        }
        return out
    }
}

// MARK: - Store

/// Persistence for `SearchProviderConfiguration` at
/// `~/.osaurus/providers/search.json`.
@MainActor
public enum SearchProviderConfigurationStore {
    public static func load() -> SearchProviderConfiguration {
        let url = OsaurusPaths.searchProviderConfigFile()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                return try JSONDecoder().decode(SearchProviderConfiguration.self, from: Data(contentsOf: url))
            } catch {
                print("[Osaurus] Failed to load SearchProviderConfiguration: \(error)")
            }
        }
        // Never auto-save the default here (see MCPProviderConfigurationStore.load);
        // the manager persists on the first user mutation.
        return .makeDefault()
    }

    public static func save(_ configuration: SearchProviderConfiguration) {
        let url = OsaurusPaths.searchProviderConfigFile()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save SearchProviderConfiguration: \(error)")
        }
    }
}

// MARK: - Custom definition store

/// Persistence for user-created provider definitions:
/// `~/.osaurus/providers/search-definitions/<id>.json`. Bundled definitions
/// always win on id collision so a stale export can't shadow the catalog.
@MainActor
public enum SearchProviderDefinitionStore {
    public static func loadCustom() -> [SearchProviderDefinition] {
        let dir = OsaurusPaths.searchProviderDefinitionsDirectory()
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        let bundledIds = Set(SearchProviderCatalog.bundled.map { $0.id })
        var out: [SearchProviderDefinition] = []
        for entry in entries where entry.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: entry),
                let def = try? JSONDecoder().decode(SearchProviderDefinition.self, from: data)
            else { continue }
            if bundledIds.contains(def.id) { continue }
            out.append(def)
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func save(_ definition: SearchProviderDefinition) throws {
        let dir = OsaurusPaths.searchProviderDefinitionsDirectory()
        try OsaurusPaths.ensureExists(dir)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(definition)
        try data.write(to: fileURL(for: definition.id, in: dir), options: [.atomic])
    }

    public static func delete(definitionId: String) {
        let dir = OsaurusPaths.searchProviderDefinitionsDirectory()
        try? FileManager.default.removeItem(at: fileURL(for: definitionId, in: dir))
    }

    private static func fileURL(for definitionId: String, in dir: URL) -> URL {
        // Reuse the tool-name sanitiser: ids are user input and become filenames.
        let safe = ToolRegistry.sanitizeToolName(definitionId)
        return dir.appendingPathComponent("\(safe).json")
    }
}
