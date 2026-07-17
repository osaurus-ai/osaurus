//
//  OsaurusRouterSearchBackend.swift
//  osaurus
//
//  Hosted, credit-billed search through the Osaurus Router (`/v1/search`,
//  `/v1/contents`). Deliberately NOT a `SearchBackend` in the cascade: the
//  manager tries it first when premium search is gated on, and any failure
//  or empty result falls through to the existing provider cascade unchanged.
//  Every response's billing metadata is returned so the caller can update
//  the Credits UI even when the search itself fell back.
//

import Foundation

// MARK: - Availability backoff

/// Caches hosted-search unavailability so a server-side 404 (feature off) or
/// 429 (rate limit) doesn't get hammered on every tool call. Lock-protected:
/// checked from the MainActor manager, updated from backend call sites.
final class RouterWebSearchAvailability: @unchecked Sendable {
    static let shared = RouterWebSearchAvailability()

    /// Recheck interval after a 404: long enough to stop hammering, short
    /// enough that a server-side enable is picked up the same session.
    static let featureOffBackoff: TimeInterval = 30 * 60
    static let defaultRateLimitBackoff: TimeInterval = 60

    private let lock = NSLock()
    private var unavailableUntil: Date?

    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = unavailableUntil else { return true }
        if Date() >= until {
            unavailableUntil = nil
            return true
        }
        return false
    }

    func markFeatureUnavailable(now: Date = Date()) {
        markUnavailable(until: now.addingTimeInterval(Self.featureOffBackoff))
    }

    func markRateLimited(retryAfter: String?, now: Date = Date()) {
        let seconds = retryAfter.flatMap(TimeInterval.init) ?? Self.defaultRateLimitBackoff
        markUnavailable(until: now.addingTimeInterval(max(1, seconds)))
    }

    func markAvailable() {
        lock.lock()
        unavailableUntil = nil
        lock.unlock()
    }

    private func markUnavailable(until: Date) {
        lock.lock()
        unavailableUntil = until
        lock.unlock()
    }
}

// MARK: - Outcomes

/// Why a hosted attempt did not serve the request. Every case falls back to
/// the local cascade; the associated UI effect differs (spec section 5).
enum HostedSearchFailure: Error, Sendable, Equatable {
    /// 402 INSUFFICIENT_FUNDS — must surface the top-up state even though
    /// the fallback succeeds.
    case insufficientFunds
    /// 402 PAID_WEB_DISABLED — the user turned auto-pay off; silent fallback.
    case paidWebDisabled
    /// 404 — hosted search disabled server-side; silent fallback + backoff.
    case featureUnavailable
    /// 429 — honor retry-after for future hosted calls.
    case rateLimited
    /// 409 — client bug (key reuse); log and fall back.
    case idempotencyConflict
    /// 400 — unsupported input for hosted search; silent fallback.
    case invalidRequest
    /// 401/403-signing — surface in router diagnostics; fall back.
    case unauthorized
    /// 403 ACCOUNT_FROZEN — show the billing-hold state; fall back.
    case accountFrozen
    /// 5xx/timeout — nothing was charged (server refunds the hold).
    case providerError
    case transport(String)

    /// Stable diagnostic token recorded in the attempts trace and the tool
    /// payload's `premium_fallback` field.
    var reason: String {
        switch self {
        case .insufficientFunds: return "insufficient_funds"
        case .paidWebDisabled: return "paid_web_disabled"
        case .featureUnavailable: return "unavailable"
        case .rateLimited: return "rate_limited"
        case .idempotencyConflict: return "idempotency_conflict"
        case .invalidRequest: return "invalid_request"
        case .unauthorized: return "unauthorized"
        case .accountFrozen: return "account_frozen"
        case .providerError: return "provider_error"
        case .transport: return "network"
        }
    }

    var attemptKind: SearchFailureKind {
        switch self {
        case .unauthorized, .accountFrozen, .insufficientFunds, .paidWebDisabled:
            return .providerAuth
        case .transport: return .network
        case .rateLimited, .featureUnavailable, .invalidRequest, .idempotencyConflict,
            .providerError:
            return .providerHTTP
        }
    }
}

/// Successful hosted `/v1/search` outcome. `hits` is empty for `replayed`
/// responses (billing is authoritative, content is not persisted server-side).
struct HostedSearchOutcome: Sendable {
    var hits: [SearchHit]
    /// Lowercased URL -> extracted page text, when `contents.text` was
    /// requested (search_and_extract query mode).
    var textByURL: [String: String]
    var billing: RouterWebBillingSummary?
    var warnings: [String]
    var replayed: Bool
}

/// Successful hosted `/v1/contents` outcome, one page per requested URL.
/// Pages whose `status` is not "success" were not billed and need the local
/// Readability fallback.
struct HostedContentsOutcome: Sendable {
    struct Page: Sendable {
        var url: String
        var title: String?
        var text: String?
        var succeeded: Bool
        var error: String?
    }

    var pages: [Page]
    var billing: RouterWebBillingSummary?
    var replayed: Bool
}

// MARK: - Backend

struct OsaurusRouterSearchBackend: Sendable {
    /// Definition-id-style token used in attempts traces and tool payloads.
    static let providerId = "osaurus_router"
    /// Server cap on `num_results`.
    static let maxResults = 25
    /// Default extraction budget for query-mode search_and_extract, aligned
    /// with the local extractor's markdown cap.
    static let defaultTextMaxCharacters = 12_000

    var client: OsaurusRouterAPIClient = .shared
    var availability: RouterWebSearchAvailability = .shared

    // MARK: /v1/search

    func search(
        _ request: SearchRequest,
        extractTextMaxCharacters: Int? = nil,
        idempotencyKey: String
    ) async -> Result<HostedSearchOutcome, HostedSearchFailure> {
        let body = Self.searchBody(
            for: request,
            extractTextMaxCharacters: extractTextMaxCharacters,
            idempotencyKey: idempotencyKey
        )
        do {
            let response = try await client.webSearch(body)
            availability.markAvailable()
            var textByURL: [String: String] = [:]
            let hits = response.results.compactMap { result -> SearchHit? in
                guard let url = result.url, !url.isEmpty else { return nil }
                if let text = result.text, !text.isEmpty {
                    textByURL[url.lowercased()] = text
                }
                return Self.hit(from: result, url: url)
            }
            return .success(
                HostedSearchOutcome(
                    hits: hits,
                    textByURL: textByURL,
                    billing: response.osaurus.map(RouterWebBillingSummary.init),
                    warnings: response.warnings ?? [],
                    replayed: response.replayed == true
                ))
        } catch {
            return .failure(classify(error))
        }
    }

    // MARK: /v1/contents

    func contents(
        urls: [String],
        maxCharacters: Int = OsaurusRouterSearchBackend.defaultTextMaxCharacters,
        idempotencyKey: String
    ) async -> Result<HostedContentsOutcome, HostedSearchFailure> {
        let body = OsaurusRouterWebContentsRequestBody(
            urls: urls,
            contents: OsaurusRouterWebContentsSpec(
                text: .init(max_characters: maxCharacters),
                highlights: nil
            ),
            idempotency_key: idempotencyKey
        )
        do {
            let response = try await client.webContents(body)
            availability.markAvailable()
            let resultsByURL = Dictionary(
                response.results.compactMap { result -> (String, OsaurusRouterWebResult)? in
                    guard let url = result.url, !url.isEmpty else { return nil }
                    return (url.lowercased(), result)
                },
                uniquingKeysWith: { first, _ in first }
            )
            let statusByURL = Dictionary(
                (response.statuses ?? []).map { ($0.url.lowercased(), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let replayed = response.replayed == true
            let pages = urls.map { url -> HostedContentsOutcome.Page in
                let key = url.lowercased()
                let result = resultsByURL[key]
                let status = statusByURL[key]
                // A page counts as served only when actual text came back;
                // replayed responses carry no content, so every URL needs the
                // local fallback.
                let succeeded =
                    !replayed
                    && (result?.text?.isEmpty == false)
                    && (status == nil || status?.status == "success")
                return HostedContentsOutcome.Page(
                    url: url,
                    title: result?.title,
                    text: result?.text,
                    succeeded: succeeded,
                    error: status?.error
                )
            }
            return .success(
                HostedContentsOutcome(
                    pages: pages,
                    billing: response.osaurus.map(RouterWebBillingSummary.init),
                    replayed: replayed
                ))
        } catch {
            return .failure(classify(error))
        }
    }

    // MARK: Mapping

    /// Router category for a native request category. `nil` means plain web
    /// search (omit the field). Image/video requests must never reach here —
    /// the manager's gate excludes them.
    static func routerCategory(for category: String) -> String? {
        switch category {
        case SearchCategory.web:
            return nil
        case SearchCategory.news:
            return "news"
        case "company", "research paper", "people", "financial report", "personal site",
            "pdf", "github":
            return category
        default:
            // Unknown categories fall back to general web rather than risking
            // a 400 round-trip for a category the router doesn't know.
            return nil
        }
    }

    static func searchBody(
        for request: SearchRequest,
        extractTextMaxCharacters: Int?,
        idempotencyKey: String
    ) -> OsaurusRouterWebSearchRequestBody {
        var contents: OsaurusRouterWebContentsSpec?
        if let maxCharacters = extractTextMaxCharacters {
            contents = OsaurusRouterWebContentsSpec(
                text: .init(max_characters: maxCharacters),
                highlights: true
            )
        }
        return OsaurusRouterWebSearchRequestBody(
            query: request.query,
            category: routerCategory(for: request.category),
            num_results: min(max(1, request.maxResults), maxResults),
            site: request.site,
            file_type: request.filetype,
            time_range: request.timeRange,
            region: request.region,
            contents: contents,
            idempotency_key: idempotencyKey
        )
    }

    private static func hit(from result: OsaurusRouterWebResult, url: String) -> SearchHit {
        let snippet: String
        if let highlight = result.highlights?.first(where: { !$0.isEmpty }) {
            snippet = highlight
        } else if let summary = result.summary, !summary.isEmpty {
            snippet = summary
        } else if let text = result.text, !text.isEmpty {
            snippet = String(text.prefix(300))
        } else {
            snippet = ""
        }
        return SearchHit(
            title: result.title ?? url,
            url: url,
            snippet: snippet,
            publishedDate: result.publishedDate,
            engine: providerId
        )
    }

    // MARK: Error classification (spec section 5)

    private func classify(_ error: Error) -> HostedSearchFailure {
        guard let apiError = error as? OsaurusRouterAPIError else {
            return .transport(error.localizedDescription)
        }
        switch apiError {
        case .insufficientFunds:
            return .insufficientFunds
        case .paidWebDisabled:
            return .paidWebDisabled
        case .accountFrozen:
            return .accountFrozen
        case .unauthorized, .noIdentity:
            return .unauthorized
        case .rateLimited(let retryAfter):
            availability.markRateLimited(retryAfter: retryAfter)
            return .rateLimited
        case .idempotencyConflict:
            return .idempotencyConflict
        case .transport(let message):
            return .transport(message)
        case .server(_, _, let status):
            switch status {
            case 404:
                availability.markFeatureUnavailable()
                return .featureUnavailable
            case 400:
                return .invalidRequest
            case 402:
                return .paidWebDisabled
            case 403:
                return .accountFrozen
            default:
                return .providerError
            }
        case .invalidURL, .invalidResponse, .belowMinimumTopUp:
            return .providerError
        }
    }
}
