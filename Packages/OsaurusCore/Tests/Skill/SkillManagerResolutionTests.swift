//
//  SkillManagerResolutionTests.swift
//  OsaurusCoreTests
//
//  Universal-library harness guarantees around SkillManager:
//
//   * name-collision resolution — `skill(named:)` is deterministic and
//     prefers a deliberately user-authored skill over a built-in or a
//     plugin skill sharing the name (the raw `skills` array puts built-ins
//     first, so a naive `first(where:)` inverted that precedence).
//   * reference budgeting — `buildFullInstructions(for:referenceBudget:)`
//     includes reference materials up to the budget and collapses the
//     rest into a named omission note, so the `capabilities_load` path
//     can carry references without unbounded tool-result growth.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SkillManagerResolutionTests {

    // MARK: - Name-collision resolution

    /// Same-named *saved* skills share a slug directory (the second save
    /// overwrites the first), so the coexisting collision in practice is a
    /// user skill shadowing a built-in — built-ins live in memory, not on
    /// disk. The raw `skills` array sorts built-ins first, so a naive
    /// `first(where:)` resolved the tie to the built-in; the user's
    /// deliberately authored skill must win instead.
    @Test @MainActor
    func namedLookupPrefersUserSkillOverBuiltIn() async throws {
        try await Self.withTempSkillStorage {
            let builtIn = try #require(Skill.builtInSkills.first)
            let name = builtIn.name

            let userSkill = await SkillManager.shared.create(
                name: name,
                description: "user variant",
                instructions: "From the user."
            )

            // Both are installed and enumerable…
            #expect(SkillManager.shared.skills(named: name).count == 2)
            // …but the tie breaks toward the user-authored skill.
            let resolved = SkillManager.shared.skill(named: name)
            #expect(resolved?.id == userSkill.id)
            #expect(resolved?.isBuiltIn == false)

            // Case-insensitive lookups resolve the same way.
            let lowercased = SkillManager.shared.skill(named: name.lowercased())
            #expect(lowercased?.id == userSkill.id)
        }
    }

    // MARK: - Reference budgeting

    @Test @MainActor
    func fullInstructionsIncludeReferencesWithinBudget() async throws {
        try await Self.withTempSkillStorage {
            let skill = await Self.makeSkillWithReferences(
                small: "alpha reference body",
                large: String(repeating: "x", count: 2_000)
            )

            // Unlimited budget (slash path): both files ride along.
            let full = await SkillManager.shared.buildFullInstructions(for: skill)
            #expect(full.contains("## Reference Materials"))
            #expect(full.contains("alpha reference body"))
            #expect(full.contains(String(repeating: "x", count: 2_000)))
            #expect(!full.contains("Omitted references"))
        }
    }

    @Test @MainActor
    func fullInstructionsCollapseOverBudgetReferencesToNamedNote() async throws {
        try await Self.withTempSkillStorage {
            let skill = await Self.makeSkillWithReferences(
                small: "alpha reference body",
                large: String(repeating: "x", count: 2_000)
            )

            // Budget fits the small file but not the large one: the small
            // file must still load, and the large one must be *named* in
            // the omission note rather than silently dropped.
            let budgeted = await SkillManager.shared.buildFullInstructions(
                for: skill,
                referenceBudget: 100
            )
            #expect(budgeted.contains("alpha reference body"))
            #expect(!budgeted.contains(String(repeating: "x", count: 200)))
            #expect(budgeted.contains("Omitted references"))
            #expect(budgeted.contains("big.md"))
        }
    }

    // MARK: - Fixtures

    /// Creates a user skill with two references: `alpha.md` (tiny, sorts
    /// first) and `big.md` (2k chars). Returns the reloaded skill so the
    /// reference file list is populated.
    @MainActor
    private static func makeSkillWithReferences(small: String, large: String) async -> Skill {
        let created = await SkillManager.shared.create(
            name: "Reference Budget \(UUID().uuidString.prefix(6))",
            description: "budget fixture",
            instructions: "Use the reference materials."
        )
        try? await SkillStore.addReference(
            to: created, name: "alpha.md", content: Data(small.utf8)
        )
        try? await SkillStore.addReference(
            to: created, name: "big.md", content: Data(large.utf8)
        )
        await SkillManager.shared.refresh()
        return SkillManager.shared.skill(for: created.id) ?? created
    }

    private static func withTempSkillStorage(
        _ body: @Sendable @MainActor () async throws -> Void
    ) async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-skill-resolution-\(UUID().uuidString)"
            )
            let previousRoot = OsaurusPaths.overrideRoot
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            await SkillManager.shared.refresh()

            let result: Result<Void, Error>
            do {
                try await body()
                result = .success(())
            } catch {
                result = .failure(error)
            }

            // Restore the live library before releasing the lock, even when
            // the body throws — the singleton must not keep temp skills.
            OsaurusPaths.overrideRoot = previousRoot
            try? FileManager.default.removeItem(at: root)
            await SkillManager.shared.refresh()
            try result.get()
        }
    }
}
