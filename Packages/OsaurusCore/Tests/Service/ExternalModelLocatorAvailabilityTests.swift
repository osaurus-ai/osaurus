import Darwin
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ExternalModelLocatorAvailabilityTests {
    private let id = "publisher/availability-fixture"

    private func writeBundle(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["config.json", "tokenizer.json", "model.safetensors"] {
            try Data("{}".utf8).write(to: directory.appendingPathComponent(name))
        }
    }

    private func isolated(
        _ body: @Sendable (URL, URL) async throws -> Void
    ) async throws {
        try await OsaurusTestGlobals.withPathsLock {
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("external-availability-\(UUID().uuidString)", isDirectory: true)
            let root = temporary.appendingPathComponent("library", isDirectory: true)
            let previousRoot = OsaurusPaths.overrideRoot
            let previousSources = ExternalModelLocator.testRootsOverride
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = temporary.appendingPathComponent("state", isDirectory: true)
            ExternalModelLocator.testRootsOverride = [(root, .customModelFolder)]
            ExternalModelLocator.invalidateInMemory()
            defer {
                ExternalModelLocator.testRootsOverride = previousSources
                OsaurusPaths.overrideRoot = previousRoot
                ExternalModelLocator.invalidateInMemory()
                try? FileManager.default.removeItem(at: temporary)
            }
            try await body(temporary, root)
        }
    }

    private func manifestIDs() throws -> Set<String> {
        let data = try Data(contentsOf: OsaurusPaths.externalModelsManifestFile())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try #require(json["models"] as? [[String: Any]])
        return Set(models.compactMap { $0["id"] as? String })
    }

    @Test
    func prunePreservesTemporarilyUnavailableRootAndPersistedIdentity() async throws {
        try await isolated { temporary, root in
            let bundle = root.appendingPathComponent(id, isDirectory: true)
            try writeBundle(bundle)
            _ = ExternalModelLocator.rescan()
            let before = try Data(contentsOf: OsaurusPaths.externalModelsManifestFile())
            let offline = temporary.appendingPathComponent("offline-library", isDirectory: true)
            try FileManager.default.moveItem(at: root, to: offline)
            #expect(ExternalModelLocator.bundlePresence(at: bundle) == .missingDirectory)
            #expect(ExternalModelLocator.path(forId: id) == nil)
            #expect(!ExternalModelLocator.pruneMissing())
            #expect(try Data(contentsOf: OsaurusPaths.externalModelsManifestFile()) == before)
            try FileManager.default.moveItem(at: offline, to: root)
            ExternalModelLocator.invalidateInMemory()
            #expect(ExternalModelLocator.path(forId: id)?.path == bundle.path)
        }
    }

    @Test
    func failedRescanPreservesRegistryAcrossRestartAndRecovery() async throws {
        try await isolated { temporary, root in
            let bundle = root.appendingPathComponent(id, isDirectory: true)
            try writeBundle(bundle)
            _ = ExternalModelLocator.rescan()
            let before = try Data(contentsOf: OsaurusPaths.externalModelsManifestFile())
            let offline = temporary.appendingPathComponent("offline-library", isDirectory: true)
            try FileManager.default.moveItem(at: root, to: offline)
            _ = ExternalModelLocator.rescan()
            #expect(ExternalModelLocator.lastScanReport()?.skipped.contains { $0.reason == .unreadableRoot } == true)
            #expect(try Data(contentsOf: OsaurusPaths.externalModelsManifestFile()) == before)
            ExternalModelLocator.invalidateInMemory()
            #expect(ExternalModelLocator.path(forId: id) == nil)
            try FileManager.default.moveItem(at: offline, to: root)
            #expect(ExternalModelLocator.path(forId: id)?.path == bundle.path)
        }
    }

    @Test
    func positivelyMissingConfigIsPrunedWithoutDeletingSourceFiles() async throws {
        try await isolated { _, root in
            let bundle = root.appendingPathComponent(id, isDirectory: true)
            try writeBundle(bundle)
            _ = ExternalModelLocator.rescan()
            try FileManager.default.removeItem(at: bundle.appendingPathComponent("config.json"))
            #expect(ExternalModelLocator.bundlePresence(at: bundle) == .missingConfig)
            #expect(ExternalModelLocator.pruneMissing())
            #expect(try manifestIDs().isEmpty)
            #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("model.safetensors").path))
            #expect(!ExternalModelLocator.pruneMissing())
        }
    }

    @Test
    func healthyRescanRemovesAnActuallyDeletedBundle() async throws {
        try await isolated { _, root in
            let bundle = root.appendingPathComponent(id, isDirectory: true)
            try writeBundle(bundle)
            _ = ExternalModelLocator.rescan()
            try FileManager.default.removeItem(at: bundle)
            #expect(!ExternalModelLocator.pruneMissing())
            _ = ExternalModelLocator.rescan()
            #expect(ExternalModelLocator.lastScanReport()?.skipped.isEmpty == true)
            #expect(try manifestIDs().isEmpty)
        }
    }

    @Test
    func explicitForgetAndDisabledSourceStillRemoveUnavailableEntries() async throws {
        try await isolated { temporary, root in
            let bundle = root.appendingPathComponent(id, isDirectory: true)
            try writeBundle(bundle)
            _ = ExternalModelLocator.rescan()
            let offline = temporary.appendingPathComponent("offline-library", isDirectory: true)
            try FileManager.default.moveItem(at: root, to: offline)
            ExternalModelLocator.forget(id: id)
            #expect(try manifestIDs().isEmpty)
            try FileManager.default.moveItem(at: offline, to: root)
            #expect(ExternalModelLocator.path(forId: id) == nil)
            _ = ExternalModelLocator.rescan()
            #expect(try manifestIDs() == [id])
            try FileManager.default.moveItem(at: root, to: offline)
            ExternalModelLocator.testRootsOverride = []
            _ = ExternalModelLocator.rescan()
            #expect(try manifestIDs().isEmpty)
        }
    }

    @Test
    func explicitRootReplacementDoesNotRetainTheRemovedRoot() async throws {
        try await isolated { temporary, root in
            try writeBundle(root.appendingPathComponent(id, isDirectory: true))
            _ = ExternalModelLocator.rescan()
            let replacement = temporary.appendingPathComponent("new-library", isDirectory: true)
            try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
            ExternalModelLocator.testRootsOverride = [(replacement, .customModelFolder)]
            _ = ExternalModelLocator.rescan()
            #expect(try manifestIDs().isEmpty)
        }
    }

    @Test
    func unreadableBundleIsRetainedByPruneAndPartialRescan() async throws {
        try await isolated { _, root in
            try #require(geteuid() != 0, "The real permission fixture requires an unprivileged test process")
            let bundle = root.appendingPathComponent(id, isDirectory: true)
            let removed = root.appendingPathComponent("healthy/deleted", isDirectory: true)
            try writeBundle(bundle)
            try writeBundle(removed)
            _ = ExternalModelLocator.rescan()
            try FileManager.default.removeItem(at: removed)
            try #require(chmod(bundle.path, 0) == 0)
            defer { _ = chmod(bundle.path, 0o700) }
            #expect(ExternalModelLocator.bundlePresence(at: bundle) == .unavailable)
            #expect(!ExternalModelLocator.pruneMissing())
            _ = ExternalModelLocator.rescan()
            #expect(ExternalModelLocator.lastScanReport()?.skipped.contains { $0.reason == .unreadableRoot } == true)
            #expect(try manifestIDs() == [id])
            try #require(chmod(bundle.path, 0o700) == 0)
            ExternalModelLocator.invalidateInMemory()
            #expect(ExternalModelLocator.path(forId: id)?.path == bundle.path)
        }
    }

    @Test
    func danglingConfigSymlinkDoesNotProveTheBundleWasDeleted() async throws {
        try await isolated { _, root in
            let bundle = root.appendingPathComponent(id, isDirectory: true)
            try writeBundle(bundle)
            _ = ExternalModelLocator.rescan()
            try FileManager.default.removeItem(at: bundle.appendingPathComponent("config.json"))
            try FileManager.default.createSymbolicLink(
                at: bundle.appendingPathComponent("config.json"),
                withDestinationURL: bundle.appendingPathComponent("unavailable-config.json"))
            #expect(ExternalModelLocator.bundlePresence(at: bundle) == .unavailable)
            #expect(ExternalModelLocator.path(forId: id) == nil)
            #expect(!ExternalModelLocator.pruneMissing())
            _ = ExternalModelLocator.rescan()
            #expect(ExternalModelLocator.models().allSatisfy { $0.id != id })
            #expect(try manifestIDs() == [id])
        }
    }

    @Test
    func legacyManifestWithoutRootProvenanceSurvivesAnUnavailableRoot() async throws {
        try await isolated { temporary, root in
            let bundle = root.appendingPathComponent(id, isDirectory: true)
            try writeBundle(bundle)
            _ = ExternalModelLocator.rescan()
            let file = OsaurusPaths.externalModelsManifestFile()
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            var entries = try #require(json["models"] as? [[String: Any]])
            for index in entries.indices { entries[index].removeValue(forKey: "scanRootPath") }
            json["models"] = entries
            try JSONSerialization.data(withJSONObject: json).write(to: file, options: .atomic)
            ExternalModelLocator.invalidateInMemory()
            let offline = temporary.appendingPathComponent("offline-library", isDirectory: true)
            try FileManager.default.moveItem(at: root, to: offline)
            _ = ExternalModelLocator.rescan()
            #expect(try manifestIDs() == [id])
            try FileManager.default.moveItem(at: offline, to: root)
            ExternalModelLocator.invalidateInMemory()
            #expect(ExternalModelLocator.path(forId: id)?.path == bundle.path)
        }
    }

    @Test
    func pruneCannotRemoveAnIdReboundToAnotherValidPath() async throws {
        try await isolated { temporary, root in
            let oldBundle = root.appendingPathComponent(id, isDirectory: true)
            try writeBundle(oldBundle)
            _ = ExternalModelLocator.rescan()
            let replacement = temporary.appendingPathComponent("replacement", isDirectory: true)
            let newBundle = replacement.appendingPathComponent(id, isDirectory: true)
            try writeBundle(newBundle)
            let removed = ExternalModelLocator.pruneMissing { directory in
                #expect(directory.path == oldBundle.path)
                ExternalModelLocator.testRootsOverride = [(replacement, .customModelFolder)]
                _ = ExternalModelLocator.rescan()
                return .missingConfig
            }
            #expect(!removed)
            ExternalModelLocator.invalidateInMemory()
            #expect(ExternalModelLocator.path(forId: id)?.path == newBundle.path)
        }
    }

    @Test
    func symlinkedScanRootKeepsItsIdentityWhileTargetIsUnavailable() async throws {
        try await isolated { temporary, root in
            let bundle = root.appendingPathComponent(id, isDirectory: true)
            try writeBundle(bundle)
            let alias = temporary.appendingPathComponent("library-alias", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
            ExternalModelLocator.testRootsOverride = [(alias, .customModelFolder)]
            _ = ExternalModelLocator.rescan()
            let offline = temporary.appendingPathComponent("offline-library", isDirectory: true)
            try FileManager.default.moveItem(at: root, to: offline)
            _ = ExternalModelLocator.rescan()
            #expect(try manifestIDs() == [id])
            try FileManager.default.moveItem(at: offline, to: root)
            ExternalModelLocator.invalidateInMemory()
            #expect(ExternalModelLocator.path(forId: id)?.path == bundle.path)
        }
    }

    @Test
    func failedScanCannotResurrectAnEntryForgottenDuringItsProbe() async throws {
        try await isolated { temporary, root in
            try writeBundle(root.appendingPathComponent(id, isDirectory: true))
            _ = ExternalModelLocator.rescan()
            let offline = temporary.appendingPathComponent("offline-library", isDirectory: true)
            try FileManager.default.moveItem(at: root, to: offline)
            _ = ExternalModelLocator.rescan { _ in
                ExternalModelLocator.forget(id: id)
                return .missingDirectory
            }
            #expect(try manifestIDs().isEmpty)
        }
    }

    @Test
    func unchangedIdentityRefreshClearsReadinessAndPickerAcrossOutageAndRecovery() async throws {
        try await isolated { temporary, root in
            try await RemoteProviderTestLock.shared.run {
                let previousScan = ModelManager.scanLocalModelsOverrideForTests
                defer {
                    ModelManager.scanLocalModelsOverrideForTests = previousScan
                    ModelManager.invalidateLocalModelsCache()
                }
                ModelManager.scanLocalModelsOverrideForTests = { _ in [] }
                ModelManager.invalidateLocalModelsCache()
                await ModelManager.awaitLocalModelsCacheReadyForDispatch()
                let bundle = root.appendingPathComponent(id, isDirectory: true)
                try writeBundle(bundle)
                _ = ExternalModelLocator.rescan()
                let before = try Data(contentsOf: OsaurusPaths.externalModelsManifestFile())
                let model = try #require(ExternalModelLocator.models().first { $0.id == id })
                #expect(model.isDownloaded)
                #expect(ModelManager.findInstalledModelFromCache(named: id)?.id == id)
                let warmItems = await ModelPickerItemCache.shared.buildModelPickerItems()
                #expect(warmItems.contains { $0.id == id })

                let offline = temporary.appendingPathComponent("offline-library", isDirectory: true)
                try FileManager.default.moveItem(at: root, to: offline)
                let beforeOutage = ExternalModelLocator.catalogGeneration()
                #expect(!ExternalModelLocator.pruneMissing())
                #expect(ExternalModelLocator.catalogGeneration() != beforeOutage)
                #expect(!model.isDownloaded)
                #expect(ExternalModelLocator.models().allSatisfy { $0.id != id })
                #expect(ModelManager.findInstalledModelFromCache(named: id) == nil)
                let offlineItems = await ModelPickerItemCache.shared.buildModelPickerItems()
                #expect(!offlineItems.contains { $0.id == id })
                #expect(try Data(contentsOf: OsaurusPaths.externalModelsManifestFile()) == before)

                // Warm the negative result, then restore the exact same identity.
                #expect(!model.isDownloaded)
                try FileManager.default.moveItem(at: offline, to: root)
                let beforeRecovery = ExternalModelLocator.catalogGeneration()
                _ = ExternalModelLocator.rescan()
                #expect(ExternalModelLocator.catalogGeneration() != beforeRecovery)
                #expect(model.isDownloaded)
                #expect(ModelManager.findInstalledModelFromCache(named: id)?.id == id)
                let recoveredItems = await ModelPickerItemCache.shared.buildModelPickerItems()
                #expect(recoveredItems.contains { $0.id == id })
                #expect(try Data(contentsOf: OsaurusPaths.externalModelsManifestFile()) == before)
            }
        }
    }

    @Test
    func unchangedHealthyRefreshInvalidatesAvailabilityWithoutRewritingManifest() async throws {
        try await isolated { _, root in
            let bundle = root.appendingPathComponent(id, isDirectory: true)
            try writeBundle(bundle)
            _ = ExternalModelLocator.rescan()
            let before = try Data(contentsOf: OsaurusPaths.externalModelsManifestFile())
            let generation = ExternalModelLocator.catalogGeneration()
            #expect(!ExternalModelLocator.pruneMissing())
            #expect(ExternalModelLocator.catalogGeneration() != generation)
            #expect(ExternalModelLocator.models().map(\.id) == [id])
            #expect(try Data(contentsOf: OsaurusPaths.externalModelsManifestFile()) == before)
        }
    }

    @Test(arguments: [ExternalModelLocator.BundlePresence.unavailable, .missingDirectory, .present])
    func failedRootReconciliationRetainsOnlyItsOwnEntries(presence: ExternalModelLocator.BundlePresence) {
        let failedRoot = URL(fileURLWithPath: "/proof/offline", isDirectory: true)
        let healthyRoot = URL(fileURLWithPath: "/proof/healthy", isDirectory: true)
        let failed = ExternalModelLocator.Discovered(
            id: "publisher/offline", bundlePath: failedRoot.appendingPathComponent("publisher/offline").path,
            revision: nil, source: ExternalModelLocator.Source.customModelFolder.rawValue,
            scanRootPath: failedRoot.path)
        let deleted = ExternalModelLocator.Discovered(
            id: "publisher/deleted", bundlePath: healthyRoot.appendingPathComponent("publisher/deleted").path,
            revision: nil, source: ExternalModelLocator.Source.customModelFolder.rawValue,
            scanRootPath: healthyRoot.path)
        let report = ExternalModelLocator.ScanReport(sources: [
            .init(source: .customModelFolder, rootPath: failedRoot.path, discovered: [], skipped: [
                .init(repoId: nil, path: failedRoot.path, reason: .unreadableRoot, detail: "Fixture root unavailable")
            ]),
            .init(source: .customModelFolder, rootPath: healthyRoot.path, discovered: [], skipped: []),
        ])
        let result = ExternalModelLocator.reconciledRegistry(
            previous: [failed.id: failed, deleted.id: deleted], report: report,
            configuredRoots: [(failedRoot, .customModelFolder), (healthyRoot, .customModelFolder)],
            probe: { $0.path == failed.bundlePath ? presence : .missingDirectory })
        #expect(result == [failed.id: failed])
    }
}
