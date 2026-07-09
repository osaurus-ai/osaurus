//
//  SkillRuntimeAffordanceTests.swift
//  OsaurusCoreTests
//
//  Verifies that skills can advertise helper files without auto-running or
//  reading untrusted scripts into the prompt.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SkillRuntimeAffordanceTests {

    @Test func supportFilesListScriptsAssetsAndTemplatesOnlyAsMetadata() async throws {
        try await Self.withTempSkill { _, skill in
            try Self.writeSkillFile("scripts/main.py", in: skill, contents: "print('hello')")
            try Self.writeSkillFile("scripts/utils/helper.py", in: skill, contents: "print('nested')")
            try Self.writeSkillFile("assets/template.txt", in: skill, contents: "template")
            try Self.writeSkillFile("templates/report.md", in: skill, contents: "# Report")

            let scriptsDir = SkillStore.skillDirectory(for: skill).appendingPathComponent("scripts")
            let templatesDir = SkillStore.skillDirectory(for: skill).appendingPathComponent("templates")
            let secret = OsaurusPaths.skills().appendingPathComponent("outside-script.txt")
            try "secret".write(to: secret, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(
                at: scriptsDir.appendingPathComponent("linked-secret.txt"),
                withDestinationURL: secret
            )
            let outsideTemplates = OsaurusPaths.skills().appendingPathComponent("outside-templates", isDirectory: true)
            try FileManager.default.createDirectory(at: outsideTemplates, withIntermediateDirectories: true)
            try "outside".write(
                to: outsideTemplates.appendingPathComponent("outside-template.txt"),
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.createSymbolicLink(
                at: templatesDir.appendingPathComponent("linked-outside"),
                withDestinationURL: outsideTemplates
            )

            let files = SkillStore.supportFiles(from: skill)
            let paths = files.map(\.relativePath)

            #expect(
                paths == [
                    "assets/template.txt",
                    "scripts/main.py",
                    "scripts/utils/helper.py",
                    "templates/report.md",
                ]
            )
            #expect(!paths.contains("scripts/linked-secret.txt"))
            #expect(!paths.contains("templates/linked-outside/outside-template.txt"))
            #expect(files.first(where: { $0.relativePath == "scripts/main.py" })?.size == 14)
        }
    }

    @Test func supportFilesStopsAtConfiguredLimit() async throws {
        try await Self.withTempSkill { _, skill in
            for index in 0..<6 {
                try Self.writeSkillFile("scripts/file-\(index).py", in: skill, contents: "\(index)")
            }

            let files = SkillStore.supportFiles(from: skill, maxFiles: 3)

            #expect(files.count == 3)
            #expect(files.map(\.relativePath).allSatisfy { $0.hasPrefix("scripts/") })
        }
    }

    @Test func supportFilesExcludeReferencesByDefaultAndIgnoreInvalidSubdirectories() async throws {
        try await Self.withTempSkill { _, skill in
            try await SkillStore.addReference(to: skill, name: "guide.md", content: Data("reference body".utf8))
            try Self.writeSkillFile("scripts/main.py", in: skill, contents: "print('hello')")

            let defaultPaths = SkillStore.supportFiles(from: skill).map(\.relativePath)
            let invalidPaths = SkillStore.supportFiles(
                from: skill,
                subdirectories: ["../references", "/tmp", ""],
                maxFiles: 10
            )

            #expect(defaultPaths == ["scripts/main.py"])
            #expect(invalidPaths.isEmpty)
        }
    }

    @Test func supportFilesRespectDepthLimit() async throws {
        try await Self.withTempSkill { _, skill in
            try Self.writeSkillFile("scripts/root.py", in: skill, contents: "root")
            try Self.writeSkillFile("scripts/nested/helper.py", in: skill, contents: "nested")

            let paths = SkillStore.supportFiles(from: skill, maxDepth: 0).map(\.relativePath)

            #expect(paths == ["scripts/root.py"])
        }
    }

    @Test @MainActor
    func fullInstructionsIncludeReferencesAndSupportInventoryWithoutScriptBody() async throws {
        try await Self.withTempSkill { root, skill in
            try await SkillStore.addReference(to: skill, name: "guide.md", content: Data("reference body".utf8))
            try Self.writeSkillFile("scripts/main.py", in: skill, contents: "print('hello')")
            try Self.writeSkillFile("assets/template.txt", in: skill, contents: "template body")
            try Self.writeSkillFile("assets/bad\nname.txt", in: skill, contents: "bad name body")
            try Self.writeSkillFile("assets/bidi\u{202E}name.txt", in: skill, contents: "bidi body")

            let loaded = try #require(await SkillStore.load(id: skill.id))
            let rendered = await SkillManager.shared.buildFullInstructions(for: loaded)

            #expect(rendered.contains("reference body"))
            #expect(rendered.contains("## Skill Package Files"))
            #expect(rendered.contains("scripts/main.py"))
            #expect(rendered.contains("assets/template.txt"))
            #expect(rendered.contains("assets/bad?name.txt"))
            #expect(rendered.contains("assets/bidi?name.txt"))
            #expect(rendered.contains("Reference materials, when present, are loaded separately above."))
            #expect(rendered.contains("The inventory is capped at 200 support files."))
            #expect(rendered.contains("loading a skill never executes"))
            #expect(!rendered.contains("print('hello')"))
            #expect(!rendered.contains("template body"))
            #expect(!rendered.contains("bad\nname.txt"))
            #expect(!rendered.contains("bad name body"))
            #expect(!rendered.contains("bidi\u{202E}name.txt"))
            #expect(!rendered.contains("bidi body"))
            #expect(!rendered.contains(root.path))
        }
    }

    @Test @MainActor
    func capabilitiesLoadSkillUsesFullInstructionsAndSupportInventory() async throws {
        try await Self.withTempSkill { root, skill in
            try await SkillStore.addReference(to: skill, name: "guide.md", content: Data("reference body".utf8))
            try Self.writeSkillFile("scripts/main.py", in: skill, contents: "print('hello')")

            await SkillManager.shared.refresh()
            let agent = Agent(
                name: "SkillRuntime-\(UUID().uuidString.prefix(6))",
                agentAddress: "skill-runtime-\(UUID().uuidString)",
                manualToolNames: []
            )
            await AgentManager.shared.add(agent)

            let result: String
            do {
                result = try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
                    try await CapabilitiesLoadTool().execute(
                        argumentsJSON: "{\"ids\": [\"skill/\(skill.name)\"]}"
                    )
                }
            } catch {
                _ = await AgentManager.shared.delete(id: agent.id)
                throw error
            }
            _ = await AgentManager.shared.delete(id: agent.id)

            #expect(result.contains("## Skill: Runtime Demo"))
            #expect(result.contains("reference body"))
            #expect(result.contains("scripts/main.py"))
            #expect(result.contains("loading a skill never executes"))
            #expect(!result.contains("print('hello')"))
            #expect(!result.contains(root.path))
        }

        await SkillManager.shared.refresh()
    }

    private static func withTempSkill<T: Sendable>(
        _ body: @Sendable (URL, Skill) async throws -> T
    ) async throws -> T {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-skill-runtime-\(UUID().uuidString)",
                isDirectory: true
            )
            let previousRoot = OsaurusPaths.overrideRoot
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root

            let skill = Skill(
                name: "Runtime Demo",
                instructions: "Use the helper files when the user explicitly asks.",
                directoryName: "runtime-demo"
            )
            await SkillStore.save(skill)

            do {
                let value = try await body(root, skill)
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
                await SkillManager.shared.refresh()
                return value
            } catch {
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
                await SkillManager.shared.refresh()
                throw error
            }
        }
    }

    private static func writeSkillFile(_ relativePath: String, in skill: Skill, contents: String) throws {
        let url = SkillStore.skillDirectory(for: skill).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
