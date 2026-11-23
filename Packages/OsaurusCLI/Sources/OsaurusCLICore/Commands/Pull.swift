//
//  Pull.swift
//  osaurus
//
//  Downloads an MLX model from Hugging Face directly to the local models directory.
//  Uses the same file patterns as the app (`ModelFilePatterns`).
//

import Foundation
import OsaurusRepository

public struct PullCommand: Command {
    public static let name = "pull"

    static let usage = """
        Usage: osaurus pull <model_id>

        Downloads a model from Hugging Face into the Osaurus models folder.
        Example: osaurus pull mlx-community/Llama-3.2-1B-4bit

        Gated and private models need a Hugging Face token: set HF_TOKEN (or
        HUGGING_FACE_HUB_TOKEN), or sign in with `hf auth login`.
        """

    // MARK: - Decodable helpers

    struct TreeNode: Decodable {
        let path: String
        let type: String?
        let size: Int64?
        let lfs: LFS?
        struct LFS: Decodable { let size: Int64? }
    }

    // MARK: - Execute

    public static func execute(args: [String]) async {
        if args.contains("--help") || args.contains("-h") {
            print(usage)
            exit(EXIT_SUCCESS)
        }
        guard let modelId = args.first, !modelId.isEmpty, !modelId.hasPrefix("-") else {
            fputs("Missing required <model_id>\n\n\(usage)\n", stderr)
            exit(EXIT_FAILURE)
        }
        if args.count > 1 {
            fputs("osaurus pull: unknown argument `\(args[1])`\n\n\(usage)\n", stderr)
            exit(EXIT_FAILURE)
        }
        let token = huggingFaceToken()

        print("Pulling \(modelId) ...")

        // Use the same model root as the app and installation diagnostics.
        guard let destination = resolveLocalDirectory(for: modelId) else {
            fputs("Invalid or escaping model identifier: \(modelId)\n", stderr)
            exit(EXIT_FAILURE)
        }

        do {
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
        } catch {
            fputs("Failed to create model directory: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }

        // Fetch file list from Hugging Face tree API
        let files: [(path: String, size: Int64)]
        do {
            files = try await fetchMatchingFiles(repoId: modelId, token: token)
        } catch let error as HubError {
            fputs("\(error.message)\n", stderr)
            exit(EXIT_FAILURE)
        } catch {
            fputs("Could not retrieve the file list from Hugging Face for '\(modelId)': \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }

        if files.isEmpty {
            fputs("No matching files found for '\(modelId)'.\n", stderr)
            exit(EXIT_FAILURE)
        }

        // Skip files that are already fully downloaded
        var filesToDownload: [(path: String, size: Int64)] = []
        var alreadyDownloaded: Int64 = 0
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }

        for file in files {
            guard let dest = destinationURL(forRemotePath: file.path, under: destination) else {
                fputs("Invalid remote path for file: \(file.path)\n", stderr)
                exit(EXIT_FAILURE)
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
            let existingSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            if existingSize == file.size {
                alreadyDownloaded += file.size
            } else {
                filesToDownload.append(file)
            }
        }

        if filesToDownload.isEmpty {
            guard notifyAppIfPullComplete(files: files, destination: destination) else {
                fputs("Model files are incomplete or changed while checking the download.\n", stderr)
                exit(EXIT_FAILURE)
            }
            print("Model '\(modelId)' is already up to date.")
            exit(EXIT_SUCCESS)
        }

        print(
            "Downloading \(filesToDownload.count) file(s) "
                + "(\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)) total) ..."
        )

        // Download each file sequentially with progress
        var completedBytes = alreadyDownloaded
        for file in filesToDownload {
            guard
                let downloadURL = resolveDownloadURL(repoId: modelId, path: file.path),
                let fileDest = destinationURL(forRemotePath: file.path, under: destination)
            else {
                fputs("Invalid remote path for file: \(file.path)\n", stderr)
                exit(EXIT_FAILURE)
            }

            // Create intermediate subdirectories if needed (e.g. for sharded weights)
            let parent = fileDest.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

            do {
                try await downloadFile(
                    from: downloadURL,
                    token: token,
                    to: fileDest,
                    fileName: file.path,
                    fileSize: file.size,
                    completedSoFar: completedBytes,
                    totalBytes: totalBytes
                )
                completedBytes += file.size
            } catch let error as HubError {
                fputs("\nFailed to download '\(file.path)': \(error.message)\n", stderr)
                exit(EXIT_FAILURE)
            } catch {
                fputs("\nFailed to download '\(file.path)': \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }

        guard notifyAppIfPullComplete(files: files, destination: destination) else {
            fputs("Model files are incomplete or changed while checking the download.\n", stderr)
            exit(EXIT_FAILURE)
        }
        print("\nDone. Model saved to: \(destination.path)")
        exit(EXIT_SUCCESS)
    }

    /// Refresh a running app only after every expected file is present at its
    /// final size. This also covers the already-up-to-date path without using
    /// the HTTP API (which may require an access key).
    static func notifyAppIfPullComplete(
        files: [(path: String, size: Int64)],
        destination: URL,
        postNotification: (String, [AnyHashable: Any]) -> Void = { name, payload in
            AppControl.postDistributedNotification(name: name, userInfo: payload)
        }
    ) -> Bool {
        guard !files.isEmpty else { return false }
        for file in files {
            guard file.size > 0,
                let url = destinationURL(forRemotePath: file.path, under: destination),
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                attributes[.type] as? FileAttributeType == .typeRegular,
                (attributes[.size] as? NSNumber)?.int64Value == file.size
            else { return false }
        }
        postNotification("com.dinoki.osaurus.control.modelsReload", [:])
        return true
    }

    // MARK: - Local directory resolution

    /// Resolve the model root through the shared configuration contract, then
    /// contain the repository path before creating directories or requesting files.
    static func resolveLocalDirectory(
        for modelId: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appDefaults: UserDefaults? = UserDefaults(suiteName: AppIdentity.bundleIdentifier),
        sharedDefaults: UserDefaults? = UserDefaults(suiteName: "group.com.osaurus.shared"),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        let base = Configuration.resolveModelsDirectoryWithSource(
            environment: environment,
            appDefaults: appDefaults,
            sharedDefaults: sharedDefaults,
            home: home
        ).url
        guard let destination = destinationURL(forRemotePath: modelId, under: base),
            (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) == nil
        else { return nil }
        return destination
    }

    // MARK: - Remote path containment

    /// HF tree entries are remote input but become local files; accept only
    /// portable relative paths before appending them under the model directory.
    static func normalizedRemoteFilePath(_ path: String) -> String? {
        guard !path.isEmpty,
            !path.contains("\\"),
            !path.contains("\0"),
            !(path as NSString).isAbsolutePath
        else {
            return nil
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }
        var normalized: [String] = []
        for component in components {
            guard !component.isEmpty,
                component != ".",
                component != ".."
            else {
                return nil
            }
            normalized.append(String(component))
        }
        return normalized.joined(separator: "/")
    }

    static func destinationURL(forRemotePath path: String, under directory: URL) -> URL? {
        guard let safePath = normalizedRemoteFilePath(path) else { return nil }
        let base = directory.standardizedFileURL
        let destination =
            safePath
            .split(separator: "/")
            .reduce(base) { partial, component in
                partial.appendingPathComponent(String(component))
            }
            .standardizedFileURL

        guard isContained(destination, in: base),
            existingParentChainIsContained(for: destination, under: base)
        else {
            return nil
        }
        return destination
    }

    static func resolveDownloadURL(repoId: String, path: String) -> URL? {
        guard let safePath = normalizedRemoteFilePath(path) else { return nil }
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "huggingface.co"
        comps.path = "/\(repoId)/resolve/main/\(safePath)"
        return comps.url
    }

    private static func existingParentChainIsContained(for destination: URL, under base: URL) -> Bool {
        let fileManager = FileManager.default
        let resolvedBase = base.resolvingSymlinksInPath().standardizedFileURL
        let parent = destination.deletingLastPathComponent().standardizedFileURL
        let baseComponents = base.pathComponents
        let parentComponents = parent.pathComponents
        guard parentComponents.count >= baseComponents.count,
            Array(parentComponents.prefix(baseComponents.count)) == baseComponents
        else {
            return false
        }

        var current = base
        for component in parentComponents.dropFirst(baseComponents.count) {
            current = current.appendingPathComponent(component, isDirectory: true)
            guard isContained(current.standardizedFileURL, in: base) else { return false }
            guard fileManager.fileExists(atPath: current.path) else { break }
            guard (try? fileManager.destinationOfSymbolicLink(atPath: current.path)) == nil else {
                return false
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: current.path, isDirectory: &isDirectory),
                isDirectory.boolValue,
                isContained(current.resolvingSymlinksInPath().standardizedFileURL, in: resolvedBase)
            else {
                return false
            }
        }
        return true
    }

    private static func isContained(_ url: URL, in directory: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return path == directoryPath || path.hasPrefix(directoryPath + "/")
    }

    // MARK: - HuggingFace file listing

    struct HubError: Error, Equatable {
        let message: String
    }

    /// A Hub refusal worded for what the user can do about it; nil when the
    /// status is not one.
    static func hubStatusMessage(_ status: Int, repoId: String, hasToken: Bool) -> String? {
        switch status {
        case 401:
            return hasToken
                ? "Hugging Face rejected the token for '\(repoId)' (401). Check HF_TOKEN."
                : "'\(repoId)' is private or gated and needs a Hugging Face token (401). Set HF_TOKEN, "
                    + "or sign in with `hf auth login`."
        case 403:
            return "Hugging Face refused access to '\(repoId)' (403). If it is gated, accept its terms on "
                + "huggingface.co/\(repoId) with the account that owns the token."
        case 404:
            return hasToken
                ? "Model '\(repoId)' was not found on Hugging Face (404)."
                : "Model '\(repoId)' was not found on Hugging Face (404). If it is private, set HF_TOKEN."
        case 429:
            return "Hugging Face is rate limiting downloads (429). Wait a minute and try again"
                + (hasToken ? "." : ", or set HF_TOKEN for a higher limit.")
        default:
            return nil
        }
    }

    /// `HF_TOKEN`, then `HUGGING_FACE_HUB_TOKEN`, then the token `hf auth
    /// login` saved (`$HF_HOME/token`, default `~/.cache/huggingface/token`).
    static func huggingFaceToken(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        for name in ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"] {
            if let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        let hfHome =
            environment["HF_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".cache/huggingface", isDirectory: true)
        let saved = (try? String(contentsOf: hfHome.appendingPathComponent("token"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return saved?.isEmpty == false ? saved : nil
    }

    /// The `rel="next"` URL of a Hub `Link` header (tree listings are paged).
    static func nextPageURL(linkHeader: String?) -> URL? {
        guard let linkHeader else { return nil }
        for part in linkHeader.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2, pieces.dropFirst().contains(where: { $0 == "rel=\"next\"" }),
                pieces[0].hasPrefix("<"), pieces[0].hasSuffix(">")
            else { continue }
            return URL(string: String(pieces[0].dropFirst().dropLast()))
        }
        return nil
    }

    /// The tree entries Osaurus downloads, as safe relative paths.
    static func matchingFiles(in nodes: [TreeNode]) -> [(path: String, size: Int64)] {
        nodes.compactMap { node in
            guard node.type != "directory",
                let safePath = normalizedRemoteFilePath(node.path),
                ModelFilePatterns.matches(path: safePath)
            else { return nil }
            let size = node.size ?? node.lfs?.size ?? 0
            guard size > 0 else { return nil }
            return (path: safePath, size: size)
        }
    }

    /// Every page of the repository's file tree, filtered to what Osaurus
    /// downloads.
    private static func fetchMatchingFiles(
        repoId: String,
        token: String?
    ) async throws -> [(path: String, size: Int64)] {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "huggingface.co"
        comps.path = "/api/models/\(repoId)/tree/main"
        comps.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        var next = comps.url
        var nodes: [TreeNode] = []
        var pages = 0

        while let url = next {
            pages += 1
            guard pages <= 100 else { throw HubError(message: "The file list for '\(repoId)' has too many pages.") }
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            request.timeoutInterval = 30.0

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if let message = hubStatusMessage(http.statusCode, repoId: repoId, hasToken: token != nil) {
                throw HubError(message: message)
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                throw HubError(message: "Hugging Face returned HTTP \(http.statusCode) for '\(repoId)'.")
            }
            nodes += try JSONDecoder().decode([TreeNode].self, from: data)
            next = nextPageURL(linkHeader: http.value(forHTTPHeaderField: "Link"))
        }
        return matchingFiles(in: nodes)
    }

    // MARK: - File download with progress bar

    private static func downloadFile(
        from url: URL,
        token: String?,
        to destination: URL,
        fileName: String,
        fileSize: Int64,
        completedSoFar: Int64,
        totalBytes: Int64
    ) async throws {
        // Use a delegate-based session for per-byte progress reporting
        let downloader = CLIFileDownloader()
        defer { downloader.invalidate() }

        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        try await downloader.download(
            from: request,
            to: destination,
            expectedSize: fileSize,
            onProgress: { bytesWritten, _ in
                // Compute overall progress across all files
                let overallCompleted = completedSoFar + bytesWritten
                let fraction =
                    totalBytes > 0
                    ? Double(overallCompleted) / Double(totalBytes)
                    : 0.0
                printProgress(
                    fileName: fileName,
                    received: overallCompleted,
                    total: totalBytes,
                    fraction: fraction
                )
            }
        )
    }

    /// Renders a compact progress line in-place using ANSI carriage return.
    private static func printProgress(
        fileName: String,
        received: Int64,
        total: Int64,
        fraction: Double
    ) {
        let percent = Int(fraction * 100)
        let receivedStr = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        let totalStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)

        // 20-character progress bar
        let barWidth = 20
        let filled = Int(Double(barWidth) * fraction)
        let bar = String(repeating: "=", count: filled) + String(repeating: " ", count: barWidth - filled)

        let line = "\r[\(bar)] \(percent)%  \(receivedStr)/\(totalStr)  \(fileName)"
        fputs(line, stdout)
        fflush(stdout)
    }
}

// MARK: - Download engine with URLSessionDownloadDelegate for reliable progress

/// Downloads a single file using a session-level URLSessionDownloadDelegate,
/// providing reliable per-byte progress callbacks.
private final class CLIFileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var destinationURL: URL?
    private var expectedFileSize: Int64?
    private var progressCallback: (@Sendable (Int64, Int64) -> Void)?
    private var lastProgressTime: CFAbsoluteTime = 0

    // Throttle progress callbacks to avoid flooding stdout
    private static let progressInterval: CFAbsoluteTime = 0.1

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    func download(
        from request: URLRequest,
        to destination: URL,
        expectedSize: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            self.continuation = cont
            self.destinationURL = destination
            self.expectedFileSize = expectedSize
            self.progressCallback = onProgress
            self.lastProgressTime = 0
            lock.unlock()
            let task = session.downloadTask(with: request)
            task.resume()
        }
    }

    func invalidate() { session.invalidateAndCancel() }

    /// `owner/name` from a `huggingface.co/<owner>/<name>/resolve/...` URL.
    private static func repoId(from url: URL?) -> String {
        let parts = url?.pathComponents.filter { $0 != "/" } ?? []
        return parts.count >= 2 ? "\(parts[0])/\(parts[1])" : "the model"
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let elapsed = now - lastProgressTime
        let isComplete =
            totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
        guard elapsed >= Self.progressInterval || isComplete else {
            lock.unlock()
            return
        }
        lastProgressTime = now
        let callback = progressCallback
        lock.unlock()
        callback?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let cont = continuation
        let dest = destinationURL
        let expectedSize = expectedFileSize
        continuation = nil
        destinationURL = nil
        expectedFileSize = nil
        progressCallback = nil
        lock.unlock()

        guard let cont, let dest else { return }

        if let http = downloadTask.response as? HTTPURLResponse,
            !(200 ..< 300).contains(http.statusCode)
        {
            let repoId = Self.repoId(from: downloadTask.originalRequest?.url)
            let hasToken = downloadTask.originalRequest?.value(forHTTPHeaderField: "Authorization") != nil
            let message =
                PullCommand.hubStatusMessage(http.statusCode, repoId: repoId, hasToken: hasToken)
                ?? "HTTP \(http.statusCode)"
            cont.resume(throwing: PullCommand.HubError(message: message))
            return
        }

        do {
            let fm = FileManager.default
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: location, to: dest)

            // Validate final size matches the manifest
            if let expected = expectedSize, expected > 0 {
                let attrs = try fm.attributesOfItem(atPath: dest.path)
                let actual = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                if actual != expected {
                    try? fm.removeItem(at: dest)
                    cont.resume(
                        throwing: URLError(
                            .cannotDecodeContentData,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Size mismatch: expected \(expected), got \(actual)"
                            ]
                        )
                    )
                    return
                }
            }
            cont.resume()
        } catch {
            cont.resume(throwing: error)
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.lock()
        let cont = continuation
        continuation = nil
        destinationURL = nil
        expectedFileSize = nil
        progressCallback = nil
        lock.unlock()
        cont?.resume(throwing: error)
    }
}
