//
//  PluginHTTP.swift
//  osaurus
//
//  Request/response models for plugin HTTP route handling.
//

import Foundation

// MARK: - Request (Host → Plugin)

struct OsaurusHTTPRequest: Encodable {
    let route_id: String
    let method: String
    let path: String
    let query: [String: String]
    /// Path parameters extracted from `:name` segments in the route's
    /// declared path. For example, a route declared as `/items/:id`
    /// hit with `/items/abc` populates `path_params` as `["id": "abc"]`.
    /// Empty for routes without parameters.
    let path_params: [String: String]
    let headers: [String: String]
    let body: String
    let body_encoding: String
    let remote_addr: String
    let plugin_id: String
    let osaurus: OsaurusContext

    struct OsaurusContext: Encodable {
        let base_url: String
        let plugin_url: String
        let agent_address: String
    }
}

// MARK: - Response (Plugin → Host)

struct OsaurusHTTPResponse: Decodable {
    let status: Int
    let headers: [String: String]?
    let body: String?
    let body_encoding: String?
}

// MARK: - Helpers

extension OsaurusHTTPRequest {
    /// Parse query string parameters from a URI
    static func parseQueryParams(from uri: String) -> [String: String] {
        guard let queryIndex = uri.firstIndex(of: "?") else { return [:] }
        let queryString = String(uri[uri.index(after: queryIndex)...])
        var params: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let key = parts.first.flatMap({ String($0).removingPercentEncoding }) else { continue }
            let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? "") : ""
            params[key] = value
        }
        return params
    }
}

// MARK: - Rate Limiter

/// Simple per-plugin token bucket rate limiter for public/verify routes.
final class PluginRateLimiter: @unchecked Sendable {
    static let shared = PluginRateLimiter()

    private struct Bucket {
        var tokens: Double
        var lastRefill: Date
    }

    private var buckets: [String: Bucket] = [:]
    private let lock = NSLock()
    /// Last time idle buckets were swept. Keyed buckets (per plugin id, incl.
    /// anonymous / agent-scoped keys) previously accumulated forever; a
    /// periodic sweep drops fully-refilled (idle) buckets so the dict stays
    /// bounded by *active* callers.
    private var lastSweep = Date.distantPast
    private let sweepInterval: TimeInterval = 300

    private let maxTokens: Double = 100
    private let refillRate: Double = 100.0 / 60.0  // 100 per minute

    /// Returns true if the request is allowed, false if rate-limited.
    func allow(pluginId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        sweepIfNeeded(now: now)
        var bucket = buckets[pluginId] ?? Bucket(tokens: maxTokens, lastRefill: now)

        let elapsed = now.timeIntervalSince(bucket.lastRefill)
        bucket.tokens = min(maxTokens, bucket.tokens + elapsed * refillRate)
        bucket.lastRefill = now

        if bucket.tokens >= 1 {
            bucket.tokens -= 1
            buckets[pluginId] = bucket
            return true
        }

        buckets[pluginId] = bucket
        return false
    }

    /// Drop buckets that have been idle long enough to have fully refilled —
    /// they carry no rate-limit state worth keeping. Caller must hold `lock`.
    private func sweepIfNeeded(now: Date) {
        guard now.timeIntervalSince(lastSweep) >= sweepInterval else { return }
        lastSweep = now
        let fullAfter = maxTokens / refillRate
        buckets = buckets.filter { now.timeIntervalSince($0.value.lastRefill) < fullAfter }
    }
}

// MARK: - MIME Type

enum MIMEType {
    static func forExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "map": return "application/json"
        case "txt": return "text/plain; charset=utf-8"
        case "xml": return "application/xml"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }
}
