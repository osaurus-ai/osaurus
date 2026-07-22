//
//  SlashCommandSkillSurfacingTests.swift
//  OsaurusCoreTests
//
//  Universal-library regression: every installed skill must surface as an
//  explicit one-off `/skill-name` shortcut, with no enable gate in between.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SlashCommandSkillSurfacingTests {

    /// All installed skills (built-ins included) register as slash
    /// commands. Before the universal library, disabled skills were
    /// filtered out here — that gate is gone, so the count and the
    /// specific slugs must match the full installed library.
    @Test @MainActor
    func everyInstalledSkillIsRegisteredAsSlashCommand() async {
        await SandboxTestLock.runWithStoragePaths {
            await SkillManager.shared.refresh()
            let skills = SkillManager.shared.skills
            guard !skills.isEmpty else {
                Issue.record("expected built-in skills to be installed")
                return
            }

            // Empty query returns the full command list.
            let commands = SlashCommandRegistry.shared.filtered(query: "")
            let skillCommandIds = Set(
                commands.filter { $0.kind == .skill }.map(\.id)
            )

            for skill in skills {
                #expect(
                    skillCommandIds.contains(skill.id),
                    "installed skill \(skill.name) missing from slash commands"
                )
            }
        }
    }
}
