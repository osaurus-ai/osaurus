//
//  RedactionToolsTests.swift
//  osaurusTests
//
//  Coverage for `detect_pii` / `redact_file` on the regex-only path
//  (no PII model bundle in the test environment — which also exercises
//  the degradation contract: results still flow, with a warning).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct RedactionToolsTests {

    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-redaction-tools-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func envelopeWarnings(_ output: String) -> [String] {
        guard let data = output.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return dict["warnings"] as? [String] ?? []
    }

    // MARK: - detect_pii

    @Test func detectPII_inlineText_findsEmailAndPhone() async throws {
        let output = try await DetectPIITool().execute(
            argumentsJSON:
                #"{"text":"Contact Bob at bob@example.com or (555) 010-4477."}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        let categories = try #require(payload["categories"] as? [String: Any])
        #expect(categories["email"] != nil)
        #expect(categories["phone"] != nil)
    }

    @Test func detectPII_file_reportsLineNumbers() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "line one\nreach me: a@b.co\n".write(
            to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let output = try await DetectPIITool(rootPath: root).execute(
            argumentsJSON: #"{"path":"note.txt"}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        let categories = try #require(payload["categories"] as? [String: Any])
        let email = try #require(categories["email"] as? [String: Any])
        let samples = try #require(email["samples"] as? [[String: Any]])
        #expect(samples.first?["line"] as? Int == 2)
        #expect(samples.first?["text"] as? String == "a@b.co")
    }

    @Test func detectPII_customRule_matchesDomainPattern() async throws {
        let output = try await DetectPIITool().execute(
            argumentsJSON: """
                {"text":"Q3 revenue was $4.2M, churn 3%.",
                 "custom_rules":[{"name":"money","pattern":"\\\\$[0-9.,]+[MK]?","placeholder":"NUMBERS"}]}
                """
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect((payload["total_detections"] as? Int ?? 0) >= 1)
    }

    @Test func detectPII_invalidCustomRule_rejectedPerRuleNotWholeCall() async throws {
        let output = try await DetectPIITool().execute(
            argumentsJSON: """
                {"text":"mail me: a@b.co",
                 "custom_rules":[{"name":"bad","pattern":"("}]}
                """
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        let rejected = try #require(payload["rejected_rules"] as? [[String: Any]])
        #expect(rejected.first?["name"] as? String == "bad")
        // The valid built-in detection still ran.
        let categories = try #require(payload["categories"] as? [String: Any])
        #expect(categories["email"] != nil)
    }

    @Test func detectPII_withoutModel_carriesDegradationWarning() async throws {
        // Test environment has no Rampart/OpenAI bundle installed.
        guard !RampartModelManager.bundleExists(), !PrivacyFilterEngine.shared.isLoaded else {
            return
        }
        let output = try await DetectPIITool().execute(
            argumentsJSON: #"{"text":"hello"}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["backend"] as? String == "regex-only")
        #expect(envelopeWarnings(output).contains { $0.contains("PII model") })
    }

    // MARK: - redact_file

    @Test func redactFile_replacesWithDefaultPlaceholders() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("note.txt")
        try "email a@b.co and a@b.co again\n".write(to: url, atomically: true, encoding: .utf8)

        let output = try await RedactFileTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"note.txt"}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["written"] as? Bool == true)
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(!content.contains("a@b.co"))
        #expect(content.contains("[REDACTED EMAIL]"))
        #expect((payload["replacements"] as? Int ?? 0) == 2)
    }

    @Test func redactFile_placeholderOverride_applies() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("note.txt")
        try "email a@b.co\n".write(to: url, atomically: true, encoding: .utf8)

        _ = try await RedactFileTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"note.txt","placeholders":{"email":"[GONE]"}}"#
        )
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("[GONE]"))
    }

    @Test func redactFile_customRulePlaceholder_usesRuleLabel() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("note.txt")
        try "revenue $4.2M\n".write(to: url, atomically: true, encoding: .utf8)

        let output = try await RedactFileTool(rootPath: root).execute(
            argumentsJSON: """
                {"path":"note.txt",
                 "custom_rules":[{"name":"money","pattern":"\\\\$[0-9.,]+[MK]?","placeholder":"NUMBERS"}]}
                """
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["written"] as? Bool == true)
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("[REDACTED NUMBERS]"))
    }

    @Test func redactFile_bracketedCustomPlaceholder_usedVerbatim() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("note.txt")
        try "revenue $4.2M\n".write(to: url, atomically: true, encoding: .utf8)

        // Agents pass the full bracketed placeholder from the user's
        // request; it must land verbatim, not double-wrapped as
        // "[REDACTED REDACTEDNUMBERS]".
        _ = try await RedactFileTool(rootPath: root).execute(
            argumentsJSON: """
                {"path":"note.txt",
                 "custom_rules":[{"name":"money","pattern":"\\\\$[0-9.,]+[MK]?","placeholder":"[REDACTED NUMBERS]"}]}
                """
        )
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("revenue [REDACTED NUMBERS]"))
        #expect(!content.contains("REDACTEDNUMBERS"))
    }

    @Test func redactFile_dryRun_countsWithoutWriting() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = "email a@b.co\n"
        let url = root.appendingPathComponent("note.txt")
        try original.write(to: url, atomically: true, encoding: .utf8)

        let output = try await RedactFileTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"note.txt","dry_run":true}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["written"] as? Bool == false)
        #expect((payload["replacements"] as? Int ?? 0) >= 1)
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
    }

    @Test func redactFile_noDetections_writesNothing() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = "nothing sensitive here\n"
        let url = root.appendingPathComponent("note.txt")
        try original.write(to: url, atomically: true, encoding: .utf8)

        let output = try await RedactFileTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"note.txt"}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["written"] as? Bool == false)
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
    }

    @Test func redactFile_explicitEmptyCategories_writesNothing() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = "email a@b.co\n"
        let url = root.appendingPathComponent("note.txt")
        try original.write(to: url, atomically: true, encoding: .utf8)

        // `categories: []` is a model's opt-out; it must be a no-op, not
        // an implicit "all categories".
        let output = try await RedactFileTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"note.txt","categories":[]}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["written"] as? Bool == false)
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
    }

    @Test func redactFile_unknownCategory_warnsAndSkips() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = "email a@b.co\n"
        let url = root.appendingPathComponent("note.txt")
        try original.write(to: url, atomically: true, encoding: .utf8)

        // Unknown entries warn and are skipped; with no valid entries left
        // the call is a safe no-op rather than a hard failure.
        let output = try await RedactFileTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"note.txt","categories":["nope"]}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["written"] as? Bool == false)
        #expect(envelopeWarnings(output).contains { $0.contains("nope") })
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
    }

    // MARK: - persisted config guard

    @Test func toolCalls_neverTouchPersistedCustomRules() async throws {
        let before = PrivacyFilterStore.snapshot().customRules
        _ = try await DetectPIITool().execute(
            argumentsJSON: """
                {"text":"a@b.co","custom_rules":[{"name":"r","pattern":"x+"}]}
                """
        )
        let after = PrivacyFilterStore.snapshot().customRules
        #expect(before == after)
    }
}
