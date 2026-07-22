//
//  SkillImportPolicyTests.swift
//  OsaurusCoreTests
//
//  Exercises third-party skill archive bounds before imported files enter the
//  persisted skill directory.
//

import Darwin
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SkillImportPolicyTests {

    @Test func zipImportCopiesReferencesAndAssets() async throws {
        try await Self.withTempRoot { root in
            let source = try Self.makeSkillBundle(
                in: root,
                directoryName: "safe-skill-bundle",
                skillName: "Safe Skill",
                references: ["guide.md": "reference"],
                assets: ["images/icon.txt": "asset"]
            )
            let zipURL = try Self.makeZip(from: source, in: root)

            let result = try await SkillManager.shared.importSkillFromZip(
                zipURL,
                overwriteExisting: false,
                policy: .test
            )

            #expect(result.skill.name == "Safe Skill")
            #expect(result.notes.isEmpty)

            let skillDir = SkillStore.skillDirectory(for: result.skill)
            #expect(
                try String(
                    contentsOf: skillDir.appendingPathComponent("references/guide.md"),
                    encoding: .utf8
                ) == "reference"
            )
            #expect(
                try String(
                    contentsOf: skillDir.appendingPathComponent("assets/images/icon.txt"),
                    encoding: .utf8
                ) == "asset"
            )

            let loaded = await SkillStore.load(id: result.skill.id)
            #expect(loaded?.references.contains { $0.relativePath == "references/guide.md" } == true)
            #expect(loaded?.assets.contains { $0.relativePath == "assets/images/icon.txt" } == true)
        }
    }

    /// Skills exported before the universal library carried an
    /// `osaurus-enabled` frontmatter key. Parsing must ignore it — a
    /// legacy `osaurus-enabled: false` file must not error out or hide
    /// the skill from the always-available library.
    @Test func legacyOsaurusEnabledMetadataIsIgnored() throws {
        let markdown = """
            ---
            name: Legacy Disabled Skill
            description: Exported while toggled off
            version: 1.2.0
            osaurus-enabled: false
            ---

            # Legacy Disabled Skill

            Instructions body.
            """

        let skill = try Skill.parseAgentSkillsFormat(from: markdown)
        #expect(skill.name == "Legacy Disabled Skill")
        #expect(skill.description == "Exported while toggled off")
        #expect(skill.instructions.contains("Instructions body."))
        // No enabled gate exists anymore; re-serialization must not
        // write the legacy key back out.
        #expect(!skill.toAgentSkillsFormat().contains("osaurus-enabled"))
    }

    @Test func archivePathValidationRejectsTraversalAndDepth() throws {
        try Self.expectSkillFileError(matching: { error in
            if case .archiveEntryEscapes("../SKILL.md") = error { return true }
            return false
        }) {
            try SkillImportPolicy.test.validateArchiveEntryNames(["../SKILL.md"])
        }

        try Self.expectSkillFileError(matching: { error in
            if case .archiveEntryTooDeep("a/b/c/d/SKILL.md", 3) = error { return true }
            return false
        }) {
            try SkillImportPolicy(
                maxArchiveBytes: 1_000_000,
                maxEntryBytes: 1_000_000,
                maxEntryCount: 20,
                maxPathDepth: 3
            )
            .validateArchiveEntryNames(["a/b/c/d/SKILL.md"])
        }
    }

    @Test func archiveCapsRejectBeforeExtraction() async throws {
        try await Self.withTempRoot { root in
            let source = try Self.makeSkillBundle(
                in: root,
                directoryName: "large-skill-bundle",
                skillName: "Large Skill",
                references: ["large.txt": String(repeating: "x", count: 256)]
            )
            let zipURL = try Self.makeZip(from: source, in: root)

            try Self.expectSkillFileError(matching: { error in
                if case .archiveEntryTooLarge(let path, 64) = error {
                    return path.hasSuffix("references/large.txt")
                }
                return false
            }) {
                try SkillImportPolicy(maxArchiveBytes: 1_000_000, maxEntryBytes: 64, maxEntryCount: 20, maxPathDepth: 8)
                    .validateArchiveBeforeExtraction(zipURL)
            }

            try Self.expectSkillFileError(matching: { error in
                if case .archiveTooLarge(32) = error { return true }
                return false
            }) {
                try SkillImportPolicy(maxArchiveBytes: 32, maxEntryBytes: 1_000_000, maxEntryCount: 20, maxPathDepth: 8)
                    .validateArchiveBeforeExtraction(zipURL)
            }
        }
    }

    @Test func archiveEntryLimitRejectsHighEntryListingWithoutStalling() async throws {
        try await Self.withTempRoot { root in
            let source = try Self.makeSkillBundle(
                in: root,
                directoryName: "many-entry-bundle",
                skillName: "Many Entry Skill"
            )
            let references = source.appendingPathComponent("references", isDirectory: true)
            try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)

            for index in 0..<2_000 {
                _ = FileManager.default.createFile(
                    atPath: references.appendingPathComponent("entry-\(index).txt").path,
                    contents: Data(),
                    attributes: nil
                )
            }

            let zipURL = try Self.makeZip(from: source, in: root)
            let startedAt = Date()

            try Self.expectSkillFileError(matching: { error in
                if case .archiveEntryLimitExceeded(40) = error { return true }
                return false
            }) {
                try SkillImportPolicy.test.validateArchiveBeforeExtraction(zipURL)
            }

            #expect(Date().timeIntervalSince(startedAt) < 10)
        }
    }

    @Test func archiveListingFailsClosedWhenOutputIsTruncated() async throws {
        try await Self.withTempRoot { root in
            let source = try Self.makeSkillBundle(
                in: root,
                directoryName: "long-listing-bundle",
                skillName: "Long Listing Skill"
            )
            var longDirectory = source.appendingPathComponent("references", isDirectory: true)
            for segment in 0..<4 {
                longDirectory = longDirectory.appendingPathComponent(
                    "segment-\(segment)-" + String(repeating: "x", count: 120),
                    isDirectory: true
                )
            }
            try FileManager.default.createDirectory(at: longDirectory, withIntermediateDirectories: true)

            for index in 0..<700 {
                _ = FileManager.default.createFile(
                    atPath: longDirectory.appendingPathComponent("entry-\(index).txt").path,
                    contents: Data(),
                    attributes: nil
                )
            }

            let zipURL = try Self.makeZip(from: source, in: root)
            let policy = SkillImportPolicy(
                maxArchiveBytes: 10_000_000,
                maxEntryBytes: 1_000_000,
                maxEntryCount: 512,
                maxPathDepth: 8
            )

            try Self.expectSkillFileError(matching: { error in
                if case .archiveListingFailed(let details) = error {
                    return details.contains("exceeded the supported limit")
                }
                return false
            }) {
                try policy.validateArchiveBeforeExtraction(zipURL)
            }
        }
    }

    @Test func extractedTreeRejectsSymlinksAndOversizedFiles() async throws {
        try await Self.withTempRoot { root in
            let symlinkBundle = try Self.makeSkillBundle(
                in: root,
                directoryName: "symlink-skill-bundle",
                skillName: "Symlink Skill"
            )
            let references = symlinkBundle.appendingPathComponent("references", isDirectory: true)
            try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
            let outside = root.appendingPathComponent("outside-secret.txt")
            try "secret".write(to: outside, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(
                at: references.appendingPathComponent("linked-secret.txt"),
                withDestinationURL: outside
            )

            try Self.expectSkillFileError(matching: { error in
                if case .archiveEntryUnsupported(let path) = error {
                    return path.hasSuffix("references/linked-secret.txt")
                }
                return false
            }) {
                _ = try SkillImportPolicy.test.scanExtractedTree(at: symlinkBundle)
            }

            let oversizeBundle = try Self.makeSkillBundle(
                in: root,
                directoryName: "oversize-skill-bundle",
                skillName: "Oversize Skill",
                references: ["too-large.txt": String(repeating: "x", count: 128)]
            )
            try Self.expectSkillFileError(matching: { error in
                if case .archiveEntryTooLarge(let path, 32) = error {
                    return path == "references/too-large.txt"
                }
                return false
            }) {
                _ = try SkillImportPolicy(
                    maxArchiveBytes: 1_000_000,
                    maxEntryBytes: 32,
                    maxEntryCount: 20,
                    maxPathDepth: 8
                ).scanExtractedTree(at: oversizeBundle)
            }
        }
    }

    @Test func copyFailureLeavesNoPartialSkillDirectory() async throws {
        try await Self.withTempRoot { root in
            let source = try Self.makeSkillBundle(
                in: root,
                directoryName: "broken-copy-bundle",
                skillName: "Broken Copy"
            )
            try "not a directory".write(
                to: source.appendingPathComponent("references"),
                atomically: true,
                encoding: .utf8
            )
            let zipURL = try Self.makeZip(from: source, in: root)

            try await Self.expectAsyncSkillFileError(matching: { error in
                if case .skillImportCopyFailed(let path, _) = error {
                    return path == "references"
                }
                return false
            }) {
                _ = try await SkillManager.shared.importSkillFromZip(
                    zipURL,
                    overwriteExisting: false,
                    policy: .test
                )
            }

            let expectedSkill = Skill(name: "Broken Copy", directoryName: "broken-copy")
            #expect(!FileManager.default.fileExists(atPath: SkillStore.skillDirectory(for: expectedSkill).path))
        }
    }

    @Test func duplicateSkillRequiresExplicitOverwrite() async throws {
        try await Self.withTempRoot { root in
            let firstSource = try Self.makeSkillBundle(
                in: root,
                directoryName: "replace-first",
                skillName: "Replace Me",
                references: ["guide.md": "first"]
            )
            let secondSource = try Self.makeSkillBundle(
                in: root,
                directoryName: "replace-second",
                skillName: "Replace Me",
                references: ["guide.md": "second"]
            )

            let firstZip = try Self.makeZip(from: firstSource, in: root)
            let secondZip = try Self.makeZip(from: secondSource, in: root)
            let first = try await SkillManager.shared.importSkillFromZip(
                firstZip,
                overwriteExisting: false,
                policy: .test
            )
            let destination = SkillStore.skillDirectory(for: first.skill)
            #expect(
                try String(
                    contentsOf: destination.appendingPathComponent("references/guide.md"),
                    encoding: .utf8
                ) == "first"
            )

            try await Self.expectAsyncSkillFileError(matching: { error in
                if case .skillAlreadyExists("Replace Me") = error { return true }
                return false
            }) {
                _ = try await SkillManager.shared.importSkillFromZip(
                    secondZip,
                    overwriteExisting: false,
                    policy: .test
                )
            }
            #expect(
                try String(
                    contentsOf: destination.appendingPathComponent("references/guide.md"),
                    encoding: .utf8
                ) == "first"
            )

            _ = try await SkillManager.shared.importSkillFromZip(
                secondZip,
                overwriteExisting: true,
                policy: .test
            )
            #expect(
                try String(
                    contentsOf: destination.appendingPathComponent("references/guide.md"),
                    encoding: .utf8
                ) == "second"
            )
        }
    }

    @Test func multiSkillArchiveChoosesShallowestThenLexicographicAndReportsIgnored() async throws {
        try await Self.withTempRoot { root in
            let source = root.appendingPathComponent("multi-skill-bundle", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Self.writeSkillMarkdown(named: "Zeta Skill", to: source.appendingPathComponent("z/SKILL.md"))
            try Self.writeSkillMarkdown(named: "Alpha Skill", to: source.appendingPathComponent("a/SKILL.md"))
            try Self.writeSkillMarkdown(named: "Deep Skill", to: source.appendingPathComponent("a/deep/SKILL.md"))

            let zipURL = try Self.makeZip(from: source, in: root)
            let result = try await SkillManager.shared.importSkillFromZip(
                zipURL,
                overwriteExisting: false,
                policy: .test
            )

            #expect(result.skill.name == "Alpha Skill")
            #expect(result.notes.count == 1)
            #expect(result.notes[0].contains("multi-skill-bundle/z/SKILL.md"))
            #expect(result.notes[0].contains("multi-skill-bundle/a/deep/SKILL.md"))
        }
    }

    @Test func importCancellationReachesBlockedArchiveInspection() async throws {
        try await Self.withTempRoot { root in
            let fifoURL = root.appendingPathComponent("blocked-archive.zip")
            try #require(mkfifo(fifoURL.path, 0o600) == 0)

            let task = Task {
                try await SkillManager.shared.importSkillFromZip(
                    fifoURL,
                    overwriteExisting: false,
                    policy: .test
                )
            }
            guard let writerDescriptor = await Self.waitForFIFOReader(at: fifoURL) else {
                task.cancel()
                _ = try? await task.value
                Issue.record("Archive inspection did not open the FIFO")
                return
            }

            task.cancel()
            try? await Task.sleep(nanoseconds: 50_000_000)
            _ = Darwin.close(writerDescriptor)

            do {
                _ = try await task.value
                Issue.record("Expected CancellationError")
            } catch is CancellationError {
                // Cancellation must survive policy wrapping and reach the archive subprocess.
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test func exportCancellationReachesZipProcessAndRemovesPartialArchive() async throws {
        try await Self.withTempRoot { _ in
            let identifier = UUID().uuidString
            let skill = Skill(
                name: "Cancellation Export \(identifier)",
                directoryName: "cancellation-export-\(identifier)"
            )
            let skillDirectory = SkillStore.skillDirectory(for: skill)
            try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
            try "# Cancellation Export".write(
                to: skillDirectory.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )

            let sparsePayload = skillDirectory.appendingPathComponent("payload.bin")
            _ = FileManager.default.createFile(atPath: sparsePayload.path, contents: nil)
            let payloadHandle = try FileHandle(forWritingTo: sparsePayload)
            try payloadHandle.truncate(atOffset: 512 * 1024 * 1024)
            try payloadHandle.close()

            let archiveURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "\(skill.xplaceholder_agentSkillsNamex).zip"
            )
            defer { try? FileManager.default.removeItem(at: archiveURL) }

            let task = Task {
                try await SkillManager.shared.exportSkillAsZip(skill)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            task.cancel()

            do {
                _ = try await task.value
                Issue.record("Expected CancellationError")
            } catch is CancellationError {
                #expect(!FileManager.default.fileExists(atPath: archiveURL.path))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test func archiveUtilitiesTreatLeadingDashSourceAsPath() async throws {
        try await Self.withTempRoot { root in
            let source = try Self.makeSkillBundle(
                in: root,
                directoryName: "-leading-dash-bundle",
                skillName: "Leading Dash"
            )
            let archiveURL = root.appendingPathComponent("leading-dash.zip")
            let extractionURL = root.appendingPathComponent("leading-dash-extracted", isDirectory: true)

            try await FileManager.default.zipItem(at: source, to: archiveURL)
            try SkillImportPolicy.test.validateArchiveBeforeExtraction(archiveURL)
            try await FileManager.default.unzipItem(at: archiveURL, to: extractionURL)

            #expect(
                FileManager.default.fileExists(
                    atPath: extractionURL.appendingPathComponent("-leading-dash-bundle/SKILL.md").path
                )
            )
        }
    }

    private static func withTempRoot<T: Sendable>(
        _ body: @Sendable (URL) async throws -> T
    ) async throws -> T {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-skill-import-\(UUID().uuidString)",
                isDirectory: true
            )
            let previousRoot = OsaurusPaths.overrideRoot
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            await SkillManager.shared.refresh()
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
            }
            return try await body(root)
        }
    }

    private static func waitForFIFOReader(at url: URL) async -> Int32? {
        for _ in 0..<200 {
            let descriptor = Darwin.open(url.path, O_WRONLY | O_NONBLOCK)
            if descriptor >= 0 { return descriptor }
            guard errno == ENXIO else { return nil }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private static func makeSkillBundle(
        in root: URL,
        directoryName: String,
        skillName: String,
        references: [String: String] = [:],
        assets: [String: String] = [:]
    ) throws -> URL {
        let source = root.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Self.writeSkillMarkdown(named: skillName, to: source.appendingPathComponent("SKILL.md"))

        for (path, content) in references {
            let url = source.appendingPathComponent("references/\(path)")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(
                to: url,
                atomically: true,
                encoding: .utf8
            )
        }

        for (path, content) in assets {
            let url = source.appendingPathComponent("assets/\(path)")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(
                to: url,
                atomically: true,
                encoding: .utf8
            )
        }

        return source
    }

    private static func writeSkillMarkdown(named name: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        ---
        name: \(name)
        description: Test skill
        version: 1.0.0
        ---

        # \(name)

        Follow the test instructions.
        """
        .write(to: url, atomically: true, encoding: .utf8)
    }

    private static func makeZip(from source: URL, in root: URL) throws -> URL {
        let zipURL = root.appendingPathComponent("\(source.lastPathComponent)-\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = source.deletingLastPathComponent()
        process.arguments = ["-r", "-q", "-nw", zipURL.path, "--", source.lastPathComponent]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "SkillImportPolicyTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output]
            )
        }
        return zipURL
    }

    private static func expectSkillFileError(
        matching predicate: (SkillFileError) -> Bool,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            Issue.record("Expected SkillFileError")
        } catch let error as SkillFileError {
            #expect(predicate(error), "Unexpected error: \(error)")
        }
    }

    private static func expectAsyncSkillFileError(
        matching predicate: (SkillFileError) -> Bool,
        operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
            Issue.record("Expected SkillFileError")
        } catch let error as SkillFileError {
            #expect(predicate(error), "Unexpected error: \(error)")
        }
    }
}

extension SkillImportPolicy {
    fileprivate static let test = SkillImportPolicy(
        maxArchiveBytes: 1_000_000,
        maxEntryBytes: 1_000_000,
        maxEntryCount: 40,
        maxPathDepth: 8
    )
}
