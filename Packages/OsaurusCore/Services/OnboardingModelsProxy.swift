//
//  OnboardingModelsProxy.swift
//  osaurus
//
//  Client for the Osaurus model download proxy — an authenticated Hugging
//  Face resolver used exclusively during onboarding. Anonymous HF downloads are
//  heavily throttled, and during onboarding the user hasn't had a chance to
//  add their own HF token yet; the proxy resolves files with Osaurus' own
//  server-side token (never shipped in the app) and returns a presigned CDN
//  URL, so the model bytes flow directly from HF's CDN at full speed.
//
//  Every method degrades to `nil` instead of throwing: the proxy is an
//  accelerator, not a gatekeeper, and callers fall back to the plain
//  anonymous huggingface.co URL on any failure.
//

import Foundation
import LocalAuthentication

struct OnboardingModelsProxy: Sendable {
    /// Payload of a successful `?mode=json` resolve: a presigned CDN URL plus
    /// the metadata needed for progress, resume verification, and pinning
    /// every shard of a repo to one commit.
    struct ResolvedFile: Decodable, Equatable, Sendable {
        let url: URL
        let etag: String?
        let size: Int64?
        let commit: String?
    }

    static let shared = OnboardingModelsProxy()

    /// Resolved once at startup; `nil` means "no proxy configured" and every
    /// download takes the anonymous HF route. Kept out of source on purpose —
    /// see `resolveBaseURL()`.
    var baseURL: URL? = resolveBaseURL()
    var session: URLSession = .shared

    /// The proxy endpoint is deliberately not hardcoded. Same scheme as the
    /// Sentry DSN (`CrashReportingService.resolveDSNFromConfig`):
    ///   1. (DEBUG only) `MODELS_PROXY_BASE_URL` environment variable — local
    ///      one-off override; compiled out of Release.
    ///   2. `ModelsProxyBaseURL` in Info.plist, populated by the
    ///      `$(MODELS_PROXY_BASE_URL)` build setting — from the gitignored
    ///      `App/osaurus/Secrets.xcconfig` in DEBUG, injected by CI in Release.
    ///      Remember the xcconfig `//`-comment footgun: escape the scheme as
    ///      `https:$(SLASH)$(SLASH)…` with `SLASH = /`.
    /// Unconfigured builds (open-source, forks) get `nil` and fall back to
    /// anonymous Hugging Face downloads.
    static func resolveBaseURL() -> URL? {
        #if DEBUG
            if let env = ProcessInfo.processInfo.environment["MODELS_PROXY_BASE_URL"],
                !env.isEmpty
            {
                return URL(string: env)
            }
        #endif
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "ModelsProxyBaseURL") as? String,
            raw.contains("://")
        else { return nil }
        return URL(string: raw)
    }

    // MARK: - Auth message

    /// The osaurus-models signing message. Same EIP-191 signed-header scheme
    /// as osaurus-router, but simpler: no body hash and no nonce, since every
    /// proxy endpoint is GET/HEAD.
    static func authMessage(
        address: String,
        method: String,
        pathAndQuery: String,
        timestamp: Int
    ) -> String {
        "osaurus-models:\(address.lowercased()):\(method.uppercased()):\(pathAndQuery):\(timestamp)"
    }

    static func signHeaders(
        method: String,
        pathAndQuery: String,
        timestamp: Int,
        privateKey: Data
    ) throws -> OsaurusRouterAuthSigner.SignedHeaders {
        let address = try OsaurusRouterAuthSigner.evmAddress(privateKey: privateKey).lowercased()
        let message = authMessage(
            address: address,
            method: method,
            pathAndQuery: pathAndQuery,
            timestamp: timestamp
        )
        let signature = try signEIP191Message(message, privateKey: privateKey).hexEncodedString
        return OsaurusRouterAuthSigner.SignedHeaders(
            address: address,
            timestamp: timestamp,
            signature: "0x\(signature)",
            nonce: nil
        )
    }

    // MARK: - Request building

    /// The resolve URL for one repo file, always with `mode=json`: a JSON
    /// payload avoids `URLSession`'s redirect handler re-sending the signed
    /// wallet headers to the CDN host.
    static func resolveRequestURL(
        baseURL: URL,
        repoId: String,
        revision: String,
        path: String
    ) -> URL? {
        guard let safePath = HuggingFaceService.normalizedRemoteFilePath(path),
            !repoId.isEmpty, !revision.isEmpty,
            !revision.contains("/"), !revision.contains("?")
        else { return nil }
        var comps = URLComponents()
        comps.path = "/v1/\(repoId)/resolve/\(revision)/\(safePath)"
        comps.queryItems = [URLQueryItem(name: "mode", value: "json")]
        return comps.url(relativeTo: baseURL)?.absoluteURL
    }

    /// Path+query exactly as sent on the wire (percent-encoded) — the server
    /// verifies the signature against the raw request target.
    static func pathAndQuery(for url: URL) -> String {
        var path = url.path(percentEncoded: true)
        if path.isEmpty { path = "/" }
        if let query = url.query(percentEncoded: true), !query.isEmpty {
            path += "?\(query)"
        }
        return path
    }

    // MARK: - Response parsing

    /// A resolve payload must carry a `url` key. Small non-LFS files come
    /// back as the file body inline instead — those parse as `nil` here and
    /// the caller falls back to the direct HF URL, which serves small files
    /// fine anonymously.
    static func parseResolvePayload(_ data: Data) -> ResolvedFile? {
        try? JSONDecoder().decode(ResolvedFile.self, from: data)
    }

    // MARK: - Resolve

    /// Resolve one repo file to a presigned CDN URL. Returns `nil` on any
    /// failure — missing identity, signing failure, rate limit, server or
    /// network error — so the caller can fall back to anonymous HF.
    func resolve(repoId: String, revision: String, path: String) async -> ResolvedFile? {
        guard let baseURL,
            let url = Self.resolveRequestURL(
                baseURL: baseURL,
                repoId: repoId,
                revision: revision,
                path: path
            )
        else { return nil }

        guard let request = await signedRequest(for: url) else { return nil }

        // One bounded retry on 429 — the proxy's token bucket refills
        // continuously, so a short pause is usually enough.
        for attempt in 0 ..< 2 {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { return nil }
                if http.statusCode == 429, attempt == 0 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                guard http.statusCode == 200 else { return nil }
                return Self.parseResolvePayload(data)
            } catch {
                return nil
            }
        }
        return nil
    }

    /// Build a signed GET request for `url`, or `nil` when no identity is
    /// available or the master key can't be read without user interaction.
    /// Key read and signing run off the calling thread — the keychain read
    /// is synchronous and must never land on the main thread.
    private func signedRequest(for url: URL) async -> URLRequest? {
        let pathAndQuery = Self.pathAndQuery(for: url)
        let headers = await Task.detached(priority: .userInitiated) {
            () -> OsaurusRouterAuthSigner.SignedHeaders? in
            // Existence check and key read both hit the keychain synchronously
            // (blocking on securityd's mutex), so they must stay inside this
            // detached task — callers are on the main actor mid-download.
            guard MasterKey.exists() else { return nil }
            // Never prompt for biometrics mid-onboarding; a key that needs
            // interaction just means "use the anonymous fallback".
            let context = LAContext()
            context.interactionNotAllowed = true
            guard var privateKey = try? MasterKey.getPrivateKey(context: context) else {
                return nil
            }
            defer { privateKey.zeroOut() }
            return try? Self.signHeaders(
                method: "GET",
                pathAndQuery: pathAndQuery,
                timestamp: Int(Date().timeIntervalSince1970),
                privateKey: privateKey
            )
        }.value
        guard let headers else { return nil }

        var request = URLRequest(url: url)
        for (name, value) in headers.values {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}
