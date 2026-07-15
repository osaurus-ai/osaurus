//
//  SearchReadability.swift
//  osaurus
//
//  Lightweight Readability-style extraction used by `search_and_extract`:
//  fetches a page, strips chrome, picks the main container, and converts to
//  markdown. Ported from the osaurus.search plugin.
//

import Foundation

enum SearchExtractionStatus: String, Sendable, Equatable {
    case ok
    case fetchFailed = "fetch_failed"
    case challenge
    case boilerplate
    case empty
    case blocked
    case timeout
    case cancelled
    case tooLarge = "too_large"
}

enum SearchReadability {
    static let maxMarkdownCharacters = 12_000
    /// Structured datasets need more room than an article excerpt: one year
    /// of daily OHLC rows or a compact JSON response routinely exceeds 12K
    /// characters. Still bounded so a direct URL cannot flood the model.
    static let maxStructuredTextCharacters = 64_000
    /// Full structured payload retained for an in-process tool-to-tool handoff.
    /// The model-facing excerpt remains capped above; larger responses fall
    /// back to that excerpt instead of occupying the reference store.
    static let maxStructuredDataCharacters = 1_000_000
    static let maxHTMLBytes = 5 * 1_024 * 1_024
    private static let minUsefulWordCount = 20

    struct Extraction: Sendable {
        var markdown: String
        var wordCount: Int
        var title: String?
        var byline: String?
        var lang: String?
        var canonicalURL: String?
        var status: SearchExtractionStatus
        var truncated: Bool
        var message: String?
        var totalWordCount: Int?
        var structuredData: String?
        var structuredFormat: String?

        var extracted: Bool { status == .ok }
    }

    /// Fetch `url` and extract the main content. Always returns a typed status
    /// so tool payloads can explain failures without raw network errors.
    static func extract(
        url: String,
        timeout: TimeInterval,
        configuration: URLSessionConfiguration = .ephemeral
    ) async -> Extraction {
        // Best-effort preflight for obvious unsafe targets. URLSession still
        // resolves the hostname at connect time, so DNS-rebinding protection
        // requires a future pinned-address transport.
        if let blocked = SearchHTML.resolvedUnsafeExtractionURLReason(url) {
            return failure(status: .blocked, message: blocked)
        }
        guard let requestURL = URL(string: url) else {
            return failure(status: .blocked, message: "invalid URL is blocked")
        }

        var request = URLRequest(
            url: requestURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        request.setValue(
            SearchHTTPClient.userAgents.randomElement() ?? SearchHTTPClient.userAgents[0],
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "text/html,application/xhtml+xml,text/csv,text/tab-separated-values,text/plain,application/json,application/*+json;q=0.9,*/*;q=0.1",
            forHTTPHeaderField: "Accept"
        )

        let delegate = SearchReadabilityRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer {
            session.invalidateAndCancel()
        }

        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let blocked = delegate.blockedReason {
                return failure(status: .blocked, message: blocked)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200 ... 299).contains(status) else {
                return failure(status: .fetchFailed, message: "HTTP status \(status)")
            }
            if response.expectedContentLength > Int64(maxHTMLBytes) {
                return failure(status: .tooLarge, message: "response exceeds \(maxHTMLBytes) bytes")
            }
            var data = Data()
            data.reserveCapacity(
                response.expectedContentLength > 0
                    ? min(Int(response.expectedContentLength), maxHTMLBytes)
                    : min(64 * 1_024, maxHTMLBytes)
            )
            for try await byte in bytes {
                if data.count >= maxHTMLBytes {
                    return failure(status: .tooLarge, message: "response exceeds \(maxHTMLBytes) bytes")
                }
                data.append(byte)
                try Task.checkCancellation()
            }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                return failure(status: .empty, message: "empty response")
            }
            let contentType = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Type")
            return extract(responseText: text, contentType: contentType, sourceURL: requestURL)
        } catch is CancellationError {
            return failure(status: .cancelled, message: "cancelled")
        } catch let error as URLError {
            if error.code == .cancelled {
                return failure(status: .cancelled, message: "cancelled")
            }
            if error.code == .timedOut {
                return failure(status: .timeout, message: "timed out")
            }
            return failure(status: .fetchFailed, message: SearchDiagnostics.redact(error.localizedDescription))
        } catch {
            return failure(status: .fetchFailed, message: SearchDiagnostics.redact(error.localizedDescription))
        }
    }

    /// Preserve structured text responses verbatim instead of running them
    /// through HTML readability. This is the data path used by chart tasks:
    /// CSV/TSV/JSON rows must reach `render_chart` with their header and values
    /// intact. HTML (including pages mislabeled as text/plain) still follows
    /// the normal readability path.
    static func extract(
        responseText: String,
        contentType: String?,
        sourceURL: URL? = nil
    ) -> Extraction {
        let normalizedType = contentType?.lowercased() ?? ""
        let pathExtension = sourceURL?.pathExtension.lowercased() ?? ""
        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedPrefix = trimmed.prefix(32).lowercased()
        let looksLikeHTML =
            lowercasedPrefix.hasPrefix("<!doctype html")
            || lowercasedPrefix.hasPrefix("<html")
        let structuredFormat: String? = {
            guard !looksLikeHTML else { return nil }
            if normalizedType.contains("application/json")
                || normalizedType.contains("+json")
                || pathExtension == "json"
            {
                return "json"
            }
            if normalizedType.contains("tab-separated-values") || pathExtension == "tsv" {
                return "tsv"
            }
            if normalizedType.contains("text/csv")
                || normalizedType.contains("application/csv")
                || pathExtension == "csv"
            {
                return "csv"
            }
            return nil
        }()

        guard let structuredFormat else {
            return extract(html: responseText, sourceURL: sourceURL)
        }
        guard !trimmed.isEmpty else {
            return failure(status: .empty, message: "empty content")
        }

        let capped = SearchDiagnostics.truncate(
            trimmed,
            maxCharacters: maxStructuredTextCharacters
        )
        let wordCount = capped.text.split(whereSeparator: { $0.isWhitespace }).count
        return Extraction(
            markdown: capped.text,
            wordCount: wordCount,
            title: sourceURL?.lastPathComponent,
            byline: nil,
            lang: nil,
            canonicalURL: sourceURL?.absoluteString,
            status: .ok,
            truncated: capped.truncated,
            message: nil,
            totalWordCount: capped.truncated
                ? trimmed.split(whereSeparator: { $0.isWhitespace }).count : nil,
            structuredData: trimmed.count <= maxStructuredDataCharacters ? trimmed : nil,
            structuredFormat: structuredFormat
        )
    }

    /// Pure extraction from raw HTML (testable without network).
    static func extract(html: String, sourceURL: URL? = nil) -> Extraction {
        let title = SearchHTML.firstGroup(in: html, pattern: "<title[^>]*>([\\s\\S]*?)</title>")
            .map { SearchHTML.decodeHTMLEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let byline =
            SearchHTML.metaContent(in: html, name: "author")
            ?? SearchHTML.metaContent(in: html, property: "article:author")
        let lang = SearchHTML.firstGroup(in: html, pattern: "<html[^>]*\\blang=[\"']([^\"']+)[\"']")
        let canonical = SearchHTML.canonicalURL(in: html, baseURL: sourceURL)

        if SearchHTML.isLikelyChallengePage(html, treatShortAsChallenge: false) {
            return failure(
                status: .challenge,
                title: title,
                canonicalURL: canonical,
                message: "challenge_page"
            )
        }

        var content = SearchHTML.stripBlocks(
            html,
            tags: [
                "script", "style", "noscript", "template", "svg", "iframe", "header", "footer",
                "nav", "aside", "form", "button",
            ]
        )
        if let main = SearchHTML.pickMainContainer(content) { content = main }
        let markdown = SearchHTML.htmlToMarkdown(content)
        let wordCount = markdown.split(whereSeparator: { $0.isWhitespace }).count
        guard !markdown.isEmpty, wordCount > 0 else {
            return failure(status: .empty, title: title, canonicalURL: canonical, message: "empty content")
        }
        guard wordCount >= minUsefulWordCount else {
            return failure(
                status: .boilerplate,
                title: title,
                canonicalURL: canonical,
                message: "too little readable content"
            )
        }
        let capped = SearchDiagnostics.truncate(markdown, maxCharacters: maxMarkdownCharacters)
        let cappedWordCount = capped.text.split(whereSeparator: { $0.isWhitespace }).count

        return Extraction(
            markdown: capped.text,
            wordCount: cappedWordCount,
            title: title,
            byline: byline,
            lang: lang,
            canonicalURL: canonical,
            status: .ok,
            truncated: capped.truncated,
            message: nil,
            totalWordCount: capped.truncated ? wordCount : nil,
            structuredData: nil,
            structuredFormat: nil
        )
    }

    private static func failure(
        status: SearchExtractionStatus,
        title: String? = nil,
        canonicalURL: String? = nil,
        message: String? = nil
    ) -> Extraction {
        Extraction(
            markdown: "",
            wordCount: 0,
            title: title,
            byline: nil,
            lang: nil,
            canonicalURL: canonicalURL,
            status: status,
            truncated: false,
            message: message.map(SearchDiagnostics.redact),
            totalWordCount: nil,
            structuredData: nil,
            structuredFormat: nil
        )
    }
}

private final class SearchReadabilityRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var unsafeRedirectReason: String?

    var blockedReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return unsafeRedirectReason
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url else {
            setBlockedReason("redirect to missing URL is blocked")
            completionHandler(nil)
            return
        }
        if let blocked = SearchHTML.resolvedUnsafeExtractionURLReason(url.absoluteString) {
            setBlockedReason("redirect \(blocked)")
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private func setBlockedReason(_ reason: String) {
        lock.lock()
        unsafeRedirectReason = reason
        lock.unlock()
    }
}
