//
//  SearchEngineCascadeTests.swift
//  OsaurusCoreTests
//
//  Cascade contract with mocked backends: keyed providers run sequentially in
//  rank order (first non-empty result wins, quota-friendly), unconfigured
//  keyed providers are skipped, the free scrapers only race when the keyed
//  pass produced nothing, results dedupe by URL, category support filters the
//  provider set, and pinned runs report unsupported categories as failures.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct SearchEngineCascadeTests {

    // MARK: - Fixtures

    private struct StubBackend: SearchBackend {
        let definitionId: String
        let result: Result<[SearchHit], SearchBackendError>

        func search(_ request: SearchRequest) async throws -> [SearchHit] {
            try result.get()
        }
    }

    private static func hit(_ url: String, engine: String) -> SearchHit {
        SearchHit(title: url, url: url, snippet: "snippet for \(url)", engine: engine)
    }

    private static func keyedDefinition(_ id: String, categories: [String] = ["web"]) -> SearchProviderDefinition {
        SearchProviderDefinition(
            id: id,
            name: id,
            secrets: [SearchSecretField(id: "api_key", label: "Key")],
            endpoints: Dictionary(
                uniqueKeysWithValues: categories.map {
                    (
                        $0,
                        SearchEndpoint(
                            url: "https://example.com/\(id)",
                            response: SearchResponseMapping(
                                resultsPath: "results",
                                item: SearchHitFieldPaths(title: "t", url: "u", snippet: "s")
                            )
                        )
                    )
                }
            )
        )
    }

    private static func freeDefinition(_ id: String, categories: [String] = ["web"]) -> SearchProviderDefinition {
        SearchProviderDefinition(id: id, name: id, runtime: .native, categories: categories)
    }

    /// Free scraper flagged like DDG: races, but never trusted over others.
    private static func lastResortDefinition(_ id: String) -> SearchProviderDefinition {
        SearchProviderDefinition(id: id, name: id, runtime: .native, lastResort: true, categories: ["web"])
    }

    /// Engine whose backends are table-driven stubs.
    private static func makeEngine(
        results: [String: Result<[SearchHit], SearchBackendError>]
    ) -> SearchEngine {
        SearchEngine(
            backendFactory: { definition, _ in
                StubBackend(
                    definitionId: definition.id,
                    result: results[definition.id] ?? .success([])
                )
            },
            freeRaceBudget: 5,
            earlyExitHitCount: 3
        )
    }

    private static func configured(
        _ definition: SearchProviderDefinition,
        enabled: Bool = true
    ) -> SearchProviderSnapshot {
        SearchProviderSnapshot(
            definition: definition,
            enabled: enabled,
            secrets: definition.isKeyless ? [:] : ["api_key": "test-key"]
        )
    }

    // MARK: - Keyed pass

    @Test func primaryKeyedProviderWinsWithoutTouchingFallbacks() async {
        let engine = Self.makeEngine(results: [
            "primary": .success([Self.hit("https://a.example", engine: "primary")]),
            "backup": .success([Self.hit("https://b.example", engine: "backup")]),
            "free": .success([Self.hit("https://c.example", engine: "free")]),
        ])
        let outcome = await engine.run(
            request: SearchRequest(query: "q"),
            providers: [
                Self.configured(Self.keyedDefinition("primary")),
                Self.configured(Self.keyedDefinition("backup")),
                Self.configured(Self.freeDefinition("free")),
            ]
        )
        #expect(outcome.provider == "primary")
        #expect(outcome.hits.map(\.url) == ["https://a.example"])
        // Neither the backup (quota!) nor the free race were touched.
        #expect(outcome.attempts.map(\.provider) == ["primary"])
    }

    @Test func keyedFailureFallsThroughToNextRank() async {
        let engine = Self.makeEngine(results: [
            "primary": .failure(SearchBackendError("HTTP 401")),
            "backup": .success([Self.hit("https://b.example", engine: "backup")]),
        ])
        let outcome = await engine.run(
            request: SearchRequest(query: "q"),
            providers: [
                Self.configured(Self.keyedDefinition("primary")),
                Self.configured(Self.keyedDefinition("backup")),
            ]
        )
        #expect(outcome.provider == "backup")
        #expect(outcome.hits.count == 1)
        #expect(outcome.attempts.count == 2)
        #expect(outcome.attempts[0].ok == false)
        #expect(outcome.attempts[0].error == "HTTP 401")
        #expect(outcome.attempts[1].ok == true)
    }

    @Test func unconfiguredKeyedProviderIsSkippedEntirely() async {
        let engine = Self.makeEngine(results: [
            "keyless-missing": .success([Self.hit("https://never.example", engine: "keyless-missing")]),
            "free": .success([Self.hit("https://free.example", engine: "free")]),
        ])
        let outcome = await engine.run(
            request: SearchRequest(query: "q"),
            providers: [
                // Keyed definition WITHOUT secrets in the snapshot: must not
                // even be attempted (no wasted call, no misleading attempt).
                SearchProviderSnapshot(
                    definition: Self.keyedDefinition("keyless-missing"),
                    enabled: true,
                    secrets: [:]
                ),
                Self.configured(Self.freeDefinition("free")),
            ]
        )
        #expect(outcome.provider == "free")
        #expect(!outcome.attempts.contains { $0.provider == "keyless-missing" })
    }

    @Test func disabledProviderIsSkipped() async {
        let engine = Self.makeEngine(results: [
            "primary": .success([Self.hit("https://a.example", engine: "primary")]),
            "free": .success([Self.hit("https://free.example", engine: "free")]),
        ])
        let outcome = await engine.run(
            request: SearchRequest(query: "q"),
            providers: [
                Self.configured(Self.keyedDefinition("primary"), enabled: false),
                Self.configured(Self.freeDefinition("free")),
            ]
        )
        #expect(outcome.provider == "free")
        #expect(!outcome.attempts.contains { $0.provider == "primary" })
    }

    // MARK: - Free race

    @Test func emptyKeyedResultsFallThroughToFreeRace() async {
        let engine = Self.makeEngine(results: [
            "primary": .success([]),
            "free": .success([Self.hit("https://free.example", engine: "free")]),
        ])
        let outcome = await engine.run(
            request: SearchRequest(query: "q"),
            providers: [
                Self.configured(Self.keyedDefinition("primary")),
                Self.configured(Self.freeDefinition("free")),
            ]
        )
        #expect(outcome.provider == "free")
        #expect(outcome.hits.count == 1)
        // The empty keyed attempt is still recorded (ok, count 0).
        let keyedAttempt = outcome.attempts.first { $0.provider == "primary" }
        #expect(keyedAttempt?.ok == true)
        #expect(keyedAttempt?.count == 0)
    }

    @Test func freeRaceDedupesByURLCaseInsensitively() async {
        let engine = Self.makeEngine(results: [
            "free_a": .success([
                Self.hit("https://shared.example/page", engine: "free_a"),
                Self.hit("https://only-a.example", engine: "free_a"),
            ]),
            "free_b": .success([
                Self.hit("https://SHARED.example/page", engine: "free_b"),
                Self.hit("https://only-b.example", engine: "free_b"),
            ]),
        ])
        let outcome = await engine.run(
            request: SearchRequest(query: "q"),
            providers: [
                Self.configured(Self.freeDefinition("free_a")),
                Self.configured(Self.freeDefinition("free_b")),
            ]
        )
        let urls = Set(outcome.hits.map { $0.url.lowercased() })
        #expect(urls.count == outcome.hits.count, "duplicate URLs must be deduped")
        #expect(urls.count == 3)
        #expect(outcome.provider != nil)
    }

    @Test func noResultsAnywhereYieldsEmptyOutcomeWithAttempts() async {
        let engine = Self.makeEngine(results: [
            "primary": .failure(SearchBackendError("HTTP 500")),
            "free": .success([]),
        ])
        let outcome = await engine.run(
            request: SearchRequest(query: "q"),
            providers: [
                Self.configured(Self.keyedDefinition("primary")),
                Self.configured(Self.freeDefinition("free")),
            ]
        )
        #expect(outcome.hits.isEmpty)
        #expect(outcome.provider == nil)
        // Both attempts are present so NO_RESULTS payloads are actionable.
        #expect(Set(outcome.attempts.map(\.provider)) == ["primary", "free"])
    }

    // MARK: - Last-resort demotion (DDG decoy defense)

    @Test func lastResortHitsAreDroppedWhenATrustedScraperReturns() async {
        let engine = Self.makeEngine(results: [
            "trusted": .success([Self.hit("https://real.example", engine: "trusted")]),
            "decoy": .success([
                Self.hit("https://decoy-1.example", engine: "decoy"),
                Self.hit("https://decoy-2.example", engine: "decoy"),
            ]),
        ])
        let outcome = await engine.run(
            request: SearchRequest(query: "q"),
            providers: [
                Self.configured(Self.freeDefinition("trusted")),
                Self.configured(Self.lastResortDefinition("decoy")),
            ]
        )
        #expect(outcome.provider == "trusted")
        #expect(outcome.hits.map(\.url) == ["https://real.example"])
        // The decoy attempt is still recorded for the trace.
        #expect(outcome.attempts.contains { $0.provider == "decoy" })
    }

    @Test func lastResortIsUsedWhenEveryTrustedScraperFails() async {
        let engine = Self.makeEngine(results: [
            "trusted_a": .failure(SearchBackendError("challenge_page")),
            "trusted_b": .success([]),
            "fallback": .success([Self.hit("https://fallback.example", engine: "fallback")]),
        ])
        let outcome = await engine.run(
            request: SearchRequest(query: "q"),
            providers: [
                Self.configured(Self.freeDefinition("trusted_a")),
                Self.configured(Self.freeDefinition("trusted_b")),
                Self.configured(Self.lastResortDefinition("fallback")),
            ]
        )
        #expect(outcome.provider == "fallback")
        #expect(outcome.hits.map(\.url) == ["https://fallback.example"])
    }

    @Test func lastResortSuccessDoesNotEarlyExitTheRace() async {
        // The last-resort provider "wins" the race instantly with plenty of
        // hits; the trusted provider is slower. Without the demotion the fast
        // decoys would early-exit the race and be served — with it, the engine
        // waits for the trusted provider and prefers its results.
        struct SlowBackend: SearchBackend {
            let definitionId: String
            let hits: [SearchHit]
            func search(_ request: SearchRequest) async throws -> [SearchHit] {
                try? await Task.sleep(nanoseconds: 150_000_000)
                return hits
            }
        }
        let decoys = (1...5).map { Self.hit("https://decoy-\($0).example", engine: "decoy") }
        let engine = SearchEngine(
            backendFactory: { definition, _ in
                if definition.id == "slow_trusted" {
                    return SlowBackend(
                        definitionId: definition.id,
                        hits: [Self.hit("https://real.example", engine: "slow_trusted")]
                    )
                }
                return StubBackend(definitionId: definition.id, result: .success(decoys))
            },
            freeRaceBudget: 5,
            earlyExitHitCount: 3
        )
        let outcome = await engine.run(
            request: SearchRequest(query: "q"),
            providers: [
                Self.configured(Self.freeDefinition("slow_trusted")),
                Self.configured(Self.lastResortDefinition("decoy")),
            ]
        )
        #expect(outcome.provider == "slow_trusted")
        #expect(outcome.hits.first?.url == "https://real.example")
        // Only trusted hits are served; the decoy set is dropped entirely.
        #expect(outcome.hits.allSatisfy { $0.engine == "slow_trusted" })
    }

    @Test func trustedSuccessStillEarlyExitsWithoutWaitingForLastResort() async {
        // Trusted provider returns >= earlyExitHitCount instantly; a slow
        // last-resort provider must not hold up the race.
        struct NeverFinishBackend: SearchBackend {
            let definitionId: String
            func search(_ request: SearchRequest) async throws -> [SearchHit] {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return []
            }
        }
        let trustedHits = (1...3).map { Self.hit("https://real-\($0).example", engine: "trusted") }
        let engine = SearchEngine(
            backendFactory: { definition, _ in
                if definition.id == "trusted" {
                    return StubBackend(definitionId: definition.id, result: .success(trustedHits))
                }
                return NeverFinishBackend(definitionId: definition.id)
            },
            freeRaceBudget: 30,
            earlyExitHitCount: 3
        )
        let started = Date()
        let outcome = await engine.run(
            request: SearchRequest(query: "q"),
            providers: [
                Self.configured(Self.freeDefinition("trusted")),
                Self.configured(Self.lastResortDefinition("slow_decoy")),
            ]
        )
        #expect(outcome.provider == "trusted")
        #expect(outcome.hits.count == 3)
        // Early exit fired: nowhere near the 30s budget.
        #expect(Date().timeIntervalSince(started) < 5)
        // The unfinished last-resort provider reads as did_not_complete.
        let decoyAttempt = outcome.attempts.first { $0.provider == "slow_decoy" }
        #expect(decoyAttempt?.ok == false)
        #expect(decoyAttempt?.error == "did_not_complete")
    }

    // MARK: - Category routing

    @Test func providersNotSupportingTheCategoryAreFilteredOut() async {
        let engine = Self.makeEngine(results: [
            "news_only": .success([Self.hit("https://news.example", engine: "news_only")]),
            "web_only": .success([Self.hit("https://web.example", engine: "web_only")]),
        ])
        let outcome = await engine.run(
            request: SearchRequest(query: "q", category: "news"),
            providers: [
                Self.configured(Self.keyedDefinition("news_only", categories: ["news"])),
                Self.configured(Self.keyedDefinition("web_only", categories: ["web"])),
            ]
        )
        #expect(outcome.provider == "news_only")
        #expect(!outcome.attempts.contains { $0.provider == "web_only" })
    }

    // MARK: - Pinned runs

    @Test func pinnedRunReportsUnsupportedCategoryAsFailure() async {
        let engine = Self.makeEngine(results: [:])
        let outcome = await engine.runPinned(
            request: SearchRequest(query: "q", category: "images"),
            provider: Self.configured(Self.keyedDefinition("web_only", categories: ["web"]))
        )
        #expect(outcome.hits.isEmpty)
        #expect(outcome.attempts.count == 1)
        #expect(outcome.attempts[0].ok == false)
        #expect(outcome.attempts[0].error?.contains("does not support images") == true)
    }

    @Test func pinnedRunReturnsHitsAndProvider() async {
        let engine = Self.makeEngine(results: [
            "solo": .success([Self.hit("https://solo.example", engine: "solo")])
        ])
        let outcome = await engine.runPinned(
            request: SearchRequest(query: "q"),
            provider: Self.configured(Self.keyedDefinition("solo"))
        )
        #expect(outcome.provider == "solo")
        #expect(outcome.hits.count == 1)
        #expect(outcome.attempts == [SearchAttempt(provider: "solo", ok: true, count: 1)])
    }
}
