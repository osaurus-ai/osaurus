//
//  SafeImportFetcher.swift
//  osaurus
//
//  HTTPS-only downloads for chat import. Ephemeral session (no cookies,
//  no cache), every redirect must stay on https, bodies stream under a
//  hard byte cap, and nothing fetched is ever executed. Pages are asked
//  for markdown first; HTML falls back to the `.md` variant, the site's
//  `/llms.txt`, and finally a text rendering that keeps code blocks.
//

import Foundation

enum SafeImportFetcher {
    static let textLimitBytes = 512 * 1024
    static let archiveLimitBytes = 100 * 1024 * 1024
    static let requestTimeout: TimeInterval = 20
    static let maxRedirects = 5

    struct Response: Sendable {
        let requestedURL: URL
        let finalURL: URL
        let status: Int
        let contentType: String
        let data: Data

        var text: String? {
            String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }

        var isHTML: Bool {
            contentType.contains("text/html") || contentType.contains("application/xhtml")
        }
    }

    enum FetchError: Error, LocalizedError, Equatable {
        case insecure(String)
        case redirectRefused(String)
        case tooLarge(String)
        case http(String, status: Int)
        case network(String, reason: String)

        var errorDescription: String? {
            switch self {
            case .insecure: return "only https links are allowed"
            case .redirectRefused: return "it redirected somewhere that isn't https"
            case .tooLarge: return "the download is too large"
            case .http(_, let status): return "HTTP \(status)"
            case .network(_, let reason): return reason
            }
        }
    }

    /// Test seam: replaces the network. Bound with `withValue` so a test's
    /// fixtures never leak into a concurrent test or the app.
    typealias Transport = @Sendable (URLRequest, Int) async throws -> Response
    @TaskLocal static var transportOverride: Transport?

    static func isSecure(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
    }

    /// Fetch raw bytes under `limit`.
    static func fetch(_ url: URL, accept: String = "*/*", limit: Int = textLimitBytes) async throws -> Response {
        guard isSecure(url) else { throw FetchError.insecure(url.absoluteString) }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Osaurus-Import", forHTTPHeaderField: "User-Agent")
        if let transportOverride {
            let response = try await transportOverride(request, limit)
            guard response.data.count <= limit else { throw FetchError.tooLarge(url.absoluteString) }
            return response
        }
        return try await live(request, limit: limit)
    }

    /// Download a large binary (a repository archive) to a temporary file,
    /// aborting as soon as it passes `limit`.
    static func download(_ url: URL, limit: Int = archiveLimitBytes) async throws -> (file: URL, status: Int) {
        guard isSecure(url) else { throw FetchError.insecure(url.absoluteString) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-import-\(UUID().uuidString).zip")
        if let transportOverride {
            var request = URLRequest(url: url, timeoutInterval: requestTimeout)
            request.setValue("application/zip", forHTTPHeaderField: "Accept")
            let response = try await transportOverride(request, limit)
            guard response.data.count <= limit else { throw FetchError.tooLarge(url.absoluteString) }
            try response.data.write(to: destination)
            return (destination, response.status)
        }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.setValue("Osaurus-Import", forHTTPHeaderField: "User-Agent")
        let downloader = CappedDownload(destination: destination, limit: limit, maxRedirects: maxRedirects)
        return try await downloader.run(request)
    }

    /// Fetch a page as readable text, preferring markdown.
    static func fetchText(_ url: URL) async throws -> (text: String, finalURL: URL) {
        let accept = "text/markdown, text/x-markdown;q=0.95, text/plain;q=0.9, text/html;q=0.5, */*;q=0.1"
        let response = try await fetch(url, accept: accept)
        guard (200..<300).contains(response.status) else {
            throw FetchError.http(url.absoluteString, status: response.status)
        }
        let body = response.text ?? ""
        guard response.isHTML || looksLikeHTML(body) else { return (body, response.finalURL) }

        for alternate in markdownAlternates(for: response.finalURL) {
            if let alt = try? await fetch(alternate, accept: accept),
                (200..<300).contains(alt.status), !alt.isHTML,
                let text = alt.text, !looksLikeHTML(text),
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return (text, alt.finalURL)
            }
        }
        return (ChatImportHTMLText.render(body), response.finalURL)
    }

    /// `page.md` for an extensionless path, then the site's `/llms.txt`
    /// when the link is the site root.
    static func markdownAlternates(for url: URL) -> [URL] {
        var out: [URL] = []
        let path = url.path
        let last = (path as NSString).lastPathComponent
        if !path.isEmpty, path != "/", !last.contains(".") {
            var trimmed = url.absoluteString
            if let q = trimmed.firstIndex(where: { $0 == "?" || $0 == "#" }) { trimmed = String(trimmed[..<q]) }
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
            if let md = URL(string: trimmed + ".md") { out.append(md) }
        }
        if path.isEmpty || path == "/", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.path = "/llms.txt"
            components.query = nil
            components.fragment = nil
            if let llms = components.url { out.append(llms) }
        }
        return out
    }

    static func looksLikeHTML(_ text: String) -> Bool {
        let head = text.prefix(512).lowercased()
        return head.contains("<!doctype html") || head.contains("<html")
    }

    // MARK: - Live transport

    private static func live(_ request: URLRequest, limit: Int) async throws -> Response {
        let guardDelegate = HTTPSRedirectGuard(maxRedirects: maxRedirects)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = limit > textLimitBytes ? 180 : 45
        let session = URLSession(configuration: configuration, delegate: guardDelegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let url = request.url!
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            if guardDelegate.refused { throw FetchError.redirectRefused(url.absoluteString) }
            throw FetchError.network(url.absoluteString, reason: error.localizedDescription)
        }
        if guardDelegate.refused { throw FetchError.redirectRefused(url.absoluteString) }
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.network(url.absoluteString, reason: "no HTTP response")
        }
        if http.expectedContentLength > Int64(limit) { throw FetchError.tooLarge(url.absoluteString) }
        var data = Data()
        data.reserveCapacity(min(Int(max(http.expectedContentLength, 0)), limit))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { throw FetchError.tooLarge(url.absoluteString) }
            }
        } catch let error as FetchError {
            throw error
        } catch {
            throw FetchError.network(url.absoluteString, reason: error.localizedDescription)
        }
        let finalURL = http.url ?? url
        guard isSecure(finalURL) else { throw FetchError.redirectRefused(url.absoluteString) }
        return Response(
            requestedURL: url, finalURL: finalURL, status: http.statusCode,
            contentType: (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased(), data: data)
    }
}

/// Refuses any redirect that leaves https or exceeds the hop limit.
private final class HTTPSRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var hops = 0
    private var _refused = false
    let maxRedirects: Int

    init(maxRedirects: Int) { self.maxRedirects = maxRedirects }

    var refused: Bool { lock.withLock { _refused } }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let allowed: Bool = lock.withLock {
            hops += 1
            let ok = hops <= maxRedirects && request.url.map(SafeImportFetcher.isSecure) == true
            if !ok { _refused = true }
            return ok
        }
        completionHandler(allowed ? request : nil)
    }
}

/// Streams a response body to disk in chunks and cancels once it passes
/// the cap. Redirects follow the same https-only rule.
private final class CappedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let limit: Int
    private let maxRedirects: Int
    private let lock = NSLock()
    private var handle: FileHandle?
    private var written = 0
    private var hops = 0
    private var status = 0
    private var failure: SafeImportFetcher.FetchError?
    private var continuation: CheckedContinuation<(file: URL, status: Int), Error>?

    init(destination: URL, limit: Int, maxRedirects: Int) {
        self.destination = destination
        self.limit = limit
        self.maxRedirects = maxRedirects
    }

    func run(_ request: URLRequest) async throws -> (file: URL, status: Int) {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        handle = try FileHandle(forWritingTo: destination)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = SafeImportFetcher.requestTimeout
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let allowed: Bool = lock.withLock {
            hops += 1
            let ok = hops <= maxRedirects && request.url.map(SafeImportFetcher.isSecure) == true
            if !ok { failure = .redirectRefused(task.originalRequest?.url?.absoluteString ?? "") }
            return ok
        }
        completionHandler(allowed ? request : nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        let tooBig = (http?.expectedContentLength ?? -1) > Int64(limit)
        lock.withLock {
            status = http?.statusCode ?? 0
            if tooBig { failure = .tooLarge(response.url?.absoluteString ?? "") }
        }
        completionHandler(tooBig ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceeded: Bool = lock.withLock {
            written += data.count
            if written > limit {
                failure = .tooLarge(dataTask.originalRequest?.url?.absoluteString ?? "")
                return true
            }
            try? handle?.write(contentsOf: data)
            return false
        }
        if exceeded { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, failure, status): (CheckedContinuation<(file: URL, status: Int), Error>?, SafeImportFetcher.FetchError?, Int) =
            lock.withLock {
                let c = self.continuation
                self.continuation = nil
                try? handle?.close()
                handle = nil
                return (c, self.failure, self.status)
            }
        guard let continuation else { return }
        if let failure {
            try? FileManager.default.removeItem(at: destination)
            continuation.resume(throwing: failure)
        } else if let error {
            try? FileManager.default.removeItem(at: destination)
            continuation.resume(
                throwing: SafeImportFetcher.FetchError.network(
                    task.originalRequest?.url?.absoluteString ?? "", reason: error.localizedDescription))
        } else if let finalURL = task.currentRequest?.url, !SafeImportFetcher.isSecure(finalURL) {
            try? FileManager.default.removeItem(at: destination)
            continuation.resume(throwing: SafeImportFetcher.FetchError.redirectRefused(finalURL.absoluteString))
        } else {
            continuation.resume(returning: (destination, status))
        }
    }
}

// MARK: - HTML to text

/// Minimal HTML rendering for pages that offer no markdown: drops
/// scripts/styles/nav chrome, keeps headings, list items, links, and
/// fences `<pre>` blocks so install commands survive intact.
enum ChatImportHTMLText {
    static func render(_ html: String) -> String {
        var text = html
        for tag in ["script", "style", "noscript", "svg", "nav", "footer", "header", "form", "iframe"] {
            text = replacing(text, pattern: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: "\n")
        }
        text = replacing(text, pattern: "<!--[\\s\\S]*?-->", with: "")
        text = replacing(text, pattern: "<pre\\b[^>]*>([\\s\\S]*?)</pre>") { inner in
            "\n```\n" + decodeEntities(stripTags(inner)).trimmingCharacters(in: .newlines) + "\n```\n"
        }
        text = replacing(text, pattern: "<code\\b[^>]*>([\\s\\S]*?)</code>") { inner in
            "`" + stripTags(inner) + "`"
        }
        text = replacing(text, pattern: "<a\\b[^>]*href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>", groups: 2) { groups in
            let label = stripTags(groups[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            return label.isEmpty ? groups[0] : "[\(label)](\(groups[0]))"
        }
        for level in 1...6 {
            text = replacing(text, pattern: "<h\(level)\\b[^>]*>([\\s\\S]*?)</h\(level)>") { inner in
                "\n\n" + String(repeating: "#", count: level) + " " + stripTags(inner) + "\n\n"
            }
        }
        text = replacing(text, pattern: "<li\\b[^>]*>", with: "\n- ")
        text = replacing(text, pattern: "<(br|/p|/div|/tr|/li|/ul|/ol|/section|/article)\\b[^>]*>", with: "\n")
        text = stripTags(text)
        text = decodeEntities(text)
        text = replacing(text, pattern: "[ \\t]+\\n", with: "\n")
        text = replacing(text, pattern: "\\n{3,}", with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripTags(_ s: String) -> String {
        replacing(s, pattern: "<[^>]+>", with: "")
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let named = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        out = replacing(out, pattern: "&#(x?[0-9a-fA-F]+);") { code in
            let value = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func replacing(_ s: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        return regex.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }

    private static func replacing(_ s: String, pattern: String, transform: (String) -> String) -> String {
        replacing(s, pattern: pattern, groups: 1) { transform($0[0]) }
    }

    private static func replacing(
        _ s: String, pattern: String, groups: Int, transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        let ns = s as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            var captured: [String] = []
            for g in 1...groups {
                let r = match.range(at: g)
                captured.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result += transform(captured)
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}
