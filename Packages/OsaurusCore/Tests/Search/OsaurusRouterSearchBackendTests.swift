import Foundation
import Testing

@testable import OsaurusCore

@Suite("Osaurus router search backend", .serialized)
struct OsaurusRouterSearchBackendTests {

    // MARK: - Request mapping

    @Test func searchBody_mapsNativeRequestFields() {
        let request = SearchRequest(
            query: "capybara habitats",
            category: SearchCategory.news,
            maxResults: 10,
            offset: 0,
            site: "example.org",
            filetype: "pdf",
            timeRange: "w",
            region: "us-en"
        )
        let body = OsaurusRouterSearchBackend.searchBody(
            for: request, extractTextMaxCharacters: nil, idempotencyKey: "key-1")

        #expect(body.query == "capybara habitats")
        #expect(body.category == "news")
        #expect(body.num_results == 10)
        #expect(body.site == "example.org")
        #expect(body.file_type == "pdf")
        #expect(body.time_range == "w")
        #expect(body.region == "us-en")
        #expect(body.contents == nil)
        #expect(body.idempotency_key == "key-1")
    }

    @Test func searchBody_clampsResultCountToServerCap() {
        let request = SearchRequest(query: "q", maxResults: 50)
        let body = OsaurusRouterSearchBackend.searchBody(
            for: request, extractTextMaxCharacters: nil, idempotencyKey: "k")
        #expect(body.num_results == 25)
    }

    @Test func searchBody_requestsTextExtractionWhenAsked() {
        let request = SearchRequest(query: "q")
        let body = OsaurusRouterSearchBackend.searchBody(
            for: request, extractTextMaxCharacters: 9000, idempotencyKey: "k")
        #expect(body.contents?.text?.max_characters == 9000)
        #expect(body.contents?.highlights == true)
    }

    @Test func routerCategory_mapsKnownCategoriesAndOmitsWeb() {
        #expect(OsaurusRouterSearchBackend.routerCategory(for: SearchCategory.web) == nil)
        #expect(OsaurusRouterSearchBackend.routerCategory(for: SearchCategory.news) == "news")
        #expect(OsaurusRouterSearchBackend.routerCategory(for: "github") == "github")
        // Unknown custom categories degrade to general web instead of risking
        // a 400 round-trip.
        #expect(OsaurusRouterSearchBackend.routerCategory(for: "academic") == nil)
    }

    @Test func canonicalEncoding_producesStableSortedBytes() throws {
        let request = SearchRequest(query: "q", maxResults: 5, timeRange: "d")
        let body = OsaurusRouterSearchBackend.searchBody(
            for: request, extractTextMaxCharacters: nil, idempotencyKey: "stable-key")
        let first = try JSONEncoder.osaurusCanonical(prettyPrinted: false).encode(body)
        let second = try JSONEncoder.osaurusCanonical(prettyPrinted: false).encode(body)
        // Signed bytes must equal sent bytes; the canonical encoder guarantees
        // deterministic output for the same value.
        #expect(first == second)
        let text = try #require(String(data: first, encoding: .utf8))
        #expect(text.contains(#""idempotency_key":"stable-key""#))
        #expect(text.contains(#""num_results":5"#))
        // Nil optionals stay off the wire.
        #expect(!text.contains("category"))
        #expect(!text.contains("site"))
    }

    // MARK: - /v1/search wire behavior

    @Test func search_sendsSignedBodyAndDecodesHits() async throws {
        let backend = try makeBackend { request in
            #expect(request.url?.path == "/v1/search")
            #expect(request.httpMethod == "POST")
            let body = String(
                data: request.httpBodyStreamData ?? request.httpBody ?? Data(), encoding: .utf8) ?? ""
            #expect(body.contains(#""query":"capybara""#))
            #expect(body.contains(#""idempotency_key":"key-42""#))
            return json(
                """
                {"request_id":"key-42",
                 "results":[
                    {"title":"Capybara","url":"https://example.com/a","published_date":"2026-01-01",
                     "highlights":["semi-aquatic rodent"],"text":"full text here"},
                    {"title":"No URL result"}
                 ],
                 "warnings":["offset is not supported by hosted search and was ignored"],
                 "osaurus":{"request_id":"key-42","operation":"search","provider":"exa",
                            "billing":"free","cost_micro":"0",
                            "allowance":{"included_total":20,"used_total":3,"remaining_total":17},
                            "status":"completed"}}
                """
            )
        }

        let result = await backend.search(
            SearchRequest(query: "capybara"), idempotencyKey: "key-42")
        let outcome = try result.get()

        #expect(outcome.hits.count == 1)
        #expect(outcome.hits[0].title == "Capybara")
        #expect(outcome.hits[0].url == "https://example.com/a")
        #expect(outcome.hits[0].snippet == "semi-aquatic rodent")
        #expect(outcome.hits[0].engine == "osaurus_router")
        #expect(outcome.textByURL["https://example.com/a"] == "full text here")
        #expect(outcome.warnings.count == 1)
        #expect(outcome.replayed == false)

        let billing = try #require(outcome.billing)
        #expect(billing.isIncluded)
        #expect(billing.costMicro == "0")
        #expect(billing.allowanceRemaining == 17)
    }

    @Test func search_replayedResponseCarriesBillingWithoutResults() async throws {
        let backend = try makeBackend { _ in
            json(
                """
                {"request_id":"key-1","results":[],"replayed":true,
                 "osaurus":{"operation":"search","provider":"exa","billing":"paid",
                            "cost_micro":"2500","allowance":null,"status":"completed"}}
                """
            )
        }

        let outcome = try await backend.search(
            SearchRequest(query: "q"), idempotencyKey: "key-1"
        ).get()
        #expect(outcome.replayed)
        #expect(outcome.hits.isEmpty)
        #expect(outcome.billing?.costMicro == "2500")
        #expect(outcome.billing?.isIncluded == false)
    }

    @Test func search_snippetFallsBackToSummaryThenText() async throws {
        let backend = try makeBackend { _ in
            json(
                """
                {"results":[
                    {"title":"A","url":"https://a.example","summary":"the summary"},
                    {"title":"B","url":"https://b.example","text":"the text body"}
                ]}
                """
            )
        }
        let outcome = try await backend.search(
            SearchRequest(query: "q"), idempotencyKey: "k"
        ).get()
        #expect(outcome.hits[0].snippet == "the summary")
        #expect(outcome.hits[1].snippet == "the text body")
    }

    // MARK: - Fallback classification (spec section 5)

    @Test func search_classifiesInsufficientFunds() async throws {
        let backend = try makeBackend { _ in
            json(#"{"error":{"code":"INSUFFICIENT_FUNDS","message":"top up"}}"#, status: 402)
        }
        let result = await backend.search(SearchRequest(query: "q"), idempotencyKey: "k")
        #expect(failure(of: result) == .insufficientFunds)
    }

    @Test func search_classifiesPaidWebDisabled() async throws {
        let backend = try makeBackend { _ in
            json(#"{"error":{"code":"PAID_WEB_DISABLED","message":"auto-pay off"}}"#, status: 402)
        }
        let result = await backend.search(SearchRequest(query: "q"), idempotencyKey: "k")
        #expect(failure(of: result) == .paidWebDisabled)
    }

    @Test func search_classifiesIdempotencyConflict() async throws {
        let backend = try makeBackend { _ in
            json(#"{"error":{"code":"IDEMPOTENCY_CONFLICT","message":"key reuse"}}"#, status: 409)
        }
        let result = await backend.search(SearchRequest(query: "q"), idempotencyKey: "k")
        #expect(failure(of: result) == .idempotencyConflict)
    }

    @Test func search_classifiesInvalidRequest() async throws {
        let backend = try makeBackend { _ in
            json(#"{"error":{"code":"INVALID_REQUEST","message":"bad category"}}"#, status: 400)
        }
        let result = await backend.search(SearchRequest(query: "q"), idempotencyKey: "k")
        #expect(failure(of: result) == .invalidRequest)
    }

    @Test func search_classifiesProviderError() async throws {
        let backend = try makeBackend { _ in
            json(#"{"error":{"code":"PROVIDER_ERROR","message":"upstream died"}}"#, status: 502)
        }
        let result = await backend.search(SearchRequest(query: "q"), idempotencyKey: "k")
        #expect(failure(of: result) == .providerError)
    }

    @Test func search_featureOff404MarksAvailabilityBackoff() async throws {
        let availability = RouterWebSearchAvailability()
        let backend = try makeBackend(availability: availability) { _ in
            json(#"{"error":{"code":"NOT_FOUND","message":"not found"}}"#, status: 404)
        }
        #expect(availability.isAvailable)

        let result = await backend.search(SearchRequest(query: "q"), idempotencyKey: "k")
        #expect(failure(of: result) == .featureUnavailable)
        // The gate now skips hosted attempts instead of hammering the 404.
        #expect(!availability.isAvailable)
    }

    @Test func search_rateLimitHonorsRetryAfterForFutureCalls() async throws {
        let availability = RouterWebSearchAvailability()
        let backend = try makeBackend(availability: availability) { _ in
            (429, Data(#"{"error":{"code":"RATE_LIMITED","message":"slow down"}}"#.utf8),
             ["content-type": "application/json", "retry-after": "120"])
        }

        let result = await backend.search(SearchRequest(query: "q"), idempotencyKey: "k")
        #expect(failure(of: result) == .rateLimited)
        #expect(!availability.isAvailable)
    }

    @Test func search_successClearsAvailabilityBackoff() async throws {
        let availability = RouterWebSearchAvailability()
        availability.markFeatureUnavailable()
        #expect(!availability.isAvailable)

        let backend = try makeBackend(availability: availability) { _ in
            json(#"{"results":[]}"#)
        }
        _ = await backend.search(SearchRequest(query: "q"), idempotencyKey: "k")
        #expect(availability.isAvailable)
    }

    @Test func availability_expiresOnItsOwn() {
        let availability = RouterWebSearchAvailability()
        availability.markRateLimited(retryAfter: "1", now: Date(timeIntervalSinceNow: -10))
        // The backoff window is already in the past.
        #expect(availability.isAvailable)
    }

    // MARK: - /v1/contents

    @Test func contents_marksFailedURLsForLocalFallback() async throws {
        let backend = try makeBackend { request in
            #expect(request.url?.path == "/v1/contents")
            let body = String(
                data: request.httpBodyStreamData ?? request.httpBody ?? Data(), encoding: .utf8) ?? ""
            #expect(body.contains(#""urls":["https://a.example/x","https://b.example/y"]"#))
            return json(
                """
                {"results":[{"title":"A","url":"https://a.example/x","text":"page text"}],
                 "statuses":[
                    {"url":"https://a.example/x","status":"success","error":null},
                    {"url":"https://b.example/y","status":"error","error":"fetch_failed"}
                 ],
                 "osaurus":{"operation":"contents","provider":"exa","billing":"paid",
                            "cost_micro":"1200","allowance":null,"status":"completed"}}
                """
            )
        }

        let outcome = try await backend.contents(
            urls: ["https://a.example/x", "https://b.example/y"],
            idempotencyKey: "k"
        ).get()

        #expect(outcome.pages.count == 2)
        #expect(outcome.pages[0].succeeded)
        #expect(outcome.pages[0].text == "page text")
        #expect(outcome.pages[1].succeeded == false)
        #expect(outcome.pages[1].error == "fetch_failed")
        #expect(outcome.billing?.operation == "contents")
    }

    @Test func contents_replayedResponseNeedsFullLocalFallback() async throws {
        let backend = try makeBackend { _ in
            json(
                """
                {"results":[],"replayed":true,
                 "osaurus":{"operation":"contents","provider":"exa","billing":"free",
                            "cost_micro":"0","allowance":null,"status":"completed"}}
                """
            )
        }
        let outcome = try await backend.contents(
            urls: ["https://a.example"], idempotencyKey: "k"
        ).get()
        #expect(outcome.replayed)
        #expect(outcome.pages.allSatisfy { !$0.succeeded })
    }

    // MARK: - Premium default resolution

    @Test func premiumDefault_freeOnlySetupHasNoActiveUserProviders() {
        let config = SearchProviderConfiguration.makeDefault()
        let active = SearchProviderManager.hasActiveUserProviderSetup(
            configuration: config,
            customDefinitions: [],
            definitionFor: { SearchProviderCatalog.definition(id: $0) },
            hasSecrets: { _ in false }
        )
        #expect(!active)
    }

    @Test func premiumDefault_configuredAPIProviderCountsAsUserSetup() {
        var config = SearchProviderConfiguration.makeDefault()
        config.providers.insert(SearchProvider(definitionId: "tavily"), at: 0)
        let active = SearchProviderManager.hasActiveUserProviderSetup(
            configuration: config,
            customDefinitions: [],
            definitionFor: { SearchProviderCatalog.definition(id: $0) },
            hasSecrets: { $0.id == "tavily" }
        )
        #expect(active)
    }

    @Test func premiumDefault_unconfiguredAPIProviderDoesNotCount() {
        var config = SearchProviderConfiguration.makeDefault()
        config.providers.insert(SearchProvider(definitionId: "tavily"), at: 0)
        let active = SearchProviderManager.hasActiveUserProviderSetup(
            configuration: config,
            customDefinitions: [],
            definitionFor: { SearchProviderCatalog.definition(id: $0) },
            hasSecrets: { _ in false }
        )
        #expect(!active)
    }

    @Test func premiumDefault_disabledAPIProviderDoesNotCount() {
        var config = SearchProviderConfiguration.makeDefault()
        config.providers.insert(SearchProvider(definitionId: "tavily", enabled: false), at: 0)
        let active = SearchProviderManager.hasActiveUserProviderSetup(
            configuration: config,
            customDefinitions: [],
            definitionFor: { SearchProviderCatalog.definition(id: $0) },
            hasSecrets: { _ in true }
        )
        #expect(!active)
    }

    @Test func premiumDefault_customDefinitionCountsEvenWhenKeyless() {
        let custom = SearchProviderDefinition(
            id: "my_searx",
            name: "My SearXNG",
            endpoints: [:]
        )
        var config = SearchProviderConfiguration.makeDefault()
        config.providers.insert(SearchProvider(definitionId: "my_searx"), at: 0)
        let active = SearchProviderManager.hasActiveUserProviderSetup(
            configuration: config,
            customDefinitions: [custom],
            definitionFor: { id in
                id == "my_searx" ? custom : SearchProviderCatalog.definition(id: id)
            },
            hasSecrets: { _ in false }
        )
        #expect(active)
    }

    // MARK: - Hosted gate

    @Test func hostedGate_excludesImageAndVideoCategories() {
        func gate(_ category: String) -> Bool {
            SearchProviderManager.shouldTryHostedSearch(
                category: category,
                hostedSearchEnabled: true,
                routerEnabled: true,
                identityExists: true,
                hostedAvailable: true
            )
        }
        #expect(gate(SearchCategory.web))
        #expect(gate(SearchCategory.news))
        #expect(gate("github"))
        #expect(!gate(SearchCategory.images))
        #expect(!gate("videos"))
        #expect(!gate("video"))
    }

    @Test func hostedGate_requiresEveryPrecondition() {
        func gate(
            enabled: Bool = true,
            router: Bool = true,
            identity: Bool = true,
            available: Bool = true
        ) -> Bool {
            SearchProviderManager.shouldTryHostedSearch(
                category: SearchCategory.web,
                hostedSearchEnabled: enabled,
                routerEnabled: router,
                identityExists: identity,
                hostedAvailable: available
            )
        }
        #expect(gate())
        #expect(!gate(enabled: false))
        #expect(!gate(router: false))
        #expect(!gate(identity: false))
        #expect(!gate(available: false))
    }

    // MARK: - Source classification

    @Test func sourceClassification_distinguishesPremiumCustomAndFree() {
        let custom = SearchProviderDefinition(id: "my_searx", name: "My SearXNG")
        func classify(_ id: String?) -> WebSearchSource {
            SearchProviderManager.classifySource(
                providerId: id,
                customDefinitionIds: ["my_searx"],
                definitionFor: { lookup in
                    lookup == "my_searx" ? custom : SearchProviderCatalog.definition(id: lookup)
                }
            )
        }
        #expect(classify("osaurus_router") == .premium)
        // Keyed bundled providers are the user's own API setup.
        #expect(classify("tavily") == .custom)
        // Custom definitions are custom even when keyless.
        #expect(classify("my_searx") == .custom)
        // Bundled keyless scrapers are the free tier.
        #expect(classify("brave_html") == .free)
        #expect(classify("ddg") == .free)
        #expect(classify(nil) == .free)
        #expect(classify("unknown_id") == .free)
    }

    // MARK: - Structured-data URL gate

    @Test func structuredDataURLsStayLocal() {
        #expect(SearchAndExtractTool.looksLikeStructuredData("https://x.example/data.csv"))
        #expect(SearchAndExtractTool.looksLikeStructuredData("https://x.example/api/rows.json"))
        #expect(SearchAndExtractTool.looksLikeStructuredData("https://x.example/t.tsv"))
        #expect(!SearchAndExtractTool.looksLikeStructuredData("https://x.example/article"))
        #expect(!SearchAndExtractTool.looksLikeStructuredData("https://x.example/post.html"))
    }

    // MARK: - Helpers

    private func failure(
        of result: Result<HostedSearchOutcome, HostedSearchFailure>
    ) -> HostedSearchFailure? {
        if case .failure(let failure) = result { return failure }
        return nil
    }

    private func makeBackend(
        availability: RouterWebSearchAvailability = RouterWebSearchAvailability(),
        handler: @escaping @Sendable (URLRequest) throws -> (Int, Data, [String: String])
    ) throws -> OsaurusRouterSearchBackend {
        SearchRouterURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SearchRouterURLProtocol.self]
        let session = URLSession(configuration: config)
        let baseURL = try #require(URL(string: "https://router.test"))
        let client = OsaurusRouterAPIClient(
            baseURL: baseURL,
            session: session,
            authOverride: { request, _ in
                request.setValue("0xabc", forHTTPHeaderField: "x-wallet-address")
            }
        )
        return OsaurusRouterSearchBackend(client: client, availability: availability)
    }

    private func json(_ body: String, status: Int = 200) -> (Int, Data, [String: String]) {
        (status, Data(body.utf8), ["content-type": "application/json"])
    }
}

private final class SearchRouterURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler:
        (@Sendable (URLRequest) throws -> (Int, Data, [String: String]))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data, headers) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    var httpBodyStreamData: Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
