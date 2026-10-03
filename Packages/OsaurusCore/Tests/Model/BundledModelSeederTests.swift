//
//  BundledModelSeederTests.swift
//  osaurusTests
//
//  Covers the first-launch seeding of models shipped inside the full
//  distribution app bundle: seed-when-absent, no-op when installed, the
//  user-deletion marker, manifest/bundle corruption handling, and the
//  discovery notification.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite struct BundledModelSeederTests {
    private static let modelId = "OsaurusAI/Raptor-0.6-4B-JANG_6M"
    private static let revision = "0123456789abcdef0123456789abcdef01234567"

    private struct Fixture {
        let root: URL
        let bundledRoot: URL
        let modelsDirectory: URL
        let markerURL: URL

        var bundledModelDirectory: URL {
            bundledRoot
                .appendingPathComponent("OsaurusAI", isDirectory: true)
                .appendingPathComponent("Raptor-0.6-4B-JANG_6M", isDirectory: true)
        }

        var destination: URL {
            modelsDirectory
                .appendingPathComponent("OsaurusAI", isDirectory: true)
                .appendingPathComponent("Raptor-0.6-4B-JANG_6M", isDirectory: true)
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// The seeded bundle must be exactly what `ModelDownloadService` would
    /// have written: config, tokenizer assets, weights, publisher manifest.
    private static let bundleFiles: [(name: String, contents: Data)] = [
        ("config.json", Data(#"{"model_type":"spark2_5"}"#.utf8)),
        ("tokenizer.json", Data(#"{"version":"1.0"}"#.utf8)),
        ("model-00001-of-00001.safetensors", Data(repeating: 0x5A, count: 4096)),
        ("model.safetensors.index.json", Data(#"{"metadata":{"total_size":4096},"weight_map":{}}"#.utf8)),
        ("osaurus.json", Data(#"{"required_osaurus_version":"0.1.0","model_version":"1"}"#.utf8)),
    ]

    private func makeFixture(
        manifest: String? = nil,
        omitBundledFile: String? = nil
    ) throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("osu-bundled-seed-\(UUID().uuidString)", isDirectory: true)
        let fixture = Fixture(
            root: root,
            bundledRoot: root.appendingPathComponent("BundledModels", isDirectory: true),
            modelsDirectory: root.appendingPathComponent("MLXModels", isDirectory: true),
            markerURL: root.appendingPathComponent("osaurus-root/bundled-models-seeded.json")
        )
        try fm.createDirectory(at: fixture.bundledModelDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: fixture.modelsDirectory, withIntermediateDirectories: true)

        var files: [[String: Any]] = []
        for file in Self.bundleFiles {
            if file.name != omitBundledFile {
                try file.contents.write(to: fixture.bundledModelDirectory.appendingPathComponent(file.name))
            }
            files.append([
                "path": file.name,
                "bytes": file.contents.count,
                "sha256": Self.sha256Hex(file.contents),
            ])
        }

        let manifestData: Data
        if let manifest {
            manifestData = Data(manifest.utf8)
        } else {
            manifestData = try JSONSerialization.data(withJSONObject: [
                "models": [
                    [
                        "id": Self.modelId,
                        "revision": Self.revision,
                        "files": files,
                    ]
                ]
            ])
        }
        try manifestData.write(to: fixture.bundledRoot.appendingPathComponent("manifest.json"))
        return fixture
    }

    private static func sha256Hex(_ data: Data) -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-bundled-seed-hash-\(UUID().uuidString)")
        try? data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return BundledModelSeeder.sha256Hex(of: tmp) ?? ""
    }

    private func stagingLeftovers(in fixture: Fixture) -> [String] {
        let org = fixture.destination.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: org.path)) ?? []
        return names.filter { $0.hasPrefix(".") }
    }

    // MARK: - Tests

    @Test func seedsWhenAbsentAndWritesMarker() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        let outcomes = BundledModelSeeder.seedIfNeeded(
            bundledRoot: fixture.bundledRoot,
            modelsDirectory: fixture.modelsDirectory,
            markerURL: fixture.markerURL,
            notify: false
        )

        #expect(outcomes == [.seeded(id: Self.modelId)])
        for file in Self.bundleFiles {
            let copied = fixture.destination.appendingPathComponent(file.name)
            #expect(try Data(contentsOf: copied) == file.contents, "\(file.name) must be copied verbatim")
        }
        #expect(stagingLeftovers(in: fixture).isEmpty)

        let probe = MLXModel(
            id: Self.modelId,
            name: "",
            description: "",
            downloadURL: "",
            rootDirectory: fixture.modelsDirectory
        )
        #expect(probe.computeIsDownloadedFromDisk())

        let markers = BundledModelSeeder.readMarkers(at: fixture.markerURL)
        #expect(markers["\(Self.modelId)@\(Self.revision)"] != nil)
    }

    @Test func secondLaunchIsNoOpWhenInstalled() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        _ = BundledModelSeeder.seedIfNeeded(
            bundledRoot: fixture.bundledRoot,
            modelsDirectory: fixture.modelsDirectory,
            markerURL: fixture.markerURL,
            notify: false
        )
        let before =
            try FileManager.default.attributesOfItem(atPath: fixture.destination.path)[.modificationDate] as? Date

        let outcomes = BundledModelSeeder.seedIfNeeded(
            bundledRoot: fixture.bundledRoot,
            modelsDirectory: fixture.modelsDirectory,
            markerURL: fixture.markerURL,
            notify: false
        )

        #expect(outcomes == [.alreadyInstalled(id: Self.modelId)])
        let after =
            try FileManager.default.attributesOfItem(atPath: fixture.destination.path)[.modificationDate] as? Date
        #expect(before == after)
    }

    @Test func userDeletionIsHonoredViaMarker() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        _ = BundledModelSeeder.seedIfNeeded(
            bundledRoot: fixture.bundledRoot,
            modelsDirectory: fixture.modelsDirectory,
            markerURL: fixture.markerURL,
            notify: false
        )
        try FileManager.default.removeItem(at: fixture.destination)

        let outcomes = BundledModelSeeder.seedIfNeeded(
            bundledRoot: fixture.bundledRoot,
            modelsDirectory: fixture.modelsDirectory,
            markerURL: fixture.markerURL,
            notify: false
        )

        #expect(outcomes == [.previouslySeeded(id: Self.modelId)])
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func newRevisionSeedsAgainAfterDeletion() throws {
        // A marker for an older revision must not suppress a newer bundle.
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        try FileManager.default.createDirectory(
            at: fixture.markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(["\(Self.modelId)@olderrevision": "2026-01-01T00:00:00Z"])
            .write(to: fixture.markerURL)

        let outcomes = BundledModelSeeder.seedIfNeeded(
            bundledRoot: fixture.bundledRoot,
            modelsDirectory: fixture.modelsDirectory,
            markerURL: fixture.markerURL,
            notify: false
        )

        #expect(outcomes == [.seeded(id: Self.modelId)])
        let markers = BundledModelSeeder.readMarkers(at: fixture.markerURL)
        #expect(markers.count == 2)
    }

    @Test func malformedManifestIsANoOp() throws {
        let fixture = try makeFixture(manifest: #"{"models": "nope"}"#)
        defer { fixture.tearDown() }

        let outcomes = BundledModelSeeder.seedIfNeeded(
            bundledRoot: fixture.bundledRoot,
            modelsDirectory: fixture.modelsDirectory,
            markerURL: fixture.markerURL,
            notify: false
        )

        #expect(outcomes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.markerURL.path))
    }

    @Test func pathTraversalIdIsRejected() throws {
        let manifest = """
            {"models":[{"id":"../escape","revision":"r","files":[{"path":"config.json","bytes":1}]}]}
            """
        let fixture = try makeFixture(manifest: manifest)
        defer { fixture.tearDown() }

        let outcomes = BundledModelSeeder.seedIfNeeded(
            bundledRoot: fixture.bundledRoot,
            modelsDirectory: fixture.modelsDirectory,
            markerURL: fixture.markerURL,
            notify: false
        )

        #expect(outcomes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("escape").path))
    }

    @Test func missingBundledFileFailsCleanly() throws {
        let fixture = try makeFixture(omitBundledFile: "model-00001-of-00001.safetensors")
        defer { fixture.tearDown() }

        let outcomes = BundledModelSeeder.seedIfNeeded(
            bundledRoot: fixture.bundledRoot,
            modelsDirectory: fixture.modelsDirectory,
            markerURL: fixture.markerURL,
            notify: false
        )

        #expect(outcomes.count == 1)
        guard case .failed(let id, let reason) = outcomes[0] else {
            Issue.record("expected .failed, got \(outcomes[0])")
            return
        }
        #expect(id == Self.modelId)
        #expect(reason.contains("model-00001-of-00001.safetensors"))
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(stagingLeftovers(in: fixture).isEmpty, "staging directory must be cleaned up")
        // No marker: the next launch (or a repaired bundle) may retry.
        #expect(BundledModelSeeder.readMarkers(at: fixture.markerURL).isEmpty)
    }

    @Test func sizeMismatchFailsCleanly() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        // Corrupt the bundled weights after the manifest was written.
        try Data(repeating: 0x00, count: 10)
            .write(to: fixture.bundledModelDirectory.appendingPathComponent("model-00001-of-00001.safetensors"))

        let outcomes = BundledModelSeeder.seedIfNeeded(
            bundledRoot: fixture.bundledRoot,
            modelsDirectory: fixture.modelsDirectory,
            markerURL: fixture.markerURL,
            notify: false
        )

        guard case .failed(_, let reason) = outcomes.first else {
            Issue.record("expected .failed, got \(outcomes)")
            return
        }
        #expect(reason.contains("expected 4096"))
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func existingIncompleteDestinationIsNeverOverwritten() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        let partial = fixture.destination.appendingPathComponent("config.json")
        try Data("partial".utf8).write(to: partial)

        let outcomes = BundledModelSeeder.seedIfNeeded(
            bundledRoot: fixture.bundledRoot,
            modelsDirectory: fixture.modelsDirectory,
            markerURL: fixture.markerURL,
            notify: false
        )

        guard case .failed = outcomes.first else {
            Issue.record("expected .failed, got \(outcomes)")
            return
        }
        #expect(try Data(contentsOf: partial) == Data("partial".utf8))
    }

    @Test func lightBuildHasNothingToSeed() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        let outcomes = BundledModelSeeder.seedIfNeeded(
            bundledRoot: nil,
            modelsDirectory: fixture.modelsDirectory,
            markerURL: fixture.markerURL,
            notify: false
        )

        #expect(outcomes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func bundledRootRequiresManifest() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        try FileManager.default.removeItem(at: fixture.bundledRoot.appendingPathComponent("manifest.json"))

        // A bundle whose Resources lack `BundledModels/manifest.json` is the
        // light distribution.
        #expect(BundledModelSeeder.bundledRoot(bundle: Bundle(for: ProbeClass.self)) == nil)
        #expect(BundledModelSeeder.loadManifest(at: fixture.bundledRoot) == nil)
    }

    @Test func seedingPostsLocalModelsChanged() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        final class Flag: @unchecked Sendable { var count = 0 }
        let flag = Flag()
        // Other suites post `.localModelsChanged` concurrently; count only
        // the seeder's own posts.
        let token = NotificationCenter.default.addObserver(
            forName: .localModelsChanged,
            object: nil,
            queue: nil
        ) { note in
            guard
                note.userInfo?[BundledModelSeeder.notificationSourceKey] as? String
                    == BundledModelSeeder.notificationSourceValue
            else { return }
            flag.count += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        _ = BundledModelSeeder.seedIfNeeded(
            bundledRoot: fixture.bundledRoot,
            modelsDirectory: fixture.modelsDirectory,
            markerURL: fixture.markerURL,
            notify: true
        )
        #expect(flag.count == 1)

        // Nothing changed on the second pass: no notification.
        _ = BundledModelSeeder.seedIfNeeded(
            bundledRoot: fixture.bundledRoot,
            modelsDirectory: fixture.modelsDirectory,
            markerURL: fixture.markerURL,
            notify: true
        )
        #expect(flag.count == 1)
    }

    @Test func isValidModelIdRejectsEscapes() {
        #expect(BundledModelSeeder.isValidModelId("OsaurusAI/Raptor-0.6-4B-JANG_6M"))
        #expect(!BundledModelSeeder.isValidModelId("Raptor"))
        #expect(!BundledModelSeeder.isValidModelId("a/b/c"))
        #expect(!BundledModelSeeder.isValidModelId("../x"))
        #expect(!BundledModelSeeder.isValidModelId("x/.."))
        #expect(!BundledModelSeeder.isValidModelId("/x"))
        #expect(!BundledModelSeeder.isValidModelId(".hidden/x"))
    }

    private final class ProbeClass {}
}
