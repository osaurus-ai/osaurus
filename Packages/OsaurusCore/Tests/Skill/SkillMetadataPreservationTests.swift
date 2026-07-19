//
//  SkillMetadataPreservationTests.swift
//  OsaurusCoreTests
//
//  Pins the custom-skill lifecycle seams behind "custom skills aren't
//  getting utilized": keywords are the discovery signal
//  `SkillSearchService` indexes, and three separate paths silently
//  destroyed them —
//
//   * single-file imports (JSON and markdown) rebuilt the parsed skill
//     without `keywords`, so an author's discovery vocabulary was gone the
//     moment the skill entered the library;
//   * the editor rebuilt the skill with default (empty) fields, so ANY
//     edit rewrote SKILL.md without its keywords — a permanent, invisible
//     discovery regression;
//   * lookups resolved display names only, so a model copying the
//     slash-command / directory slug (`code-reviewer`) into
//     `capabilities_load` got `not found` for an installed skill.
//
//  All fixes are off-prompt (persistence, lookup, index): nothing here may
//  change the composed system prompt or the tool schema.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SkillMetadataPreservationTests {

    // MARK: - Import paths keep keywords

    @Test @MainActor
    func markdownImportPreservesFrontmatterKeywords() async throws {
        try await Self.withTempSkillStorage {
            let markdown = """
                ---
                name: keyword-probe
                description: "Fixture skill for keyword preservation"
                keywords: "alpha-signal, beta-signal, gamma-signal"
                ---

                Follow the fixture instructions.
                """
            let imported = try await SkillManager.shared.importSkillFromMarkdown(markdown)
            #expect(imported.keywords == ["alpha-signal", "beta-signal", "gamma-signal"])

            // Survives the on-disk round trip (SKILL.md frontmatter → reload).
            await SkillManager.shared.refresh()
            let reloaded = SkillManager.shared.skill(for: imported.id)
            #expect(reloaded?.keywords == ["alpha-signal", "beta-signal", "gamma-signal"])
        }
    }

    @Test @MainActor
    func jsonImportPreservesKeywords() async throws {
        try await Self.withTempSkillStorage {
            let source = Skill(
                name: "JSON Keyword Probe",
                description: "Fixture skill",
                keywords: ["delta-signal", "epsilon-signal"],
                instructions: "Follow the fixture instructions."
            )
            let data = try SkillManager.shared.exportSkill(source)
            let imported = try await SkillManager.shared.importSkill(from: data)
            #expect(imported.keywords == ["delta-signal", "epsilon-signal"])
        }
    }

    @Test @MainActor
    func batchMarkdownImportPreservesKeywords() async throws {
        try await Self.withTempSkillStorage {
            let parsed = Skill(
                name: "Batch Keyword Probe",
                description: "Fixture skill",
                keywords: ["zeta-signal"],
                instructions: "Follow the fixture instructions."
            )
            let imported = await SkillManager.shared.importSkillsFromMarkdown([parsed])
            #expect(imported.first?.keywords == ["zeta-signal"])
        }
    }

    // MARK: - Create / update keep keywords

    @Test @MainActor
    func createWithKeywordsPersistsThemToDisk() async throws {
        try await Self.withTempSkillStorage {
            let created = await SkillManager.shared.create(
                name: "Create Keyword Probe",
                description: "Fixture skill",
                keywords: ["eta-signal", "theta-signal"],
                instructions: "Follow the fixture instructions."
            )
            await SkillManager.shared.refresh()
            let reloaded = SkillManager.shared.skill(for: created.id)
            #expect(reloaded?.keywords == ["eta-signal", "theta-signal"])
        }
    }

    /// The editor-shaped edit: same id, changed instructions, keywords
    /// carried through. Before the fix the rebuilt skill carried empty
    /// keywords and `SkillStore.save` rewrote SKILL.md without them.
    @Test @MainActor
    func updateRoundTripKeepsKeywordsOnDisk() async throws {
        try await Self.withTempSkillStorage {
            let created = await SkillManager.shared.create(
                name: "Update Keyword Probe",
                description: "Fixture skill",
                keywords: ["iota-signal"],
                instructions: "Original instructions."
            )

            var edited = try #require(SkillManager.shared.skill(for: created.id))
            edited.instructions = "Edited instructions."
            await SkillManager.shared.update(edited)

            await SkillManager.shared.refresh()
            let reloaded = SkillManager.shared.skill(for: created.id)
            #expect(reloaded?.instructions == "Edited instructions.")
            #expect(reloaded?.keywords == ["iota-signal"])
        }
    }

    /// The editor's comma-separated keywords field must parse the same way
    /// the frontmatter does: trim whitespace, drop empties.
    @Test
    func editorKeywordFieldParsing() {
        #expect(
            SkillEditorSheet.parseKeywords(" alpha, beta ,,  gamma-delta ")
                == ["alpha", "beta", "gamma-delta"]
        )
        #expect(SkillEditorSheet.parseKeywords("").isEmpty)
        #expect(SkillEditorSheet.parseKeywords(" , ,").isEmpty)
    }

    // MARK: - Slug-aware lookup

    @Test @MainActor
    func slugLookupResolvesDisplayNamedSkill() async throws {
        try await Self.withTempSkillStorage {
            let created = await SkillManager.shared.create(
                name: "Code Reviewer Probe",
                description: "Fixture skill",
                instructions: "Review the code."
            )

            // Slash-command / directory slug form.
            let bySlug = SkillManager.shared.skill(named: "code-reviewer-probe")
            #expect(bySlug?.id == created.id)

            // Display name still resolves (and always wins over slugs).
            let byName = SkillManager.shared.skill(named: "Code Reviewer Probe")
            #expect(byName?.id == created.id)
        }
    }

    @Test @MainActor
    func slugCollisionKeepsUserSkillPrecedence() async throws {
        try await Self.withTempSkillStorage {
            // A user skill saved under a built-in's slug: SKILL.md
            // round-trips lowercase-hyphen names back to Title Case, so
            // after `create` the two skills collide on display name AND
            // slug. Slug-form lookups must follow the same documented
            // precedence as display-name lookups — the deliberately
            // user-authored skill wins over the built-in — so `/slug` and
            // `capabilities_load skill/<slug>` invoke the same skill.
            let builtIn = try #require(Skill.builtInSkills.first)
            let slug = Skill.agentSkillsSlug(for: builtIn.name)
            let literal = await SkillManager.shared.create(
                name: slug,
                description: "Fixture skill",
                instructions: "Literal slug-named variant."
            )

            let bySlug = SkillManager.shared.skill(named: slug)
            #expect(bySlug?.id == literal.id)
            #expect(bySlug?.isBuiltIn == false)

            let byDisplayName = SkillManager.shared.skill(named: builtIn.name)
            #expect(byDisplayName?.id == literal.id)
        }
    }

    /// `capabilities_load skill/<slug>` must deliver the skill the manifest
    /// advertised as `skill/<Display Name>` — the model-facing end of the
    /// slug seam.
    @Test @MainActor
    func capabilitiesLoadResolvesSkillSlug() async throws {
        try await Self.withTempSkillStorage {
            _ = await SkillManager.shared.create(
                name: "Slug Load Probe",
                description: "Fixture skill",
                instructions: "Marker: follow the slug-load fixture."
            )

            let tool = CapabilitiesLoadTool()
            let result = try await tool.execute(
                argumentsJSON: "{\"ids\": [\"skill/slug-load-probe\"]}"
            )
            #expect(result.contains("## Skill: Slug Load Probe"))
            #expect(result.contains("Marker: follow the slug-load fixture."))
        }
    }

    // MARK: - Fixtures

    private static func withTempSkillStorage(
        _ body: @Sendable @MainActor () async throws -> Void
    ) async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-skill-metadata-\(UUID().uuidString)"
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

            OsaurusPaths.overrideRoot = previousRoot
            try? FileManager.default.removeItem(at: root)
            await SkillManager.shared.refresh()
            try result.get()
        }
    }
}
