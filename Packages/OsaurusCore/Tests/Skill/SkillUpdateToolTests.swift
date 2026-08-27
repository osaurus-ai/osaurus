//
//  SkillUpdateToolTests.swift
//  OsaurusCoreTests
//
//  `update_skill` contract:
//
//   * an approved edit lands in the skill's stored instructions and the
//     result echoes the updated text, so the agent can verify what it saved
//     instead of assuming (stale in-conversation copies are called out).
//   * built-in and plugin skills fail EXPLICITLY rather than tripping
//     `SkillManager.update`'s silent guard — success over a write that never
//     happened is the fabricated "Done" the tool exists to eliminate.
//   * edit failures (no match) are retryable without re-approval, and a
//     no-op edit reports "nothing saved" rather than success theater.
//   * surface gating: denied externally, excluded from spawned children.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SkillUpdateToolTests {

    private static func execute(_ arguments: [String: Any]) async throws -> String {
        let data = try JSONSerialization.data(withJSONObject: arguments)
        return try await SkillUpdateTool().execute(
            argumentsJSON: String(data: data, encoding: .utf8) ?? "{}"
        )
    }

    @Test @MainActor
    func editLandsInStoredInstructionsAndEchoesResult() async throws {
        try await Self.withTempSkillStorage {
            let skill = await SkillManager.shared.create(
                name: "Plain English",
                instructions: "Explain concepts in plain English. Use Canadian English."
            )

            let result = try await Self.execute([
                "skill": "plain english",
                "edits": [["find": "Canadian English", "replace": "American English"]],
                "rationale": "user prefers American spelling",
            ])

            #expect(result.contains("\"ok\":true") || result.contains("\"ok\": true"))
            #expect(result.contains("American English"))
            let stored = SkillManager.shared.skill(for: skill.id)
            #expect(stored?.instructions == "Explain concepts in plain English. Use American English.")
        }
    }

    @Test @MainActor
    func builtInSkillIsRejectedExplicitly() async throws {
        try await Self.withTempSkillStorage {
            let builtIn = try #require(Skill.builtInSkills.first)
            let result = try await Self.execute([
                "skill": builtIn.id.uuidString,
                "edits": [["find": "a", "replace": "b"]],
            ])
            #expect(ToolEnvelope.failureMessage(result).contains("built-in"))
        }
    }

    @Test @MainActor
    func pluginSkillIsRejectedExplicitly() async throws {
        try await Self.withTempSkillStorage {
            var pluginSkill = Skill(name: "Plugin Provided", instructions: "Original.")
            pluginSkill.pluginId = "com.example.plugin"
            await SkillManager.shared.registerPluginSkill(pluginSkill)

            let result = try await Self.execute([
                "skill": "Plugin Provided",
                "edits": [["find": "Original", "replace": "Changed"]],
            ])
            #expect(ToolEnvelope.failureMessage(result).contains("plugin"))
            #expect(SkillManager.shared.skill(for: pluginSkill.id)?.instructions == "Original.")
        }
    }

    @Test @MainActor
    func unknownSkillIsNotFound() async throws {
        try await Self.withTempSkillStorage {
            let result = try await Self.execute([
                "skill": "No Such Skill",
                "edits": [["find": "a", "replace": "b"]],
            ])
            #expect(result.contains("not_found"))
        }
    }

    @Test @MainActor
    func unmatchedFindIsRetryableAndWritesNothing() async throws {
        try await Self.withTempSkillStorage {
            let skill = await SkillManager.shared.create(
                name: "Stable", instructions: "Keep this text.")

            let result = try await Self.execute([
                "skill": "Stable",
                "edits": [["find": "text that is not there", "replace": "x"]],
            ])
            #expect(result.contains("\"retryable\":true") || result.contains("\"retryable\": true"))
            #expect(SkillManager.shared.skill(for: skill.id)?.instructions == "Keep this text.")
        }
    }

    @Test @MainActor
    func noOpEditReportsNothingSaved() async throws {
        try await Self.withTempSkillStorage {
            _ = await SkillManager.shared.create(name: "Idempotent", instructions: "Same. Same.")
            let result = try await Self.execute([
                "skill": "Idempotent",
                "edits": [["find": "Same", "replace": "Same", "all": true]],
            ])
            #expect(result.contains("Nothing was saved"))
        }
    }

    // MARK: - Surface gating

    @Test
    func deniedExternallyAndExcludedFromChildren() {
        #expect(ToolRegistry.externallyDeniedToolNames.contains("update_skill"))
        #expect(TextSubagentKind.isExcludedChildTool("update_skill"))
    }

    // MARK: - Harness

    private static func withTempSkillStorage(
        _ body: @Sendable @MainActor () async throws -> Void
    ) async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-skill-update-tool-\(UUID().uuidString)"
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
