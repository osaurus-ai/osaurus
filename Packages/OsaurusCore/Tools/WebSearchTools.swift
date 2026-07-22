//
//  WebSearchTools.swift
//  osaurus
//
//  Native web-search tool surface — exactly two tools, tuned for both local
//  and frontier callers:
//
//    - `web_search` — always-loaded baseline built-in. One required param
//      (`query`); optional `category` whose enum is generated from what the
//      user's enabled providers actually support (omitted entirely when only
//      web search is available).
//    - `search_and_extract` — dynamic built-in (loaded via capabilities);
//      search plus Readability extraction of the top results.
//
//  Weak-caller contract: never fail the call over a malformed argument.
//  Unknown categories fall back to web with a warning, string numbers are
//  accepted, time-range variants are normalized, unknown fields are ignored.
//

import Foundation

// MARK: - Shared argument sanitization

enum WebSearchArgs {
    /// Canonicalize a time-range value: "d"/"day" -> "d", "week" -> "w", etc.
    /// Invalid values return nil and append a warning.
    static func sanitizeTimeRange(_ raw: Any?, warnings: inout [String]) -> String? {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty
        else { return nil }
        switch s {
        case "d", "day": return "d"
        case "w", "week": return "w"
        case "m", "month": return "m"
        case "y", "year": return "y"
        default:
            warnings.append("Ignored invalid time_range '\(s)'; expected d, w, m, or y.")
            return nil
        }
    }

    /// Validate a region code ("xx-yy"). Invalid values return nil + warning.
    static func sanitizeRegion(_ raw: Any?, warnings: inout [String]) -> String? {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.range(of: "^[A-Za-z]{2}-[A-Za-z]{2}$", options: .regularExpression) != nil {
            return s.lowercased()
        }
        warnings.append("Ignored invalid region '\(s)'; expected format 'xx-yy' (e.g. 'us-en').")
        return nil
    }

    /// Resolve a requested category against what's actually available.
    /// Unknown categories fall back to web with a warning instead of erroring.
    static func sanitizeCategory(
        _ raw: Any?,
        available: [String],
        warnings: inout [String]
    ) -> String {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty
        else { return SearchCategory.web }
        if available.contains(s) { return s }
        // Common synonyms local models produce.
        let synonyms: [String: String] = [
            "websearch": SearchCategory.web, "general": SearchCategory.web,
            "article": SearchCategory.news, "articles": SearchCategory.news,
            "image": SearchCategory.images, "img": SearchCategory.images,
            "photo": SearchCategory.images, "photos": SearchCategory.images,
        ]
        if let mapped = synonyms[s], available.contains(mapped) { return mapped }
        warnings.append(
            "Ignored unknown category '\(s)'; searched the web instead. "
                + "Available: \(available.joined(separator: ", "))."
        )
        return SearchCategory.web
    }

    static func optionalTrimmedString(_ raw: Any?) -> String? {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty
        else { return nil }
        return s
    }
}

// MARK: - Result formatting

enum WebSearchResultFormatter {
    /// Cap snippet length so local models don't drown in tokens; frontier
    /// callers still get the full structure.
    static let maxSnippetLength = 400

    static func resultsPayload(
        request: SearchRequest,
        outcome: SearchEngineOutcome
    ) -> [String: Any] {
        let candidateURLs = outcome.hits.prefix(3).map(\.url).filter { !$0.isEmpty }
        var out: [String: Any] = [
            "query": request.query,
            "category": request.category,
            "provider": outcome.provider ?? "",
            "next_action": [
                "tool": "search_and_extract",
                "instruction":
                    "Pass a selected result URL in `url` to retrieve its actual page text or raw CSV/JSON before processing or charting it. Do not rephrase the discovery query.",
                "candidate_urls": candidateURLs,
            ],
            "results": outcome.hits.enumerated().map { index, hit -> [String: Any] in
                var d = hit.toDict(rank: index + 1)
                if let snippet = d["snippet"] as? String, snippet.count > maxSnippetLength {
                    d["snippet"] = String(snippet.prefix(maxSnippetLength)) + "…"
                }
                return d
            },
            "count": outcome.hits.count,
        ]
        if outcome.hits.count == request.maxResults {
            out["next_offset"] = request.offset + request.maxResults
        }
        return out
    }

    /// Stamp the source classification (premium / custom / free) and hosted
    /// fallback state onto a success payload so the tool-call UI and logs can
    /// distinguish who served the results. Billing detail stays out of the
    /// model-facing payload — the Credits UI reads it from the account service.
    static func applySourceMetadata(_ payload: inout [String: Any], run: HostedFirstSearchResult) {
        payload["search_source"] = run.source.rawValue
        if let reason = run.hostedFallbackReason {
            payload["premium_fallback"] = reason
        }
    }

    /// Actionable hint for a NO_RESULTS failure — differs depending on
    /// whether any API provider is configured, since "add a provider" is
    /// useless advice when the user already has one and it just failed.
    static func noResultsHint(hasConfiguredAPIProvider: Bool) -> String {
        if hasConfiguredAPIProvider {
            return
                "Tried the configured providers and built-in fallbacks. Try a broader query, "
                + "or check in Settings → Search that the API keys are still valid."
        }
        return
            "Try a broader query or drop site:/filetype:/time_range. For better results, "
            + "add a search provider in Settings → Search."
    }

    static func noResultsFailure(
        tool: String,
        request: SearchRequest,
        outcome: SearchEngineOutcome,
        warnings: [String],
        hasConfiguredAPIProvider: Bool
    ) -> String {
        var metadata: [String: Any] = [
            "query": request.query,
            "attempts": outcome.attempts.map { $0.toDict() },
            "hint": noResultsHint(hasConfiguredAPIProvider: hasConfiguredAPIProvider),
        ]
        if !warnings.isEmpty { metadata["warnings"] = warnings }
        return ToolEnvelope.failure(
            kind: .notFound,
            message: "No results from any search provider.",
            tool: tool,
            retryable: true,
            metadata: metadata
        )
    }
}

// MARK: - web_search

final class WebSearchTool: OsaurusTool, @unchecked Sendable {
    let name = "web_search"
    let description =
        "Discover relevant web sources. Just pass `query`; results come from the user's "
        + "configured search providers with automatic fallback. Returns ranked titles, URLs, "
        + "and snippets only — it does not fetch page bodies or downloadable data. Once you "
        + "select a source, retrieve its content with `search_and_extract`; if that tool is not "
        + "loaded and `capabilities_load` is available, load `tool/search_and_extract`. Do not "
        + "keep rephrasing `web_search` when you need source content."

    var parameters: JSONValue? {
        var properties: [String: JSONValue] = [
            "query": .object([
                "type": .string("string"),
                "description": .string("Plain-language search query."),
            ]),
            "max_results": .object([
                "type": .string("integer"),
                "description": .string("How many results (1-50). Default 10."),
            ]),
            "time_range": .object([
                "type": .string("string"),
                "enum": .array([.string("d"), .string("w"), .string("m"), .string("y")]),
                "description": .string("Recency: d=day, w=week, m=month, y=year. Omit for any time."),
            ]),
            "site": .object([
                "type": .string("string"),
                "description": .string("Restrict to a domain (e.g. 'arxiv.org')."),
            ]),
            "filetype": .object([
                "type": .string("string"),
                "description": .string("Restrict to a file type (e.g. 'pdf')."),
            ]),
            "offset": .object([
                "type": .string("integer"),
                "description": .string("Pagination offset. Default 0."),
            ]),
            "region": .object([
                "type": .string("string"),
                "description": .string("Region code 'xx-yy' (e.g. 'us-en'). Omit for global."),
            ]),
        ]
        // Only advertise `category` when the user's providers support more
        // than plain web search — keeps the minimal schema minimal.
        let categories = SearchToolSchemaState.availableCategories()
        if categories.count > 1 {
            properties["category"] = .object([
                "type": .string("string"),
                "enum": .array(categories.map { .string($0) }),
                "description": .string(
                    "What to search: \(categories.joined(separator: " | ")). Default web."
                ),
            ])
        }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let queryReq = requireString(args, "query", expected: "non-empty search query", tool: name)
        guard case .value(let queryRaw) = queryReq else { return queryReq.failureEnvelope ?? "" }
        let query = queryRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Argument `query` must not be whitespace-only.",
                field: "query",
                expected: "non-empty search query",
                tool: name
            )
        }

        var warnings: [String] = []
        let available = await SearchProviderManager.shared.availableCategories()
        let category = WebSearchArgs.sanitizeCategory(
            args["category"],
            available: available,
            warnings: &warnings
        )
        let timeRange = WebSearchArgs.sanitizeTimeRange(args["time_range"], warnings: &warnings)
        let region = WebSearchArgs.sanitizeRegion(args["region"], warnings: &warnings)
        let maxCap = category == SearchCategory.images ? 100 : 50
        let defaultMax = category == SearchCategory.images ? 20 : 10
        let maxResults = max(1, min(ArgumentCoercion.int(args["max_results"]) ?? defaultMax, maxCap))
        let offset = max(0, ArgumentCoercion.int(args["offset"]) ?? 0)

        let request = SearchRequest(
            query: query,
            category: category,
            maxResults: maxResults,
            offset: offset,
            site: WebSearchArgs.optionalTrimmedString(args["site"]),
            filetype: WebSearchArgs.optionalTrimmedString(args["filetype"]),
            // News defaults to the last week so stale results don't read as news.
            timeRange: timeRange ?? (category == SearchCategory.news ? "w" : nil),
            region: region
        )

        // One stable idempotency key per logical tool call: hosted retries of
        // this call can never double-charge or double-consume a free slot.
        let idempotencyKey = UUID().uuidString
        let run = await SearchProviderManager.shared.runHostedFirstSearch(
            request, idempotencyKey: idempotencyKey)
        let outcome = run.outcome
        if outcome.hits.isEmpty {
            let hasAPIProvider = await SearchProviderManager.shared.hasConfiguredAPIProvider
            return WebSearchResultFormatter.noResultsFailure(
                tool: name,
                request: request,
                outcome: outcome,
                warnings: warnings,
                hasConfiguredAPIProvider: hasAPIProvider
            )
        }
        var payload = WebSearchResultFormatter.resultsPayload(request: request, outcome: outcome)
        WebSearchResultFormatter.applySourceMetadata(&payload, run: run)
        return ToolEnvelope.success(
            tool: name,
            result: payload,
            warnings: warnings.isEmpty ? nil : warnings
        )
    }
}

// MARK: - search_and_extract

final class SearchAndExtractTool: OsaurusTool, @unchecked Sendable {
    private static let inlineStructuredCharacterLimit = 8_000

    let name = "search_and_extract"
    let description =
        "Fetch a specific URL and return its actual page text or data, preserving raw CSV/TSV/JSON. "
        + "Large structured data is returned as a compact `data_ref` with an exact `render_chart` "
        + "next action so the raw payload moves tool-to-tool without flooding the model context. "
        + "After `web_search`, pass the selected result's URL in `url`; do not search for the "
        + "URL as a query. If no URL is known, `query` can search and extract top results in "
        + "one step."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string(
                    "Plain-language search query. Use only when no source URL is known."
                ),
            ]),
            "url": .object([
                "type": .string("string"),
                "description": .string(
                    "Direct http(s) source URL to fetch. Preferred after web_search."
                ),
            ]),
            "urls": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "maxItems": .number(5),
                "description": .string("Up to 5 direct http(s) source URLs to fetch."),
            ]),
            "max_results": .object([
                "type": .string("integer"),
                "description": .string("How many search results (1-20). Default 5."),
            ]),
            "extract_count": .object([
                "type": .string("integer"),
                "description": .string("How many of the top results to extract. Default 3."),
            ]),
            "time_range": .object([
                "type": .string("string"),
                "enum": .array([.string("d"), .string("w"), .string("m"), .string("y")]),
                "description": .string("Recency filter."),
            ]),
            "site": .object([
                "type": .string("string"),
                "description": .string("Restrict to a domain."),
            ]),
            "filetype": .object([
                "type": .string("string"),
                "description": .string("Restrict to a file type."),
            ]),
            "timeout": .object([
                "type": .string("number"),
                "description": .string("Per-page extraction timeout in seconds. Default 25."),
            ]),
        ]),
        "additionalProperties": .bool(false),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        var directURLs: [String] = []
        if let url = WebSearchArgs.optionalTrimmedString(args["url"]) {
            directURLs.append(url)
        }
        if let urls = args["urls"] as? [Any] {
            directURLs.append(contentsOf: urls.compactMap(WebSearchArgs.optionalTrimmedString))
        }
        var seenURLs: Set<String> = []
        directURLs = Array(
            directURLs.filter { seenURLs.insert($0).inserted }.prefix(5)
        )

        let query = WebSearchArgs.optionalTrimmedString(args["query"])
        guard !directURLs.isEmpty || query != nil else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Provide a direct `url`/`urls` value or a non-empty `query`.",
                expected: "url, urls, or query",
                tool: name
            )
        }

        let timeout: TimeInterval = {
            if let n = args["timeout"] as? NSNumber { return n.doubleValue }
            if let s = args["timeout"] as? String, let d = Double(s) { return d }
            return 25
        }()

        if !directURLs.isEmpty {
            // Hosted extraction first when premium search is on. Raw
            // CSV/TSV/JSON endpoints stay local: the structured-data pipeline
            // (data_refs, render_chart handoff) needs the untouched payload,
            // which hosted extraction does not preserve.
            var hostedTexts: [String: (title: String?, text: String)] = [:]
            if !directURLs.contains(where: Self.looksLikeStructuredData) {
                let idempotencyKey = UUID().uuidString
                if let hosted = await SearchProviderManager.shared.hostedExtract(
                    urls: directURLs, idempotencyKey: idempotencyKey)
                {
                    // Only pages that actually returned content were billed;
                    // failed URLs fall back to local Readability per URL.
                    for page in hosted.pages where page.succeeded {
                        if let text = page.text, !text.isEmpty {
                            hostedTexts[page.url.lowercased()] = (page.title, text)
                        }
                    }
                }
            }
            let hits = directURLs.map {
                SearchHit(title: $0, url: $0, snippet: "", engine: "direct_url")
            }
            let results = await enrichedResults(
                hits: hits,
                extractCount: directURLs.count,
                timeout: timeout,
                hostedTexts: hostedTexts
            )
            var payload: [String: Any] = [
                "mode": "direct_url",
                "provider": "direct_url",
                "results": results,
            ]
            if !hostedTexts.isEmpty {
                payload["extract_source"] = "premium"
            }
            return ToolEnvelope.success(tool: name, result: payload)
        }

        var warnings: [String] = []
        let timeRange = WebSearchArgs.sanitizeTimeRange(args["time_range"], warnings: &warnings)
        let maxResults = max(1, min(ArgumentCoercion.int(args["max_results"]) ?? 5, 20))
        let extractCount = max(1, min(ArgumentCoercion.int(args["extract_count"]) ?? 3, maxResults))
        let request = SearchRequest(
            query: query ?? "",
            category: SearchCategory.web,
            maxResults: maxResults,
            site: WebSearchArgs.optionalTrimmedString(args["site"]),
            filetype: WebSearchArgs.optionalTrimmedString(args["filetype"]),
            timeRange: timeRange
        )

        // Query mode rides a single billed hosted request: search plus text
        // extraction in one call (spec section 3), falling back to the local
        // cascade + Readability when the hosted attempt cannot serve it.
        let idempotencyKey = UUID().uuidString
        let run = await SearchProviderManager.shared.runHostedFirstSearch(
            request,
            idempotencyKey: idempotencyKey,
            extractTextMaxCharacters: SearchReadability.maxMarkdownCharacters
        )
        let outcome = run.outcome
        if outcome.hits.isEmpty {
            let hasAPIProvider = await SearchProviderManager.shared.hasConfiguredAPIProvider
            return WebSearchResultFormatter.noResultsFailure(
                tool: name,
                request: request,
                outcome: outcome,
                warnings: warnings,
                hasConfiguredAPIProvider: hasAPIProvider
            )
        }

        var payload = WebSearchResultFormatter.resultsPayload(request: request, outcome: outcome)
        payload.removeValue(forKey: "next_action")
        payload["mode"] = "search_and_extract"
        payload["results"] = await enrichedResults(
            hits: outcome.hits,
            extractCount: extractCount,
            timeout: timeout,
            hostedTexts: run.hostedTextByURL.mapValues { (title: String?.none, text: $0) }
        )
        WebSearchResultFormatter.applySourceMetadata(&payload, run: run)

        return ToolEnvelope.success(
            tool: name,
            result: payload,
            warnings: warnings.isEmpty ? nil : warnings
        )
    }

    /// Raw structured-data endpoints (CSV/TSV/JSON) must be extracted locally
    /// so the data_ref/render_chart pipeline gets the untouched payload.
    static func looksLikeStructuredData(_ url: String) -> Bool {
        guard let parsed = URL(string: url) else { return false }
        return ["csv", "tsv", "json"].contains(parsed.pathExtension.lowercased())
    }

    private func enrichedResults(
        hits: [SearchHit],
        extractCount: Int,
        timeout: TimeInterval,
        hostedTexts: [String: (title: String?, text: String)] = [:]
    ) async -> [[String: Any]] {
        var enriched: [[String: Any]] = []
        for (index, hit) in hits.enumerated() {
            var entry = hit.toDict(rank: index + 1)
            let shouldExtract = index < extractCount && !hit.url.isEmpty && !Task.isCancelled
            // Hosted-extracted pages skip the local fetch entirely; structured
            // endpoints never use hosted text (see `looksLikeStructuredData`).
            if shouldExtract,
                !Self.looksLikeStructuredData(hit.url),
                let hosted = hostedTexts[hit.url.lowercased()],
                !hosted.text.isEmpty
            {
                if let title = hosted.title, !title.isEmpty { entry["title"] = title }
                let (text, truncated) = SearchDiagnostics.truncate(
                    hosted.text, maxCharacters: SearchReadability.maxMarkdownCharacters)
                entry["extract_status"] = SearchExtractionStatus.ok.rawValue
                entry["extracted"] = true
                entry["extract_source"] = "premium"
                entry["markdown"] = text
                entry["truncated"] = truncated
                entry["word_count"] = text.split(whereSeparator: \.isWhitespace).count
                enriched.append(entry)
                continue
            }
            if shouldExtract {
                let extraction = await SearchReadability.extract(url: hit.url, timeout: timeout)
                if let title = extraction.title, !title.isEmpty { entry["title"] = title }
                if let canonicalURL = extraction.canonicalURL, !canonicalURL.isEmpty {
                    entry["canonical_url"] = canonicalURL
                }
                entry["extract_status"] = extraction.status.rawValue
                entry["word_count"] = extraction.wordCount
                if let total = extraction.totalWordCount {
                    entry["word_count_total"] = total
                }
                entry["extracted"] = extraction.extracted
                if extraction.extracted {
                    if let structuredData = extraction.structuredData,
                        let structuredFormat = extraction.structuredFormat,
                        structuredData.count > Self.inlineStructuredCharacterLimit,
                        let dataRef = await SearchStructuredDataStore.shared.store(
                            raw: structuredData,
                            format: structuredFormat,
                            sourceURL: extraction.canonicalURL ?? hit.url,
                            sessionId: ChatExecutionContext.currentSessionId
                        )
                    {
                        entry["data_ref"] = dataRef
                        entry["format"] = structuredFormat
                        entry["character_count"] = structuredData.count
                        entry["content_omitted_from_prompt"] = true
                        entry["truncated"] = false

                        if structuredFormat == "json" {
                            let descriptors = SearchStructuredDataInspector.jsonArrayDescriptors(
                                structuredData
                            )
                            entry["structure"] = descriptors.map(\.payload)
                            if let suggestion = SearchStructuredDataInspector.suggestedJSONChart(
                                descriptors: descriptors
                            ) {
                                entry["next_action"] = [
                                    "tool": "render_chart",
                                    "arguments": suggestion.toolArguments(
                                        dataRef: dataRef,
                                        title: entry["title"] as? String
                                    ),
                                    "instruction":
                                        "Call render_chart with these arguments; it reads the raw data_ref directly. Do not copy the raw payload through the model.",
                                ]
                            }
                        } else {
                            let separator: Character = structuredFormat == "tsv" ? "\t" : ","
                            let metadata = SearchStructuredDataInspector.delimitedMetadata(
                                structuredData,
                                separator: separator,
                                format: structuredFormat,
                                dataRef: dataRef
                            )
                            entry["columns"] = metadata.columns
                            entry["row_count"] = metadata.rowCount
                            if let nextAction = metadata.nextAction {
                                entry["next_action"] = nextAction
                            }
                        }
                    } else {
                        entry["markdown"] = extraction.markdown
                        entry["truncated"] = extraction.truncated
                    }
                    if let byline = extraction.byline { entry["byline"] = byline }
                    if let lang = extraction.lang { entry["lang"] = lang }
                } else if let message = extraction.message, !message.isEmpty {
                    entry["extract_error"] = message
                }
            } else {
                entry["extracted"] = false
                if Task.isCancelled { entry["extract_status"] = SearchExtractionStatus.cancelled.rawValue }
            }
            enriched.append(entry)
        }
        return enriched
    }
}
