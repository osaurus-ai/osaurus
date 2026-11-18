//
//  HTTPNodeExecutor.swift
//  osaurus
//
//  HTTP steps: one request described declaratively (method, URL, headers,
//  body, auth) with no code. The URL, headers, and body are templates
//  rendered with the run's bindings. The request only reaches the hosts
//  the step names (the literal host in `url` plus `allowed_hosts`), over
//  HTTPS except for localhost (never Osaurus's own server port), through
//  an ephemeral session with no
//  cookies or cache; every redirect hop is checked against the same list.
//  Auth reads declared secrets the runner resolved; the values never
//  enter the run record (the runner redacts them). The body is capped at
//  4 MB. Output is `{status, ok, headers, body}`; a non-2xx status fails
//  the step unless `fail_on_error` is false. With `paginate` the step
//  follows the API's pages (cursor, next URL, `Link` header, or page
//  numbers) up to a cap and outputs the merged items as `body`, with
//  `pages` and `complete`.
//

import Foundation

enum HTTPNodeExecutor {

    static let allowedMethods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
    static let maximumBodyBytes = 4 * 1024 * 1024
    static let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// Test seam: performs one request.
    struct Transport: Sendable {
        var perform: @Sendable (_ request: URLRequest, _ allowedHosts: Set<String>) async throws -> (Data, HTTPURLResponse)

        static let live = Transport { request, allowedHosts in
            let delegate = RedirectGuard(allowedHosts: allowedHosts, osaurusPort: await HTTPNodeExecutor.osaurusPort())
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieAcceptPolicy = .never
            config.httpShouldSetCookies = false
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            if let refused = delegate.refusedHost {
                throw WorkflowNodeError.toolFailed(
                    tool: "http", kind: "host_not_allowed",
                    message: L("The server redirected to \(refused), which this step may not reach."), retryable: false)
            }
            guard let http = response as? HTTPURLResponse else {
                throw WorkflowNodeError.toolFailed(
                    tool: "http", kind: "execution_error", message: L("The response was not HTTP."), retryable: true)
            }
            return (data, http)
        }
    }

    /// Stops a redirect that leaves the allowed hosts or drops to HTTP.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let allowedHosts: Set<String>
        let osaurusPort: Int?
        private(set) var refusedHost: String?

        init(allowedHosts: Set<String>, osaurusPort: Int? = nil) {
            self.allowedHosts = allowedHosts
            self.osaurusPort = osaurusPort
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            if let url = request.url,
                HTTPNodeExecutor.isAllowed(url, hosts: allowedHosts, osaurusPort: osaurusPort) == nil
            {
                completionHandler(request)
            } else {
                refusedHost = request.url?.host ?? "?"
                completionHandler(nil)
            }
        }
    }

    /// Why `url` is outside the step's reach, or nil when it may be used.
    /// Checked for the first request and again for every redirect hop.
    /// Loopback is allowed on purpose (services on this Mac), except
    /// Osaurus's own server port: its API trusts loopback callers, so a
    /// step could otherwise change settings or drive agents. Every other
    /// private, link-local, carrier-NAT, and multicast range is refused
    /// even when the author listed it, with the same rules the plugin host
    /// applies (`PluginHostContext.checkSSRF`).
    static func isAllowed(_ url: URL, hosts: Set<String>, osaurusPort: Int? = nil) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return L("The URL has no host.") }
        let scheme = url.scheme?.lowercased() ?? ""
        let local = localHosts.contains(host)
        guard scheme == "https" || (scheme == "http" && local) else {
            return L("Only https URLs are allowed (http only for localhost); got \(scheme)://\(host).")
        }
        if local, let osaurusPort, (url.port ?? (scheme == "https" ? 443 : 80)) == osaurusPort {
            return L("Workflow steps may not call Osaurus's own server (port \(osaurusPort)).")
        }
        if !local, let blocked = PluginHostContext.checkSSRF(url: url) {
            return L("\(host) is a private or link-local address; workflow steps may not reach it. (\(blocked))")
        }
        guard hosts.contains(host) else {
            return L("\(host) is not among the hosts this step may reach (\(hosts.sorted().joined(separator: ", "))).")
        }
        return nil
    }

    static func run(spec: HTTPSpec, context: WorkflowNodeContext) async throws -> WorkflowNodeOutcome {
        try await run(spec: spec, context: context, transport: .live)
    }

    /// The port Osaurus's server listens on.
    static func osaurusPort() async -> Int {
        await MainActor.run { ServerController.appShellSettingsForConfigureTool().port }
    }

    static func run(spec: HTTPSpec, context: WorkflowNodeContext, transport: Transport) async throws
        -> WorkflowNodeOutcome
    {
        let method = spec.method.uppercased()
        guard allowedMethods.contains(method) else {
            throw WorkflowNodeError.unsupported(L("HTTP method \(method) is not supported."))
        }
        let hosts = Set(spec.hosts)
        let urlText = BindingRenderer.renderText(spec.url, in: context.bindings)
        var queryItems: [URLQueryItem] = []
        for (name, template) in spec.query.sorted(by: { $0.key < $1.key }) {
            queryItems.append(URLQueryItem(name: name, value: BindingRenderer.renderText(template, in: context.bindings)))
        }
        var headers: [String: String] = [:]
        for (name, template) in spec.headers {
            headers[name] = BindingRenderer.renderText(template, in: context.bindings)
        }
        func secret(_ key: String) throws -> String {
            guard let value = context.secrets[key], !value.isEmpty else {
                throw WorkflowNodeError.missingSecret(key: key, forAgent: context.caller.credentialAgentID != nil)
            }
            return value
        }
        if let auth = spec.auth {
            switch auth {
            case .bearer(let key), .connection(let key):
                headers["Authorization"] = "Bearer " + (try secret(key))
            case .basic(let userKey, let passwordKey):
                // Token-style APIs send the token as the user with no password.
                let user = userKey.isEmpty ? "" : try secret(userKey)
                let password = try secret(passwordKey)
                headers["Authorization"] = "Basic " + Data((user + ":" + password).utf8).base64EncodedString()
            case .header(let name, let key):
                headers[name] = try secret(key)
            case .query(let name, let key):
                queryItems.append(URLQueryItem(name: name, value: try secret(key)))
            }
        }
        guard let firstURL = url(urlText, adding: queryItems) else {
            throw WorkflowNodeError.unsupported(L("\"\(spec.url)\" did not render to a valid URL."))
        }
        var body: Data?
        var contentType: String?
        if let template = spec.body, method != "GET", method != "HEAD" {
            let rendered = BindingRenderer.render(template, in: context.bindings)
            switch rendered {
            case .string(let text):
                body = Data(text.utf8)
            default:
                body = Data(rendered.compactJSONString.utf8)
                contentType = "application/json"
            }
        }
        if headers["Accept"] == nil, headers["accept"] == nil, spec.response == .json {
            headers["Accept"] = "application/json"
        }
        let plan = RequestPlan(
            method: method, headers: headers, body: body, contentType: contentType, hosts: hosts,
            timeout: max(1, context.timeout), response: spec.response, failOnError: spec.failOnError)

        guard let paginate = spec.paginate else {
            let page = try await fetch(firstURL, plan: plan, transport: transport)
            return WorkflowNodeOutcome(output: page.output(), logs: [page.log], fetches: [page.line])
        }
        return try await paginated(firstURL, paginate: paginate, plan: plan, transport: transport)
    }

    /// Everything about the request that stays the same from page to page.
    struct RequestPlan {
        var method: String
        var headers: [String: String]
        var body: Data?
        var contentType: String?
        var hosts: Set<String>
        var timeout: TimeInterval
        var response: HTTPSpec.ResponseMode
        var failOnError: Bool
    }

    /// One response, parsed, with the lines the run record keeps.
    struct Page {
        var status: Int
        var ok: Bool
        var headers: [String: JSONValue]
        var body: JSONValue
        var line: String
        var log: String

        func output() -> JSONValue {
            .object([
                "status": .number(Double(status)), "ok": .bool(ok), "headers": .object(headers), "body": body,
            ])
        }

        /// A response header by case-insensitive name.
        func header(_ name: String) -> String? { headers[name.lowercased()]?.stringValue }
    }

    static func url(_ text: String, adding items: [URLQueryItem]) -> URL? {
        guard !items.isEmpty else { return URL(string: text) }
        guard var components = URLComponents(string: text) else { return nil }
        components.queryItems = (components.queryItems ?? []) + items
        return components.url
    }

    /// Performs one request against the plan and shapes the response.
    static func fetch(_ url: URL, plan: RequestPlan, transport: Transport) async throws -> Page {
        if let problem = isAllowed(url, hosts: plan.hosts, osaurusPort: await osaurusPort()) {
            throw WorkflowNodeError.unsupported(problem)
        }
        var request = URLRequest(url: url)
        request.httpMethod = plan.method
        request.timeoutInterval = plan.timeout
        for (name, value) in plan.headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body = plan.body {
            request.httpBody = body
            if let contentType = plan.contentType, request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
        }

        let started = Date()
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.perform(request, plan.hosts)
        } catch let error as WorkflowNodeError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let ns = error as NSError
            let retryable =
                ns.domain == NSURLErrorDomain
                && [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost,
                    NSURLErrorNotConnectedToInternet, NSURLErrorDNSLookupFailed].contains(ns.code)
            throw WorkflowNodeError.toolFailed(
                tool: "http", kind: "network_error", message: error.localizedDescription, retryable: retryable)
        }
        let line = "\(plan.method) \(url.host ?? "")\(url.path) → \(response.statusCode)"
        guard data.count <= maximumBodyBytes else {
            throw WorkflowNodeError.toolFailed(
                tool: "http", kind: "response_too_large",
                message: L("The response body is \(data.count) bytes; the limit is \(maximumBodyBytes)."),
                retryable: false)
        }
        // Session cookies are credentials, not data; they stay out of the
        // run record (the session never stores cookies either).
        var responseHeaders: [String: JSONValue] = [:]
        for (key, value) in response.allHeaderFields {
            let name = String(describing: key).lowercased()
            guard !HTTPSpec.droppedResponseHeaders.contains(name) else { continue }
            responseHeaders[name] = .string(String(describing: value))
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        let body: JSONValue
        switch plan.response {
        case .json: body = JSONValue.parse(text) ?? .string(text)
        case .text: body = .string(text)
        }
        let ok = (200 ..< 300).contains(response.statusCode)
        if !ok, plan.failOnError {
            let detail = text.prefix(300)
            throw WorkflowNodeError.toolFailed(
                tool: "http", kind: "http_\(response.statusCode)",
                message: L("\(line)\(detail.isEmpty ? "" : ": \(detail)")"),
                retryable: response.statusCode == 429 || response.statusCode >= 500)
        }
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        return Page(
            status: response.statusCode, ok: ok, headers: responseHeaders, body: body, line: line,
            log: L("\(line) in \(durationMs) ms"))
    }

    // MARK: - Pagination

    /// Walks pages from `first` until the API runs out, the cap is hit, or
    /// a page fails. Items are merged in order; a repeated page URL ends
    /// the walk (an API that keeps returning the same cursor would loop).
    static func paginated(_ first: URL, paginate: HTTPPagination, plan: RequestPlan, transport: Transport)
        async throws -> WorkflowNodeOutcome
    {
        if let issue = paginate.issues.first { throw WorkflowNodeError.unsupported(L("http \(issue)")) }
        let maxPages = paginate.effectiveMaxPages
        let maxItems = min(paginate.maxItems ?? HTTPPagination.maximumItems, HTTPPagination.maximumItems)
        var items: [JSONValue] = []
        var logs: [String] = []
        var fetches: [String] = []
        var seen: Set<String> = []
        var next: URL? = first
        var pageNumber = paginate.startPage
        var last: Page?
        var complete = false
        let itemsLabel = paginate.itemsPath.isEmpty ? "(body)" : paginate.itemsPath
        if paginate.mode == .page { next = url(first, setting: paginate.pageParam, to: String(pageNumber)) }

        while let url = next, fetches.count < maxPages {
            guard seen.insert(url.absoluteString).inserted else {
                logs.append(L("Stopped: the API pointed back to a page already fetched."))
                complete = true
                break
            }
            let page = try await fetch(url, plan: plan, transport: transport)
            logs.append(page.log)
            fetches.append(page.line)
            last = page
            guard page.ok else {
                // `fail_on_error` is off: hand back what was collected.
                complete = false
                break
            }
            let pageItems = pageItems(page.body, path: paginate.itemsPath)
            guard let pageItems else {
                throw WorkflowNodeError.toolFailed(
                    tool: "http", kind: "pagination_shape",
                    message: L("Page \(fetches.count) has no array at `\(itemsLabel)`; check `paginate.items_path`."),
                    retryable: false)
            }
            items += pageItems
            if items.count >= maxItems {
                items = Array(items.prefix(maxItems))
                complete = false
                logs.append(L("Stopped at \(maxItems) items (`max_items`)."))
                break
            }
            switch paginate.mode {
            case .cursor:
                let cursor = page.body.value(atPath: paginate.cursorPath ?? "")
                if let cursorText = cursorString(cursor), !cursorText.isEmpty {
                    next = self.url(first, setting: paginate.cursorParam, to: cursorText)
                } else {
                    next = nil
                    complete = true
                }
            case .nextURL:
                if let text = page.body.value(atPath: paginate.nextURLPath ?? "")?.stringValue, !text.isEmpty {
                    guard let candidate = URL(string: text, relativeTo: url)?.absoluteURL else {
                        throw WorkflowNodeError.toolFailed(
                            tool: "http", kind: "pagination_shape",
                            message: L("The next page URL \"\(text.prefix(120))\" is not a valid URL."), retryable: false)
                    }
                    next = candidate
                } else {
                    next = nil
                    complete = true
                }
            case .link:
                if let link = page.header("Link"), let text = nextLink(link) {
                    guard let candidate = URL(string: text, relativeTo: url)?.absoluteURL else {
                        throw WorkflowNodeError.toolFailed(
                            tool: "http", kind: "pagination_shape",
                            message: L("The Link header's next URL is not valid."), retryable: false)
                    }
                    next = candidate
                } else {
                    next = nil
                    complete = true
                }
            case .page:
                if pageItems.isEmpty {
                    next = nil
                    complete = true
                } else {
                    pageNumber += 1
                    next = self.url(first, setting: paginate.pageParam, to: String(pageNumber))
                }
            }
        }
        if next != nil, !complete, fetches.count >= maxPages {
            logs.append(L("Stopped after \(maxPages) pages (`max_pages`); more may remain."))
        }
        guard let last else {
            throw WorkflowNodeError.unsupported(L("\"\(first.absoluteString)\" could not be requested."))
        }
        return WorkflowNodeOutcome(
            output: .object([
                "status": .number(Double(last.status)), "ok": .bool(last.ok), "headers": .object(last.headers),
                "body": .array(items), "pages": .number(Double(fetches.count)), "complete": .bool(complete),
            ]),
            logs: logs, fetches: fetches)
    }

    /// The array a page carries at `path` (the body itself when empty), or
    /// nil when there is no array there.
    static func pageItems(_ body: JSONValue, path: String) -> [JSONValue]? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        let value = trimmed.isEmpty ? body : body.value(atPath: trimmed)
        if case .array(let items)? = value { return items }
        if trimmed.isEmpty, value != nil, value != .null { return nil }
        // A missing key on an otherwise valid page means no items.
        if value == nil || value == .null { return [] }
        return nil
    }

    static func cursorString(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let s)?: return s
        case .number(let n)?: return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool, .null, .array, .object, nil: return nil
        }
    }

    /// `url` with the query parameter `name` set to `value` (replacing an
    /// earlier value of the same name).
    static func url(_ url: URL, setting name: String, to value: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = (components.queryItems ?? []).filter { $0.name != name }
        items.append(URLQueryItem(name: name, value: value))
        components.queryItems = items
        return components.url
    }

    /// The `rel="next"` target of an RFC 8288 `Link` header, if any.
    static func nextLink(_ header: String) -> String? {
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let target = pieces.first, target.hasPrefix("<"), target.hasSuffix(">") else { continue }
            let isNext = pieces.dropFirst().contains { param in
                let lowered = param.lowercased().replacingOccurrences(of: " ", with: "")
                return lowered == "rel=\"next\"" || lowered == "rel=next" || lowered.hasPrefix("rel=\"next ")
                    || lowered.hasSuffix(" next\"")
            }
            if isNext { return String(target.dropFirst().dropLast()) }
        }
        return nil
    }
}
