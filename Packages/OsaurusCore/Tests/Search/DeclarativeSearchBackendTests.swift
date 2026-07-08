//
//  DeclarativeSearchBackendTests.swift
//  OsaurusCoreTests
//
//  Fixture tests for the generic REST executor. Each bundled definition must
//  build the correct request (URL, auth placement, param maps, clamps) and
//  parse a canned response into normalized hits — validating both the
//  executor and the declarative definition format itself, in place of
//  per-provider unit tests.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct DeclarativeSearchBackendTests {

    private static func webEndpoint(_ id: String) -> SearchEndpoint {
        SearchProviderCatalog.definition(id: id)!.endpoints![SearchCategory.web]!
    }

    private static func newsEndpoint(_ id: String) -> SearchEndpoint {
        SearchProviderCatalog.definition(id: id)!.endpoints![SearchCategory.news]!
    }

    private static func bodyJSON(_ built: DeclarativeSearchBackend.BuiltRequest) throws -> [String: Any] {
        let data = try #require(built.body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Request building per bundled definition

    @Test func tavilyBuildsPOSTBodyWithMappedTimeRange() throws {
        let request = SearchRequest(query: "swift", maxResults: 5, timeRange: "w")
        let built = try DeclarativeSearchBackend.buildRequest(
            endpoint: Self.webEndpoint("tavily"),
            request: request,
            secrets: ["api_key": "tvly-test"],
            providerName: "Tavily"
        )
        #expect(built.url == "https://api.tavily.com/search")
        #expect(built.headers["Content-Type"] == "application/json")
        let body = try Self.bodyJSON(built)
        #expect(body["api_key"] as? String == "tvly-test")
        #expect(body["query"] as? String == "swift")
        #expect(body["max_results"] as? Int == 5)
        #expect(body["search_depth"] as? String == "basic")
        #expect(body["topic"] as? String == "general")
        #expect(body["time_range"] as? String == "week")
    }

    @Test func tavilyOmitsTimeRangeWhenUnset() throws {
        let built = try DeclarativeSearchBackend.buildRequest(
            endpoint: Self.webEndpoint("tavily"),
            request: SearchRequest(query: "swift"),
            secrets: ["api_key": "tvly-test"],
            providerName: "Tavily"
        )
        let body = try Self.bodyJSON(built)
        #expect(body["time_range"] == nil)
    }

    @Test func braveSendsHeaderTokenAndMappedFreshness() throws {
        let request = SearchRequest(query: "swift", maxResults: 8, offset: 2, timeRange: "w")
        let built = try DeclarativeSearchBackend.buildRequest(
            endpoint: Self.webEndpoint("brave_api"),
            request: request,
            secrets: ["api_key": "brave-key"],
            providerName: "Brave"
        )
        #expect(built.headers["X-Subscription-Token"] == "brave-key")
        #expect(built.url.hasPrefix("https://api.search.brave.com/res/v1/web/search?"))
        #expect(built.url.contains("q=swift"))
        #expect(built.url.contains("count=8"))
        #expect(built.url.contains("offset=2"))
        #expect(built.url.contains("freshness=pw"))
        #expect(built.body == nil)
    }

    @Test func serperComputesPageFromOffset() throws {
        let request = SearchRequest(query: "swift", maxResults: 10, offset: 20, timeRange: "m")
        let built = try DeclarativeSearchBackend.buildRequest(
            endpoint: Self.webEndpoint("serper"),
            request: request,
            secrets: ["api_key": "serper-key"],
            providerName: "Serper"
        )
        #expect(built.headers["X-API-KEY"] == "serper-key")
        let body = try Self.bodyJSON(built)
        #expect(body["num"] as? Int == 10)
        #expect(body["page"] as? Int == 3)
        #expect(body["tbs"] as? String == "qdr:m")
    }

    @Test func googleCSEClampsNumAndUsesOneBasedStart() throws {
        let request = SearchRequest(query: "swift", maxResults: 25, offset: 10)
        let built = try DeclarativeSearchBackend.buildRequest(
            endpoint: Self.webEndpoint("google_cse"),
            request: request,
            secrets: ["api_key": "g-key", "cx": "engine-id"],
            providerName: "Google CSE"
        )
        #expect(built.url.contains("key=g-key"))
        #expect(built.url.contains("cx=engine-id"))
        #expect(built.url.contains("num=10"), "Google CSE caps num at 10")
        #expect(built.url.contains("start=11"), "start is 1-based offset")
    }

    @Test func kagiUsesBotAuthorizationHeader() throws {
        let built = try DeclarativeSearchBackend.buildRequest(
            endpoint: Self.webEndpoint("kagi"),
            request: SearchRequest(query: "swift"),
            secrets: ["api_key": "kagi-token"],
            providerName: "Kagi"
        )
        #expect(built.headers["Authorization"] == "Bot kagi-token")
        #expect(built.url.contains("q=swift"))
    }

    @Test func siteAndFiletypeAugmentTheQuery() throws {
        let request = SearchRequest(query: "swift", site: "arxiv.org", filetype: "pdf")
        let built = try DeclarativeSearchBackend.buildRequest(
            endpoint: Self.webEndpoint("kagi"),
            request: request,
            secrets: ["api_key": "kagi-token"],
            providerName: "Kagi"
        )
        let encoded = SearchHTML.urlEncode("swift site:arxiv.org filetype:pdf")
        #expect(built.url.contains("q=\(encoded)"))
    }

    @Test func unresolvedSecretPlaceholderBecomesEmpty() {
        let out = DeclarativeSearchBackend.substitute(
            "Bearer {{secret.missing}}",
            request: SearchRequest(query: "q"),
            secrets: [:]
        )
        #expect(out == "Bearer ")
    }

    @Test func exaBuildsNestedContentsAndAbsoluteStartDate() throws {
        let request = SearchRequest(query: "swift concurrency", maxResults: 7, timeRange: "w")
        let built = try DeclarativeSearchBackend.buildRequest(
            endpoint: Self.webEndpoint("exa"),
            request: request,
            secrets: ["api_key": "exa-key"],
            providerName: "Exa"
        )
        #expect(built.url == "https://api.exa.ai/search")
        #expect(built.headers["x-api-key"] == "exa-key")
        let body = try Self.bodyJSON(built)
        #expect(body["query"] as? String == "swift concurrency")
        #expect(body["type"] as? String == "auto")
        #expect(body["numResults"] as? Int == 7)
        // `contents` is a "json"-typed param: a real nested object, not a string.
        let contents = try #require(body["contents"] as? [String: Any])
        #expect(contents["highlights"] as? Bool == true)
        // "w" becomes an absolute yyyy-MM-dd date one week back.
        let startDate = try #require(body["startPublishedDate"] as? String)
        #expect(startDate.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil)
        #expect(startDate == DeclarativeSearchBackend.afterDate(for: "w"))
    }

    @Test func exaOmitsStartDateWhenNoTimeRange() throws {
        let built = try DeclarativeSearchBackend.buildRequest(
            endpoint: Self.webEndpoint("exa"),
            request: SearchRequest(query: "swift"),
            secrets: ["api_key": "exa-key"],
            providerName: "Exa"
        )
        let body = try Self.bodyJSON(built)
        #expect(body["startPublishedDate"] == nil)
    }

    @Test func exaNewsEndpointSetsCategory() throws {
        let built = try DeclarativeSearchBackend.buildRequest(
            endpoint: Self.newsEndpoint("exa"),
            request: SearchRequest(query: "swift", category: "news"),
            secrets: ["api_key": "exa-key"],
            providerName: "Exa"
        )
        let body = try Self.bodyJSON(built)
        #expect(body["category"] as? String == "news")
    }

    @Test func afterDateComputesCanonicalRanges() {
        let now = ISO8601DateFormatter().date(from: "2026-07-08T12:00:00Z")!
        #expect(DeclarativeSearchBackend.afterDate(for: "d", now: now) == "2026-07-07")
        #expect(DeclarativeSearchBackend.afterDate(for: "w", now: now) == "2026-07-01")
        #expect(DeclarativeSearchBackend.afterDate(for: "m", now: now) == "2026-06-08")
        #expect(DeclarativeSearchBackend.afterDate(for: "y", now: now) == "2025-07-08")
        #expect(DeclarativeSearchBackend.afterDate(for: nil, now: now) == "")
        #expect(DeclarativeSearchBackend.afterDate(for: "bogus", now: now) == "")
    }

    @Test func parallelWrapsQueryInRequiredStringArray() throws {
        let request = SearchRequest(query: "swift concurrency", maxResults: 10, site: "swift.org")
        let built = try DeclarativeSearchBackend.buildRequest(
            endpoint: Self.webEndpoint("parallel"),
            request: request,
            secrets: ["api_key": "parallel-key"],
            providerName: "Parallel"
        )
        #expect(built.url == "https://api.parallel.ai/v1/search")
        #expect(built.headers["x-api-key"] == "parallel-key")
        let body = try Self.bodyJSON(built)
        // `search_queries` must be a JSON array (Parallel rejects strings);
        // it carries the augmented query, `objective` the raw one.
        let queries = try #require(body["search_queries"] as? [String])
        #expect(queries == ["swift concurrency site:swift.org"])
        #expect(body["objective"] as? String == "swift concurrency")
        #expect(body["mode"] as? String == "basic")
    }

    // MARK: - Response mapping per bundled definition

    @Test func braveWebResponseMapsNestedResultsPath() throws {
        let fixture: [String: Any] = [
            "web": [
                "results": [
                    [
                        "title": "Swift.org",
                        "url": "https://swift.org",
                        "description": "The Swift language",
                        "page_age": "2024-01-01",
                    ],
                    ["title": "No URL item"],
                ]
            ]
        ]
        let hits = DeclarativeSearchBackend.mapResponse(
            fixture,
            mapping: Self.webEndpoint("brave_api").response,
            engine: "brave_api",
            maxResults: 10
        )
        #expect(hits.count == 2)
        #expect(hits[0].title == "Swift.org")
        #expect(hits[0].url == "https://swift.org")
        #expect(hits[0].snippet == "The Swift language")
        #expect(hits[0].publishedDate == "2024-01-01")
        #expect(hits[0].engine == "brave_api")
    }

    @Test func kagiResponseFiltersToOrganicResults() throws {
        let fixture: [String: Any] = [
            "data": [
                ["t": 0, "title": "Organic", "url": "https://a.example", "snippet": "s"],
                ["t": 1, "title": "Related searches", "url": "", "snippet": ""],
                ["t": 0, "title": "Organic 2", "url": "https://b.example", "snippet": "s2"],
            ]
        ]
        let hits = DeclarativeSearchBackend.mapResponse(
            fixture,
            mapping: Self.webEndpoint("kagi").response,
            engine: "kagi",
            maxResults: 10
        )
        #expect(hits.map(\.title) == ["Organic", "Organic 2"])
    }

    @Test func youResponseUsesFallbackFieldPaths() throws {
        let fixture: [String: Any] = [
            "hits": [
                // First item has `description`, second only `snippet` — the
                // "description|snippet" fallback must catch both.
                ["title": "A", "url": "https://a.example", "description": "desc"],
                ["title": "B", "url": "https://b.example", "snippet": "snip"],
            ]
        ]
        let hits = DeclarativeSearchBackend.mapResponse(
            fixture,
            mapping: Self.webEndpoint("you").response,
            engine: "you",
            maxResults: 10
        )
        #expect(hits.map(\.snippet) == ["desc", "snip"])
    }

    @Test func serperNewsResponseParsesSourceDomain() throws {
        let fixture: [String: Any] = [
            "news": [
                [
                    "title": "Headline",
                    "link": "https://news.example/story",
                    "snippet": "s",
                    "date": "2 hours ago",
                    "source": "Example News",
                ]
            ]
        ]
        let hits = DeclarativeSearchBackend.mapResponse(
            fixture,
            mapping: Self.newsEndpoint("serper").response,
            engine: "serper",
            maxResults: 10
        )
        #expect(hits.count == 1)
        #expect(hits[0].url == "https://news.example/story")
        #expect(hits[0].sourceDomain == "Example News")
        #expect(hits[0].publishedDate == "2 hours ago")
    }

    @Test func serperImagesBuildsSameBodyAndMapsImageFields() throws {
        let endpoint = try #require(
            SearchProviderCatalog.definition(id: "serper")?.endpoints?[SearchCategory.images])

        let built = try DeclarativeSearchBackend.buildRequest(
            endpoint: endpoint,
            request: SearchRequest(query: "dinosaur", category: SearchCategory.images, maxResults: 12),
            secrets: ["api_key": "serper-key"],
            providerName: "Serper"
        )
        #expect(built.url == "https://google.serper.dev/images")
        #expect(built.headers["X-API-KEY"] == "serper-key")
        let body = try Self.bodyJSON(built)
        #expect(body["q"] as? String == "dinosaur")
        #expect(body["num"] as? Int == 12)

        let fixture: [String: Any] = [
            "images": [
                [
                    "title": "A T-Rex",
                    "link": "https://dino.example/trex",
                    "imageUrl": "https://dino.example/trex-full.jpg",
                    "thumbnailUrl": "https://dino.example/trex-thumb.jpg",
                    "domain": "dino.example",
                    "source": "Dino Museum",
                ]
            ]
        ]
        let hits = DeclarativeSearchBackend.mapResponse(
            fixture,
            mapping: endpoint.response,
            engine: "serper",
            maxResults: 10
        )
        #expect(hits.count == 1)
        #expect(hits[0].title == "A T-Rex")
        #expect(hits[0].url == "https://dino.example/trex")
        #expect(hits[0].imageURL == "https://dino.example/trex-full.jpg")
        #expect(hits[0].thumbnailURL == "https://dino.example/trex-thumb.jpg")
        #expect(hits[0].sourceDomain == "dino.example")
    }

    @Test func mapResponseTruncatesToMaxResults() {
        let fixture: [String: Any] = [
            "results": (1...10).map {
                ["title": "T\($0)", "url": "https://example.com/\($0)", "content": "c"]
            }
        ]
        let hits = DeclarativeSearchBackend.mapResponse(
            fixture,
            mapping: Self.webEndpoint("tavily").response,
            engine: "tavily",
            maxResults: 3
        )
        #expect(hits.count == 3)
    }

    @Test func mapResponseReturnsEmptyForUnexpectedShape() {
        let hits = DeclarativeSearchBackend.mapResponse(
            ["results": "not an array"],
            mapping: Self.webEndpoint("tavily").response,
            engine: "tavily",
            maxResults: 10
        )
        #expect(hits.isEmpty)
    }

    @Test func exaResponseJoinsHighlightArraysIntoSnippet() throws {
        let fixture: [String: Any] = [
            "results": [
                [
                    "title": "Swift Concurrency",
                    "url": "https://swift.org/concurrency",
                    "highlights": ["First highlight.", "Second highlight."],
                    "publishedDate": "2026-01-15T00:00:00.000Z",
                ],
                [
                    // No highlights: the `highlights|text|summary` fallback
                    // lands on `text`.
                    "title": "Fallback",
                    "url": "https://b.example",
                    "text": "Full text body",
                ],
            ]
        ]
        let hits = DeclarativeSearchBackend.mapResponse(
            fixture,
            mapping: Self.webEndpoint("exa").response,
            engine: "exa",
            maxResults: 10
        )
        #expect(hits.count == 2)
        #expect(hits[0].snippet == "First highlight. … Second highlight.")
        #expect(hits[0].publishedDate == "2026-01-15T00:00:00.000Z")
        #expect(hits[1].snippet == "Full text body")
    }

    @Test func parallelResponseJoinsExcerptArraysIntoSnippet() throws {
        let fixture: [String: Any] = [
            "results": [
                [
                    "title": "Swift.org",
                    "url": "https://swift.org",
                    "excerpts": ["Excerpt one.", "Excerpt two."],
                    "publish_date": "2026-02-01",
                ]
            ]
        ]
        let hits = DeclarativeSearchBackend.mapResponse(
            fixture,
            mapping: Self.webEndpoint("parallel").response,
            engine: "parallel",
            maxResults: 10
        )
        #expect(hits.count == 1)
        #expect(hits[0].snippet == "Excerpt one. … Excerpt two.")
        #expect(hits[0].publishedDate == "2026-02-01")
    }
}
