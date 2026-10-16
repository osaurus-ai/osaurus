import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

struct ImageBundleRoutingTests {
    @Test func imageLayoutReproducesReportedLanguageModelPreflightError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ["model_index.json", "transformer/config.json", "vae/config.json", "text_encoder/config.json"]
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("{}".utf8).write(to: url)
        }
        let wrongRoute = ExternalModelLocator.bundleDiagnostic(at: root, root: root)
        #expect(wrongRoute.reason == .missingConfig)
        #expect(wrongRoute.detail == "config.json is required for MLX bundle discovery.")
        #expect(ImageModelDownloadService.isImageBundle(paths: paths))
    }

    @Test func nestedImageBundleDoesNotNeedLanguageModelRootConfig() {
        #expect(
            ImageModelDownloadService.isImageBundle(paths: [
                "model_index.json", "transformer/config.json", "transformer/0.safetensors",
                "vae/config.json", "vae/0.safetensors", "text_encoder/config.json",
            ])
        )
        #expect(ImageModelDownloadService.isImageBundle(paths: ["vae/config.json", "unet/config.json"]))
    }

    @Test func languageAndVisionLanguageBundlesStayOnChatRoute() {
        #expect(
            !ImageModelDownloadService.isImageBundle(paths: [
                "config.json", "model.safetensors", "preprocessor_config.json", "tokenizer.json",
                "vision_tower/model.safetensors",
            ])
        )
        #expect(!ImageModelDownloadService.isImageBundle(paths: ["transformer/config.json"]))
        #expect(!ImageModelDownloadService.isImageBundle(paths: []))
    }

    @Test @MainActor func offeredRepoIsVisibleWithoutStartingDownload() {
        let service = ImageModelDownloadService()
        let repo = "example/arbitrary-image-bundle"
        service.offer(repoId: repo)
        service.offer(repoId: repo)
        #expect(service.fetchedCatalog.filter { $0.repoId == repo }.count == 1)
        #expect(service.states.isEmpty)
    }

    @Test func recoveryPreservesSourceAndNestedLayout() throws {
        try withFiles { root, source, destination, file in
            #expect(try ImageModelDownloadService.recoverMisroutedFile(file, from: root, to: destination))
            #expect(try Data(contentsOf: destination) == Data(contentsOf: source))
            try Data("edited".utf8).write(to: destination)
            #expect(try Data(contentsOf: source) == Data("weights".utf8))
        }
    }

    @Test func recoveryRejectsSameSizeWrongContent() throws {
        try withFiles { root, source, destination, file in
            try Data("garbage".utf8).write(to: source)
            let recovered = try ImageModelDownloadService.recoverMisroutedFile(file, from: root, to: destination)
            #expect(!recovered)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test func recoveryNeedsPublishedDigest() throws {
        try withFiles { root, _, destination, original in
            var file = original
            file.digest = nil
            let recovered = try ImageModelDownloadService.recoverMisroutedFile(file, from: root, to: destination)
            #expect(!recovered)
        }
    }

    @Test func recoveryRejectsSymlinkAndTraversal() throws {
        try withFiles { root, source, destination, original in
            let real = root.appendingPathComponent("real")
            try FileManager.default.moveItem(at: source, to: real)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: real)
            #expect(try !ImageModelDownloadService.recoverMisroutedFile(original, from: root, to: destination))
            let traversal = HuggingFaceService.MatchedFile(
                path: "../real",
                size: original.size,
                digest: original.digest
            )
            #expect(try !ImageModelDownloadService.recoverMisroutedFile(traversal, from: root, to: destination))
        }
    }

    private func withFiles(
        _ body: (URL, URL, URL, HuggingFaceService.MatchedFile) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("legacy")
        let source = legacy.appendingPathComponent("transformer/0.safetensors")
        let destination = root.appendingPathComponent("image/transformer/0.safetensors")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let bytes = Data("weights".utf8)
        try bytes.write(to: source)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let file = HuggingFaceService.MatchedFile(
            path: "transformer/0.safetensors",
            size: Int64(bytes.count),
            digest: .sha256(digest)
        )
        try body(legacy, source, destination, file)
    }
}
