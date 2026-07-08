//
//  DeclarativeSearchBackend.swift
//  osaurus
//
//  Generic REST executor for `SearchProviderDefinition`s. One implementation
//  covers every bundled API provider and every user-created custom provider:
//  it renders the endpoint's request templates, injects secrets, performs the
//  HTTP call, and applies the response key-path mapping to produce normalized
//  `SearchHit`s.
//

import Foundation

struct DeclarativeSearchBackend: SearchBackend {
    let definition: SearchProviderDefinition
    /// Secret field id -> value, resolved by the caller (Keychain in
    /// production, fixtures in tests).
    let secrets: [String: String]

    var definitionId: String { definition.id }

    func search(_ request: SearchRequest) async throws -> [SearchHit] {
        guard let endpoint = definition.endpoints?[request.category] else {
            throw SearchBackendError(
                "\(definition.name) does not support \(request.category) search",
                kind: .unsupportedCategory
            )
        }
        try validateSecrets()

        let built = try Self.buildRequest(
            endpoint: endpoint,
            request: request,
            secrets: secrets,
            providerName: definition.name
        )

        let timeout = endpoint.timeout ?? 15
        let (status, data) = try await SearchHTTPClient.request(
            url: built.url,
            method: endpoint.method.uppercased(),
            headers: built.headers,
            body: built.body,
            timeout: timeout
        )
        guard status == 200 else {
            let kind: SearchFailureKind = (status == 401 || status == 403) ? .providerAuth : .providerHTTP
            throw SearchBackendError("\(definition.name) returned status \(status)", kind: kind)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw SearchBackendError("\(definition.name) returned a non-JSON response", kind: .providerHTTP)
        }
        return Self.mapResponse(
            json,
            mapping: endpoint.response,
            engine: definition.id,
            maxResults: request.maxResults
        )
    }

    private func validateSecrets() throws {
        for field in definition.secrets ?? [] {
            let value = secrets[field.id]
            if value == nil || value?.isEmpty == true {
                throw SearchBackendError("\(field.label) not configured", kind: .providerAuth)
            }
        }
    }

    // MARK: - Request building

    struct BuiltRequest: Equatable {
        var url: String
        var headers: [String: String]
        var body: Data?
    }

    /// Render an endpoint into a concrete HTTP request. Static and pure so
    /// tests can validate every bundled definition against fixtures.
    static func buildRequest(
        endpoint: SearchEndpoint,
        request: SearchRequest,
        secrets: [String: String],
        providerName: String
    ) throws -> BuiltRequest {
        var urlString = endpoint.url

        // Query string
        var queryItems: [String] = []
        for param in endpoint.query {
            guard let resolved = resolveParam(param, request: request, secrets: secrets) else { continue }
            queryItems.append("\(param.name)=\(SearchHTML.urlEncode(resolved.stringValue))")
        }
        if !queryItems.isEmpty {
            urlString += (urlString.contains("?") ? "&" : "?") + queryItems.joined(separator: "&")
        }

        // Headers
        var headers: [String: String] = [:]
        for (name, template) in endpoint.headers {
            headers[name] = substitute(template, request: request, secrets: secrets)
        }

        // JSON body
        var bodyData: Data?
        if !endpoint.body.isEmpty {
            var body: [String: Any] = [:]
            for param in endpoint.body {
                guard let resolved = resolveParam(param, request: request, secrets: secrets) else { continue }
                body[param.name] = resolved.jsonValue
            }
            guard let data = try? JSONSerialization.data(withJSONObject: body) else {
                throw SearchBackendError("Failed to encode \(providerName) request", kind: .providerHTTP)
            }
            bodyData = data
        }

        return BuiltRequest(url: urlString, headers: headers, body: bodyData)
    }

    /// Resolved parameter value; carries both string and typed representations.
    private struct ResolvedValue {
        var stringValue: String
        var jsonValue: Any
    }

    /// Resolve one request param: substitute template, apply value map,
    /// honor omitIfEmpty, and coerce typed body params ("int" with clamp,
    /// "json" literals, "string_array" wrapping).
    private static func resolveParam(
        _ param: SearchRequestParam,
        request: SearchRequest,
        secrets: [String: String]
    ) -> ResolvedValue? {
        var value = substitute(param.value, request: request, secrets: secrets)
        if let map = param.map {
            value = map[value] ?? ""
        }
        if param.omitIfEmpty == true, value.isEmpty {
            return nil
        }
        if param.type == "int" || param.clampMax != nil {
            var n = Int(value) ?? 0
            if let clamp = param.clampMax { n = min(n, clamp) }
            if param.type == "int" {
                return ResolvedValue(stringValue: String(n), jsonValue: n)
            }
            return ResolvedValue(stringValue: String(n), jsonValue: String(n))
        }
        if param.type == "json" {
            // The template is a JSON literal (object/array/scalar) after
            // substitution — e.g. Exa's `"contents": {"highlights": true}`.
            // `.fragmentsAllowed` accepts bare scalars too.
            guard let data = value.data(using: .utf8),
                let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { return nil }
            return ResolvedValue(stringValue: value, jsonValue: parsed)
        }
        if param.type == "string_array" {
            return ResolvedValue(stringValue: value, jsonValue: [value])
        }
        return ResolvedValue(stringValue: value, jsonValue: value)
    }

    /// ISO date (yyyy-MM-dd) for the start of a canonical time range, used by
    /// APIs that filter on an absolute date instead of a relative code
    /// (e.g. Exa's `startPublishedDate`). Empty when no time range is set.
    static func afterDate(for timeRange: String?, now: Date = Date()) -> String {
        let component: Calendar.Component
        switch timeRange {
        case "d": component = .day
        case "w": component = .weekOfYear
        case "m": component = .month
        case "y": component = .year
        default: return ""
        }
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(byAdding: component, value: -1, to: now) else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Substitute `{{...}}` placeholders in a template.
    static func substitute(
        _ template: String,
        request: SearchRequest,
        secrets: [String: String]
    ) -> String {
        guard template.contains("{{") else { return template }
        let page = request.offset / max(1, request.maxResults) + 1
        var out = template
        let simple: [String: String] = [
            "{{query}}": request.augmentedQuery,
            "{{raw_query}}": request.query,
            "{{max_results}}": String(request.maxResults),
            "{{offset}}": String(request.offset),
            "{{page}}": String(page),
            "{{start}}": String(request.offset + 1),
            "{{time_range}}": request.timeRange ?? "",
            "{{after_date}}": afterDate(for: request.timeRange),
            "{{region}}": request.region ?? "",
            "{{category}}": request.category,
        ]
        for (placeholder, value) in simple where out.contains(placeholder) {
            out = out.replacingOccurrences(of: placeholder, with: value)
        }
        // {{secret.<id>}}
        if out.contains("{{secret.") {
            for (id, value) in secrets {
                out = out.replacingOccurrences(of: "{{secret.\(id)}}", with: value)
            }
            // Any unresolved secret placeholder becomes empty rather than a literal.
            if let regex = try? NSRegularExpression(pattern: "\\{\\{secret\\.[^}]+\\}\\}") {
                out = regex.stringByReplacingMatches(
                    in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
            }
        }
        return out
    }

    // MARK: - Response mapping

    /// Apply the response mapping to a decoded JSON tree. Static and pure for
    /// fixture-based tests.
    static func mapResponse(
        _ json: Any,
        mapping: SearchResponseMapping,
        engine: String,
        maxResults: Int
    ) -> [SearchHit] {
        guard let items = SearchJSONPath.firstValue(at: mapping.resultsPath, in: json) as? [[String: Any]] else {
            return []
        }
        var hits: [SearchHit] = []
        for item in items {
            if let filter = mapping.filter {
                let actual = SearchJSONPath.string(at: filter.path, in: item)
                if actual != filter.equals { continue }
            }
            let fields = mapping.item
            let hit = SearchHit(
                title: fields.title.flatMap { SearchJSONPath.string(at: $0, in: item) } ?? "",
                url: fields.url.flatMap { SearchJSONPath.string(at: $0, in: item) } ?? "",
                snippet: fields.snippet.flatMap { SearchJSONPath.string(at: $0, in: item) } ?? "",
                publishedDate: fields.publishedDate.flatMap { SearchJSONPath.string(at: $0, in: item) },
                sourceDomain: fields.sourceDomain.flatMap { SearchJSONPath.string(at: $0, in: item) },
                engine: engine,
                imageURL: fields.imageURL.flatMap { SearchJSONPath.string(at: $0, in: item) },
                thumbnailURL: fields.thumbnailURL.flatMap { SearchJSONPath.string(at: $0, in: item) }
            )
            hits.append(hit)
            if hits.count >= maxResults { break }
        }
        return hits
    }
}
