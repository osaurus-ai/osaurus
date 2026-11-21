import Foundation
import Testing

@testable import OsaurusCore

@Suite("Shared model index")
struct SharedModelIndexTests {
    /// SHA-256 of the ASCII bytes "hello".
    private static let helloDigest = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

    private func makeModel(in directory: URL, contents: [String: String]) throws -> ShareableModel {
        for (path, text) in contents {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: url)
        }
        let files = try #require(ShareableFiles.list(root: directory))
        return ShareableModel(
            kind: .language,
            localId: "mlx-community/Raptor-4bit",
            name: "Raptor",
            repoId: "mlx-community/Raptor-4bit",
            revision: "abc123",
            files: files
        )
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-shared-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func prepareHashesEveryFileAndKeepsMetadata() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(
            in: root.appendingPathComponent("bundle"),
            contents: ["config.json": "hello", "weights/model.safetensors": "hello"]
        )
        let index = SharedModelIndex(cacheURL: root.appendingPathComponent("hashes.json"))

        #expect(await !index.isPrepared(model))
        let shared = try await index.prepare(model)
        #expect(await index.isPrepared(model))

        #expect(shared.id == "language:mlx-community/Raptor-4bit")
        #expect(shared.kind == "language")
        #expect(shared.format == "mlx")
        #expect(shared.repoId == "mlx-community/Raptor-4bit")
        #expect(shared.revision == "abc123")
        #expect(shared.files.map(\.path) == ["config.json", "weights/model.safetensors"])
        #expect(shared.files.allSatisfy { $0.sha256 == Self.helloDigest && $0.size == 5 })
        #expect(shared.files.allSatisfy { FileManager.default.fileExists(atPath: $0.sourcePath) })
    }

    @Test func savedDigestsSurviveANewIndex() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("hashes.json")
        let model = try makeModel(in: root.appendingPathComponent("bundle"), contents: ["config.json": "hello"])

        let first = SharedModelIndex(cacheURL: cache)
        _ = try await first.prepare(model)
        await first.save(keeping: [model])
        #expect(FileManager.default.fileExists(atPath: cache.path))

        let second = SharedModelIndex(cacheURL: cache)
        #expect(await second.isPrepared(model))
    }

    @Test func changedFileIsHashedAgain() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("bundle")
        let index = SharedModelIndex(cacheURL: root.appendingPathComponent("hashes.json"))
        let model = try makeModel(in: directory, contents: ["config.json": "hello"])
        _ = try await index.prepare(model)

        let changed = try makeModel(in: directory, contents: ["config.json": "hello, world"])
        #expect(await !index.isPrepared(changed))
        let shared = try await index.prepare(changed)
        #expect(shared.files.first?.sha256 != Self.helloDigest)
        #expect(shared.files.first?.size == 12)
    }

    @Test func saveDropsDigestsForModelsNoLongerShareable() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("hashes.json")
        let kept = try makeModel(in: root.appendingPathComponent("kept"), contents: ["config.json": "hello"])
        let gone = try makeModel(in: root.appendingPathComponent("gone"), contents: ["config.json": "hello"])

        let index = SharedModelIndex(cacheURL: cache)
        _ = try await index.prepare(kept)
        _ = try await index.prepare(gone)
        await index.save(keeping: [kept])

        let reloaded = SharedModelIndex(cacheURL: cache)
        #expect(await reloaded.isPrepared(kept))
        #expect(await !reloaded.isPrepared(gone))
    }

    @Test func hashingStopsWhenCancelled() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(in: root.appendingPathComponent("bundle"), contents: ["config.json": "hello"])
        let index = SharedModelIndex(cacheURL: root.appendingPathComponent("hashes.json"))

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await index.prepare(model)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await !index.isPrepared(model))
    }
}
