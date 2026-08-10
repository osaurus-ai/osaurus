//
//  CentralRepositoryManager.swift
//  osaurus
//
//  Manages the local copy of the central plugin specs repository.
//  Refreshes via GitHub's source-archive endpoint (no `git` binary required).
//

import Foundation

public struct CentralRepository {
    public let url: String
    public let branch: String?
    public init(url: String, branch: String? = nil) {
        self.url = url
        self.branch = branch
    }
}

public struct CentralRepositoryRefreshResult: Equatable, Sendable {
    public let succeeded: Bool
    public let repositoryURL: String
    public let attemptedArchiveURLs: [String]
    public let refreshedAt: Date?
    public let cacheAvailable: Bool
    public let cacheUpdatedAt: Date?
    public let failure: CentralRepositoryRefreshFailure?

    public var userMessage: String? {
        failure?.userMessage
    }
}

public struct CentralRepositoryRefreshFailure: Equatable, LocalizedError, Sendable {
    public enum Kind: String, Sendable {
        case unsupportedRepository
        case notFound
        case unauthorized
        case rateLimited
        case serverError
        case networkUnavailable
        case timedOut
        case tlsTrust
        case cancelled
        case malformedArchive
        case unsafeArchive
        case archiveResourceLimit
        case unzipFailed
        case fileSystem
        case unknown
    }

    public let kind: Kind
    public let message: String
    public let repositoryURL: String
    public let attemptedArchiveURLs: [String]
    public let failedArchiveURL: String?
    public let httpStatusCode: Int?
    public let retryable: Bool
    public let cacheAvailable: Bool
    public let cacheUpdatedAt: Date?

    public var errorDescription: String? { message }

    public var userMessage: String {
        let cacheSuffix: String
        if cacheAvailable {
            if let cacheUpdatedAt {
                let formattedDate = DateFormatter.localizedString(
                    from: cacheUpdatedAt,
                    dateStyle: .medium,
                    timeStyle: .short
                )
                cacheSuffix = " Showing cached plugin list from \(formattedDate)."
            } else {
                cacheSuffix = " Showing cached plugin list."
            }
        } else {
            cacheSuffix = " No cached plugin list is available yet."
        }

        let retrySuffix = retryable
            ? " You can retry after the connection or service recovers."
            : " Check the repository URL or configuration before retrying."

        switch kind {
        case .unsupportedRepository:
            return "Plugin repository URL is unsupported. Osaurus can refresh GitHub repositories only.\(cacheSuffix)"
        case .notFound:
            return "Plugin repository archive was not found for the configured branch.\(cacheSuffix)\(retrySuffix)"
        case .unauthorized:
            return "Plugin repository rejected the request as unauthorized.\(cacheSuffix)\(retrySuffix)"
        case .rateLimited:
            return "Plugin repository rate limit was reached.\(cacheSuffix)\(retrySuffix)"
        case .serverError:
            return "Plugin repository is temporarily unavailable.\(cacheSuffix)\(retrySuffix)"
        case .networkUnavailable:
            return "Plugin repository is unreachable from this network.\(cacheSuffix)\(retrySuffix)"
        case .timedOut:
            return "Plugin repository refresh timed out.\(cacheSuffix)\(retrySuffix)"
        case .tlsTrust:
            return "Plugin repository connection failed certificate validation.\(cacheSuffix)\(retrySuffix)"
        case .cancelled:
            return "Plugin repository refresh was cancelled.\(cacheSuffix)\(retrySuffix)"
        case .malformedArchive:
            return "Plugin repository downloaded an invalid registry archive.\(cacheSuffix)\(retrySuffix)"
        case .unsafeArchive:
            return "Plugin repository archive contains unsafe entries and was rejected.\(cacheSuffix)"
        case .archiveResourceLimit:
            return "Plugin repository archive exceeds extraction safety limits and was rejected.\(cacheSuffix)"
        case .unzipFailed:
            return "Plugin repository archive could not be unpacked.\(cacheSuffix)\(retrySuffix)"
        case .fileSystem:
            return "Plugin repository cache could not be updated on disk.\(cacheSuffix)\(retrySuffix)"
        case .unknown:
            return "Plugin repository refresh failed.\(cacheSuffix)\(retrySuffix)"
        }
    }
}

public final class CentralRepositoryManager: @unchecked Sendable {
    public static let shared = CentralRepositoryManager()
    private init() {}

    static nonisolated(unsafe) var downloadFileOverride: (@Sendable (URL, URL) throws -> Void)?

    public var central: CentralRepository = .init(
        url: "https://github.com/osaurus-ai/osaurus-tools.git",
        branch: nil
    )

    // MARK: - Public API

    /// Refreshes the local copy of the central plugin repository.
    ///
    /// Downloads a source-archive zip from GitHub and atomically swaps it in.
    /// No `git` binary is required, so users without Xcode Command Line Tools
    /// can still browse and install plugins.
    ///
    /// Returns `true` on success. On any failure (network, malformed archive,
    /// missing `plugins/` dir) the existing on-disk copy is left untouched.
    @discardableResult
    public func refresh() -> Bool {
        refreshWithDiagnostics().succeeded
    }

    /// Refreshes the local plugin registry and returns a typed diagnostic that
    /// callers can surface in UI/support bundles without parsing logs.
    @discardableResult
    public func refreshWithDiagnostics() -> CentralRepositoryRefreshResult {
        do {
            let attemptedURLs = try performRefresh()
            return CentralRepositoryRefreshResult(
                succeeded: true,
                repositoryURL: Self.redactedURLString(central.url),
                attemptedArchiveURLs: attemptedURLs.map { Self.redactedURLString($0.absoluteString) },
                refreshedAt: Date(),
                cacheAvailable: hasCachedSpecs(),
                cacheUpdatedAt: cacheUpdatedAt(),
                failure: nil
            )
        } catch let attemptError as RefreshAttemptError {
            let failure = makeFailure(
                from: attemptError.underlying,
                attemptedURLs: attemptError.attemptedURLs,
                failedURL: attemptError.failedURL
            )
            NSLog("[Osaurus] Registry refresh failed: %@", failure.message)
            return CentralRepositoryRefreshResult(
                succeeded: false,
                repositoryURL: failure.repositoryURL,
                attemptedArchiveURLs: failure.attemptedArchiveURLs,
                refreshedAt: nil,
                cacheAvailable: failure.cacheAvailable,
                cacheUpdatedAt: failure.cacheUpdatedAt,
                failure: failure
            )
        } catch {
            let failure = makeFailure(from: error, attemptedURLs: [], failedURL: nil)
            NSLog("[Osaurus] Registry refresh failed: %@", failure.message)
            return CentralRepositoryRefreshResult(
                succeeded: false,
                repositoryURL: failure.repositoryURL,
                attemptedArchiveURLs: failure.attemptedArchiveURLs,
                refreshedAt: nil,
                cacheAvailable: failure.cacheAvailable,
                cacheUpdatedAt: failure.cacheUpdatedAt,
                failure: failure
            )
        }
    }

    public func listAllSpecs() -> [PluginSpec] {
        decodeSpecs(in: pluginsDirectory(under: centralCloneDirectory))
    }

    public func spec(for pluginId: String) -> PluginSpec? {
        listAllSpecs().first { $0.plugin_id == pluginId }
    }

    // MARK: - Refresh pipeline

    private func performRefresh() throws -> [URL] {
        let fm = FileManager.default
        let root = ToolsPaths.pluginSpecsRoot()
        try fm.createDirectoryIfNeeded(at: root)

        let archiveURLs = try archiveZipURLs()

        // Stage the download + extraction in a sibling temp dir under the same parent
        // so the final atomic swap stays on a single volume.
        let stagingDir = root.appendingPathComponent(
            "\(Path.stagingPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        let zipURL = stagingDir.appendingPathComponent(Path.archiveZip, isDirectory: false)

        // Try candidates in order, falling through on 404 so a repo whose
        // default branch is master still resolves when no branch is pinned
        var attemptedURLs: [URL] = []
        for (index, url) in archiveURLs.enumerated() {
            attemptedURLs.append(url)
            do {
                try downloadFile(from: url, to: zipURL)
                break
            } catch RefreshError.httpStatus(404) where index < archiveURLs.count - 1 {
                continue
            } catch {
                throw RefreshAttemptError(underlying: error, attemptedURLs: attemptedURLs, failedURL: url)
            }
        }

        let extractDir = stagingDir.appendingPathComponent(Path.extracted, isDirectory: true)
        do {
            try BoundedArchiveExtractor.extract(archive: zipURL, to: extractDir, policy: .registry)
        } catch {
            throw RefreshAttemptError(underlying: error, attemptedURLs: attemptedURLs, failedURL: nil)
        }

        // GitHub source archives wrap their contents in a single top-level directory
        // named `<repo>-<branch>/`.
        guard let innerRoot = locateInnerArchiveRoot(in: extractDir) else {
            throw RefreshAttemptError(
                underlying: RefreshError.malformedArchive("no inner directory inside \(extractDir.path)"),
                attemptedURLs: attemptedURLs,
                failedURL: nil
            )
        }

        // Integrity check: the inner root must contain a `plugins/` directory with at
        // least one JSON file that decodes as a valid `PluginSpec`. Prevents accidentally
        // installing an unrelated repository as the registry.
        guard !decodeSpecs(in: pluginsDirectory(under: innerRoot)).isEmpty else {
            throw RefreshAttemptError(
                underlying: RefreshError.malformedArchive(
                    "no decodable plugin specs under \(innerRoot.path)/\(Path.plugins)"
                ),
                attemptedURLs: attemptedURLs,
                failedURL: nil
            )
        }

        do {
            try replaceDirectoryAtomically(at: centralCloneDirectory, with: innerRoot)
        } catch {
            throw RefreshAttemptError(underlying: error, attemptedURLs: attemptedURLs, failedURL: nil)
        }
        return attemptedURLs
    }

    // MARK: - URL derivation

    /// Builds the GitHub source archive URLs to try for the configured central repo.
    /// When `CentralRepository.branch` is set, returns that single URL. Otherwise
    /// returns both `main` and `master` candidates. the repo's default branch
    /// has historically been `master` but could be either, and there's no cheap
    /// unauthenticated way to ask GitHub for it
    private func archiveZipURLs() throws -> [URL] {
        guard let comps = URLComponents(string: central.url),
            let host = comps.host?.lowercased(),
            host == "github.com" || host.hasSuffix(".github.com")
        else { throw RefreshError.unsupportedURL(Self.redactedURLString(central.url)) }

        var path = comps.path
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count >= 2 else { throw RefreshError.unsupportedURL(Self.redactedURLString(central.url)) }

        let owner = String(segments[0])
        let repo = String(segments[1])
        let branches: [String] = central.branch.map { [$0] } ?? ["main", "master"]

        let urls: [URL] = branches.compactMap { branch in
            let encoded = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
            return URL(string: "https://github.com/\(owner)/\(repo)/archive/refs/heads/\(encoded).zip")
        }
        guard !urls.isEmpty else { throw RefreshError.unsupportedURL(Self.redactedURLString(central.url)) }
        return urls
    }

    // MARK: - Download / extraction

    /// Synchronously downloads `url` to `destination`. Callers invoke `refresh()`
    /// from a background thread (e.g. `Task.detached`) so blocking is acceptable.
    private func downloadFile(from url: URL, to destination: URL) throws {
        if let override = Self.downloadFileOverride {
            try override(url, destination)
            return
        }

        let outcome = SyncDownloadOutcome()
        let semaphore = DispatchSemaphore(value: 0)
        RepositoryGlobalProxySettings.sharedSession().downloadTask(with: url) { tempURL, response, error in
            defer { semaphore.signal() }
            if let error {
                outcome.error = error
                return
            }
            if let http = response as? HTTPURLResponse,
                !(200 ..< 300).contains(http.statusCode)
            {
                outcome.error = RefreshError.httpStatus(http.statusCode)
                return
            }
            guard let tempURL else {
                outcome.error = RefreshError.malformedArchive("URLSession returned no temp file")
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: tempURL, to: destination)
            } catch {
                outcome.error = error
            }
        }.resume()
        semaphore.wait()
        if let error = outcome.error { throw error }
    }

    /// Finds the single top-level directory inside an extracted GitHub source archive.
    /// Prefers a directory that already contains `plugins/`; otherwise falls back
    /// to the only subdirectory present.
    private func locateInnerArchiveRoot(in directory: URL) -> URL? {
        let fm = FileManager.default
        let entries =
            (try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        let dirs = entries.filter(\.hasDirectoryPath)
        return dirs.first(where: {
            fm.fileExists(atPath: $0.appendingPathComponent(Path.plugins).path)
        }) ?? dirs.first
    }

    /// Atomically replaces (or creates) `destination` with the directory at `source`.
    /// When `destination` already exists, uses `FileManager.replaceItemAt` so a failed
    /// swap can't leave a half-written tree visible to readers calling `listAllSpecs()`.
    private func replaceDirectoryAtomically(at destination: URL, with source: URL) throws {
        let fm = FileManager.default
        try fm.createDirectoryIfNeeded(at: destination.deletingLastPathComponent())
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: source)
        } else {
            try fm.moveItem(at: source, to: destination)
        }
    }

    /// Walks `pluginsDir` and returns every `*.json` file that decodes as a `PluginSpec`.
    /// Shared by integrity checking and public listing.
    private func decodeSpecs(in pluginsDir: URL) -> [PluginSpec] {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: pluginsDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        let decoder = JSONDecoder()
        var specs: [PluginSpec] = []
        for case let fileURL as URL in enumerator
        where fileURL.pathExtension.lowercased() == "json" {
            if let data = try? Data(contentsOf: fileURL),
                let spec = try? decoder.decode(PluginSpec.self, from: data)
            {
                specs.append(spec)
            }
        }
        return specs
    }

    // MARK: - Paths

    private var centralCloneDirectory: URL {
        ToolsPaths.pluginSpecsRoot().appendingPathComponent(Path.central, isDirectory: true)
    }

    private func pluginsDirectory(under root: URL) -> URL {
        root.appendingPathComponent(Path.plugins, isDirectory: true)
    }

    private func hasCachedSpecs() -> Bool {
        !decodeSpecs(in: pluginsDirectory(under: centralCloneDirectory)).isEmpty
    }

    private func cacheUpdatedAt() -> Date? {
        guard FileManager.default.fileExists(atPath: centralCloneDirectory.path) else { return nil }
        return try? centralCloneDirectory.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    private func makeFailure(from error: Error, attemptedURLs: [URL], failedURL: URL?)
        -> CentralRepositoryRefreshFailure
    {
        let cacheAvailable = hasCachedSpecs()
        let cacheUpdatedAt = cacheUpdatedAt()
        let mapped = mapFailure(error)
        let statusCode: Int?
        if case .httpStatus(let code)? = error as? RefreshError {
            statusCode = code
        } else {
            statusCode = nil
        }

        return CentralRepositoryRefreshFailure(
            kind: mapped.kind,
            message: Self.sanitizedDiagnosticMessage(mapped.message),
            repositoryURL: Self.redactedURLString(central.url),
            attemptedArchiveURLs: attemptedURLs.map { Self.redactedURLString($0.absoluteString) },
            failedArchiveURL: failedURL.map { Self.redactedURLString($0.absoluteString) },
            httpStatusCode: statusCode,
            retryable: mapped.retryable,
            cacheAvailable: cacheAvailable,
            cacheUpdatedAt: cacheUpdatedAt
        )
    }

    private func mapFailure(_ error: Error) -> (
        kind: CentralRepositoryRefreshFailure.Kind,
        message: String,
        retryable: Bool
    ) {
        if let archiveError = error as? ArchiveExtractionError {
            switch archiveError {
            case .unsafePath, .unsafeEntry:
                return (.unsafeArchive, archiveError.localizedDescription, false)
            case .resourceLimit:
                return (.archiveResourceLimit, archiveError.localizedDescription, false)
            case .malformed, .unsupported, .extractionFailed, .verificationFailed:
                return (.malformedArchive, archiveError.localizedDescription, false)
            case .publicationFailed:
                return (.fileSystem, "registry archive could not be published", false)
            }
        }
        if let refreshError = error as? RefreshError {
            switch refreshError {
            case .unsupportedURL:
                return (.unsupportedRepository, refreshError.description, false)
            case .httpStatus(let code):
                if code == 404 {
                    return (.notFound, refreshError.description, false)
                } else if code == 401 || code == 403 {
                    return (.unauthorized, refreshError.description, false)
                } else if code == 429 {
                    return (.rateLimited, refreshError.description, true)
                } else if code >= 500 {
                    return (.serverError, refreshError.description, true)
                }
                return (.unknown, refreshError.description, false)
            case .malformedArchive:
                return (.malformedArchive, refreshError.description, false)
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
                 .networkConnectionLost, .dnsLookupFailed:
                return (.networkUnavailable, urlError.localizedDescription, true)
            case .timedOut:
                return (.timedOut, urlError.localizedDescription, true)
            case .secureConnectionFailed, .serverCertificateHasBadDate,
                 .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .clientCertificateRejected,
                 .clientCertificateRequired:
                return (.tlsTrust, urlError.localizedDescription, false)
            case .cancelled:
                return (.cancelled, urlError.localizedDescription, true)
            default:
                return (.unknown, urlError.localizedDescription, true)
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain {
            return (.fileSystem, nsError.localizedDescription, false)
        }

        return (.unknown, String(describing: error), true)
    }

    private static func sanitizedDiagnosticMessage(_ message: String) -> String {
        var sanitized = message
        for (prefix, replacement) in pathRedactionPrefixes() where !prefix.isEmpty {
            sanitized = sanitized.replacingOccurrences(of: prefix, with: replacement)
        }
        if sanitized.count > 600 {
            let end = sanitized.index(sanitized.startIndex, offsetBy: 600)
            sanitized = String(sanitized[..<end]) + "..."
        }
        return sanitized
    }

    private static func pathRedactionPrefixes() -> [(String, String)] {
        [
            (ToolsPaths.root().path, "<osaurus-data>"),
            (FileManager.default.homeDirectoryForCurrentUser.path, "~"),
            (FileManager.default.temporaryDirectory.path, "<tmp>"),
        ]
    }

    private static func redactedURLString(_ string: String) -> String {
        guard var components = URLComponents(string: string) else { return "<repository-url>" }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "<repository-url>"
    }

    private enum Path {
        static let central = "central"
        static let plugins = "plugins"
        static let archiveZip = "archive.zip"
        static let extracted = "extracted"
        static let stagingPrefix = "central.staging-"
    }
}

private struct RefreshAttemptError: Error {
    let underlying: Error
    let attemptedURLs: [URL]
    let failedURL: URL?
}

// MARK: - Errors

enum RefreshError: Error, CustomStringConvertible {
    case unsupportedURL(String)
    case httpStatus(Int)
    case malformedArchive(String)

    var description: String {
        switch self {
        case .unsupportedURL(let url):
            return "unsupported central registry URL: \(url) (only github.com is supported)"
        case .httpStatus(let code):
            return "registry archive download returned HTTP \(code)"
        case .malformedArchive(let detail):
            return "malformed archive: \(detail)"
        }
    }
}

// MARK: - Concurrency helpers

/// Scratch storage shared between a URLSession callback and a thread waiting on
/// a `DispatchSemaphore`. Marked `@unchecked Sendable` because the semaphore
/// provides the happens-before ordering Swift's checker can't see.
private final class SyncDownloadOutcome: @unchecked Sendable {
    var error: Error?
}

extension FileManager {
    fileprivate func createDirectoryIfNeeded(at url: URL) throws {
        if !fileExists(atPath: url.path) {
            try createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
