//
//  RampartModelManager.swift
//  osaurus / PrivacyFilter
//
//  Downloads, caches, and loads the Rampart PII model — an ~37MB MLX
//  BERT token classifier — as a lightweight alternative to the
//  multi-gigabyte OpenAI privacy filter bundle. Mirrors the aux-models
//  layout and HuggingFace `resolve` download convention used by
//  `PrivacyFilterModelDownloader`, but kept small since the whole model
//  is a handful of files.
//
//  Download + disk I/O run off the main thread; `@Published` state is
//  published back on the main actor (app-hang guidance).
//

import Combine
import Foundation

public enum RampartDownloadState: Equatable, Sendable {
    case idle
    case downloading(progress: Double)
    case ready
    case failed(String)
}

@MainActor
public final class RampartModelManager: ObservableObject {
    public static let shared = RampartModelManager()

    /// Source repo on HuggingFace. Public so it can be retargeted in tests.
    nonisolated(unsafe) public static var repoId: String = "OsaurusAI/rampart-mlx"
    nonisolated(unsafe) public static var revision: String = "main"
    nonisolated static let version = "rampart-mlx-v1"

    /// Files the runtime needs. `RampartPII` reads the first three; the
    /// tokenizer files are carried for completeness/parity tooling.
    nonisolated static let requiredFiles = [
        "model.safetensors",
        "config.json",
        "vocab.txt",
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
    ]

    @Published public private(set) var state: RampartDownloadState = .idle

    private let detector = RampartPrivacyDetector()
    private var downloadTask: Task<Void, Never>?

    private init() {
        if Self.bundleExists() { state = .ready }
    }

    // MARK: - Locations

    nonisolated public static func directoryURL() -> URL {
        OsaurusPaths.root()
            .appendingPathComponent("aux-models", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    nonisolated public static func bundleExists(at directory: URL = directoryURL()) -> Bool {
        let fm = FileManager.default
        return requiredFiles.allSatisfy {
            fm.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    nonisolated private static func resolveURL(file: String) -> URL? {
        URL(string: "https://huggingface.co/\(repoId)/resolve/\(revision)/\(file)")
    }

    // MARK: - Download

    public func startDownload() {
        if case .downloading = state { return }
        downloadTask?.cancel()
        state = .downloading(progress: 0)

        let dir = Self.directoryURL()
        let files = Self.requiredFiles

        downloadTask = Task { [weak self] in
            do {
                try await Self.downloadBundle(files: files, into: dir) { progress in
                    Task { @MainActor in
                        if case .downloading = self?.state {
                            self?.state = .downloading(progress: progress)
                        }
                    }
                }
                try await self?.loadIfNeeded()
                self?.state = .ready
            } catch is CancellationError {
                self?.state = .idle
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
            self?.downloadTask = nil
        }
    }

    public func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        if case .downloading = state { state = .idle }
    }

    /// Delete the cached bundle and reset to idle.
    public func remove() {
        cancel()
        try? FileManager.default.removeItem(at: Self.directoryURL())
        state = .idle
    }

    /// Fetch each file from HuggingFace into a temp dir, then atomically
    /// move the completed set into place. Runs off the main thread.
    nonisolated private static func downloadBundle(
        files: [String],
        into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fm = FileManager.default
        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let session = URLSession(configuration: .default)
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            guard let url = resolveURL(file: file) else {
                throw RampartModelError.badURL(file)
            }
            let (tempURL, response) = try await session.download(from: url)
            if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                throw RampartModelError.httpStatus(file, http.statusCode)
            }
            let dest = staging.appendingPathComponent(file)
            try fm.moveItem(at: tempURL, to: dest)
            progress(Double(index + 1) / Double(files.count))
        }

        // Swap staged files into the final directory.
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files {
            let dest = directory.appendingPathComponent(file)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: staging.appendingPathComponent(file), to: dest)
        }
    }

    // MARK: - Load + detect

    /// Load the model into the detector if the bundle is present.
    public func loadIfNeeded() async throws {
        let dir = Self.directoryURL()
        guard Self.bundleExists(at: dir) else { throw RampartModelError.bundleMissing }
        try await detector.loadIfNeeded(bundle: dir)
    }

    /// Model NER spans for `text`, mapped to the pipeline's categories.
    /// Best-effort warms the bundle once; returns `[]` if unavailable.
    public func modelSpans(in text: String) async -> [(category: EntityCategory, range: Range<String.Index>)] {
        if !(await detector.isLoaded) {
            guard Self.bundleExists() else { return [] }
            try? await loadIfNeeded()
        }
        return await detector.modelSpans(in: text)
    }
}

public enum RampartModelError: LocalizedError {
    case badURL(String)
    case httpStatus(String, Int)
    case bundleMissing

    public var errorDescription: String? {
        switch self {
        case .badURL(let f): return "Invalid download URL for \(f)"
        case .httpStatus(let f, let code): return "Download of \(f) failed (HTTP \(code))"
        case .bundleMissing: return "Rampart model bundle is not present on disk"
        }
    }
}
