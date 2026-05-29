import Foundation
import Testing

@testable import OsaurusCore

struct HuggingFaceDownloadPathTests {

    @Test func normalizesPortableRelativeModelPaths() {
        #expect(HuggingFaceService.normalizedRemoteFilePath("config.json") == "config.json")
        #expect(
            HuggingFaceService.normalizedRemoteFilePath("model-00001-of-00002/model.safetensors")
                == "model-00001-of-00002/model.safetensors"
        )
    }

    @Test func rejectsEscapingOrPlatformSpecificRemotePaths() {
        for path in [
            "",
            "/tmp/model.safetensors",
            "../model.safetensors",
            "weights/../model.safetensors",
            "weights//model.safetensors",
            "weights/./model.safetensors",
            "weights\\model.safetensors",
            "weights/model.safetensors\0",
        ] {
            #expect(HuggingFaceService.normalizedRemoteFilePath(path) == nil, "accepted \(path)")
        }
    }

    @Test func destinationURLStaysInsideModelDirectory() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = try #require(
            HuggingFaceService.destinationURL(
                forRemotePath: "shards/model-00001.safetensors",
                under: root
            )
        )

        #expect(destination.path == root.appendingPathComponent("shards/model-00001.safetensors").path)
    }

    @Test func destinationURLRejectsSymlinkedParentEscapes() throws {
        let root = try makeDirectory()
        let outside = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let link = root.appendingPathComponent("shards", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(
            HuggingFaceService.destinationURL(
                forRemotePath: "shards/model-00001.safetensors",
                under: root
            ) == nil
        )
    }

    @Test func modelDownloadResolveURLEncodesPathComponents() {
        let url = ModelDownloadService.resolveURL(
            repoId: "mlx-community/Test Model",
            path: "weights/model 1.safetensors"
        )

        #expect(
            url?.absoluteString
                == "https://huggingface.co/mlx-community/Test%20Model/resolve/main/weights/model%201.safetensors"
        )
        #expect(ModelDownloadService.resolveURL(repoId: "mlx-community/test", path: "../config.json") == nil)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-hf-path-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }
}
