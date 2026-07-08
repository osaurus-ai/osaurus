//
//  NativeSearchBackends.swift
//  osaurus
//
//  Free scraper backends (no API key): DuckDuckGo HTML (+ Lite fallback and
//  image search via VQD token), Brave HTML, and Bing HTML. Screen scraping
//  can't be expressed declaratively, so these are the only hand-written
//  backends; they conform to the same `SearchBackend` protocol as the
//  declarative executor. Ported from the osaurus.search plugin.
//

import Foundation

enum NativeSearchBackends {
    /// Backend for a native definition id, or nil for unknown ids.
    static func backend(for definitionId: String) -> SearchBackend? {
        switch definitionId {
        case "ddg": return DDGScrapeBackend()
        case "brave_html": return BraveScrapeBackend()
        case "bing_html": return BingScrapeBackend()
        default: return nil
        }
    }
}

// MARK: - DuckDuckGo

struct DDGScrapeBackend: SearchBackend {
    let definitionId = "ddg"

    func search(_ request: SearchRequest) async throws -> [SearchHit] {
        if request.category == SearchCategory.images {
            return try await searchImages(request)
        }
        var url = "https://html.duckduckgo.com/html/?q=\(SearchHTML.urlEncode(request.augmentedQuery))"
        if let region = request.region {
            url += "&kl=\(SearchHTML.urlEncode(region))"
        } else {
            url += "&kl=wt-wt"
        }
        if request.category == SearchCategory.news { url += "&iar=news" }
        if let df = request.timeRange { url += "&df=\(df)" }
        let (status, data) = try await SearchHTTPClient.request(url: url)
        guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
            throw SearchBackendError("DDG: empty response")
        }
        if Self.isChallengePage(status: status, html: html) {
            throw SearchBackendError("DDG: challenge_page")
        }
        let hits = Self.parseHTML(html, max: request.maxResults)
        return hits
    }

    /// DDG's anti-bot interstitial ("Select all squares containing a duck")
    /// ships as HTTP 202 with a distinctive body. Throwing here surfaces the
    /// block in the attempts trace instead of silently parsing to zero hits.
    static func isChallengePage(status: Int, html: String) -> Bool {
        if status == 202 { return true }
        let lc = html.lowercased()
        return lc.contains("bots use duckduckgo too")
            || lc.contains("anomaly-modal")
            || lc.contains("error-lite@duckduckgo.com")
    }

    static func parseHTML(_ html: String, max: Int) -> [SearchHit] {
        var results: [SearchHit] = []

        let resultPattern =
            "<div\\s+class=\"result[^\"]*\"[\\s\\S]*?<a[^>]*class=\"[^\"]*result__a[^\"]*\"[^>]*href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>(?:[\\s\\S]*?<a[^>]*class=\"[^\"]*result__snippet[^\"]*\"[^>]*>([\\s\\S]*?)</a>)?"
        if let regex = try? NSRegularExpression(pattern: resultPattern, options: .caseInsensitive) {
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            for m in matches.prefix(max) {
                guard let urlR = Range(m.range(at: 1), in: html),
                    let titleR = Range(m.range(at: 2), in: html)
                else { continue }
                let url = SearchHTML.unwrapDDG(SearchHTML.decodeHTMLEntities(String(html[urlR])))
                let title = SearchHTML.stripHTML(String(html[titleR]))
                var snippet = ""
                if m.numberOfRanges > 3, let r = Range(m.range(at: 3), in: html) {
                    snippet = SearchHTML.stripHTML(String(html[r]))
                }
                results.append(SearchHit(title: title, url: url, snippet: snippet, engine: "ddg"))
            }
        }

        // Lite fallback
        if results.isEmpty {
            let lite = "<a[^>]*class=\"result-link\"[^>]*href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>"
            if let regex = try? NSRegularExpression(pattern: lite, options: .caseInsensitive) {
                let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                for m in matches.prefix(max) {
                    guard let urlR = Range(m.range(at: 1), in: html),
                        let titleR = Range(m.range(at: 2), in: html)
                    else { continue }
                    let url = SearchHTML.unwrapDDG(SearchHTML.decodeHTMLEntities(String(html[urlR])))
                    results.append(
                        SearchHit(
                            title: SearchHTML.stripHTML(String(html[titleR])),
                            url: url,
                            snippet: "",
                            engine: "ddg"
                        ))
                }
            }
        }

        return results
    }

    // MARK: Images (VQD token flow)

    private func searchImages(_ request: SearchRequest) async throws -> [SearchHit] {
        let q = SearchHTML.urlEncode(request.query)
        let (_, bootData) = try await SearchHTTPClient.request(
            url: "https://duckduckgo.com/?q=\(q)&iax=images&ia=images")
        guard let bootHtml = String(data: bootData, encoding: .utf8) else {
            throw SearchBackendError("DDG image bootstrap failed")
        }
        guard let vqd = SearchHTML.firstGroup(in: bootHtml, pattern: "vqd=([\"'])([^\"']+)\\1", group: 2) else {
            throw SearchBackendError("Could not obtain DDG VQD token")
        }

        let url = "https://duckduckgo.com/i.js?l=wt-wt&o=json&q=\(q)&vqd=\(vqd)&p=1"
        let (status, data) = try await SearchHTTPClient.request(
            url: url, headers: ["Referer": "https://duckduckgo.com/"])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let arr = json["results"] as? [[String: Any]]
        else { throw SearchBackendError("DDG image API failed (status \(status))") }

        return arr.prefix(request.maxResults).map { item in
            SearchHit(
                title: (item["title"] as? String) ?? "",
                url: (item["url"] as? String) ?? "",
                snippet: "",
                sourceDomain: item["source"] as? String,
                engine: "ddg",
                imageURL: (item["image"] as? String) ?? "",
                thumbnailURL: item["thumbnail"] as? String,
                width: item["width"] as? Int,
                height: item["height"] as? Int
            )
        }
    }
}

// MARK: - Brave HTML

struct BraveScrapeBackend: SearchBackend {
    let definitionId = "brave_html"

    func search(_ request: SearchRequest) async throws -> [SearchHit] {
        let q = SearchHTML.urlEncode(request.augmentedQuery)
        let endpoint =
            request.category == SearchCategory.news
            ? "https://search.brave.com/news?q=\(q)"
            : "https://search.brave.com/search?q=\(q)&source=web"
        let (_, data) = try await SearchHTTPClient.request(url: endpoint)
        guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
            throw SearchBackendError("Brave HTML: empty response")
        }
        if SearchHTML.isLikelyChallengePage(html) {
            throw SearchBackendError("Brave HTML: challenge_page")
        }
        return Self.parseHTML(html, max: request.maxResults)
    }

    /// Brave's modern markup wraps each result in `<div class="snippet ...">`
    /// with the title link as `<a class="title ...">` and the snippet text as
    /// `<div class="description ...">`. Ads come through the same wrapper but
    /// with `data-type="ad"` and `/a/redirect` hrefs; filter them out.
    static func parseHTML(_ html: String, max: Int) -> [SearchHit] {
        let chunks = SearchHTML.sliceByClass(html, className: "snippet")
        if chunks.isEmpty { return parseHTMLLegacy(html, max: max) }

        var hits: [SearchHit] = []
        for chunk in chunks {
            if chunk.contains("data-type=\"ad\"") || chunk.contains("/a/redirect?") {
                continue
            }
            var url = SearchHTML.firstAttr(in: chunk, tag: "a", className: "title", attr: "href")
            if url == nil { url = SearchHTML.firstAttr(in: chunk, tag: "a", className: "l1", attr: "href") }
            if url == nil { url = SearchHTML.firstHrefStartingWithHttp(in: chunk) }
            guard let rawURL = url, rawURL.hasPrefix("http") else { continue }

            let title = SearchHTML.firstInnerByClass(in: chunk, className: "title") ?? ""
            let snippet = SearchHTML.firstInnerByClass(in: chunk, className: "description") ?? ""
            let cleanedTitle = SearchHTML.stripHTML(title)
            if cleanedTitle.isEmpty { continue }

            hits.append(
                SearchHit(
                    title: cleanedTitle,
                    url: SearchHTML.decodeHTMLEntities(rawURL),
                    snippet: SearchHTML.stripHTML(snippet),
                    engine: "brave_html"
                )
            )
            if hits.count >= max { break }
        }
        return hits
    }

    /// Fallback to older selectors in case Brave switches markup back.
    private static func parseHTMLLegacy(_ html: String, max: Int) -> [SearchHit] {
        var hits: [SearchHit] = []
        let pattern =
            "<div[^>]*class=\"[^\"]*snippet[^\"]*\"[^>]*>[\\s\\S]*?<a[^>]*href=\"([^\"]+)\"[^>]*>[\\s\\S]*?<div[^>]*class=\"[^\"]*title[^\"]*\"[^>]*>([\\s\\S]*?)</div>[\\s\\S]*?<div[^>]*class=\"[^\"]*snippet-description[^\"]*\"[^>]*>([\\s\\S]*?)</div>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            for m in matches.prefix(max) {
                guard let urlR = Range(m.range(at: 1), in: html),
                    let titleR = Range(m.range(at: 2), in: html),
                    let snipR = Range(m.range(at: 3), in: html)
                else { continue }
                let url = SearchHTML.decodeHTMLEntities(String(html[urlR]))
                guard url.hasPrefix("http") else { continue }
                hits.append(
                    SearchHit(
                        title: SearchHTML.stripHTML(String(html[titleR])),
                        url: url,
                        snippet: SearchHTML.stripHTML(String(html[snipR])),
                        engine: "brave_html"
                    ))
            }
        }
        return hits
    }
}

// MARK: - Bing HTML

struct BingScrapeBackend: SearchBackend {
    let definitionId = "bing_html"

    func search(_ request: SearchRequest) async throws -> [SearchHit] {
        let q = SearchHTML.urlEncode(request.augmentedQuery)
        let endpoint =
            request.category == SearchCategory.news
            ? "https://www.bing.com/news/search?q=\(q)&count=\(request.maxResults)"
            : "https://www.bing.com/search?q=\(q)&count=\(request.maxResults)"
        let (_, data) = try await SearchHTTPClient.request(url: endpoint)
        guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
            throw SearchBackendError("Bing HTML: empty response")
        }
        if Self.isChallengePage(html) {
            throw SearchBackendError("Bing HTML: challenge_page")
        }
        return Self.parseHTML(html, max: request.maxResults)
    }

    /// Bing's anti-bot interstitial ("One last step — please solve the
    /// challenge below to continue") is a 200 page with no organic results.
    static func isChallengePage(_ html: String) -> Bool {
        let lc = html.lowercased()
        return lc.contains("solve the challenge") || lc.contains("challenge below to continue")
    }

    static func parseHTML(_ html: String, max: Int) -> [SearchHit] {
        var hits: [SearchHit] = []
        let pattern =
            "<li[^>]*class=\"b_algo\"[^>]*>[\\s\\S]*?<h2>[\\s\\S]*?<a[^>]*href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>[\\s\\S]*?</h2>(?:[\\s\\S]*?<p[^>]*>([\\s\\S]*?)</p>)?"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            for m in matches.prefix(max) {
                guard let urlR = Range(m.range(at: 1), in: html),
                    let titleR = Range(m.range(at: 2), in: html)
                else { continue }
                var snippet = ""
                if m.numberOfRanges > 3, let r = Range(m.range(at: 3), in: html) {
                    snippet = SearchHTML.stripHTML(String(html[r]))
                }
                hits.append(
                    SearchHit(
                        title: SearchHTML.stripHTML(String(html[titleR])),
                        url: SearchHTML.decodeHTMLEntities(String(html[urlR])),
                        snippet: snippet,
                        engine: "bing_html"
                    ))
            }
        }
        return hits
    }
}
