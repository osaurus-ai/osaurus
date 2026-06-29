//
//  ProviderReplayDiagnostics.swift
//  osaurus
//
//  Redacted request/response evidence for provider connectivity failures.
//

import Foundation

public struct ProviderReplayDiagnosticHeader: Sendable, Equatable {
    public let name: String
    public let value: String
}

public struct ProviderReplayDiagnosticRequest: Sendable, Equatable {
    public let method: String
    public let url: String
    public let timeout: TimeInterval
    public let headers: [ProviderReplayDiagnosticHeader]
    public let body: String?
}

public struct ProviderReplayDiagnosticResponse: Sendable, Equatable {
    public let statusCode: Int
    public let url: String
    public let headers: [ProviderReplayDiagnosticHeader]
    public let body: String?
}

public struct ProviderReplayDiagnosticBundle: Sendable, Equatable {
    public let phase: String
    public let request: ProviderReplayDiagnosticRequest
    public let response: ProviderReplayDiagnosticResponse?
    public let transportError: String?

    public init(
        phase: String,
        request: URLRequest,
        response: HTTPURLResponse? = nil,
        responseData: Data? = nil,
        transportError: Error? = nil,
        configuredSecretHeaderKeys: [String] = []
    ) {
        self.phase = ProviderDiagnosticRedactor.safe(phase, maxLength: 120)
        self.request = ProviderReplayDiagnosticRequest(
            method: request.httpMethod ?? "GET",
            url: ProviderDiagnosticRedactor.redactedURLString(request.url),
            timeout: request.timeoutInterval,
            headers: ProviderDiagnosticRedactor.redactedHeaderList(
                request.allHTTPHeaderFields ?? [:],
                configuredSecretHeaderKeys: configuredSecretHeaderKeys
            ),
            body: ProviderDiagnosticRedactor.redactedBodyExcerpt(request.httpBody)
        )
        self.response = response.map { httpResponse in
            ProviderReplayDiagnosticResponse(
                statusCode: httpResponse.statusCode,
                url: ProviderDiagnosticRedactor.redactedURLString(httpResponse.url),
                headers: ProviderDiagnosticRedactor.redactedHeaderList(
                    httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                        guard let name = pair.key as? String else { return }
                        result[name] = String(describing: pair.value)
                    },
                    configuredSecretHeaderKeys: configuredSecretHeaderKeys
                ),
                body: ProviderDiagnosticRedactor.redactedBodyExcerpt(responseData)
            )
        }
        self.transportError = transportError.map {
            ProviderDiagnosticRedactor.safe($0.localizedDescription, maxLength: 500)
        }
    }

    public var summary: String {
        if let response {
            return "\(request.method) \(request.url) -> HTTP \(response.statusCode)"
        }
        if transportError != nil {
            return "\(request.method) \(request.url) -> transport error"
        }
        return "\(request.method) \(request.url)"
    }

    public var pasteboardText: String {
        var lines = [
            "Provider request evidence:",
            "phase: \(phase)",
            "request: \(request.method) \(request.url)",
            "request_timeout_seconds: \(formatSeconds(request.timeout))",
            "request_headers: \(formatHeaders(request.headers))",
        ]
        if let body = request.body {
            lines.append("request_body: \(body)")
        }
        if let response {
            lines.append("response: HTTP \(response.statusCode) \(response.url)")
            lines.append("response_headers: \(formatHeaders(response.headers))")
            if let body = response.body {
                lines.append("response_body: \(body)")
            }
        }
        if let transportError {
            lines.append("transport_error: \(transportError)")
        }
        return lines.joined(separator: "\n")
    }

    private func formatSeconds(_ value: TimeInterval) -> String {
        if value.isFinite {
            return String(format: "%.1f", value)
        }
        return "unbounded"
    }

    private func formatHeaders(_ headers: [ProviderReplayDiagnosticHeader]) -> String {
        guard !headers.isEmpty else { return "none" }
        return
            headers
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }
}

enum ProviderDiagnosticRedactor {
    private static let sensitiveFieldNames: Set<String> = [
        "access_token",
        "api_key",
        "apikey",
        "authorization",
        "client_secret",
        "code",
        "code_verifier",
        "id_token",
        "key",
        "password",
        "refresh_token",
        "secret",
        "token",
        "verifier",
    ]

    static func redactedURLString(_ url: URL?) -> String {
        guard let url else { return "unknown" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return safe(url.absoluteString, maxLength: 700)
        }

        if components.user?.isEmpty == false {
            components.user = "***"
        }
        if components.password?.isEmpty == false {
            components.password = "***"
        }
        if let queryItems = components.queryItems {
            components.queryItems = queryItems.map { item in
                guard isSensitiveFieldName(item.name) else { return item }
                return URLQueryItem(name: item.name, value: "***")
            }
        }

        return safe(components.url?.absoluteString ?? url.absoluteString, maxLength: 700)
    }

    static func redactedHeaderList(
        _ headers: [String: String],
        configuredSecretHeaderKeys: [String] = []
    ) -> [ProviderReplayDiagnosticHeader] {
        headers
            .map { name, value in
                let redacted = RemoteProviderHeaderRedactor.valueForLogging(
                    headerName: name,
                    value: value,
                    configuredSecretHeaderKeys: configuredSecretHeaderKeys
                )
                return ProviderReplayDiagnosticHeader(
                    name: safe(name, maxLength: 120),
                    value: redacted == RemoteProviderHeaderRedactor.redactedValue
                        ? redacted
                        : safe(redacted, maxLength: 300)
                )
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func redactedBodyExcerpt(_ data: Data?, maxBytes: Int = 1600) -> String? {
        guard let data, !data.isEmpty else { return nil }
        let excerptData = Data(data.prefix(maxBytes))
        let raw =
            String(data: excerptData, encoding: .utf8)
            ?? excerptData.map { String(format: "%02x", $0) }.joined()
        let suffix = data.count > maxBytes ? " ... [truncated \(data.count - maxBytes) bytes]" : ""
        return safe(raw, maxLength: maxBytes) + suffix
    }

    static func safe(_ raw: String, maxLength: Int = 700) -> String {
        var value = raw
        let replacements: [(pattern: String, template: String)] = [
            (#"(?i)\b(authorization|proxy-authorization)\s*[:=]\s*(?:bearer\s+)?[^\s,;}]+\"?"#, "$1=***"),
            (#"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]+"#, "$1 ***"),
            (
                #"(?i)\"(access_token|refresh_token|id_token|code_verifier|code|verifier|client_secret|api_key|apikey|password|secret|token|key)\"\s*:\s*\"[^\"]*\""#,
                #""$1":"***""#
            ),
            (
                #"(?i)\b(access_token|refresh_token|id_token|code_verifier|code|verifier|client_secret|api_key|apikey|password|secret|token|key)\s*=\s*([^&\s,;}]+)"#,
                "$1=***"
            ),
            (
                #"(?i)\b(api[-_]?key|x[-_]?api[-_]?key|x[-_]?goog[-_]?api[-_]?key|password|secret|token|client_secret)\s*:\s*([^\s,;}]+)"#,
                "$1=***"
            ),
            (#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, "jwt=***"),
            (#"\bsk-[A-Za-z0-9._-]{8,}\b"#, "sk-***"),
            (#"\bosk-[A-Za-z0-9._-]{8,}\b"#, "osk-***"),
        ]

        for replacement in replacements {
            value = replaceMatches(
                in: value,
                pattern: replacement.pattern,
                template: replacement.template
            )
        }

        value =
            value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while value.contains("  ") {
            value = value.replacingOccurrences(of: "  ", with: " ")
        }
        guard !value.isEmpty else { return "No details returned" }
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength)) + "..."
    }

    private static func isSensitiveFieldName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if sensitiveFieldNames.contains(normalized) {
            return true
        }
        return normalized.contains("token")
            || normalized.contains("secret")
            || normalized.contains("password")
            || normalized.contains("api_key")
            || normalized.contains("apikey")
    }

    private static func replaceMatches(
        in value: String,
        pattern: String,
        template: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }
}
