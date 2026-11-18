//
//  CodexClientVersionStore.swift
//  osaurus
//
//  The Codex client version every ChatGPT sign-in request names. ChatGPT lists a model only to a client at or above
//  that model's `minimal_client_version`, so a new model stayed hidden until an app release raised
//  `OpenAICodexOAuthService.codexClientVersion`. Osaurus now publishes a checked version at
//  https://osaurus.ai/clients/codex.json (the osaurus-website repository; its daily codex-watch cron opens a PR when
//  Codex ships a release, and a person merges it after one live turn), and this store adopts it.
//
//  The version is a claim about what our requests look like, and a bad one breaks every ChatGPT chat at once, so a
//  published value is only ever a raise: plain x.y.z, the built-in version's major, at or above it. Anything else is
//  refused and the last good copy (or the built-in version) stands. The last good copy lives at
//  `~/.osaurus/codex-client.json`. The Windows app reads the same file with the same rules
//  (osaurus-win docs/codex-client-version.md).
//

import Foundation
import os

public final class CodexClientVersionStore: @unchecked Sendable {
    public enum Source: String, Sendable, Equatable {
        case builtIn = "built_in"
        case published
    }

    public struct Current: Sendable, Equatable {
        public let version: String
        public let source: Source
        /// The publish file's `checked` date (when Osaurus tested the version); nil for the built-in version.
        public let checked: String?
        /// When this Mac last read the file successfully; nil when it never has.
        public let fetchedAt: Date?
    }

    public enum Outcome: String, Sendable, Equatable {
        /// Read, and different from the version in use before.
        case updated
        /// Read, and the version already in use.
        case unchanged
        /// The site answered with something this build may not adopt; the last good copy stands.
        case rejected
        /// The site could not be reached; the last good copy stands.
        case unreachable
        /// Reading is switched off (`OSAURUS_CODEX_CLIENT_URL=off`); the built-in version is in use.
        case off
    }

    public struct Refresh: Sendable, Equatable {
        public let outcome: Outcome
        public let version: String
        public let source: Source
    }

    public static let defaultURL = URL(string: "https://osaurus.ai/clients/codex.json")!
    public static let urlVariable = "OSAURUS_CODEX_CLIENT_URL"
    public static let fileName = "codex-client.json"
    public static let maxBytes = 16 * 1024
    public static let refreshEvery: TimeInterval = 24 * 60 * 60
    /// Long enough that listings never hammer the site after a failure, short enough that a merged change is not a day
    /// late after a blip.
    public static let retryAfterFailure: TimeInterval = 60 * 60

    public static var builtIn: String { OpenAICodexOAuthService.codexClientVersion }

    /// The store the app uses: `~/.osaurus/codex-client.json`, the URL from the environment.
    public static let shared: CodexClientVersionStore = {
        let url = configuredURL()
        return CodexClientVersionStore(
            fileURL: OsaurusPaths.root().appendingPathComponent(fileName),
            url: url ?? defaultURL,
            fetch: url == nil ? nil : CodexClientVersionStore.httpFetch
        )
    }()

    /// `defaultURL` unless the environment names another; nil when it says `off`.
    public static func configuredURL() -> URL? {
        guard let raw = ProcessEnvironment.value(urlVariable)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return defaultURL }
        if raw.caseInsensitiveCompare("off") == .orderedSame { return nil }
        return URL(string: raw) ?? defaultURL
    }

    private struct State {
        var current: Current?
        var inFlight: Task<Refresh, Never>?
        var lastFailure: Date?
    }

    private let fileURL: URL
    private let url: URL
    private let fetch: (@Sendable (URL) async throws -> Data)?
    private let now: @Sendable () -> Date
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// - Parameter fetch: reads the published file; nil switches reading off.
    public init(
        fileURL: URL,
        url: URL = CodexClientVersionStore.defaultURL,
        fetch: (@Sendable (URL) async throws -> Data)?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.url = url
        self.fetch = fetch
        self.now = now
    }

    /// The version in use: the last good published copy when it is still a raise over the built-in version, else the
    /// built-in version.
    public var current: Current {
        state.withLock { s in
            if let c = s.current { return c }
            let c = readCache()
            s.current = c
            return c
        }
    }

    /// The version string every request names.
    public var version: String { current.version }

    /// Reads the published file now. Concurrent callers share one read.
    @discardableResult
    public func refresh() async -> Refresh {
        guard fetch != nil else {
            let c = current
            return Refresh(outcome: .off, version: c.version, source: c.source)
        }
        let task: Task<Refresh, Never> = state.withLock { s in
            if let running = s.inFlight { return running }
            let started = Task { [self] in await self.readPublished() }
            s.inFlight = started
            return started
        }
        let result = await task.value
        state.withLock { s in
            s.inFlight = nil
            s.lastFailure = (result.outcome == .updated || result.outcome == .unchanged) ? nil : now()
        }
        return result
    }

    /// Starts a read in the background when the last good copy is a day old (an hour after a failed read). Never
    /// blocks: the caller goes on with `version`, and the next caller gets the new value.
    @discardableResult
    public func refreshInBackgroundIfStale() -> Task<Refresh, Never>? {
        guard fetch != nil else { return nil }
        let at = now()
        let due: Bool = state.withLock { s in
            if s.inFlight != nil { return false }
            if let failed = s.lastFailure, at.timeIntervalSince(failed) < Self.retryAfterFailure { return false }
            let c = s.current ?? readCache()
            s.current = c
            if let fetched = c.fetchedAt, at.timeIntervalSince(fetched) < Self.refreshEvery { return false }
            return true
        }
        guard due else { return nil }
        return Task { [self] in await self.refresh() }
    }

    private func readPublished() async -> Refresh {
        let before = current
        let data: Data
        do {
            data = try await fetch!(url)
        } catch {
            return Refresh(outcome: .unreachable, version: before.version, source: before.source)
        }
        guard let published = Self.parse(data) else {
            return Refresh(outcome: .rejected, version: before.version, source: before.source)
        }
        let at = now()
        let after = Self.orBuiltIn(published.version, checked: published.checked, fetchedAt: at)
        var doc: [String: String] = [
            "client_version": published.version,
            "fetched_at": ISO8601DateFormatter().string(from: at),
        ]
        if let checked = published.checked { doc["checked"] = checked }
        if let bytes = try? JSONSerialization.data(withJSONObject: doc) {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Still used for this run if the save fails; the next launch reads the built-in version until a read works.
            try? bytes.write(to: fileURL, options: .atomic)
        }
        state.withLock { $0.current = after }
        let changed = before.version != after.version
        return Refresh(outcome: changed ? .updated : .unchanged, version: after.version, source: after.source)
    }

    private func readCache() -> Current {
        guard let data = try? Data(contentsOf: fileURL),
            let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return Current(version: Self.builtIn, source: .builtIn, checked: nil, fetchedAt: nil) }
        let fetchedAt = (doc["fetched_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        // Re-checked on every read: an app update may have raised the built-in version past what this Mac fetched.
        guard let version = doc["client_version"] as? String, Self.acceptable(version) else {
            return Current(version: Self.builtIn, source: .builtIn, checked: nil, fetchedAt: fetchedAt)
        }
        return Self.orBuiltIn(version, checked: doc["checked"] as? String, fetchedAt: fetchedAt)
    }

    private static func orBuiltIn(_ version: String, checked: String?, fetchedAt: Date?) -> Current {
        compareVersions(version, builtIn) > 0
            ? Current(version: version, source: .published, checked: checked, fetchedAt: fetchedAt)
            : Current(version: builtIn, source: .builtIn, checked: nil, fetchedAt: fetchedAt)
    }

    struct Published: Equatable {
        let version: String
        let checked: String?
    }

    /// Reads the publish file: `{"version":1,"client_version":"x.y.z",…}`. Nil for anything this build may not adopt.
    static func parse(_ data: Data) -> Published? {
        guard data.count <= maxBytes,
            let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let format = doc["version"] as? NSNumber, CFGetTypeID(format) != CFBooleanGetTypeID(),
            format.intValue == 1, format.doubleValue == 1,
            let version = doc["client_version"] as? String,
            acceptable(version)
        else { return nil }
        return Published(version: version, checked: doc["checked"] as? String)
    }

    /// Plain x.y.z, the built-in version's major, and at or above it.
    static func acceptable(_ version: String) -> Bool {
        guard version.range(of: #"^(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})$"#,
            options: .regularExpression) != nil
        else { return false }
        return version.split(separator: ".").first == builtIn.split(separator: ".").first
            && compareVersions(version, builtIn) >= 0
    }

    /// Numeric x.y.z comparison; a missing or non-numeric part reads as 0.
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count, 3) {
            let d = (i < pa.count ? pa[i] : 0) - (i < pb.count ? pb[i] : 0)
            if d != 0 { return d < 0 ? -1 : 1 }
        }
        return 0
    }

    /// The line "Check for new models" shows: what the model list gained or lost, and when osaurus.ai could not be
    /// read, which version was used. The same wording as the Windows app.
    static func checkSentence(
        listRead: Bool, before: [String], after: [String], outcome: Outcome, version: String
    ) -> String {
        let had = Set(before)
        let has = Set(after)
        let added = after.filter { !had.contains($0) }
        let removed = before.filter { !has.contains($0) }
        var line: String
        if !listRead {
            line = L("ChatGPT's model list couldn't be read just now. Try again in a moment.")
        } else if !added.isEmpty {
            line = String(format: L("Added %@."), names(added))
        } else {
            line = L("Up to date. No new models from ChatGPT.")
        }
        if listRead, !removed.isEmpty {
            line += " " + String(format: L("No longer offered: %@."), names(removed))
        }
        if outcome == .unreachable || outcome == .rejected {
            line += " " + String(format: L("Couldn't check osaurus.ai for a newer Codex version, so %@ was used."), version)
        }
        return line
    }

    private static func names(_ ids: [String]) -> String {
        switch ids.count {
        case 1: return ids[0]
        case 2: return "\(ids[0]) and \(ids[1])"
        default: return ids.dropLast().joined(separator: ", ") + " and " + ids[ids.count - 1]
        }
    }

    /// One GET, 15 seconds, 200 only, at most `maxBytes`.
    @Sendable static func httpFetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= maxBytes else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }
}
