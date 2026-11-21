import Foundation
import Testing

@testable import OsaurusCore

@Suite("Share providers")
struct ShareProviderTests {
    private let fm = FileManager.default

    private func scratch() throws -> URL {
        let url = fm.temporaryDirectory
            .appendingPathComponent("osaurus-share-provider-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ path: String, under root: URL, bytes: Int = 4) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    @Test func listsNestedFilesWithRelativePaths() throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        try write("config.json", under: root)
        try write("model.safetensors", under: root, bytes: 32)
        try write("vae/diffusion.safetensors", under: root)

        let files = try #require(ShareableFiles.list(root: root))
        #expect(files.map(\.path) == ["config.json", "model.safetensors", "vae/diffusion.safetensors"])
        #expect(files.first { $0.path == "model.safetensors" }?.size == 32)
    }

    @Test func skipsHiddenFilesAndDownloadLeftovers() throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        try write("config.json", under: root)
        try write(".osaurus-source", under: root)
        try write(".model.safetensors.nearby.part", under: root)
        for leftover in ["a.part", "b.download", "c.incomplete", "d.part.json", "e.tmp"] {
            try write(leftover, under: root)
        }

        let files = try #require(ShareableFiles.list(root: root))
        #expect(files.map(\.path) == ["config.json"])
    }

    @Test func emptyFolderIsNotShareable() throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        #expect(ShareableFiles.list(root: root) == nil)
    }

    @Test func followsSymlinksInsideTheConfinement() throws {
        let cache = try scratch()
        defer { try? fm.removeItem(at: cache) }
        try write("blobs/abc", under: cache, bytes: 9)
        let snapshot = cache.appendingPathComponent("snapshots/main", isDirectory: true)
        try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: snapshot.appendingPathComponent("model.safetensors"),
            withDestinationURL: cache.appendingPathComponent("blobs/abc")
        )

        let files = try #require(ShareableFiles.list(root: snapshot, confinement: cache))
        #expect(files.map(\.path) == ["model.safetensors"])
        #expect(files.first?.url.path == cache.appendingPathComponent("blobs/abc").path)
        #expect(files.first?.size == 9)

        #expect(ShareableFiles.list(root: snapshot) == nil, "outside the bundle without a wider confinement")
    }

    @Test func symlinkOutsideTheConfinementRefusesTheWholeBundle() throws {
        let root = try scratch()
        let outside = try scratch()
        defer {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: outside)
        }
        try write("config.json", under: root)
        try write("secret", under: outside)
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("model.safetensors"),
            withDestinationURL: outside.appendingPathComponent("secret")
        )
        #expect(ShareableFiles.list(root: root) == nil)
    }

    @Test func imageProviderListsOnlyCompleteBundles() throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let bundle = root.appendingPathComponent("flux-schnell-4bit", isDirectory: true)
        try write("model_index.json", under: bundle)
        try write("vae/0.safetensors", under: bundle)
        try write("transformer/0.safetensors", under: bundle)
        try write("text_encoder/0.safetensors", under: bundle)
        try Data("mflux/flux-schnell-4bit".utf8).write(to: bundle.appendingPathComponent(".osaurus-source"))
        try write("not-a-bundle/text_encoder/0.safetensors", under: root)

        let models = ImageBundleShareProvider.shareableModels(in: root)
        #expect(models.map(\.id) == ["image:flux-schnell-4bit"])
        let model = try #require(models.first)
        #expect(model.kind.format == "mflux")
        #expect(model.repoId == "mflux/flux-schnell-4bit")
        #expect(!model.files.contains { $0.path == ".osaurus-source" })
    }

    @Test func kindsMapToCatalogKindsAndFormats() {
        for kind in ModelShareKind.allCases {
            #expect(ModelShareKind(kind.localModelKind) == kind)
        }
        #expect(ModelShareKind.language.format == "mlx")
        #expect(ModelShareKind.embedding.format == "mlx")
        #expect(ModelShareKind.applescript.format == "mlx")
        #expect(ModelShareKind.privacy.format == "mlx")
        #expect(ModelShareKind.image.format == "mflux")
        #expect(ModelShareKind.speech.format == "coreml")
        #expect(ShareableModel.id(kind: .speech, localId: "v3") == "speech:v3")
    }
}
