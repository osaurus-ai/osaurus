//
//  SearchEngine.swift
//  osaurus
//
//  The provider cascade behind `web_search`. Resolves the ranked provider
//  list for a category, tries API-key providers sequentially (each call costs
//  quota), then races the free scrapers in parallel under a wall-clock budget
//  with an early exit once any scraper returns enough hits. Dedupes by URL
//  and records a per-provider attempts trace for diagnostics.
//

import Foundation

// MARK: - Snapshot

/// Immutable view of one configured provider handed to the engine
/// (config + definitions live on the MainActor manager; the engine is
/// actor-agnostic and testable with fixture snapshots).
public struct SearchProviderSnapshot: Sendable {
    public var definition: SearchProviderDefinition
    public var enabled: Bool
    /// Secret field id -> value (resolved from Keychain by the manager).
    public var secrets: [String: String]

    public init(definition: SearchProviderDefinition, enabled: Bool, secrets: [String: String] = [:]) {
        self.definition = definition
        self.enabled = enabled
        self.secrets = secrets
    }

    /// All declared secrets present (keyless providers are always configured).
    public var isConfigured: Bool {
        for field in definition.secrets ?? [] {
            let value = secrets[field.id]
            if value == nil || value?.isEmpty == true { return false }
        }
        return true
    }
}

// MARK: - Outcome

public struct SearchEngineOutcome: Sendable {
    public var hits: [SearchHit]
    /// Definition id of the provider that served the first hits, if any.
    public var provider: String?
    public var attempts: [SearchAttempt]
    public var elapsed: TimeInterval

    public init(
        hits: [SearchHit],
        provider: String?,
        attempts: [SearchAttempt],
        elapsed: TimeInterval = 0
    ) {
        self.hits = hits
        self.provider = provider
        self.attempts = attempts
        self.elapsed = elapsed
    }
}

// MARK: - Engine

public struct SearchEngine: Sendable {
    /// Builds an executable backend for a definition. Injectable for tests.
    var backendFactory: @Sendable (SearchProviderDefinition, [String: String]) -> SearchBackend?
    /// Wall-clock budget for the parallel free-scraper race.
    var freeRaceBudget: TimeInterval
    /// Early-exit threshold: stop the race once one scraper returns this many hits.
    var earlyExitHitCount: Int

    public static let shared = SearchEngine()

    init(
        backendFactory: @escaping @Sendable (SearchProviderDefinition, [String: String]) -> SearchBackend? =
            SearchEngine.defaultBackend,
        freeRaceBudget: TimeInterval = 12,
        earlyExitHitCount: Int = 3
    ) {
        self.backendFactory = backendFactory
        self.freeRaceBudget = freeRaceBudget
        self.earlyExitHitCount = earlyExitHitCount
    }

    static func defaultBackend(
        definition: SearchProviderDefinition,
        secrets: [String: String]
    ) -> SearchBackend? {
        switch definition.runtime {
        case .native:
            return NativeSearchBackends.backend(for: definition.id)
        case .declarative:
            return DeclarativeSearchBackend(definition: definition, secrets: secrets)
        }
    }

    // MARK: Full cascade

    /// Run the cascade for `request` over `providers` (already in rank order
    /// for the request's category).
    public func run(
        request: SearchRequest,
        providers: [SearchProviderSnapshot]
    ) async -> SearchEngineOutcome {
        let started = Date()
        let usable = providers.filter { $0.enabled && $0.definition.supports(category: request.category) }
        // API-key providers cost quota: sequential, in rank order, skipping
        // any whose keys aren't configured. Keyless scrapers are raced in
        // parallel only when the keyed pass produced nothing.
        let keyed = usable.filter { !$0.definition.isKeyless && $0.isConfigured }
        let free = usable.filter { $0.definition.isKeyless }

        var attempts: [SearchAttempt] = []
        var deduped: [SearchHit] = []
        var seen = Set<String>()
        var usedProvider: String?

        func ingest(_ hits: [SearchHit]) {
            for h in hits {
                let key = h.url.lowercased()
                if key.isEmpty || seen.contains(key) { continue }
                seen.insert(key)
                deduped.append(h)
            }
        }

        for snapshot in keyed {
            let result = await runOne(snapshot, request: request)
            switch result {
            case .success(let hits):
                attempts.append(SearchAttempt(provider: snapshot.definition.id, ok: true, count: hits.count))
                if !hits.isEmpty {
                    ingest(hits)
                    usedProvider = snapshot.definition.id
                }
            case .failure(let error):
                attempts.append(
                    SearchAttempt(
                        provider: snapshot.definition.id,
                        ok: false,
                        kind: error.kind,
                        error: error.message
                    ))
            }
            if !deduped.isEmpty { break }
        }

        if deduped.isEmpty, !free.isEmpty {
            let race = await raceFree(free, request: request)
            attempts.append(contentsOf: race.attempts)
            ingest(race.hits)
            if usedProvider == nil { usedProvider = race.provider }
        }

        return SearchEngineOutcome(
            hits: deduped,
            provider: usedProvider,
            attempts: attempts,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    // MARK: Pinned single-provider run (per-card Test button)

    public func runPinned(
        request: SearchRequest,
        provider: SearchProviderSnapshot
    ) async -> SearchEngineOutcome {
        let started = Date()
        guard provider.definition.supports(category: request.category) else {
            return SearchEngineOutcome(
                hits: [],
                provider: nil,
                attempts: [
                    SearchAttempt(
                        provider: provider.definition.id,
                        ok: false,
                        kind: .unsupportedCategory,
                        error: "\(provider.definition.name) does not support \(request.category) search"
                    )
                ],
                elapsed: 0
            )
        }
        let result = await runOne(provider, request: request)
        switch result {
        case .success(let hits):
            return SearchEngineOutcome(
                hits: hits,
                provider: hits.isEmpty ? nil : provider.definition.id,
                attempts: [SearchAttempt(provider: provider.definition.id, ok: true, count: hits.count)],
                elapsed: Date().timeIntervalSince(started)
            )
        case .failure(let error):
            return SearchEngineOutcome(
                hits: [],
                provider: nil,
                attempts: [
                    SearchAttempt(
                        provider: provider.definition.id,
                        ok: false,
                        kind: error.kind,
                        error: error.message
                    )
                ],
                elapsed: Date().timeIntervalSince(started)
            )
        }
    }

    // MARK: Internals

    private func runOne(
        _ snapshot: SearchProviderSnapshot,
        request: SearchRequest
    ) async -> Result<[SearchHit], SearchBackendError> {
        guard let backend = backendFactory(snapshot.definition, snapshot.secrets) else {
            return .failure(
                SearchBackendError(
                    "No backend available for \(snapshot.definition.id)",
                    kind: .providerHTTP
                ))
        }
        do {
            return .success(try await backend.search(request))
        } catch let error as SearchBackendError {
            return .failure(error)
        } catch is CancellationError {
            return .failure(SearchBackendError("cancelled", kind: .cancelled))
        } catch {
            return .failure(SearchBackendError(error.localizedDescription, kind: .network))
        }
    }

    /// Race the free scrapers in parallel under the wall-clock budget,
    /// early-exiting as soon as any trusted provider returns enough hits.
    ///
    /// Last-resort providers (`definition.lastResort`, e.g. DDG whose anti-bot
    /// layer serves decoy results) run in the race but never trigger the early
    /// exit, and their hits are used only when no trusted provider produced any.
    private func raceFree(
        _ providers: [SearchProviderSnapshot],
        request: SearchRequest
    ) async -> (hits: [SearchHit], attempts: [SearchAttempt], provider: String?) {
        typealias RaceItem = (id: String, result: Result<[SearchHit], SearchBackendError>)

        let lastResortIds = Set(
            providers.filter { $0.definition.lastResort }.map { $0.definition.id })

        let done: [RaceItem] = await withTaskGroup(of: RaceItem?.self) { group in
            for snapshot in providers {
                group.addTask {
                    (snapshot.definition.id, await runOne(snapshot, request: request))
                }
            }
            // Budget sentinel: a nil item means the wall clock elapsed.
            let budget = freeRaceBudget
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                return nil
            }

            var collected: [RaceItem] = []
            for await item in group {
                guard let item else { break }
                collected.append(item)
                if case .success(let hits) = item.result,
                    hits.count >= earlyExitHitCount && !lastResortIds.contains(item.id) {
                    break
                }
                if collected.count == providers.count { break }
            }
            group.cancelAll()
            return collected
        }

        var attempts: [SearchAttempt] = []
        let completed = Set(done.map { $0.id })
        for snapshot in providers where !completed.contains(snapshot.definition.id) {
            // Either the budget elapsed before this one finished or another
            // provider triggered the early exit; both read as did_not_complete
            // to avoid implying the request itself timed out.
            attempts.append(
                SearchAttempt(
                    provider: snapshot.definition.id,
                    ok: false,
                    kind: .didNotComplete,
                    error: "did_not_complete"
                ))
        }
        for (id, result) in done {
            switch result {
            case .success(let h):
                attempts.append(SearchAttempt(provider: id, ok: true, count: h.count))
            case .failure(let error):
                attempts.append(
                    SearchAttempt(provider: id, ok: false, kind: error.kind, error: error.message))
            }
        }

        // Ingest trusted results first, in rank order (not completion order);
        // last-resort hits are used only when every trusted provider came up
        // empty.
        var hits: [SearchHit] = []
        var seen = Set<String>()
        var bestProvider: String?
        let resultsById = Dictionary(
            done.compactMap { item -> (String, [SearchHit])? in
                guard case .success(let h) = item.result else { return nil }
                return (item.id, h)
            },
            uniquingKeysWith: { first, _ in first }
        )

        func ingest(_ providerIds: [String]) {
            for id in providerIds {
                for hit in resultsById[id] ?? [] {
                    let key = hit.url.lowercased()
                    if key.isEmpty || seen.contains(key) { continue }
                    seen.insert(key)
                    hits.append(hit)
                    if bestProvider == nil { bestProvider = id }
                }
            }
        }

        let rankOrder = providers.map { $0.definition.id }
        ingest(rankOrder.filter { !lastResortIds.contains($0) })
        if hits.isEmpty {
            ingest(rankOrder.filter { lastResortIds.contains($0) })
        }
        return (hits, attempts, bestProvider)
    }
}
