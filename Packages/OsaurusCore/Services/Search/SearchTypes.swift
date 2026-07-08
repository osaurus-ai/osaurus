//
//  SearchTypes.swift
//  osaurus
//
//  Shared request/result types for the native search stack.
//

import Foundation

// MARK: - Request

/// Normalized search request handed to backends. Argument sanitization
/// (clamping, canonicalizing time ranges, unknown-category fallback) happens
/// in the tool layer, so backends can trust these values.
public struct SearchRequest: Sendable {
    public var query: String
    public var category: String
    public var maxResults: Int
    public var offset: Int
    public var site: String?
    public var filetype: String?
    /// Canonical recency filter: "d" | "w" | "m" | "y" or nil.
    public var timeRange: String?
    /// Region code in "xx-yy" form (e.g. "us-en") or nil.
    public var region: String?

    public init(
        query: String,
        category: String = SearchCategory.web,
        maxResults: Int = 10,
        offset: Int = 0,
        site: String? = nil,
        filetype: String? = nil,
        timeRange: String? = nil,
        region: String? = nil
    ) {
        self.query = query
        self.category = category
        self.maxResults = maxResults
        self.offset = offset
        self.site = site
        self.filetype = filetype
        self.timeRange = timeRange
        self.region = region
    }

    /// Query with site:/filetype: operators appended.
    public var augmentedQuery: String {
        var q = query
        if let site, !site.isEmpty { q += " site:\(site)" }
        if let filetype, !filetype.isEmpty { q += " filetype:\(filetype)" }
        return q
    }
}

// MARK: - Result

/// One normalized search result. Image hits populate the image fields;
/// web/news hits leave them nil.
public struct SearchHit: Sendable, Equatable {
    public var title: String
    public var url: String
    public var snippet: String
    public var publishedDate: String?
    public var sourceDomain: String?
    /// Definition id of the backend that produced this hit.
    public var engine: String
    public var imageURL: String?
    public var thumbnailURL: String?
    public var width: Int?
    public var height: Int?

    public init(
        title: String,
        url: String,
        snippet: String,
        publishedDate: String? = nil,
        sourceDomain: String? = nil,
        engine: String,
        imageURL: String? = nil,
        thumbnailURL: String? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.publishedDate = publishedDate
        self.sourceDomain = sourceDomain
        self.engine = engine
        self.imageURL = imageURL
        self.thumbnailURL = thumbnailURL
        self.width = width
        self.height = height
    }

    public func toDict(rank: Int) -> [String: Any] {
        var d: [String: Any] = [
            "rank": rank,
            "title": title,
            "url": url,
            "snippet": snippet,
            "engine": engine,
        ]
        if let publishedDate { d["published_date"] = publishedDate }
        if let domain = sourceDomain ?? SearchHTML.sourceDomain(of: url) {
            d["source_domain"] = domain
        }
        if let imageURL { d["image_url"] = imageURL }
        if let thumbnailURL { d["thumbnail_url"] = thumbnailURL }
        if let width { d["width"] = width }
        if let height { d["height"] = height }
        return d
    }
}

// MARK: - Errors / attempts

public struct SearchBackendError: Error, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Diagnostic record of one provider attempt in a cascade run.
public struct SearchAttempt: Sendable, Equatable {
    public var provider: String
    public var ok: Bool
    public var count: Int
    public var error: String?

    public init(provider: String, ok: Bool, count: Int = 0, error: String? = nil) {
        self.provider = provider
        self.ok = ok
        self.count = count
        self.error = error
    }

    public func toDict() -> [String: Any] {
        var d: [String: Any] = ["provider": provider, "ok": ok]
        if ok { d["count"] = count }
        if let error { d["error"] = error }
        return d
    }
}

// MARK: - Backend protocol

/// One executable search backend (declarative REST executor or a native
/// scraper). Implementations must be cancellation-friendly: they use
/// `URLSession` async APIs which propagate task cancellation.
public protocol SearchBackend: Sendable {
    /// Matches the owning `SearchProviderDefinition.id`.
    var definitionId: String { get }
    func search(_ request: SearchRequest) async throws -> [SearchHit]
}

// MARK: - HTTP

/// Minimal async HTTP helper shared by search backends. Rotates browser
/// user agents for the scraper backends (APIs override with their own headers).
enum SearchHTTPClient {
    static let userAgents = [
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0",
    ]

    static func request(
        url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 8
    ) async throws -> (status: Int, data: Data) {
        guard let u = URL(string: url) else { throw SearchBackendError("Invalid URL: \(url)") }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        req.httpBody = body

        var combined: [String: String] = [
            "User-Agent": userAgents.randomElement() ?? userAgents[0],
            "Accept-Language": "en-US,en;q=0.9",
        ]
        for (k, v) in headers { combined[k] = v }
        for (k, v) in combined { req.setValue(v, forHTTPHeaderField: k) }

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status, data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SearchBackendError(error.localizedDescription)
        }
    }
}

// MARK: - JSON path helpers

/// Dot-path lookup with `|` fallback alternatives, shared by the declarative
/// backend's response mapping ("web.results", "description|snippet").
enum SearchJSONPath {
    /// Resolve a single dot path against a JSON object tree.
    static func value(at path: String, in object: Any) -> Any? {
        var current: Any = object
        for segment in path.split(separator: ".") {
            guard let dict = current as? [String: Any], let next = dict[String(segment)] else {
                return nil
            }
            current = next
        }
        return current
    }

    /// Resolve the first `|`-alternative that yields a value.
    static func firstValue(at alternatives: String, in object: Any) -> Any? {
        for path in alternatives.split(separator: "|") {
            if let v = value(at: String(path), in: object), !(v is NSNull) {
                return v
            }
        }
        return nil
    }

    /// String extraction with number tolerance (some APIs return dates or
    /// ids as numbers) and string-array joining (Exa `highlights` and
    /// Parallel `excerpts` return snippet material as arrays of strings).
    static func string(at alternatives: String, in object: Any) -> String? {
        guard let v = firstValue(at: alternatives, in: object) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let arr = v as? [String] {
            let joined = arr.filter { !$0.isEmpty }.joined(separator: " … ")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }
}
