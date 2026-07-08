//
//  SearchReadability.swift
//  osaurus
//
//  Lightweight Readability-style extraction used by `search_and_extract`:
//  fetches a page, strips chrome, picks the main container, and converts to
//  markdown. Ported from the osaurus.search plugin.
//

import Foundation

enum SearchReadability {
    struct Extraction: Sendable {
        var markdown: String
        var wordCount: Int
        var title: String?
        var byline: String?
        var lang: String?
    }

    /// Fetch `url` and extract the main content. Returns nil when the page
    /// can't be fetched or decoded (callers mark the hit `extracted: false`).
    static func extract(url: String, timeout: TimeInterval) async -> Extraction? {
        guard
            let (_, data) = try? await SearchHTTPClient.request(
                url: url,
                headers: ["Accept": "text/html,application/xhtml+xml"],
                timeout: timeout
            ),
            let html = String(data: data, encoding: .utf8)
        else { return nil }
        return extract(html: html)
    }

    /// Pure extraction from raw HTML (testable without network).
    static func extract(html: String) -> Extraction {
        let title = SearchHTML.firstGroup(in: html, pattern: "<title[^>]*>([\\s\\S]*?)</title>")
            .map { SearchHTML.decodeHTMLEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let byline =
            SearchHTML.metaContent(in: html, name: "author")
            ?? SearchHTML.metaContent(in: html, property: "article:author")
        let lang = SearchHTML.firstGroup(in: html, pattern: "<html[^>]*\\blang=[\"']([^\"']+)[\"']")

        var content = SearchHTML.stripBlocks(
            html,
            tags: [
                "script", "style", "noscript", "template", "svg", "iframe", "header", "footer",
                "nav", "aside", "form", "button",
            ])
        if let main = SearchHTML.pickMainContainer(content) { content = main }
        let markdown = SearchHTML.htmlToMarkdown(content)
        let wordCount = markdown.split(whereSeparator: { $0.isWhitespace }).count

        return Extraction(
            markdown: markdown,
            wordCount: wordCount,
            title: title,
            byline: byline,
            lang: lang
        )
    }
}
