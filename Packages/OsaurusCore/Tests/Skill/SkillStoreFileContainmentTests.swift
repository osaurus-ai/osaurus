//
//  SkillStoreFileContainmentTests.swift
//  osaurusTests
//
//  Verifies that caller-provided skill file paths stay inside the skill,
//  references, and assets directories they are scoped to.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SkillStoreFileContainmentTests {

    @Test func validReferenceAndAssetOperationsStayContained() async throws {
        try await Self.withTempSkill { _, skill in
            let referenceData = Data("reference".utf8)
            let nestedReferenceData = Data("nested reference".utf8)
            let assetData = Data("asset".utf8)

            try await SkillStore.addReference(to: skill, name: "guide.md", content: referenceData)
            try await SkillStore.addReference(
                to: skill,
                name: "deep/notes.md",
                content: nestedReferenceData
            )
            try await SkillStore.addAsset(to: skill, name: "images/icon.txt", content: assetData)

            let skillDir = SkillStore.skillDirectory(for: skill)
            #expect(
                try Data(contentsOf: skillDir.appendingPathComponent("references/guide.md"))
                    == referenceData
            )
            #expect(
                try Data(contentsOf: skillDir.appendingPathComponent("references/deep/notes.md"))
                    == nestedReferenceData
            )
            #expect(
                try Data(contentsOf: skillDir.appendingPathComponent("assets/images/icon.txt"))
                    == assetData
            )

            let loadedGuide = try await SkillStore.readFile(from: skill, relativePath: "references/guide.md")
            let loadedNested = try await SkillStore.readFile(
                from: skill,
                relativePath: "references/deep/notes.md"
            )
            #expect(loadedGuide == referenceData)
            #expect(loadedNested == nestedReferenceData)

            let reloaded = await SkillStore.load(id: skill.id)
            #expect(reloaded?.references.contains { $0.relativePath == "references/guide.md" } == true)
            #expect(reloaded?.references.contains { $0.relativePath == "references/deep/notes.md" } == true)
            #expect(reloaded?.assets.contains { $0.relativePath == "assets/images/icon.txt" } == true)

            try await SkillStore.removeFile(from: skill, relativePath: "assets/images/icon.txt")
            #expect(
                !FileManager.default.fileExists(
                    atPath: skillDir.appendingPathComponent("assets/images/icon.txt").path
                )
            )
        }
    }

    @Test func addReferenceAndAssetRejectEscapingPaths() async throws {
        try await Self.withTempSkill { root, skill in
            let escapedReference = OsaurusPaths.skills().appendingPathComponent("escaped-reference.md")
            let escapedAsset = SkillStore.skillDirectory(for: skill).appendingPathComponent("escaped-asset.bin")
            let absoluteReference = root.appendingPathComponent("absolute-reference.md")
            let absoluteAsset = root.appendingPathComponent("absolute-asset.bin")

            for name in ["", "../escaped-reference.md", "deep/../escaped-reference.md", absoluteReference.path] {
                await #expect(throws: SkillStoreFileError.self) {
                    try await SkillStore.addReference(to: skill, name: name, content: Data("bad".utf8))
                }
            }

            for name in ["", "../escaped-asset.bin", "images/../../escaped-asset.bin", absoluteAsset.path] {
                await #expect(throws: SkillStoreFileError.self) {
                    try await SkillStore.addAsset(to: skill, name: name, content: Data("bad".utf8))
                }
            }

            #expect(!FileManager.default.fileExists(atPath: escapedReference.path))
            #expect(!FileManager.default.fileExists(atPath: escapedAsset.path))
            #expect(!FileManager.default.fileExists(atPath: absoluteReference.path))
            #expect(!FileManager.default.fileExists(atPath: absoluteAsset.path))
        }
    }

    @Test func readFileRejectsEscapesWithoutReturningOutsideData() async throws {
        try await Self.withTempSkill { root, skill in
            let outsideRead = OsaurusPaths.skills().appendingPathComponent("outside-read.txt")
            let absoluteRead = root.appendingPathComponent("absolute-read.txt")
            try Data("secret".utf8).write(to: outsideRead)
            try Data("absolute secret".utf8).write(to: absoluteRead)

            for path in ["", "../outside-read.txt", "references/../../outside-read.txt", absoluteRead.path] {
                await #expect(throws: SkillStoreFileError.self) {
                    _ = try await SkillStore.readFile(from: skill, relativePath: path)
                }
            }

            #expect(try Data(contentsOf: outsideRead) == Data("secret".utf8))
            #expect(try Data(contentsOf: absoluteRead) == Data("absolute secret".utf8))
        }
    }

    @Test func removeFileRejectsEscapesWithoutDeletingOutsideFiles() async throws {
        try await Self.withTempSkill { root, skill in
            let outsideDelete = OsaurusPaths.skills().appendingPathComponent("outside-delete.txt")
            let absoluteDelete = root.appendingPathComponent("absolute-delete.txt")
            try Data("keep".utf8).write(to: outsideDelete)
            try Data("keep absolute".utf8).write(to: absoluteDelete)

            for path in ["", "../outside-delete.txt", "references/../../outside-delete.txt", absoluteDelete.path] {
                await #expect(throws: SkillStoreFileError.self) {
                    try await SkillStore.removeFile(from: skill, relativePath: path)
                }
            }

            #expect(try Data(contentsOf: outsideDelete) == Data("keep".utf8))
            #expect(try Data(contentsOf: absoluteDelete) == Data("keep absolute".utf8))
        }
    }

    @Test func readFileRejectsSymlinkEscapes() async throws {
        try await Self.withTempSkill { _, skill in
            let skillDir = SkillStore.skillDirectory(for: skill)
            let referencesDir = skillDir.appendingPathComponent("references")
            let outsideRead = OsaurusPaths.skills().appendingPathComponent("symlink-secret.txt")
            let linkURL = referencesDir.appendingPathComponent("linked-secret.txt")
            try FileManager.default.createDirectory(at: referencesDir, withIntermediateDirectories: true)
            try Data("keep symlink secret".utf8).write(to: outsideRead)
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideRead)

            await #expect(throws: SkillStoreFileError.self) {
                _ = try await SkillStore.readFile(from: skill, relativePath: "references/linked-secret.txt")
            }
            #expect(try Data(contentsOf: outsideRead) == Data("keep symlink secret".utf8))
        }
    }

    @Test func addReferenceRejectsSymlinkedBaseDirectory() async throws {
        try await Self.withTempSkill { _, skill in
            let skillDir = SkillStore.skillDirectory(for: skill)
            let outsideReferences = OsaurusPaths.skills().appendingPathComponent("outside-references")
            let referencesDir = skillDir.appendingPathComponent("references")
            try FileManager.default.createDirectory(at: outsideReferences, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: referencesDir, withDestinationURL: outsideReferences)

            await #expect(throws: SkillStoreFileError.self) {
                try await SkillStore.addReference(to: skill, name: "leak.md", content: Data("bad".utf8))
            }
            #expect(!FileManager.default.fileExists(atPath: outsideReferences.appendingPathComponent("leak.md").path))
        }
    }

    private static func withTempSkill<T: Sendable>(
        _ body: @Sendable (URL, Skill) async throws -> T
    ) async throws -> T {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-skill-containment-\(UUID().uuidString)"
            )
            let previousRoot = OsaurusPaths.overrideRoot
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
            }

            let skill = Skill(
                name: "Containment Test",
                instructions: "Stay contained.",
                directoryName: "containment-test"
            )
            await SkillStore.save(skill)

            return try await body(root, skill)
        }
    }
}
