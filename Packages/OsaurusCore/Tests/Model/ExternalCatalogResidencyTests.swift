import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ExternalCatalogResidencyTests {
    @Test func completedExternalCatalogInvalidatesProvisionalNameMiss() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("external-residency-\(UUID().uuidString)")
            let previousRoot = OsaurusPaths.overrideRoot
            let previousExternal = ExternalModelLocator.testRootsOverride
            let previousLocal = ModelManager.scanLocalModelsOverrideForTests
            let previousHook = ExternalModelLocator.beforeModelsBuildForTests
            let gate = CatalogBuildGate()
            defer {
                gate.release()
                ExternalModelLocator.beforeModelsBuildForTests = previousHook
                ExternalModelLocator.testRootsOverride = previousExternal
                ModelManager.scanLocalModelsOverrideForTests = previousLocal
                OsaurusPaths.overrideRoot = previousRoot
                ExternalModelLocator.invalidateInMemory()
                ModelManager.invalidateLocalModelsCache()
                try? FileManager.default.removeItem(at: root)
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root.appendingPathComponent("state")
            ExternalModelLocator.testRootsOverride = []
            ExternalModelLocator.invalidateInMemory()
            _ = ExternalModelLocator.rescan()
            ModelManager.scanLocalModelsOverrideForTests = { _ in [] }
            ModelManager.invalidateLocalModelsCache()
            _ = ModelManager.discoverLocalModels()

            let bundle = root.appendingPathComponent("models/publisher/resident-fixture")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            for name in ["config.json", "tokenizer.json", "model.safetensors"] {
                try Data("{}".utf8).write(to: bundle.appendingPathComponent(name))
            }
            ExternalModelLocator.testRootsOverride = [(root.appendingPathComponent("models"), .customModelFolder)]
            ExternalModelLocator.beforeModelsBuildForTests = { gate.wait() }
            let rebuild = Task.detached { ExternalModelLocator.rescan() }
            for _ in 0 ..< 200 {
                if gate.entered { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            #expect(gate.entered)
            let registryBefore = ExternalModelLocator.registryGeneration()
            let catalogBefore = ExternalModelLocator.catalogGeneration()

            // The registry knows this bundle, but the nonblocking catalog is
            // still empty. Cache the same provisional miss that made an open
            // HF-backed chat invisible to activeLocalModelNames().
            #expect(
                ExternalModelLocator.path(forId: "publisher/resident-fixture")?.standardizedFileURL.path
                    == bundle.standardizedFileURL.path
            )
            #expect(ModelManager.findInstalledModelFromCache(named: "publisher/resident-fixture") == nil)
            gate.release()
            _ = await rebuild.value
            #expect(ExternalModelLocator.registryGeneration() == registryBefore)
            #expect(ExternalModelLocator.catalogGeneration() != catalogBefore)
            #expect(
                ModelManager.findInstalledModelFromCache(named: "publisher/resident-fixture")?.name
                    == "resident-fixture"
            )
            #expect(
                ModelManager.findInstalledMLXModelFromCache(named: "publisher/resident-fixture")?.id
                    == "publisher/resident-fixture"
            )

            // Removal must invalidate a cached hit as well as a cached miss.
            ExternalModelLocator.testRootsOverride = []
            _ = ExternalModelLocator.rescan()
            #expect(ModelManager.findInstalledModelFromCache(named: "publisher/resident-fixture") == nil)
        }
    }
}

private final class CatalogBuildGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    var entered: Bool {
        condition.lock()
        defer { condition.unlock() }
        return started
    }

    func wait() {
        condition.lock()
        started = true
        while !released { condition.wait() }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
