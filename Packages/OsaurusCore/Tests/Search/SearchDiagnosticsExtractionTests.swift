//
//  SearchDiagnosticsExtractionTests.swift
//  OsaurusCoreTests
//
//  Offline fixtures for native search diagnostics and extraction hardening:
//  structured failure kinds, redacted attempt payloads, success-envelope
//  compactness, typed extraction statuses, bounded markdown, and SSRF guards.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SearchDiagnosticsExtractionTests {

    @Test func searchAttemptClassifiesAndRedactsProviderSecrets() {
        let attempt = SearchAttempt(
            provider: "google_cse",
            ok: false,
            error:
                "Authorization: Bot secret-token-12345 failed at "
                + "https://www.googleapis.com/customsearch/v1?key=g-key&cx=engine-id&q=swift "
                + "with tvly-secret"
        )
        let dict = attempt.toDict()

        #expect(dict["kind"] as? String == SearchFailureKind.providerAuth.rawValue)
        let error = dict["error"] as? String ?? ""
        #expect(!error.contains("secret-token-12345"))
        #expect(!error.contains("g-key"))
        #expect(!error.contains("engine-id"))
        #expect(!error.contains("tvly-secret"))
        #expect(error.contains("key=%5BREDACTED%5D") || error.contains("key=[REDACTED]"))
        #expect(error.contains("cx=%5BREDACTED%5D") || error.contains("cx=[REDACTED]"))
    }

    @Test func noResultsFailureUsesStructuredRedactedAttempts() throws {
        let outcome = SearchEngineOutcome(
            hits: [],
            provider: nil,
            attempts: [
                SearchAttempt(
                    provider: "brave_api",
                    ok: false,
                    kind: .providerAuth,
                    error: "X-Subscription-Token: brave-secret returned HTTP 401"
                ),
                SearchAttempt(provider: "bing_html", ok: true, count: 0),
            ]
        )
        let payload = WebSearchResultFormatter.noResultsFailure(
            tool: "web_search",
            request: SearchRequest(query: "swift"),
            outcome: outcome,
            warnings: [],
            hasConfiguredAPIProvider: true
        )
        let json = try Self.decodeObject(payload)
        let attempts = try #require(json["attempts"] as? [[String: Any]])

        #expect(attempts.count == 2)
        #expect(attempts[0]["kind"] as? String == SearchFailureKind.providerAuth.rawValue)
        #expect(attempts[1]["kind"] as? String == SearchFailureKind.empty.rawValue)
        #expect(!payload.contains("brave-secret"))
    }

    @Test func successPayloadDoesNotIncludeAttemptsByDefault() {
        let outcome = SearchEngineOutcome(
            hits: [
                SearchHit(title: "Swift", url: "https://swift.org", snippet: "Language", engine: "fixture")
            ],
            provider: "fixture",
            attempts: [
                SearchAttempt(provider: "fixture", ok: true, count: 1),
                SearchAttempt(provider: "backup", ok: false, error: "HTTP 500"),
            ]
        )
        let payload = WebSearchResultFormatter.resultsPayload(
            request: SearchRequest(query: "swift"),
            outcome: outcome
        )

        #expect(!payload.keys.contains("attempts"))
        #expect(payload["results"] != nil)
    }

    @Test func extractionBlocksUnsafePrivateAndMetadataURLsBeforeFetch() async {
        let urls = [
            "http://localhost:8080/page",
            "http://127.0.0.1/page",
            "http://10.0.0.5/page",
            "http://172.16.0.10/page",
            "http://192.168.1.2/page",
            "http://169.254.169.254/latest/meta-data",
            "http://[::1]/page",
            "http://[0:0:0:0:0:0:0:1]/page",
            "http://[::ffff:7f00:1]/page",
            "http://[::ffff:a9fe:a9fe]/latest/meta-data",
            "file:///etc/passwd",
        ]

        for url in urls {
            let extraction = await SearchReadability.extract(url: url, timeout: 0.01)
            #expect(extraction.status == .blocked, "Expected blocked extraction for \(url)")
            #expect(extraction.extracted == false)
        }
    }

    @Test func extractionRejectsOversizeResponsesBeforeBodyConversion() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SearchExtractionHTTPStubProtocol.self]
        SearchExtractionHTTPStubProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "text/html; charset=utf-8",
                    "Content-Length": "\(SearchReadability.maxHTMLBytes + 1)",
                ]
            )
            return (try #require(response), Data("<html></html>".utf8))
        }
        defer { SearchExtractionHTTPStubProtocol.handler = nil }

        let extraction = await SearchReadability.extract(
            url: "http://198.51.100.1/oversize",
            timeout: 1,
            configuration: configuration
        )

        #expect(extraction.status == .tooLarge)
        #expect(extraction.extracted == false)
        #expect(extraction.message?.contains("\(SearchReadability.maxHTMLBytes)") == true)
    }

    @Test func extractionPreservesRawCSVHeaderAndRows() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SearchExtractionHTTPStubProtocol.self]
        SearchExtractionHTTPStubProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Accept")?.contains("text/csv") == true)
            let response = HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/csv; charset=utf-8"]
            )
            return (
                try #require(response),
                Data("Date,Close\n2026-07-13,6234.49\n2026-07-14,6243.76".utf8)
            )
        }
        defer { SearchExtractionHTTPStubProtocol.handler = nil }

        let extraction = await SearchReadability.extract(
            url: "https://198.51.100.1/sp500.csv",
            timeout: 1,
            configuration: configuration
        )

        #expect(extraction.status == .ok)
        #expect(extraction.extracted)
        #expect(extraction.markdown.hasPrefix("Date,Close\n"))
        #expect(extraction.markdown.contains("2026-07-14,6243.76"))
    }

    @Test func structuredDataUsesTheLargerBound() {
        let csv = "Date,Close\n" + (0 ..< 1_500).map { "2026-01-01,\($0)" }.joined(separator: "\n")
        let extraction = SearchReadability.extract(
            responseText: csv,
            contentType: "text/csv",
            sourceURL: URL(string: "https://example.com/data.csv")
        )

        #expect(extraction.status == .ok)
        #expect(extraction.markdown.count > SearchReadability.maxMarkdownCharacters)
        #expect(extraction.markdown.count <= SearchReadability.maxStructuredTextCharacters)
        #expect(extraction.structuredFormat == "csv")
        #expect(extraction.structuredData == csv)
    }

    @Test func extractionDoesNotTreatHTMLMislabeledAsPlainTextAsRawData() {
        let html = """
            <!doctype html><html><head><title>Article</title></head>
            <body><main><p>\(Array(repeating: "content", count: 30).joined(separator: " "))</p></main></body></html>
            """
        let extraction = SearchReadability.extract(
            responseText: html,
            contentType: "text/plain",
            sourceURL: URL(string: "https://example.com/page")
        )

        #expect(extraction.status == .ok)
        #expect(extraction.title == "Article")
        #expect(!extraction.markdown.contains("<!doctype"))
    }

    @Test func extractionClassifiesChallengePage() {
        let html = """
            <!doctype html>
            <html><head><title>Just a moment...</title></head>
            <body><h1>Checking your browser</h1><p>Please solve this captcha.</p></body></html>
            """
        let extraction = SearchReadability.extract(html: html)

        #expect(extraction.status == .challenge)
        #expect(extraction.extracted == false)
        #expect(extraction.message == "challenge_page")
    }

    @Test func extractionClassifiesBoilerplatePage() {
        let html = """
            <!doctype html>
            <html><head><title>Shell</title></head>
            <body><main><p>Subscribe for updates.</p></main></body></html>
            """
        let extraction = SearchReadability.extract(html: html)

        #expect(extraction.status == .boilerplate)
        #expect(extraction.extracted == false)
        #expect(extraction.title == "Shell")
    }

    @Test func extractionIncludesCanonicalURLAndTruncatesMarkdown() {
        let words = (0 ..< 3_000).map { "word\($0)" }.joined(separator: " ")
        let html = """
            <!doctype html>
            <html lang="en">
            <head>
              <title>Long Article</title>
              <link rel="canonical" href="/article/canonical">
              <meta name="author" content="Reporter">
            </head>
            <body><main><h1>Long Article</h1><p>\(words)</p></main></body>
            </html>
            """
        let extraction = SearchReadability.extract(
            html: html,
            sourceURL: URL(string: "https://example.com/original?utm=secret")
        )

        #expect(extraction.status == .ok)
        #expect(extraction.extracted)
        #expect(extraction.title == "Long Article")
        #expect(extraction.byline == "Reporter")
        #expect(extraction.lang == "en")
        #expect(extraction.canonicalURL == "https://example.com/article/canonical")
        #expect(extraction.truncated)
        #expect(extraction.markdown.count <= SearchReadability.maxMarkdownCharacters)
        #expect(extraction.wordCount < (extraction.totalWordCount ?? 0))
        #expect(extraction.totalWordCount ?? 0 > 2_000)
    }

    @Test func extractionDropsUnsafeCanonicalURL() {
        let html = """
            <!doctype html>
            <html>
            <head>
              <title>Article</title>
              <link rel="canonical" href="http://169.254.169.254/latest/meta-data">
            </head>
            <body><main><p>\(Array(repeating: "content", count: 30).joined(separator: " "))</p></main></body>
            </html>
            """
        let extraction = SearchReadability.extract(
            html: html,
            sourceURL: URL(string: "https://example.com/article")
        )

        #expect(extraction.status == .ok)
        #expect(extraction.canonicalURL == nil)
    }

    private static func decodeObject(_ json: String) throws -> [String: Any] {
        let data = try #require(json.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class SearchExtractionHTTPStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        handler != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
