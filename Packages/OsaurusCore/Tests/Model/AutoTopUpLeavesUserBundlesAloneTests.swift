//
//  AutoTopUpLeavesUserBundlesAloneTests.swift
//  OsaurusCoreTests
//
//  A user stripped tensors they did not need and osaurus quietly downloaded
//  them again on the next load — the automatic top-up ran the same
//  restore-to-the-repo logic as the Repair button. These pin the split: what
//  an automatic pass may fetch, and what only an explicit Repair may.
//
//  The interesting assertion in every case is an ABSENCE. A live screenshot
//  cannot show a file that was not downloaded, which is why the decision was
//  extracted into a pure function.
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
            remote: remoteFiles, under: dir, intent: .automatic)
        #expect(auto.isEmpty, "automatic top-up must not restore a deleted shard")

        let repair = ModelDownloadService.filesToFetch(
            remote: remoteFiles, under: dir, intent: .explicitRepair)
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
            remote: remoteFiles, under: dir, intent: .automatic)
        #expect(auto.isEmpty, "automatic top-up must not overwrite an existing config")

        let repair = ModelDownloadService.filesToFetch(
            remote: remoteFiles, under: dir, intent: .explicitRepair)
        #expect(repair.map(\.path) == ["config.json"], "Repair still restores it")
    }

    @Test("Genuinely absent metadata is still filled in automatically")
    func absentMetadataStillArrives() throws {
        let dir = try makeBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(120, to: dir.appendingPathComponent("config.json"))

        // The reason automatic top-up exists: a bundle downloaded before a
        // pattern was added is missing a small sidecar, and without it the
        // model misbehaves (see the chat_template.jinja instant-EOS bug).
        let remoteFiles = [
            remote("config.json", 120),
            remote("chat_template.jinja", 900),
            remote("tokenizer.json", 5000),
        ]

        let auto = ModelDownloadService.filesToFetch(
            remote: remoteFiles, under: dir, intent: .automatic)
        #expect(Set(auto.map(\.path)) == ["chat_template.jinja", "tokenizer.json"])
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
            remote: remoteFiles, under: dir, intent: .automatic)
        #expect(auto.isEmpty, "no weight format may be auto-fetched into a user's bundle")

        let repair = ModelDownloadService.filesToFetch(
            remote: remoteFiles, under: dir, intent: .explicitRepair)
        #expect(repair.count == remoteFiles.count)
    }
}
