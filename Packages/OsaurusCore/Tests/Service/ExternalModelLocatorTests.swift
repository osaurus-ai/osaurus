//
//  ExternalModelLocatorTests.swift
//  osaurusTests
//
//  Covers external model discovery: `models--org--repo` parsing, MLX
//  bundle validation (incl. GGUF skip), symlink-escape rejection, the HF
//  cache snapshot resolution, the LM Studio nested-layout scan, and id ->
//  path resolution used by the runtime loaders.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ExternalModelLocatorTests {

    // MARK: - Helpers

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-ext-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Write a minimal valid MLX bundle (config + tokenizer + weights) into
    /// `dir`. Optionally swap the weights for a `.gguf` file to model a
    /// GGUF-only directory that must be rejected.
    private func writeBundle(at dir: URL, ggufOnly: Bool = false, tokenizer: Bool = true) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        if tokenizer {
            try? Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
        }
        let weightName = ggufOnly ? "model.gguf" : "model.safetensors"
        try? Data("w".utf8).write(to: dir.appendingPathComponent(weightName))
    }

    // MARK: - Cache folder parsing

    @Test func repoId_parsesModelsFolder() {
        #expect(
            ExternalModelLocator.repoId(fromCacheFolder: "models--mlx-community--Llama-3.2-3B")
                == "mlx-community/Llama-3.2-3B"
        )
    }

    @Test func repoId_rejectsNonModelCaches() {
        #expect(ExternalModelLocator.repoId(fromCacheFolder: "datasets--foo--bar") == nil)
        #expect(ExternalModelLocator.repoId(fromCacheFolder: "models--solo") == nil)
        #expect(ExternalModelLocator.repoId(fromCacheFolder: "random") == nil)
    }

    @Test func huggingFaceCacheRoots_includesCustomPathEvenWhenMissing() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let custom = home.appendingPathComponent("external-hf/hub", isDirectory: true)

        let roots = ExternalModelLocator.huggingFaceCacheRoots(
            environment: [:],
            homeDirectory: home,
            customPath: custom.path,
            fileExists: { _ in false }
        )

        #expect(roots == [custom.standardizedFileURL])
    }

    @Test func huggingFaceCacheRoots_expandsTildeAgainstHomeAndDeduplicatesDefault() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let defaultRoot = home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        try? FileManager.default.createDirectory(at: defaultRoot, withIntermediateDirectories: true)

        let roots = ExternalModelLocator.huggingFaceCacheRoots(
            environment: [:],
            homeDirectory: home,
            customPath: "~/.cache/huggingface/hub",
            fileExists: { $0 == defaultRoot.standardizedFileURL.path }
        )

        #expect(roots == [defaultRoot.standardizedFileURL])
    }

    @Test func huggingFaceCacheRoots_prefersCustomBeforeEnvironmentAndDefaultRoots() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let custom = home.appendingPathComponent("custom-hf/hub", isDirectory: true)
        let envHub = home.appendingPathComponent("env-hub", isDirectory: true)
        let envHomeHub = home.appendingPathComponent("env-home/hub", isDirectory: true)
        let defaultRoot = home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        for root in [custom, envHub, envHomeHub, defaultRoot] {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        let roots = ExternalModelLocator.huggingFaceCacheRoots(
            environment: [
                "HF_HUB_CACHE": envHub.path,
                "HF_HOME": home.appendingPathComponent("env-home", isDirectory: true).path,
            ],
            homeDirectory: home,
            customPath: custom.path,
            fileExists: { path in
                [custom, envHub, envHomeHub, defaultRoot]
                    .map { $0.standardizedFileURL.path }
                    .contains(path)
            }
        )

        #expect(
            roots == [
                custom.standardizedFileURL,
                envHub.standardizedFileURL,
                envHomeHub.standardizedFileURL,
                defaultRoot.standardizedFileURL,
            ]
        )
    }

    // MARK: - Bundle validation

    @Test func isMLXBundle_acceptsSafetensorsBundle() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        writeBundle(at: bundle)
        #expect(ExternalModelLocator.isMLXBundle(bundle, root: root))
    }

    @Test func isMLXBundle_rejectsGGUFOnly() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        writeBundle(at: bundle, ggufOnly: true)
        #expect(!ExternalModelLocator.isMLXBundle(bundle, root: root))
    }

    @Test func isMLXBundle_rejectsMissingTokenizer() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        writeBundle(at: bundle, tokenizer: false)
        #expect(!ExternalModelLocator.isMLXBundle(bundle, root: root))
    }

    @Test func isMLXBundle_rejectsSymlinkEscapingRoot() {
        let root = makeTempDir()
        let outside = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let fm = FileManager.default
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        try? fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try? Data("{}".utf8).write(to: bundle.appendingPathComponent("tokenizer.json"))
        try? Data("w".utf8).write(to: bundle.appendingPathComponent("model.safetensors"))
        // config.json is a symlink pointing OUTSIDE the scan root.
        let escapeTarget = outside.appendingPathComponent("config.json")
        try? Data("{}".utf8).write(to: escapeTarget)
        try? fm.createSymbolicLink(
            at: bundle.appendingPathComponent("config.json"),
            withDestinationURL: escapeTarget
        )
        #expect(!ExternalModelLocator.isMLXBundle(bundle, root: root))
    }

    @Test func isContained_detectsNesting() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("a/b", isDirectory: true)
        #expect(ExternalModelLocator.isContained(child, in: root))
        let sibling = root.deletingLastPathComponent().appendingPathComponent("elsewhere")
        #expect(!ExternalModelLocator.isContained(sibling, in: root))
    }

    // MARK: - Nested (LM Studio-style) scan

    @Test func scan_findsNestedPublisherRepoBundle() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("publisher/repo", isDirectory: true)
        writeBundle(at: bundle)

        let found = ExternalModelLocator.scan(root: root, source: .lmStudio)
        #expect(found.contains { $0.id == "publisher/repo" })
        #expect(found.allSatisfy { $0.source == "LM Studio" })
    }

    @Test func scan_skipsGGUFDirectories() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("publisher/repo", isDirectory: true)
        writeBundle(at: bundle, ggufOnly: true)
        let found = ExternalModelLocator.scan(root: root, source: .lmStudio)
        #expect(found.isEmpty)
    }

    @Test func scanReport_explainsSkippedCandidates() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingTokenizer = root.appendingPathComponent("publisher/repo", isDirectory: true)
        writeBundle(at: missingTokenizer, tokenizer: false)
        let ggufOnly = root.appendingPathComponent("publisher/gguf", isDirectory: true)
        writeBundle(at: ggufOnly, ggufOnly: true)

        let report = ExternalModelLocator.scanReport(root: root, source: .lmStudio)

        #expect(report.discovered.isEmpty)
        #expect(
            report.skipped.contains {
                $0.repoId == "publisher/repo" && $0.reason == .missingTokenizer
            }
        )
        #expect(
            report.skipped.contains {
                $0.repoId == "publisher/gguf" && $0.reason == .ggufOnly
            }
        )
    }

    // MARK: - HF cache scan + resolution (via test override)

    @Test func rescan_resolvesHFCacheSnapshotAndPath() async {
        await OsaurusTestGlobals.withPathsLock {
            rescan_resolvesHFCacheSnapshotAndPath_body()
        }
    }

    private func rescan_resolvesHFCacheSnapshotAndPath_body() {
        let previousRoot = OsaurusPaths.overrideRoot
        let previousOverride = ExternalModelLocator.testRootsOverride
        let manifestRoot = makeTempDir()
        let hfRoot = makeTempDir()
        OsaurusPaths.overrideRoot = manifestRoot
        ExternalModelLocator.invalidateInMemory()
        defer {
            OsaurusPaths.overrideRoot = previousRoot
            ExternalModelLocator.testRootsOverride = previousOverride
            ExternalModelLocator.invalidateInMemory()
            try? FileManager.default.removeItem(at: manifestRoot)
            try? FileManager.default.removeItem(at: hfRoot)
        }

        // Build a fake HF hub layout:
        //   models--org--repo/refs/main          -> <rev>
        //   models--org--repo/snapshots/<rev>/   -> bundle files
        let fm = FileManager.default
        let rev = "abc123"
        let modelDir = hfRoot.appendingPathComponent("models--org--repo", isDirectory: true)
        let refsDir = modelDir.appendingPathComponent("refs", isDirectory: true)
        try? fm.createDirectory(at: refsDir, withIntermediateDirectories: true)
        try? Data(rev.utf8).write(to: refsDir.appendingPathComponent("main"))
        let snapshot = modelDir.appendingPathComponent("snapshots/\(rev)", isDirectory: true)
        writeBundle(at: snapshot)

        ExternalModelLocator.testRootsOverride = [(root: hfRoot, source: .huggingFaceCache)]
        ExternalModelLocator.rescan()

        // The model resolves by id, with the HF-cache source label.
        let resolved = ExternalModelLocator.path(forId: "org/repo")
        #expect(resolved != nil)
        #expect(resolved?.standardizedFileURL.path == snapshot.standardizedFileURL.path)

        let models = ExternalModelLocator.models()
        #expect(models.contains { $0.id == "org/repo" && $0.externalSource == "Hugging Face cache" })

        // A catalog entry exposes the absolute bundle directory in place.
        let entry = models.first { $0.id == "org/repo" }
        #expect(entry?.bundleDirectory?.standardizedFileURL.path == snapshot.standardizedFileURL.path)
        #expect(entry?.isDownloaded == true)

        let report = ExternalModelLocator.lastScanReport()
        #expect(report?.discovered.contains { $0.id == "org/repo" } == true)
        #expect(report?.skipped.isEmpty == true)
    }

    @Test func rescan_reportsHFCacheSnapshotSkipReason() async {
        await OsaurusTestGlobals.withPathsLock {
            rescan_reportsHFCacheSnapshotSkipReason_body()
        }
    }

    private func rescan_reportsHFCacheSnapshotSkipReason_body() {
        let previousRoot = OsaurusPaths.overrideRoot
        let previousOverride = ExternalModelLocator.testRootsOverride
        let manifestRoot = makeTempDir()
        let hfRoot = makeTempDir()
        OsaurusPaths.overrideRoot = manifestRoot
        ExternalModelLocator.invalidateInMemory()
        defer {
            OsaurusPaths.overrideRoot = previousRoot
            ExternalModelLocator.testRootsOverride = previousOverride
            ExternalModelLocator.invalidateInMemory()
            try? FileManager.default.removeItem(at: manifestRoot)
            try? FileManager.default.removeItem(at: hfRoot)
        }

        let fm = FileManager.default
        let modelDir = hfRoot.appendingPathComponent("models--org--repo", isDirectory: true)
        try? fm.createDirectory(at: modelDir, withIntermediateDirectories: true)

        ExternalModelLocator.testRootsOverride = [(root: hfRoot, source: .huggingFaceCache)]
        ExternalModelLocator.rescan()

        let report = ExternalModelLocator.lastScanReport()
        #expect(report?.discovered.isEmpty == true)
        #expect(
            report?.skipped.contains {
                $0.repoId == "org/repo" && $0.reason == .missingSnapshot
            } == true
        )
    }
}
