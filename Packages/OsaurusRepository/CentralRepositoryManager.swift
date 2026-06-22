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

public final class CentralRepositoryManager: @unchecked Sendable {
    public static let shared = CentralRepositoryManager()
    private init() {}

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
        do {
            try performRefresh()
            return true
        } catch {
            NSLog("[Osaurus] Registry refresh failed: %@", String(describing: error))
            return false
        }
    }

    public func listAllSpecs() -> [PluginSpec] {
        decodeSpecs(in: pluginsDirectory(under: centralCloneDirectory))
    }

    public func spec(for pluginId: String) -> PluginSpec? {
        listAllSpecs().first { $0.plugin_id == pluginId }
    }

    // MARK: - Refresh pipeline

    private func performRefresh() throws {
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

        // try candidates in order, falling through on 404 so a repo whose
        // default branch is master still resolves when no branch is pinned
        var lastError: Error?
        for (index, url) in archiveURLs.enumerated() {
            do {
                try downloadFile(from: url, to: zipURL)
                lastError = nil
                break
            } catch RefreshError.httpStatus(404) where index < archiveURLs.count - 1 {
                lastError = RefreshError.httpStatus(404)
                continue
            } catch {
                throw error
            }
        }
        if let lastError { throw lastError }

        let extractDir = stagingDir.appendingPathComponent(Path.extracted, isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try unzip(zipURL: zipURL, to: extractDir)

        // GitHub source archives wrap their contents in a single top-level directory
        // named `<repo>-<branch>/`.
        guard let innerRoot = locateInnerArchiveRoot(in: extractDir) else {
            throw RefreshError.malformedArchive("no inner directory inside \(extractDir.path)")
        }

        // Integrity check: the inner root must contain a `plugins/` directory with at
        // least one JSON file that decodes as a valid `PluginSpec`. Prevents accidentally
        // installing an unrelated repository as the registry.
        guard !decodeSpecs(in: pluginsDirectory(under: innerRoot)).isEmpty else {
            throw RefreshError.malformedArchive(
                "no decodable plugin specs under \(innerRoot.path)/\(Path.plugins)"
            )
        }

        try replaceDirectoryAtomically(at: centralCloneDirectory, with: innerRoot)
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
        else { throw RefreshError.unsupportedURL(central.url) }

        var path = comps.path
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count >= 2 else { throw RefreshError.unsupportedURL(central.url) }

        let owner = String(segments[0])
        let repo = String(segments[1])
        let branches: [String] = central.branch.map { [$0] } ?? ["main", "master"]

        let urls: [URL] = branches.compactMap { branch in
            let encoded = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
            return URL(string: "https://github.com/\(owner)/\(repo)/archive/refs/heads/\(encoded).zip")
        }
        guard !urls.isEmpty else { throw RefreshError.unsupportedURL(central.url) }
        return urls
    }

    // MARK: - Download / unzip

    /// Synchronously downloads `url` to `destination`. Callers invoke `refresh()`
    /// from a background thread (e.g. `Task.detached`) so blocking is acceptable.
    private func downloadFile(from url: URL, to destination: URL) throws {
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

    private func unzip(zipURL: URL, to destination: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-o", "-q", zipURL.path, "-d", destination.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let stderr = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: stderr, encoding: .utf8) ?? "unknown error"
            throw RefreshError.unzipFailed(Int(task.terminationStatus), message)
        }
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

    private enum Path {
        static let central = "central"
        static let plugins = "plugins"
        static let archiveZip = "archive.zip"
        static let extracted = "extracted"
        static let stagingPrefix = "central.staging-"
    }
}

// MARK: - Errors

private enum RefreshError: Error, CustomStringConvertible {
    case unsupportedURL(String)
    case httpStatus(Int)
    case unzipFailed(Int, String)
    case malformedArchive(String)

    var description: String {
        switch self {
        case .unsupportedURL(let url):
            return "unsupported central registry URL: \(url) (only github.com is supported)"
        case .httpStatus(let code):
            return "registry archive download returned HTTP \(code)"
        case .unzipFailed(let code, let msg):
            return "unzip exited with code \(code): \(msg)"
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
