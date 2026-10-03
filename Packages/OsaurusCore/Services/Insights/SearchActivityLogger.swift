//
//  SearchActivityLogger.swift
//  osaurus
//
//  Activity-log rows for web search and URL extraction. One row per logical
//  operation (a search request, a hosted contents batch, a direct page
//  fetch) so a reviewer can see exactly which query or URL left this Mac,
//  which provider served it, and what came back.
//
//  Pure builders live here so they can be unit-tested; the emit is a
//  one-liner through `InsightsService.logEgress`.
//

import Foundation

enum SearchActivityLogger {

    // MARK: - Web search

    /// Build the egress facts for a completed search cascade.
    ///
    /// - `providersTried` is the ordered attempt list (hosted first when it
    ///   ran), `usedProvider` the one that served hits (nil when none did).
    /// - `destination` is the host of the provider that served the hits, or
    ///   of the first provider tried when nothing came back — the row has to
    ///   name *somewhere* the query went.
    static func searchEgress(
        request: SearchRequest,
        outcome: SearchEngineOutcome,
        hostedSource: WebSearchSource?,
        hostedFallbackReason: String?,
        pinned: Bool,
        hostFor: (String) -> String?
    ) -> EgressInfo {
        let providersTried = outcome.attempts.map(\.provider)
        let destinationProvider = outcome.provider ?? providersTried.first
        let host = destinationProvider.flatMap(hostFor)
        var details: [String: String] = [
            "query": request.query,
            "category": request.category,
            "hit_count": String(outcome.hits.count),
            "providers_tried": providersTried.joined(separator: ", "),
        ]
        if let used = outcome.provider { details["provider_used"] = used }
        if let site = request.site, !site.isEmpty { details["site"] = site }
        if let filetype = request.filetype, !filetype.isEmpty { details["filetype"] = filetype }
        if let range = request.timeRange, !range.isEmpty { details["time_range"] = range }
        if let region = request.region, !region.isEmpty { details["region"] = region }
        if let hostedSource { details["source"] = hostedSource.rawValue }
        if let reason = hostedFallbackReason { details["hosted_fallback"] = reason }
        if pinned { details["pinned_test"] = "true" }
        let failures = outcome.attempts.filter { !$0.ok }
        if !failures.isEmpty {
            details["failures"] = failures.map { "\($0.provider): \($0.error ?? $0.kind.rawValue)" }
                .joined(separator: " | ")
        }
        if !outcome.hits.isEmpty {
            details["result_preview"] = outcome.hits.prefix(5).map(\.url).joined(separator: "\n")
        }
        return EgressInfo(
            destinationLabel: destinationProvider.map { providerLabel($0, host: host) },
            destinationHost: host,
            bytesSent: estimatedQueryBytes(request),
            dataClasses: ["search_query"],
            details: details
        )
    }

    /// Hosts for the bundled native scrapers; declarative providers carry
    /// their endpoint URL in the definition.
    static func host(for definition: SearchProviderDefinition, category: String) -> String? {
        switch definition.runtime {
        case .native:
            switch definition.id {
            case "ddg": return "html.duckduckgo.com"
            case "brave_html": return "search.brave.com"
            case "bing_html": return "www.bing.com"
            default: return nil
            }
        case .declarative:
            let endpoint = definition.endpoints?[category] ?? definition.endpoints?.values.first
            return endpoint.flatMap { EgressInfo.host(from: $0.url) }
        }
    }

    static var hostedHost: String { OsaurusRouter.defaultBaseURL.host ?? "router.osaurus.ai" }

    static func providerLabel(_ providerId: String, host: String?) -> String {
        if providerId == OsaurusRouterSearchBackend.providerId { return L("Osaurus Router") }
        if let host, let known = InsightsService.knownHostLabels.first(where: { host.hasSuffix($0.key) }) {
            return known.value
        }
        return providerId
    }

    /// Rough size of what a search sends: the query plus filters. Good enough
    /// for the "bytes sent" roll-up; exact wire sizes are not available for
    /// the scraper backends.
    static func estimatedQueryBytes(_ request: SearchRequest) -> Int {
        var n = request.query.utf8.count
        if let s = request.site { n += s.utf8.count }
        if let f = request.filetype { n += f.utf8.count }
        if let t = request.timeRange { n += t.utf8.count }
        if let r = request.region { n += r.utf8.count }
        return n
    }

    static func logSearch(
        request: SearchRequest,
        outcome: SearchEngineOutcome,
        hostedSource: WebSearchSource?,
        hostedFallbackReason: String?,
        pinned: Bool,
        attribution: InsightsService.ActivityAttribution,
        hostFor: (String) -> String?
    ) {
        let egress = searchEgress(
            request: request,
            outcome: outcome,
            hostedSource: hostedSource,
            hostedFallbackReason: hostedFallbackReason,
            pinned: pinned,
            hostFor: hostFor
        )
        let failed = outcome.hits.isEmpty && outcome.attempts.contains { !$0.ok }
        InsightsService.logEgress(
            category: .webSearch,
            method: "SEARCH",
            path: "/search/\(request.category)",
            statusCode: failed ? 502 : 200,
            durationMs: outcome.elapsed * 1000,
            egress: egress,
            errorMessage: failed ? egress.details["failures"] : nil,
            attribution: attribution
        )
    }

    // MARK: - URL extraction

    /// Hosted (Router) contents batch: all URLs in one request to the Router.
    static func hostedExtractEgress(urls: [String], outcome: HostedContentsOutcome?, failureReason: String?) -> EgressInfo {
        var details: [String: String] = [
            "mode": "hosted",
            "urls": urls.joined(separator: "\n"),
            "url_count": String(urls.count),
        ]
        if let outcome {
            details["succeeded"] = String(outcome.pages.filter(\.succeeded).count)
            details["replayed"] = outcome.replayed ? "true" : "false"
            let failed = outcome.pages.filter { !$0.succeeded }
            if !failed.isEmpty {
                details["failures"] = failed.map { "\($0.url): \($0.error ?? "failed")" }.joined(separator: " | ")
            }
        }
        if let failureReason { details["error"] = failureReason }
        return EgressInfo(
            destinationLabel: L("Osaurus Router"),
            destinationHost: hostedHost,
            bytesSent: urls.reduce(0) { $0 + $1.utf8.count },
            bytesReceived: outcome?.pages.reduce(0) { $0 + ($1.text?.utf8.count ?? 0) },
            dataClasses: ["urls"],
            details: details
        )
    }

    static func logHostedExtract(
        urls: [String],
        outcome: HostedContentsOutcome?,
        failureReason: String?,
        durationMs: Double,
        attribution: InsightsService.ActivityAttribution
    ) {
        InsightsService.logEgress(
            category: .urlExtract,
            method: "EXTRACT",
            path: "/contents",
            statusCode: failureReason == nil ? 200 : 502,
            durationMs: durationMs,
            egress: hostedExtractEgress(urls: urls, outcome: outcome, failureReason: failureReason),
            errorMessage: failureReason,
            attribution: attribution
        )
    }

    /// Direct page fetch from this Mac (Readability path). The destination
    /// is the page's own host — that site sees our request.
    static func directExtractEgress(url: String, extraction: SearchReadability.Extraction, bytesReceived: Int?) -> EgressInfo {
        var details: [String: String] = [
            "mode": "direct",
            "urls": url,
            "status": extraction.status.rawValue,
            "word_count": String(extraction.wordCount),
        ]
        if let title = extraction.title, !title.isEmpty { details["title"] = title }
        if let canonical = extraction.canonicalURL, canonical != url { details["canonical_url"] = canonical }
        if let format = extraction.structuredFormat { details["format"] = format }
        if let message = extraction.message { details["message"] = message }
        let host = EgressInfo.host(from: url)
        return EgressInfo(
            destinationLabel: host,
            destinationHost: host,
            bytesSent: url.utf8.count,
            bytesReceived: bytesReceived,
            dataClasses: ["urls"],
            details: details
        )
    }

    static func logDirectExtract(
        url: String,
        extraction: SearchReadability.Extraction,
        bytesReceived: Int?,
        durationMs: Double,
        attribution: InsightsService.ActivityAttribution
    ) {
        let failed = !extraction.extracted && extraction.status != .cancelled
        InsightsService.logEgress(
            category: .urlExtract,
            method: "GET",
            path: URL(string: url)?.path.isEmpty == false ? URL(string: url)!.path : "/",
            statusCode: extraction.extracted ? 200 : (extraction.status == .cancelled ? 499 : 502),
            durationMs: durationMs,
            egress: directExtractEgress(url: url, extraction: extraction, bytesReceived: bytesReceived),
            errorMessage: failed ? (extraction.message ?? extraction.status.rawValue) : nil,
            attribution: attribution
        )
    }
}
