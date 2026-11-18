//
//  ImageModelScanCacheTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct ImageModelScanCacheTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("FLUX.1-schnell-mflux-4bit"), withIntermediateDirectories: true)
        return root
    }

    private func bytes(_ infos: [ImageModelInfo]) -> UInt64 {
        infos.reduce(0) { $0 + $1.totalBytes }
    }

    @Test func repeatListingsReuseTheScanUntilModelsChange() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ImageGenerationService()

        let first = try await service.availableModels(in: root)
        #expect(first.count == 1)
        #expect(bytes(first) == 0)

        // A file inside a bundle leaves the root's listing alone, so the
        // cached scan still answers.
        let bundle = root.appendingPathComponent("FLUX.1-schnell-mflux-4bit")
        try Data(repeating: 1, count: 4096).write(to: bundle.appendingPathComponent("model.safetensors"))
        #expect(bytes(try await service.availableModels(in: root)) == 0)

        NotificationCenter.default.post(name: .localModelsChanged, object: nil)
        #expect(bytes(try await service.availableModels(in: root)) == 4096)
    }

    @Test func aBundleAddedToTheRootIsSeenWithoutANotification() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ImageGenerationService()

        #expect(try await service.availableModels(in: root).count == 1)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Qwen-Image-2.1-mflux-4bit"), withIntermediateDirectories: true)
        #expect(try await service.availableModels(in: root).count == 2)
    }
}
