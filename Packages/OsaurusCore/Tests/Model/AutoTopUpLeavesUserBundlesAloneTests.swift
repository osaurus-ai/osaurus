//
//  AutoTopUpLeavesUserBundlesAloneTests.swift
//  OsaurusCoreTests
//
//  Installed bundles must not receive metadata from a newer remote revision
//  during discovery or load. Explicit repair remains a separate operation.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Automatic top-up leaves user-modified bundles alone")
struct AutoTopUpLeavesUserBundlesAloneTests {

    private func makeBundle() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("topup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    private func remote(_ path: String, _ size: Int64) -> HuggingFaceService.MatchedFile {
        HuggingFaceService.MatchedFile(path: path, size: size)
    }

    @Test("A stripped weight shard is not silently re-downloaded")
    func strippedWeightsStayStripped() throws {
        let dir = try makeBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The user deleted shard 2 on purpose; shard 1 is still here.
        try write(64, to: dir.appendingPathComponent("model-00001-of-00002.safetensors"))

        let remoteFiles = [
            remote("model-00001-of-00002.safetensors", 64),
            remote("model-00002-of-00002.safetensors", 4096),
        ]

        let auto = ModelDownloadService.filesToFetch(
            remote: remoteFiles,
            under: dir,
            intent: .automatic
        )
        #expect(auto.isEmpty, "automatic top-up must not restore a deleted shard")

        let repair = ModelDownloadService.filesToFetch(
            remote: remoteFiles,
            under: dir,
            intent: .explicitRepair
        )
        #expect(repair.map(\.path) == ["model-00002-of-00002.safetensors"])
    }

    @Test("A hand-edited config is not overwritten from the Hub")
    func editedConfigSurvives() throws {
        let dir = try makeBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Present locally, and a different size from the repo's copy — the
        // signature of an edit, which the old code treated as damage.
        try write(120, to: dir.appendingPathComponent("config.json"))

        let remoteFiles = [remote("config.json", 300)]

        let auto = ModelDownloadService.filesToFetch(
            remote: remoteFiles,
            under: dir,
            intent: .automatic
        )
        #expect(auto.isEmpty, "automatic top-up must not overwrite an existing config")

        let repair = ModelDownloadService.filesToFetch(
            remote: remoteFiles,
            under: dir,
            intent: .explicitRepair
        )
        #expect(repair.map(\.path) == ["config.json"], "Repair still restores it")
    }

    @Test("Absent metadata requires explicit repair")
    func absentMetadataRequiresRepair() throws {
        let dir = try makeBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(120, to: dir.appendingPathComponent("config.json"))

        // Latest remote metadata is not necessarily compatible with the
        // installed weights, even when that metadata is absent locally.
        let remoteFiles = [
            remote("config.json", 120),
            remote("chat_template.jinja", 900),
            remote("tokenizer.json", 5000),
        ]

        let auto = ModelDownloadService.filesToFetch(
            remote: remoteFiles,
            under: dir,
            intent: .automatic
        )
        #expect(auto.isEmpty)
        let repair = ModelDownloadService.filesToFetch(
            remote: remoteFiles,
            under: dir,
            intent: .explicitRepair
        )
        #expect(Set(repair.map(\.path)) == ["chat_template.jinja", "tokenizer.json"])
    }

    @MainActor
    @Test("Automatic completeness makes no requests or writes", arguments: [false, true])
    func automaticCompletenessIsReadOnly(existingSentinel: Bool) async throws {
        let dir = try makeBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(120, to: dir.appendingPathComponent("config.json"))
        try write(64, to: dir.appendingPathComponent("model.safetensors"))
        if existingSentinel {
            try Data("keep this sentinel".utf8).write(to: dir.appendingPathComponent(".topup_done"))
        }
        let before = try snapshot(dir)
        let requests = CompletenessRequestFixture()
        let service = HuggingFaceService(metadataRequest: { try await requests.respond($0) })
        let model = MLXModel(id: "org/installed", name: "Installed", description: "", downloadURL: "")

        let verified = await ModelDownloadService.ensureComplete(
            for: model,
            directory: dir,
            clearSentinel: true,
            intent: .automatic,
            service: service
        )
        let downloaded = await ModelDownloadService.downloadMissingFiles(
            for: model,
            to: dir,
            intent: .automatic,
            service: service
        )

        #expect(!verified && !downloaded)
        #expect(await requests.count == 0)
        #expect(try snapshot(dir) == before)
    }

    @MainActor
    @Test("Explicit completeness still reaches the real listing boundary")
    func explicitCompletenessRequestControl() async throws {
        let dir = try makeBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(120, to: dir.appendingPathComponent("config.json"))
        let requests = CompletenessRequestFixture()
        let service = HuggingFaceService(metadataRequest: { try await requests.respond($0) })
        let model = MLXModel(id: "org/installed", name: "Installed", description: "", downloadURL: "")
        let verified = await ModelDownloadService.ensureComplete(
            for: model,
            directory: dir,
            intent: .explicitRepair,
            service: service
        )
        #expect(verified)
        #expect(await requests.count == 1)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".topup_done").path))
        #expect(try Data(contentsOf: dir.appendingPathComponent("config.json")) == Data(repeating: 0x41, count: 120))
    }

    private func snapshot(_ directory: URL) throws -> [String: Data] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    @Test("Every weight extension is covered, not just .safetensors")
    func allWeightFormatsAreProtected() throws {
        let dir = try makeBundle()
        defer { try? FileManager.default.removeItem(at: dir) }

        let remoteFiles = [
            remote("weights.bin", 10),
            remote("weights.gguf", 10),
            remote("weights.npz", 10),
            remote("weights.pt", 10),
            remote("weights.safetensors", 10),
        ]

        let auto = ModelDownloadService.filesToFetch(
            remote: remoteFiles,
            under: dir,
            intent: .automatic
        )
        #expect(auto.isEmpty, "no weight format may be auto-fetched into a user's bundle")

        let repair = ModelDownloadService.filesToFetch(
            remote: remoteFiles,
            under: dir,
            intent: .explicitRepair
        )
        #expect(repair.count == remoteFiles.count)
    }
}

private actor CompletenessRequestFixture {
    var count = 0

    func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
        count += 1
        let url = try #require(request.url)
        #expect(url.path == "/api/models/org/installed/tree/main")
        let body = #"[{"type":"file","path":"config.json","size":120}]"#
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
