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

public enum SearchFailureKind: String, Sendable, Equatable {
    case success
    case empty
    case challenge
    case providerHTTP = "provider_http"
    case providerAuth = "provider_auth"
    case network
    case timeout
    case cancelled
    case didNotComplete = "did_not_complete"
    case unsupportedCategory = "unsupported_category"
    case extractionFailed = "extraction_failed"
    case blockedURL = "blocked_url"
}

public struct SearchBackendError: Error, Sendable, Equatable {
    public let message: String
    public let kind: SearchFailureKind

    public init(_ message: String, kind: SearchFailureKind? = nil) {
        self.message = SearchDiagnostics.redact(message)
        self.kind = kind ?? SearchDiagnostics.classifyFailure(message)
    }
}

/// Diagnostic record of one provider attempt in a cascade run.
public struct SearchAttempt: Sendable, Equatable {
    public var provider: String
    public var ok: Bool
    public var count: Int
    public var kind: SearchFailureKind
    public var error: String?

    public init(
        provider: String,
        ok: Bool,
        count: Int = 0,
        kind: SearchFailureKind? = nil,
        error: String? = nil
    ) {
        self.provider = provider
        self.ok = ok
        self.count = count
        self.kind = kind ?? SearchDiagnostics.kind(ok: ok, count: count, error: error)
        self.error = error.map(SearchDiagnostics.redact)
    }

    public func toDict() -> [String: Any] {
        var d: [String: Any] = ["provider": provider, "ok": ok, "kind": kind.rawValue]
        if ok { d["count"] = count }
        if let error { d["error"] = error }
        return d
    }
}

enum SearchDiagnostics {
    static func kind(ok: Bool, count: Int, error: String?) -> SearchFailureKind {
        if ok { return count > 0 ? .success : .empty }
        return classifyFailure(error ?? "")
    }

    static func classifyFailure(_ message: String) -> SearchFailureKind {
        let m = message.lowercased()
        if m.contains("did_not_complete") { return .didNotComplete }
        if m.contains("cancel") { return .cancelled }
        if m.contains("timed out") || m.contains("timeout") { return .timeout }
        if m.contains("challenge") || m.contains("captcha") || m.contains("just a moment")
            || m.contains("checking your browser") || m.contains("anomaly") {
            return .challenge
        }
        if m.contains("empty response") || m == "empty" { return .empty }
        if m.contains("does not support") { return .unsupportedCategory }
        if m.contains("blocked") || m.contains("ssrf") || m.contains("private")
            || m.contains("loopback") || m.contains("link-local") || m.contains("metadata") {
            return .blockedURL
        }
        if m.contains("401") || m.contains("403") || m.contains("unauthorized")
            || m.contains("forbidden") || m.contains("api key") || m.contains("auth")
            || m.contains("not configured") {
            return .providerAuth
        }
        if m.contains("timedout") { return .timeout }
        if m.contains("offline") || m.contains("cannot connect") || m.contains("could not connect")
            || m.contains("not connected") || m.contains("dns") || m.contains("host")
            || m.contains("connection") {
            return .network
        }
        return .providerHTTP
    }

    static func redact(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        var output = redactURLs(in: input)
        output = replace(
            output,
            pattern: #"(?i)\b(authorization|x-api-key|x-subscription-token|api-key)\s*[:=]\s*(bearer|bot|token)?\s*[A-Za-z0-9._~+/=-]{4,}"#,
            template: "$1: [REDACTED]"
        )
        output = replace(
            output,
            pattern: #"(?i)\b(bearer|bot|token)\s+[A-Za-z0-9._~+/=-]{6,}"#,
            template: "$1 [REDACTED]"
        )
        output = replace(
            output,
            pattern: #"(?i)\b(key|api_key|cx|client_secret|access_token|token|password|secret)=([^&\s]+)"#,
            template: "$1=[REDACTED]"
        )
        output = replace(
            output,
            pattern: #"\b(tvly-[A-Za-z0-9._-]+|sk-[A-Za-z0-9._-]+|AIza[A-Za-z0-9._-]+)\b"#,
            template: "[REDACTED]"
        )
        output = replace(
            output,
            pattern: #"\b[A-Za-z0-9_-]{32,}\b"#,
            template: "[REDACTED]"
        )
        return output
    }

    static func truncate(_ text: String, maxCharacters: Int) -> (text: String, truncated: Bool) {
        guard text.count > maxCharacters else { return (text, false) }
        let end = text.index(text.startIndex, offsetBy: maxCharacters)
        return (String(text[..<end]), true)
    }

    private static func redactURLs(in input: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"')\]]+"#) else {
            return input
        }
        let nsInput = input as NSString
        let result = NSMutableString(string: input)
        let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed()
        for match in matches {
            let raw = nsInput.substring(with: match.range)
            let redacted = redactURL(raw)
            result.replaceCharacters(in: match.range, with: redacted)
        }
        return result as String
    }

    private static func redactURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw), components.queryItems?.isEmpty == false else {
            return raw
        }
        components.queryItems = components.queryItems?.map {
            URLQueryItem(name: $0.name, value: "[REDACTED]")
        }
        return components.string ?? raw
    }

    private static func replace(_ input: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        return regex.stringByReplacingMatches(
            in: input,
            range: NSRange(input.startIndex..., in: input),
            withTemplate: template
        )
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
        guard let u = URL(string: url) else {
            throw SearchBackendError("Invalid URL: \(url)", kind: .network)
        }
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
        } catch let error as URLError {
            let kind: SearchFailureKind = {
                switch error.code {
                case .timedOut: return .timeout
                case .cancelled: return .cancelled
                default: return .network
                }
            }()
            throw SearchBackendError(error.localizedDescription, kind: kind)
        } catch {
            throw SearchBackendError(error.localizedDescription, kind: .network)
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
