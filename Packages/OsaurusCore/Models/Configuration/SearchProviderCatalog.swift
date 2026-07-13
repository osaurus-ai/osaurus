//
//  SearchProviderCatalog.swift
//  osaurus
//
//  Bundled search-provider definitions. These use the exact same declarative
//  schema as user-created custom providers — no privileged built-in path.
//  Request/response mappings are ported from the osaurus.search plugin's
//  hand-written backends.
//

import Foundation

public enum SearchProviderCatalog {
    /// Definition ids of the keyless native scrapers seeded by default.
    /// DDG is deliberately last: its anti-bot layer serves decoy results
    /// (`lastResort` on its definition demotes it inside the race too).
    public static let freeProviderIds: [String] = ["brave_html", "bing_html", "ddg"]

    /// Canonical time-range codes accepted by the tools layer.
    static let canonicalTimeRanges: Set<String> = ["d", "w", "m", "y"]

    /// Every bundled definition (API providers first, then free scrapers).
    public static let bundled: [SearchProviderDefinition] = apiProviders + nativeProviders

    public static func definition(id: String) -> SearchProviderDefinition? {
        bundled.first { $0.id == id }
    }

    // MARK: - API providers (declarative)

    public static let apiProviders: [SearchProviderDefinition] = [
        tavily, exa, braveAPI, serper, parallel, googleCSE, kagi, you,
    ]

    static let tavily = SearchProviderDefinition(
        id: "tavily",
        name: "Tavily",
        summary: L("Search built for AI agents — best answer quality for grounding."),
        pricingNote: L("Free: 1,000 searches/month"),
        instructions: [
            L("Sign up at tavily.com (free, no credit card)."),
            L("Copy the API key that starts with tvly- from your dashboard."),
            L("Paste it below."),
        ],
        signupURL: "https://app.tavily.com",
        homepage: "https://tavily.com",
        recommended: true,
        secrets: [
            SearchSecretField(
                id: "api_key",
                label: L("Tavily API key"),
                help: L("Starts with tvly-"),
                url: "https://app.tavily.com"
            )
        ],
        endpoints: [
            SearchCategory.web: tavilyEndpoint(topic: "general"),
            SearchCategory.news: tavilyEndpoint(topic: "news"),
        ]
    )

    private static func tavilyEndpoint(topic: String) -> SearchEndpoint {
        SearchEndpoint(
            url: "https://api.tavily.com/search",
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer {{secret.api_key}}",
            ],
            body: [
                SearchRequestParam(name: "query", value: "{{query}}"),
                SearchRequestParam(name: "max_results", value: "{{max_results}}", type: "int"),
                SearchRequestParam(name: "search_depth", value: "basic"),
                SearchRequestParam(name: "topic", value: topic),
                SearchRequestParam(
                    name: "time_range",
                    value: "{{time_range}}",
                    omitIfEmpty: true,
                    map: ["d": "day", "w": "week", "m": "month", "y": "year"]
                ),
            ],
            response: SearchResponseMapping(
                resultsPath: "results",
                item: SearchHitFieldPaths(
                    title: "title",
                    url: "url",
                    snippet: "content",
                    publishedDate: "published_date"
                )
            )
        )
    }

    static let exa = SearchProviderDefinition(
        id: "exa",
        name: "Exa",
        summary: L("Neural search built for AI agents, with key excerpts per result."),
        pricingNote: L("Free: 1,000 searches/month"),
        instructions: [
            L("Sign up at dashboard.exa.ai (free)."),
            L("Copy an API key from the API Keys page."),
            L("Paste it below."),
        ],
        signupURL: "https://dashboard.exa.ai/api-keys",
        homepage: "https://exa.ai",
        recommended: true,
        secrets: [
            SearchSecretField(
                id: "api_key",
                label: L("Exa API key"),
                url: "https://dashboard.exa.ai/api-keys"
            )
        ],
        endpoints: [
            SearchCategory.web: exaEndpoint(category: nil),
            SearchCategory.news: exaEndpoint(category: "news"),
        ]
    )

    private static func exaEndpoint(category: String?) -> SearchEndpoint {
        var body: [SearchRequestParam] = [
            SearchRequestParam(name: "query", value: "{{query}}"),
            SearchRequestParam(name: "type", value: "auto"),
            SearchRequestParam(name: "numResults", value: "{{max_results}}", type: "int"),
            // Highlights give each hit LLM-ready excerpt snippets without the
            // cost of full-text contents.
            SearchRequestParam(name: "contents", value: "{\"highlights\": true}", type: "json"),
            SearchRequestParam(name: "startPublishedDate", value: "{{after_date}}", omitIfEmpty: true),
        ]
        if let category {
            body.append(SearchRequestParam(name: "category", value: category))
        }
        return SearchEndpoint(
            url: "https://api.exa.ai/search",
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "x-api-key": "{{secret.api_key}}",
            ],
            body: body,
            response: SearchResponseMapping(
                resultsPath: "results",
                item: SearchHitFieldPaths(
                    title: "title",
                    url: "url",
                    snippet: "highlights|text|summary",
                    publishedDate: "publishedDate"
                )
            )
        )
    }

    static let parallel = SearchProviderDefinition(
        id: "parallel",
        name: "Parallel",
        summary: L("Ranked results with dense LLM-ready excerpts from Parallel Web Systems."),
        pricingNote: L("Paid: $5 per 1,000 searches"),
        instructions: [
            L("Sign up at platform.parallel.ai."),
            L("Create an API key from the settings page."),
            L("Paste it below."),
        ],
        signupURL: "https://platform.parallel.ai",
        homepage: "https://parallel.ai",
        secrets: [
            SearchSecretField(
                id: "api_key",
                label: L("Parallel API key"),
                url: "https://platform.parallel.ai"
            )
        ],
        endpoints: [
            SearchCategory.web: SearchEndpoint(
                url: "https://api.parallel.ai/v1/search",
                method: "POST",
                headers: [
                    "Content-Type": "application/json",
                    "x-api-key": "{{secret.api_key}}",
                ],
                body: [
                    // `search_queries` is required and must be an array.
                    SearchRequestParam(name: "search_queries", value: "{{query}}", type: "string_array"),
                    SearchRequestParam(name: "objective", value: "{{raw_query}}"),
                    SearchRequestParam(name: "mode", value: "basic"),
                ],
                response: SearchResponseMapping(
                    resultsPath: "results",
                    item: SearchHitFieldPaths(
                        title: "title",
                        url: "url",
                        snippet: "excerpts",
                        publishedDate: "publish_date"
                    )
                )
            )
        ]
    )

    static let braveAPI = SearchProviderDefinition(
        id: "brave_api",
        name: L("Brave Search"),
        summary: L("Independent search index via the official Brave API."),
        pricingNote: L("Paid: $5 per 1,000 queries (card required)"),
        instructions: [
            L("Sign up at api.search.brave.com (a credit card is required; new accounts get a small starting credit)."),
            L("Create an API key under API Keys."),
            L("Paste it below."),
        ],
        signupURL: "https://api.search.brave.com",
        homepage: "https://brave.com/search/api/",
        secrets: [
            SearchSecretField(
                id: "api_key",
                label: L("Brave Search API key"),
                url: "https://api.search.brave.com"
            )
        ],
        endpoints: [
            SearchCategory.web: braveEndpoint(
                url: "https://api.search.brave.com/res/v1/web/search",
                resultsPath: "web.results"
            ),
            SearchCategory.news: braveEndpoint(
                url: "https://api.search.brave.com/res/v1/news/search",
                resultsPath: "results"
            ),
        ]
    )

    private static func braveEndpoint(url: String, resultsPath: String) -> SearchEndpoint {
        SearchEndpoint(
            url: url,
            headers: [
                "X-Subscription-Token": "{{secret.api_key}}",
                "Accept": "application/json",
            ],
            query: [
                SearchRequestParam(name: "q", value: "{{query}}"),
                SearchRequestParam(name: "count", value: "{{max_results}}"),
                SearchRequestParam(name: "offset", value: "{{offset}}"),
                SearchRequestParam(
                    name: "freshness",
                    value: "{{time_range}}",
                    omitIfEmpty: true,
                    map: ["d": "pd", "w": "pw", "m": "pm", "y": "py"]
                ),
            ],
            response: SearchResponseMapping(
                resultsPath: resultsPath,
                item: SearchHitFieldPaths(
                    title: "title",
                    url: "url",
                    snippet: "description",
                    publishedDate: "page_age|age"
                )
            )
        )
    }

    static let serper = SearchProviderDefinition(
        id: "serper",
        name: "Serper",
        summary: L("Google results via API — fast and cheap."),
        pricingNote: L("Free: 2,500 queries to start"),
        instructions: [
            L("Sign up at serper.dev."),
            L("Copy your API key from the dashboard."),
            L("Paste it below."),
        ],
        signupURL: "https://serper.dev",
        homepage: "https://serper.dev",
        secrets: [
            SearchSecretField(id: "api_key", label: "Serper API key", url: "https://serper.dev")
        ],
        endpoints: [
            SearchCategory.web: serperEndpoint(
                url: "https://google.serper.dev/search",
                resultsPath: "organic"
            ),
            SearchCategory.news: serperEndpoint(
                url: "https://google.serper.dev/news",
                resultsPath: "news"
            ),
            // Google Images through the same API — gives image search a
            // keyed, trustworthy option (the only free image source is the
            // last-resort DDG scraper).
            SearchCategory.images: serperEndpoint(
                url: "https://google.serper.dev/images",
                resultsPath: "images",
                item: SearchHitFieldPaths(
                    title: "title",
                    url: "link",
                    snippet: "source",
                    sourceDomain: "domain|source",
                    imageURL: "imageUrl",
                    thumbnailURL: "thumbnailUrl"
                )
            ),
        ]
    )

    private static func serperEndpoint(
        url: String,
        resultsPath: String,
        item: SearchHitFieldPaths? = nil
    ) -> SearchEndpoint {
        SearchEndpoint(
            url: url,
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "X-API-KEY": "{{secret.api_key}}",
            ],
            body: [
                SearchRequestParam(name: "q", value: "{{query}}"),
                SearchRequestParam(name: "num", value: "{{max_results}}", type: "int"),
                SearchRequestParam(name: "page", value: "{{page}}", type: "int"),
                SearchRequestParam(
                    name: "tbs",
                    value: "{{time_range}}",
                    omitIfEmpty: true,
                    map: ["d": "qdr:d", "w": "qdr:w", "m": "qdr:m", "y": "qdr:y"]
                ),
            ],
            response: SearchResponseMapping(
                resultsPath: resultsPath,
                item: item
                    ?? SearchHitFieldPaths(
                        title: "title",
                        url: "link",
                        snippet: "snippet",
                        publishedDate: "date",
                        sourceDomain: "source"
                    )
            )
        )
    }

    static let googleCSE = SearchProviderDefinition(
        id: "google_cse",
        name: L("Google (Custom Search)"),
        summary: L("Official Google API. Needs two values — about 5 minutes to set up."),
        pricingNote: L("Free: 100 queries/day"),
        instructions: [
            L("Create a Programmable Search Engine at programmablesearchengine.google.com (enable \"Search the entire web\")."),
            L("Copy the Search engine ID (cx) from its settings."),
            L("Get an API key from the Custom Search JSON API page in Google Cloud."),
            L("Paste both values below."),
        ],
        signupURL: "https://programmablesearchengine.google.com/",
        homepage: "https://developers.google.com/custom-search/v1/introduction",
        secrets: [
            SearchSecretField(
                id: "api_key",
                label: L("Google API key"),
                url: "https://developers.google.com/custom-search/v1/introduction"
            ),
            SearchSecretField(
                id: "cx",
                label: L("Search engine ID (cx)"),
                help: L("From your Programmable Search Engine settings"),
                url: "https://programmablesearchengine.google.com/"
            ),
        ],
        endpoints: [
            SearchCategory.web: googleCSEEndpoint(),
            SearchCategory.news: googleCSEEndpoint(),
        ]
    )

    private static func googleCSEEndpoint() -> SearchEndpoint {
        SearchEndpoint(
            url: "https://www.googleapis.com/customsearch/v1",
            headers: ["Accept": "application/json"],
            query: [
                SearchRequestParam(name: "key", value: "{{secret.api_key}}"),
                SearchRequestParam(name: "cx", value: "{{secret.cx}}"),
                SearchRequestParam(name: "q", value: "{{query}}"),
                SearchRequestParam(name: "num", value: "{{max_results}}", clampMax: 10),
                SearchRequestParam(name: "start", value: "{{start}}"),
                SearchRequestParam(
                    name: "dateRestrict",
                    value: "{{time_range}}",
                    omitIfEmpty: true,
                    map: ["d": "d1", "w": "w1", "m": "m1", "y": "y1"]
                ),
            ],
            response: SearchResponseMapping(
                resultsPath: "items",
                item: SearchHitFieldPaths(
                    title: "title",
                    url: "link",
                    snippet: "snippet",
                    sourceDomain: "displayLink"
                )
            )
        )
    }

    static let kagi = SearchProviderDefinition(
        id: "kagi",
        name: "Kagi",
        summary: L("Premium ad-free search (paid API)."),
        pricingNote: L("Paid: pay-per-use (billed separately from a Kagi subscription)"),
        instructions: [
            L("Sign in at kagi.com and open the API portal at kagi.com/api."),
            L("Add a payment method under API Billing, then copy your API key."),
            L("Paste it below."),
        ],
        signupURL: "https://kagi.com/api",
        homepage: "https://help.kagi.com/kagi/api/search.html",
        secrets: [
            SearchSecretField(
                id: "api_key",
                label: L("Kagi API key"),
                url: "https://kagi.com/api"
            )
        ],
        endpoints: [
            SearchCategory.web: kagiEndpoint(workflow: "search", resultsPath: "data.search"),
            SearchCategory.news: kagiEndpoint(workflow: "news", resultsPath: "data.news"),
        ]
    )

    private static func kagiEndpoint(workflow: String, resultsPath: String) -> SearchEndpoint {
        SearchEndpoint(
            url: "https://kagi.com/api/v1/search",
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer {{secret.api_key}}",
            ],
            body: [
                SearchRequestParam(name: "query", value: "{{query}}"),
                SearchRequestParam(name: "workflow", value: workflow),
                SearchRequestParam(name: "limit", value: "{{max_results}}", type: "int"),
                SearchRequestParam(name: "page", value: "{{page}}", type: "int"),
            ],
            response: SearchResponseMapping(
                // v1 buckets results by type, so no t == 0 filter is needed.
                resultsPath: resultsPath,
                item: SearchHitFieldPaths(
                    title: "title",
                    url: "url",
                    snippet: "snippet",
                    publishedDate: "time"
                )
            )
        )
    }

    static let you = SearchProviderDefinition(
        id: "you",
        name: "You.com",
        summary: L("Web search API with snippets tuned for LLMs."),
        pricingNote: L("Free trial, then paid"),
        instructions: [
            L("Sign up at api.you.com."),
            L("Create an API key."),
            L("Paste it below."),
        ],
        signupURL: "https://api.you.com",
        homepage: "https://api.you.com",
        secrets: [
            SearchSecretField(id: "api_key", label: L("You.com API key"), url: "https://api.you.com")
        ],
        endpoints: [
            // The v1 API is a single unified endpoint returning both web and
            // news buckets; only the results path differs per category.
            SearchCategory.web: youEndpoint(resultsPath: "results.web"),
            SearchCategory.news: youEndpoint(resultsPath: "results.news"),
        ]
    )

    private static func youEndpoint(resultsPath: String) -> SearchEndpoint {
        SearchEndpoint(
            url: "https://ydc-index.io/v1/search",
            headers: ["X-API-Key": "{{secret.api_key}}", "Accept": "application/json"],
            query: [
                SearchRequestParam(name: "query", value: "{{query}}"),
                SearchRequestParam(name: "count", value: "{{max_results}}"),
                SearchRequestParam(
                    name: "freshness",
                    value: "{{time_range}}",
                    omitIfEmpty: true,
                    map: ["d": "day", "w": "week", "m": "month", "y": "year"]
                ),
            ],
            response: SearchResponseMapping(
                resultsPath: resultsPath,
                item: SearchHitFieldPaths(
                    title: "title",
                    url: "url",
                    snippet: "description|snippets",
                    publishedDate: "page_age"
                )
            )
        )
    }

    // MARK: - Free scrapers (native runtime)

    public static let nativeProviders: [SearchProviderDefinition] = [
        SearchProviderDefinition(
            id: "brave_html",
            name: L("Brave (free)"),
            runtime: .native,
            summary: L("Free Brave search results. No key needed."),
            pricingNote: "Free",
            homepage: "https://search.brave.com",
            categories: [SearchCategory.web, SearchCategory.news]
        ),
        SearchProviderDefinition(
            id: "bing_html",
            name: L("Bing (free)"),
            runtime: .native,
            summary: L("Free Bing search results. No key needed."),
            pricingNote: "Free",
            homepage: "https://www.bing.com",
            categories: [SearchCategory.web, SearchCategory.news]
        ),
        SearchProviderDefinition(
            id: "ddg",
            name: "DuckDuckGo",
            runtime: .native,
            summary: L("Free web, news, and image search. Used only when other sources fail."),
            pricingNote: "Free",
            homepage: "https://duckduckgo.com",
            // DDG's anti-bot layer serves plausible-looking decoy results to
            // flagged clients, so its hits are only trusted as a last resort.
            lastResort: true,
            categories: [SearchCategory.web, SearchCategory.news, SearchCategory.images]
        ),
    ]
}
