//
//  Pull.swift
//  osaurus
//
//  Downloads an MLX model from Hugging Face directly to the local models directory.
//  Mirrors the file patterns used by ModelDownloadService in the macOS app.
//

import Foundation

public struct PullCommand: Command {
    public static let name = "pull"

    // Files to download — mirrors ModelDownloadService.downloadFilePatterns
    private static let downloadFilePatterns: [String] = [
        "config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "generation_config.json",
        "chat_template.jinja",
        "preprocessor_config.json",
        "processor_config.json",
        "jang_config.json",
        "jjqf_config.json",
        "jang_cfg.json",
        "mxq_config.json",
        "*.safetensors",
    ]

    // MARK: - Decodable helpers

    private struct TreeNode: Decodable {
        let path: String
        let type: String?
        let size: Int64?
        let lfs: LFS?
        struct LFS: Decodable { let size: Int64? }
    }

    // MARK: - Execute

    public static func execute(args: [String]) async {
        guard let modelId = args.first, !modelId.isEmpty else {
            fputs("Missing required <model_id>\n", stderr)
            fputs("Usage: osaurus pull <model_id>\n", stderr)
            fputs("Example: osaurus pull mlx-community/Llama-3.2-1B-4bit\n", stderr)
            exit(EXIT_FAILURE)
        }

        print("Pulling \(modelId) ...")

        // Resolve the local destination: ~/.osaurus/models/<org>/<name>
        let destination = resolveLocalDirectory(for: modelId)

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
        guard let files = await fetchMatchingFiles(repoId: modelId, patterns: downloadFilePatterns) else {
            fputs("Could not retrieve file list from Hugging Face for '\(modelId)'.\n", stderr)
            fputs("Check that the model exists and is an MLX-compatible repository.\n", stderr)
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
            let dest = destination.appendingPathComponent(file.path)
            let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
            let existingSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            if existingSize == file.size {
                alreadyDownloaded += file.size
            } else {
                filesToDownload.append(file)
            }
        }

        if filesToDownload.isEmpty {
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
            let encodedPath =
                file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path
            guard
                let downloadURL = URL(
                    string: "https://huggingface.co/\(modelId)/resolve/main/\(encodedPath)"
                )
            else {
                fputs("Invalid URL for file: \(file.path)\n", stderr)
                continue
            }

            let fileDest = destination.appendingPathComponent(file.path)

            // Create intermediate subdirectories if needed (e.g. for sharded weights)
            let parent = fileDest.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

            do {
                try await downloadFile(
                    from: downloadURL,
                    to: fileDest,
                    fileName: file.path,
                    fileSize: file.size,
                    completedSoFar: completedBytes,
                    totalBytes: totalBytes
                )
                completedBytes += file.size
            } catch {
                fputs("\nFailed to download '\(file.path)': \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }

        print("\nDone. Model saved to: \(destination.path)")
        exit(EXIT_SUCCESS)
    }

    // MARK: - Local directory resolution

    /// Resolve the local storage directory for a model.
    /// Attempts to read the Osaurus shared defaults for the user-configured models path,
    /// falling back to ~/.osaurus/models.
    private static func resolveLocalDirectory(for modelId: String) -> URL {
        let baseDir: URL
        if let shared = UserDefaults(suiteName: "group.com.osaurus.shared"),
            let storedPath = shared.string(forKey: "modelsDirectoryPath"),
            !storedPath.isEmpty
        {
            baseDir = URL(fileURLWithPath: storedPath, isDirectory: true)
        } else {
            baseDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".osaurus/models", isDirectory: true)
        }
        // Decompose "org/model" into nested path components
        let components = modelId.split(separator: "/").map(String.init)
        return components.reduce(baseDir) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
    }

    // MARK: - HuggingFace file listing

    private struct MatchedFile {
        let path: String
        let size: Int64
    }

    /// Fetch the list of files from a Hugging Face repo that match any of the given glob patterns.
    private static func fetchMatchingFiles(
        repoId: String,
        patterns: [String]
    ) async -> [(path: String, size: Int64)]? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "huggingface.co"
        comps.path = "/api/models/\(repoId)/tree/main"
        comps.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        guard let url = comps.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 404 {
                fputs("Model '\(repoId)' not found on Hugging Face (404).\n", stderr)
                return nil
            }
            guard (200 ..< 300).contains(http.statusCode) else { return nil }

            let nodes = try JSONDecoder().decode([TreeNode].self, from: data)
            let matchers = patterns.compactMap { CLIGlob($0) }

            let files: [(path: String, size: Int64)] = nodes.compactMap { node in
                guard node.type != "directory" else { return nil }
                let filename = (node.path as NSString).lastPathComponent
                guard matchers.contains(where: { $0.matches(filename) }) else { return nil }
                let size = node.size ?? node.lfs?.size ?? 0
                guard size > 0 else { return nil }
                return (path: node.path, size: size)
            }
            return files
        } catch {
            return nil
        }
    }

    // MARK: - File download with progress bar

    private static func downloadFile(
        from url: URL,
        to destination: URL,
        fileName: String,
        fileSize: Int64,
        completedSoFar: Int64,
        totalBytes: Int64
    ) async throws {
        // Use a delegate-based session for per-byte progress reporting
        let downloader = CLIFileDownloader()
        defer { downloader.invalidate() }

        try await downloader.download(
            from: url,
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

// MARK: - Minimal glob matcher (standalone, no OsaurusCore dependency)

private struct CLIGlob {
    private let regex: NSRegularExpression

    init?(_ pattern: String) {
        var escaped = ""
        for ch in pattern {
            switch ch {
            case "*": escaped += ".*"
            case "?": escaped += "."
            case ".", "+", "(", ")", "[", "]", "{", "}", "^", "$", "|", "\\":
                escaped += "\\\(ch)"
            default:
                escaped += String(ch)
            }
        }
        guard let regex = try? NSRegularExpression(pattern: "^\(escaped)$") else { return nil }
        self.regex = regex
    }

    func matches(_ text: String) -> Bool {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, options: [], range: range) != nil
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
        from url: URL,
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
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    func invalidate() { session.invalidateAndCancel() }

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
            cont.resume(
                throwing: URLError(
                    .badServerResponse,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
                )
            )
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
