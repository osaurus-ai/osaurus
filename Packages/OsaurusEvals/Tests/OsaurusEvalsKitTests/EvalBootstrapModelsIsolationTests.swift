import Foundation
import Testing

@testable import OsaurusEvalsKit

/// Pins the deletion-safety contract of the isolated models store
/// (`EvalBootstrap.seedIsolatedModelsDirectory`). The eval process isolates
/// `~/.osaurus`, but the models directory lives OUTSIDE that root, and a
/// model-issued `osaurus_config` models prune deletes through
/// `ModelManager.deleteModel` → `FileManager.removeItem` on the model path.
/// Observed 2026-08-22: a DefaultAgent lane wiped the user's REAL weights
/// from `~/MLXModels` mid-run. The seeded store therefore mirrors
/// `owner/name` with per-model SYMLINKS: reads follow the link to the real
/// weights; a delete unlinks only the symlink.
struct EvalBootstrapModelsIsolationTests {
    private func makeRealModelsDirectory() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("models-isolation-real-\(UUID().uuidString)", isDirectory: true)
        let model = root.appendingPathComponent("OsaurusAI/Fixture-9B-MXFP8", isDirectory: true)
        try fm.createDirectory(at: model, withIntermediateDirectories: true)
        try "fake weights".write(
            to: model.appendingPathComponent("model.safetensors"),
            atomically: true,
            encoding: .utf8
        )
        // Hidden bookkeeping must not be mirrored.
        try "junk".write(
            to: root.appendingPathComponent(".DS_Store"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }

    private func makeIsolatedRoot() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent(
                "models-isolation-eval-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func modelDirectoriesAreSymlinkedAndReadable() throws {
        let fm = FileManager.default
        let real = try makeRealModelsDirectory()
        let isolated = try makeIsolatedRoot()
        defer {
            try? fm.removeItem(at: real)
            try? fm.removeItem(at: isolated)
        }

        let store = EvalBootstrap.seedIsolatedModelsDirectory(
            realModelsDirectory: real,
            isolatedRoot: isolated
        )

        // Owner level is a REAL directory; model level is a SYMLINK.
        let owner = store.appendingPathComponent("OsaurusAI", isDirectory: true)
        let ownerType = try fm.attributesOfItem(atPath: owner.path)[.type] as? FileAttributeType
        #expect(ownerType == .typeDirectory)

        let model = owner.appendingPathComponent("Fixture-9B-MXFP8")
        let modelType = try fm.attributesOfItem(atPath: model.path)[.type] as? FileAttributeType
        #expect(modelType == .typeSymbolicLink)

        // Reads through the link see the real weights.
        let weights = model.appendingPathComponent("model.safetensors")
        #expect(try String(contentsOf: weights, encoding: .utf8) == "fake weights")

        // Hidden files are not mirrored.
        #expect(!fm.fileExists(atPath: store.appendingPathComponent(".DS_Store").path))
    }

    @Test func deletingThroughTheIsolatedStoreNeverTouchesRealWeights() throws {
        let fm = FileManager.default
        let real = try makeRealModelsDirectory()
        let isolated = try makeIsolatedRoot()
        defer {
            try? fm.removeItem(at: real)
            try? fm.removeItem(at: isolated)
        }

        let store = EvalBootstrap.seedIsolatedModelsDirectory(
            realModelsDirectory: real,
            isolatedRoot: isolated
        )

        // The exact operation `ModelDownloadService.delete` performs on the
        // model path — through the isolated store it must remove the link only.
        let isolatedModel = store.appendingPathComponent("OsaurusAI/Fixture-9B-MXFP8")
        try fm.removeItem(atPath: isolatedModel.path)

        #expect(!fm.fileExists(atPath: isolatedModel.path))
        let realWeights = real.appendingPathComponent(
            "OsaurusAI/Fixture-9B-MXFP8/model.safetensors")
        #expect(try String(contentsOf: realWeights, encoding: .utf8) == "fake weights")
    }

    @Test func missingRealDirectoryStillYieldsAnEmptyIsolatedStore() throws {
        let fm = FileManager.default
        let isolated = try makeIsolatedRoot()
        defer { try? fm.removeItem(at: isolated) }

        let store = EvalBootstrap.seedIsolatedModelsDirectory(
            realModelsDirectory: isolated.appendingPathComponent("does-not-exist"),
            isolatedRoot: isolated
        )

        var isDirectory: ObjCBool = false
        #expect(fm.fileExists(atPath: store.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        let entries = try fm.contentsOfDirectory(atPath: store.path)
        #expect(entries.isEmpty)
    }
}
