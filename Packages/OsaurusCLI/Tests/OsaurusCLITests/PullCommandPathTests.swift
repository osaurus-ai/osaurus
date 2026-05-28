//
//  PullCommandPathTests.swift
//  osaurus
//
//  Tests the remote path guard used before Hugging Face tree entries become
//  local model-download destinations.
//

import XCTest

@testable import OsaurusCLICore

final class PullCommandPathTests: XCTestCase {

    func testNormalizesPortableRelativeModelPaths() {
        XCTAssertEqual(PullCommand.normalizedRemoteFilePath("config.json"), "config.json")
        XCTAssertEqual(
            PullCommand.normalizedRemoteFilePath("shards/model-00001.safetensors"),
            "shards/model-00001.safetensors"
        )
    }

    func testRejectsEscapingOrPlatformSpecificRemotePaths() {
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
            XCTAssertNil(PullCommand.normalizedRemoteFilePath(path), "accepted \(path)")
        }
    }

    func testDestinationURLStaysInsideModelDirectory() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = try XCTUnwrap(
            PullCommand.destinationURL(
                forRemotePath: "shards/model-00001.safetensors",
                under: root
            )
        )

        XCTAssertEqual(
            destination.path,
            root.appendingPathComponent("shards/model-00001.safetensors").path
        )
    }

    func testDestinationURLRejectsSymlinkedParentEscapes() throws {
        let root = try makeDirectory()
        let outside = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let link = root.appendingPathComponent("shards", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertNil(
            PullCommand.destinationURL(
                forRemotePath: "shards/model-00001.safetensors",
                under: root
            )
        )
    }

    func testResolveDownloadURLUsesPathComponents() {
        let url = PullCommand.resolveDownloadURL(
            repoId: "mlx-community/Test Model",
            path: "weights/model 1.safetensors"
        )

        XCTAssertEqual(
            url?.absoluteString,
            "https://huggingface.co/mlx-community/Test%20Model/resolve/main/weights/model%201.safetensors"
        )
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-cli-hf-path-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }
}
