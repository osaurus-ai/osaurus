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
import OsaurusRepository
import Testing

@testable import OsaurusCore

private final class ExternalRescanTransitionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true

    func shouldContinue() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowed
    }

    func cancel() {
        lock.lock()
        allowed = false
        lock.unlock()
    }
}

private func waitForSignal(
    _ semaphore: DispatchSemaphore,
    timeout: TimeInterval
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + timeout))
        }
    }
}

private func waitForGroup(
    _ group: DispatchGroup,
    timeout: TimeInterval
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: group.wait(timeout: .now() + timeout))
        }
    }
}

@Suite(.serialized)
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

    @Test func scanCustomModelFolder_findsDirectAndNestedBundles() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let direct = root.appendingPathComponent("Direct-Model", isDirectory: true)
        let nested = root.appendingPathComponent("publisher/repo", isDirectory: true)
        let hfSnapshot = root
            .appendingPathComponent("models--org--cached", isDirectory: true)
            .appendingPathComponent("snapshots/abc123", isDirectory: true)
        writeBundle(at: direct)
        writeBundle(at: nested)
        writeBundle(at: hfSnapshot)

        let report = ExternalModelLocator.scanCustomModelFolderReport(root: root)
        let ids = Set(report.discovered.map(\.id))

        #expect(ids.contains("Direct-Model"))
        #expect(ids.contains("publisher/repo"))
        #expect(!ids.contains("models--org--cached/snapshots/abc123"))
        #expect(report.discovered.allSatisfy { $0.source == "Custom model folder" })
    }

    @Test func scanCustomModelFolder_acceptsSelectedBundleRoot() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        writeBundle(at: root)

        let report = ExternalModelLocator.scanCustomModelFolderReport(root: root)

        #expect(report.discovered.map(\.id) == [root.lastPathComponent])
        #expect(report.discovered.first?.bundlePath == root.standardizedFileURL.path)
        #expect(report.discovered.first?.source == "Custom model folder")
        #expect(report.skipped.isEmpty)
    }

    @Test func rescan_resolvesCustomModelFolderPath() async {
        await OsaurusTestGlobals.withPathsLock {
            rescan_resolvesCustomModelFolderPath_body()
        }
    }

    private func rescan_resolvesCustomModelFolderPath_body() {
        let previousRoot = OsaurusPaths.overrideRoot
        let previousOverride = ExternalModelLocator.testRootsOverride
        let manifestRoot = makeTempDir()
        let customRoot = makeTempDir()
        OsaurusPaths.overrideRoot = manifestRoot
        ExternalModelLocator.invalidateInMemory()
        defer {
            OsaurusPaths.overrideRoot = previousRoot
            ExternalModelLocator.testRootsOverride = previousOverride
            ExternalModelLocator.invalidateInMemory()
            try? FileManager.default.removeItem(at: manifestRoot)
            try? FileManager.default.removeItem(at: customRoot)
        }

        let bundle = customRoot.appendingPathComponent("publisher/repo", isDirectory: true)
        writeBundle(at: bundle)
        try? Data(#"{"model_type":"gemma4"}"#.utf8)
            .write(to: bundle.appendingPathComponent("config.json"))
        try? Data(#"{"metadata":{"total_size":44298536392}}"#.utf8)
            .write(to: bundle.appendingPathComponent("model.safetensors.index.json"))

        ExternalModelLocator.testRootsOverride = [(root: customRoot, source: .customModelFolder)]
        ExternalModelLocator.rescan()

        let report = ExternalModelLocator.lastScanReport()
        // Exercise the app-relaunch path: the persisted registry carries no
        // architecture field, so `models()` must rehydrate it from the bundle.
        ExternalModelLocator.invalidateInMemory()

        let resolved = ExternalModelLocator.path(forId: "publisher/repo")
        #expect(resolved?.standardizedFileURL.path == bundle.standardizedFileURL.path)

        let models = ExternalModelLocator.models()
        #expect(
            models.contains {
                $0.id == "publisher/repo"
                    && $0.externalSource == "Custom model folder"
                    && $0.modelType == "gemma4"
                    && $0.downloadSizeBytes == 44_298_536_392
            }
        )

        #expect(report?.discovered.contains { $0.id == "publisher/repo" } == true)
        #expect(report?.skipped.isEmpty == true)
    }

    @Test func rescan_doesNotCommitAfterIsolationTransition() async {
        await OsaurusTestGlobals.withPathsLock {
            let previousRoot = OsaurusPaths.overrideRoot
            let previousOverride = ExternalModelLocator.testRootsOverride
            let manifestRoot = makeTempDir()
            let customRoot = makeTempDir()
            let probe = ExternalRescanTransitionProbe()
            OsaurusPaths.overrideRoot = manifestRoot
            ExternalModelLocator.invalidateInMemory()
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                ExternalModelLocator.testRootsOverride = previousOverride
                ExternalModelLocator.invalidateInMemory()
                try? FileManager.default.removeItem(at: manifestRoot)
                try? FileManager.default.removeItem(at: customRoot)
            }

            writeBundle(at: customRoot.appendingPathComponent("publisher/repo"))
            ExternalModelLocator.testRootsOverride = [
                (root: customRoot, source: .customModelFolder)
            ]
            #expect(ExternalModelLocator.models().isEmpty)
            let generationBefore = ExternalModelLocator.registryGeneration()

            let models = ExternalModelLocator.rescan(
                shouldContinue: { probe.shouldContinue() },
                afterRegistryMutationForTesting: { probe.cancel() }
            )

            #expect(models.isEmpty)
            #expect(ExternalModelLocator.models().isEmpty)
            #expect(ExternalModelLocator.registryGeneration() == generationBefore)
        }
    }

    @Test func rescanRollsBackWhenPolicyChangesBeforePersistence() async {
        await OsaurusTestGlobals.withPathsLock {
            let previousRoot = OsaurusPaths.overrideRoot
            let previousOverride = ExternalModelLocator.testRootsOverride
            let manifestRoot = makeTempDir()
            let customRoot = makeTempDir()
            let probe = ExternalRescanTransitionProbe()
            OsaurusPaths.overrideRoot = manifestRoot
            ExternalModelLocator.invalidateInMemory()
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                ExternalModelLocator.testRootsOverride = previousOverride
                ExternalModelLocator.invalidateInMemory()
                try? FileManager.default.removeItem(at: manifestRoot)
                try? FileManager.default.removeItem(at: customRoot)
            }

            writeBundle(at: customRoot.appendingPathComponent("publisher/repo"))
            ExternalModelLocator.testRootsOverride = [
                (root: customRoot, source: .customModelFolder)
            ]
            let generationBefore = ExternalModelLocator.registryGeneration()

            let models = ExternalModelLocator.rescan(
                shouldContinue: { probe.shouldContinue() },
                beforePersistValidationForTesting: { probe.cancel() }
            )

            #expect(models.isEmpty)
            #expect(ExternalModelLocator.models().isEmpty)
            #expect(ExternalModelLocator.registryGeneration() > generationBefore)
            ExternalModelLocator.invalidateInMemory()
            #expect(ExternalModelLocator.models().isEmpty)
        }
    }

    @Test func concurrentRescansPersistNewestCommittedRegistry() async {
        await OsaurusTestGlobals.withPathsLock {
            let previousRoot = OsaurusPaths.overrideRoot
            let previousOverride = ExternalModelLocator.testRootsOverride
            let manifestRoot = makeTempDir()
            let firstRoot = makeTempDir()
            let secondRoot = makeTempDir()
            let firstReachedPersistence = DispatchSemaphore(value: 0)
            let releaseFirstPersistence = DispatchSemaphore(value: 0)
            let secondCommitted = DispatchSemaphore(value: 0)
            let group = DispatchGroup()
            OsaurusPaths.overrideRoot = manifestRoot
            ExternalModelLocator.invalidateInMemory()
            defer {
                releaseFirstPersistence.signal()
                OsaurusPaths.overrideRoot = previousRoot
                ExternalModelLocator.testRootsOverride = previousOverride
                ExternalModelLocator.invalidateInMemory()
                try? FileManager.default.removeItem(at: manifestRoot)
                try? FileManager.default.removeItem(at: firstRoot)
                try? FileManager.default.removeItem(at: secondRoot)
            }

            writeBundle(at: firstRoot.appendingPathComponent("publisher/first"))
            writeBundle(at: secondRoot.appendingPathComponent("publisher/second"))
            ExternalModelLocator.testRootsOverride = [
                (root: firstRoot, source: .customModelFolder)
            ]

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                _ = ExternalModelLocator.rescan(
                    beforePersistValidationForTesting: {
                        firstReachedPersistence.signal()
                        releaseFirstPersistence.wait()
                    }
                )
                group.leave()
            }
            #expect(await waitForSignal(firstReachedPersistence, timeout: 2) == .success)

            ExternalModelLocator.testRootsOverride = [
                (root: secondRoot, source: .customModelFolder)
            ]
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                _ = ExternalModelLocator.rescan(
                    afterRegistryMutationForTesting: {
                        secondCommitted.signal()
                    }
                )
                group.leave()
            }
            #expect(await waitForSignal(secondCommitted, timeout: 2) == .success)
            releaseFirstPersistence.signal()
            #expect(await waitForGroup(group, timeout: 5) == .success)

            ExternalModelLocator.invalidateInMemory()
            let persisted = ExternalModelLocator.models()
            #expect(persisted.map(\.id) == ["publisher/second"])
        }
    }

    @Test func failedRescanPersistenceRollsBackInMemoryAndOnDisk() async {
        await OsaurusTestGlobals.withPathsLock {
            let previousRoot = OsaurusPaths.overrideRoot
            let previousOverride = ExternalModelLocator.testRootsOverride
            let manifestRoot = makeTempDir()
            let firstRoot = makeTempDir()
            let secondRoot = makeTempDir()
            OsaurusPaths.overrideRoot = manifestRoot
            ExternalModelLocator.invalidateInMemory()
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                ExternalModelLocator.testRootsOverride = previousOverride
                ExternalModelLocator.invalidateInMemory()
                try? FileManager.default.removeItem(at: manifestRoot)
                try? FileManager.default.removeItem(at: firstRoot)
                try? FileManager.default.removeItem(at: secondRoot)
            }

            writeBundle(at: firstRoot.appendingPathComponent("publisher/first"))
            writeBundle(at: secondRoot.appendingPathComponent("publisher/second"))
            ExternalModelLocator.testRootsOverride = [
                (root: firstRoot, source: .customModelFolder)
            ]
            #expect(ExternalModelLocator.rescan().map(\.id) == ["publisher/first"])

            ExternalModelLocator.testRootsOverride = [
                (root: secondRoot, source: .customModelFolder)
            ]
            let result = ExternalModelLocator.rescan(
                persistWriterForTesting: { _, _ in
                    throw CocoaError(.fileWriteNoPermission)
                }
            )

            #expect(result.map(\.id) == ["publisher/first"])
            #expect(ExternalModelLocator.models().map(\.id) == ["publisher/first"])
            ExternalModelLocator.invalidateInMemory()
            #expect(ExternalModelLocator.models().map(\.id) == ["publisher/first"])
        }
    }

    @Test func isolatedHostCannotForgetOrPrunePersistedRegistry() async {
        await OsaurusTestGlobals.withPathsLock {
            let previousRoot = OsaurusPaths.overrideRoot
            let previousOverride = ExternalModelLocator.testRootsOverride
            let manifestRoot = makeTempDir()
            let customRoot = makeTempDir()
            OsaurusPaths.overrideRoot = manifestRoot
            ExternalModelLocator.invalidateInMemory()
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                ExternalModelLocator.testRootsOverride = previousOverride
                ExternalModelLocator.invalidateInMemory()
                try? FileManager.default.removeItem(at: manifestRoot)
                try? FileManager.default.removeItem(at: customRoot)
            }

            writeBundle(at: customRoot.appendingPathComponent("publisher/repo"))
            let fixtureRoots: [(root: URL, source: ExternalModelLocator.Source)] = [
                (root: customRoot, source: .customModelFolder)
            ]
            ExternalModelLocator.testRootsOverride = fixtureRoots
            #expect(ExternalModelLocator.rescan().map(\.id) == ["publisher/repo"])

            ExternalModelLocator.testRootsOverride = nil
            #expect(ProcessDataRootPolicy.isRecognizedTestHostProcess)
            ExternalModelLocator.forget(id: "publisher/repo")
            #expect(!ExternalModelLocator.pruneMissing())

            ExternalModelLocator.testRootsOverride = fixtureRoots
            ExternalModelLocator.invalidateInMemory()
            #expect(ExternalModelLocator.models().map(\.id) == ["publisher/repo"])
        }
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
