//
//  SymlinkedUserFoldersTests.swift
//  osaurusTests
//
//  Regression coverage for #1996: users who keep their Osaurus customisations
//  in a dotfiles repository replace `~/.osaurus/skills` and
//  `~/.osaurus/slash-commands` with symbolic links to that repository. The
//  stores must list what is behind the link exactly as if it were a real
//  folder.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SymlinkedUserFoldersTests {

    /// A disposable Osaurus root whose `skills` and `slash-commands` entries
    /// are symlinks into a sibling "dotfiles" folder, mirroring
    /// `ln -sfh "$PWD/skills" ~/.osaurus/skills` from the report.
    private struct Fixture: Sendable {
        let base: URL
        let root: URL
        let dotfiles: URL

        init() throws {
            let fm = FileManager.default
            base = fm.temporaryDirectory.appendingPathComponent(
                "osaurus-symlinked-folders-\(UUID().uuidString)",
                isDirectory: true
            )
            root = base.appendingPathComponent("root", isDirectory: true)
            dotfiles = base.appendingPathComponent("dotfiles", isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try fm.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        }

        /// Creates `dotfiles/<name>/` and links `root/<name>` to it.
        func link(_ name: String) throws -> URL {
            let fm = FileManager.default
            let target = dotfiles.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try fm.createSymbolicLink(
                at: root.appendingPathComponent(name, isDirectory: true),
                withDestinationURL: target
            )
            return target
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: base)
        }
    }

    private func withFixture(_ body: @MainActor @Sendable (Fixture) async throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            let fixture = try Fixture()
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = fixture.root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                fixture.tearDown()
            }
            try await body(fixture)
        }
    }

    @Test func skillStore_listsSkillsBehindSymlinkedSkillsFolder() async throws {
        try await withFixture { fixture in
            let skillsTarget = try fixture.link("skills")
            let skillDir = skillsTarget.appendingPathComponent("dotfiles-skill", isDirectory: true)
            try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
            let skillMarkdown = """
                ---
                name: dotfiles-skill
                description: Loaded through a symlinked skills folder
                ---
                Say hello from the dotfiles repository.
                """
            try skillMarkdown.write(
                to: skillDir.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )

            let skills = await SkillStore.loadAll()

            // Agent Skills names are lowercase-hyphen on disk and title-cased
            // for display, so match on the folder name.
            let loaded = skills.first { $0.directoryName == "dotfiles-skill" }
            #expect(loaded != nil, "skill behind the symlinked folder must be listed")
            #expect(loaded?.isBuiltIn == false)
            #expect(loaded?.name == "Dotfiles Skill")
            #expect(loaded?.description == "Loaded through a symlinked skills folder")

            // The link itself must survive the store's directory provisioning.
            let attrs = try FileManager.default.attributesOfItem(
                atPath: fixture.root.appendingPathComponent("skills").path
            )
            #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        }
    }

    @Test func slashCommandStore_listsCommandsBehindSymlinkedFolder() async throws {
        try await withFixture { fixture in
            let commandsTarget = try fixture.link("slash-commands")
            let id = UUID()
            let commandJSON = """
                {
                  "id": "\(id.uuidString)",
                  "name": "dotfiles-command",
                  "description": "Loaded through a symlinked slash-commands folder",
                  "icon": "terminal",
                  "kind": "template",
                  "template": "Hello from dotfiles",
                  "isBuiltIn": false,
                  "createdAt": "2026-07-12T15:33:00Z",
                  "updatedAt": "2026-07-12T15:33:00Z"
                }
                """
            try commandJSON.write(
                to: commandsTarget.appendingPathComponent("\(id.uuidString).json"),
                atomically: true,
                encoding: .utf8
            )

            let commands = SlashCommandStore.loadAll()

            #expect(commands.map(\.name) == ["dotfiles-command"])
            #expect(commands.first?.id == id)
        }
    }

    @Test func slashCommandStore_saveThroughSymlinkIsListedBack() async throws {
        try await withFixture { fixture in
            let commandsTarget = try fixture.link("slash-commands")
            let command = SlashCommand(
                name: "saved-through-link",
                description: "Created in the app, stored in the dotfiles folder",
                icon: "terminal",
                kind: .template,
                template: "Round trip"
            )

            SlashCommandStore.save(command)

            // The file lands in the link target...
            let written = try FileManager.default.contentsOfDirectory(atPath: commandsTarget.path)
            #expect(written == ["\(command.id.uuidString).json"])
            // ...and the store lists it back.
            #expect(SlashCommandStore.loadAll().map(\.name) == ["saved-through-link"])
        }
    }
}
