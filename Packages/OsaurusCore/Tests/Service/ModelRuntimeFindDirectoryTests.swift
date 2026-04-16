import Foundation
import Testing

@testable import OsaurusCore

@Suite("ModelRuntime.resolveLocalModelDirectory — symlink resolution")
struct ModelRuntimeFindDirectoryTests {

    @Test("Plain org/repo directory with valid weights resolves")
    func plainLayoutResolves() throws {
        let (root, realModel) = try makeRoot()
        try populateValidModel(at: realModel)

        let resolved = ModelRuntime.resolveLocalModelDirectory(
            forModelId: "OsaurusAI/TestModel",
            in: root
        )
        #expect(resolved != nil)
        // Path resolution normalizes `/private/var/...` ↔ `/var/...` etc, so
        // compare realpath form to avoid false negatives on macOS where
        // `NSTemporaryDirectory` lives under a symlinked mount point.
        #expect(resolved?.resolvingSymlinksInPath().path == realModel.resolvingSymlinksInPath().path)
    }

    @Test("Symlinked model directory resolves (regression for ENOTDIR bug)")
    func symlinkLayoutResolves() throws {
        let (root, realModel) = try makeRoot(layout: .symlinked)
        try populateValidModel(at: realModel)

        // `root/OsaurusAI/TestModel` is a symlink → realModel.
        let resolved = ModelRuntime.resolveLocalModelDirectory(
            forModelId: "OsaurusAI/TestModel",
            in: root
        )
        #expect(resolved != nil)
        // Post-resolution we should be pointing at the real target, not the link path.
        #expect(resolved?.resolvingSymlinksInPath().path == realModel.resolvingSymlinksInPath().path)
    }

    @Test("Missing config.json returns nil even when safetensors exist")
    func missingConfigRejects() throws {
        let (root, realModel) = try makeRoot()
        // Populate only safetensors, no config.json.
        try FileManager.default.createDirectory(at: realModel, withIntermediateDirectories: true)
        try Data("dummy".utf8).write(to: realModel.appendingPathComponent("model.safetensors"))

        let resolved = ModelRuntime.resolveLocalModelDirectory(
            forModelId: "OsaurusAI/TestModel",
            in: root
        )
        #expect(resolved == nil)
    }

    @Test("Missing safetensors returns nil even with config.json")
    func missingSafetensorsRejects() throws {
        let (root, realModel) = try makeRoot()
        try FileManager.default.createDirectory(at: realModel, withIntermediateDirectories: true)
        try Data(#"{"model_type":"test"}"#.utf8).write(to: realModel.appendingPathComponent("config.json"))

        let resolved = ModelRuntime.resolveLocalModelDirectory(
            forModelId: "OsaurusAI/TestModel",
            in: root
        )
        #expect(resolved == nil)
    }

    @Test("Nonexistent path returns nil")
    func nonexistentReturnsNil() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("osaurus-test-\(UUID().uuidString)", isDirectory: true)
        let resolved = ModelRuntime.resolveLocalModelDirectory(
            forModelId: "Nobody/Nothing",
            in: tmp
        )
        #expect(resolved == nil)
    }

    // MARK: - Fixtures

    private enum Layout {
        /// `<root>/OsaurusAI/TestModel/` is a real directory.
        case plain
        /// `<root>/OsaurusAI/TestModel` is a symlink → an out-of-tree real directory.
        /// This exercises the actual ENOTDIR bug fix path.
        case symlinked
    }

    /// Builds a fresh root dir under `NSTemporaryDirectory()`. Returns the
    /// root plus the real directory where model files should be written
    /// (either the repo dir directly, or the symlink target).
    private func makeRoot(layout: Layout = .plain) throws -> (root: URL, realModel: URL) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("osaurus-modelruntime-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let orgDir = root.appendingPathComponent("OsaurusAI", isDirectory: true)
        try fm.createDirectory(at: orgDir, withIntermediateDirectories: true)

        switch layout {
        case .plain:
            let repoDir = orgDir.appendingPathComponent("TestModel", isDirectory: true)
            try fm.createDirectory(at: repoDir, withIntermediateDirectories: true)
            return (root, repoDir)

        case .symlinked:
            // Put the real weights outside the "picker root" so we're
            // actually resolving across a symlink boundary.
            let externalBase = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("osaurus-modelruntime-external-\(UUID().uuidString)", isDirectory: true)
            let realRepo = externalBase.appendingPathComponent("TestModel-real", isDirectory: true)
            try fm.createDirectory(at: realRepo, withIntermediateDirectories: true)
            let linkAt = orgDir.appendingPathComponent("TestModel")
            try fm.createSymbolicLink(at: linkAt, withDestinationURL: realRepo)
            return (root, realRepo)
        }
    }

    /// Writes minimum files so `resolveLocalModelDirectory` considers the
    /// directory a valid model (config.json + any `*.safetensors`).
    private func populateValidModel(at dir: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data(#"{"model_type":"test"}"#.utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data("dummy".utf8).write(to: dir.appendingPathComponent("model.safetensors"))
    }
}
