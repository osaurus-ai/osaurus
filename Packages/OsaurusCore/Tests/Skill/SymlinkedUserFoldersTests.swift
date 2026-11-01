//
//  SymlinkedUserFoldersTests.swift
//  osaurusTests
//
//  Regression coverage for #1996: users who keep their Osaurus customisations
//  in a dotfiles repository replace folders under `~/.osaurus` (`skills`,
//  `slash-commands`, `agents`, `themes`, ...) with symbolic links to that
//  repository. Every store must list what is behind the link exactly as if it
//  were a real folder.
//
//  Two fixtures:
//  - `Fixture` is a root whose folders are symlinks into a sibling "dotfiles"
//    folder from the start, mirroring `ln -sfh "$PWD/skills" ~/.osaurus/skills`.
//  - `relocated(...)` first lets a store save into a plain root, then points a
//    second root at that folder through a symlink. This exercises the store's
//    own file format (no hand-written JSON) and defeats in-memory caches,
//    because the listing has to come from disk through the link.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SymlinkedUserFoldersTests {

    /// A disposable Osaurus root whose folders are symlinks into a sibling
    /// "dotfiles" folder.
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

    /// Runs `save` against a plain root, then re-points the active root at a
    /// fresh one whose `folder` entry is a symlink to the folder the store
    /// just wrote into, and returns what `list` sees through the link.
    private func relocated<T: Sendable>(
        folder: String,
        save: @MainActor @Sendable () throws -> Void,
        list: @MainActor @Sendable () throws -> T
    ) async throws -> T {
        try await StoragePathsTestLock.shared.run {
            let fm = FileManager.default
            let base = fm.temporaryDirectory.appendingPathComponent(
                "osaurus-relocated-\(UUID().uuidString)",
                isDirectory: true
            )
            let plainRoot = base.appendingPathComponent("plain", isDirectory: true)
            let linkedRoot = base.appendingPathComponent("linked", isDirectory: true)
            try fm.createDirectory(at: plainRoot, withIntermediateDirectories: true)
            try fm.createDirectory(at: linkedRoot, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? fm.removeItem(at: base)
            }

            OsaurusPaths.overrideRoot = plainRoot
            try await save()
            let written = plainRoot.appendingPathComponent(folder, isDirectory: true)
            #expect(
                !((try? fm.contentsOfDirectory(atPath: written.path)) ?? []).isEmpty,
                "the store must have written into \(folder)/ under the plain root"
            )

            try fm.createSymbolicLink(
                at: linkedRoot.appendingPathComponent(folder, isDirectory: true),
                withDestinationURL: written
            )
            OsaurusPaths.overrideRoot = linkedRoot
            return try await list()
        }
    }

    // MARK: - Folders named in #1996

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

    // MARK: - Sibling stores with the same listing code

    @Test func agentStore_listsAgentsBehindSymlinkedFolder() async throws {
        let id = UUID()
        let names = try await relocated(
            folder: "agents",
            save: {
                AgentStore.save(Agent(id: id, name: "Dotfiles Agent", systemPrompt: "From the repo"))
                // `save` writes on a background queue; `exists` flushes it so
                // the file is on disk before the folder is re-pointed.
                _ = AgentStore.exists(id: id)
            },
            list: { AgentStore.loadAll().filter { $0.id == id }.map(\.name) }
        )
        #expect(names == ["Dotfiles Agent"])
    }

    @Test func remoteAgentStore_listsRemoteAgentsBehindSymlinkedFolder() async throws {
        let id = UUID()
        let names = try await relocated(
            folder: "remote-agents",
            save: {
                RemoteAgentStore.save(
                    RemoteAgent(
                        id: id,
                        agentAddress: "dotfiles-remote.example",
                        name: "Dotfiles Remote",
                        description: "Paired remote agent kept in the repo",
                        relayBaseURL: "https://relay.example",
                        providerId: UUID()
                    )
                )
            },
            list: { RemoteAgentStore.loadAll().filter { $0.id == id }.map(\.name) }
        )
        #expect(names == ["Dotfiles Remote"])
    }

    @Test func themeStore_listsThemesBehindSymlinkedFolder() async throws {
        let id = UUID()
        let names = try await relocated(
            folder: "themes",
            save: {
                ThemeConfigurationStore.saveTheme(CustomTheme(metadata: ThemeMetadata(id: id, name: "Dotfiles Theme")))
            },
            list: { ThemeConfigurationStore.listThemesFromDisk().filter { $0.metadata.id == id }.map(\.metadata.name) }
        )
        #expect(names == ["Dotfiles Theme"])
    }

    @Test func scheduleStore_listsSchedulesBehindSymlinkedFolder() async throws {
        let id = UUID()
        let names = try await relocated(
            folder: "schedules",
            save: {
                ScheduleStore.save(
                    Schedule(
                        id: id,
                        name: "Dotfiles Schedule",
                        instructions: "Run from the repo",
                        frequency: .daily(hour: 9, minute: 0)
                    )
                )
            },
            list: { ScheduleStore.loadAll().filter { $0.id == id }.map(\.name) }
        )
        #expect(names == ["Dotfiles Schedule"])
    }

    @Test func watcherStore_listsWatchersBehindSymlinkedFolder() async throws {
        let id = UUID()
        let names = try await relocated(
            folder: "watchers",
            save: { WatcherStore.save(Watcher(id: id, name: "Dotfiles Watcher", instructions: "Watch from the repo")) },
            list: { WatcherStore.loadAll().filter { $0.id == id }.map(\.name) }
        )
        #expect(names == ["Dotfiles Watcher"])
    }
}
