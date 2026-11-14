//
//  SpawnResultCompactionTests.swift
//  osaurusTests
//
//  Pins the split between the `spawn_result` envelope (structured telemetry
//  for the card, `SubagentJobEvaluator`, and the Subagent eval lanes) and
//  the compact form the launching model reads.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct SpawnResultCompactionTests {

    private static func envelope(
        summary: String = "Wrote the report.",
        extra: [String: Any] = [:]
    ) -> String {
        var payload: [String: Any] = [
            "kind": "spawn_result",
            "model": "local/worker-4b",
            "agent": "Writer",
            "agent_id": UUID().uuidString,
            "summary": summary,
            "session_id": "7C1E7A6E-0000-4000-8000-000000000001",
            "needs_input": false,
            "delegated": true,
            "iterations": 3,
            "elapsed_seconds": 12.53,
            "handoff": false,
            "residency_mode": "sequencing_off",
            "usage": ["completion_tokens": 812, "tokens_per_second": 41.24],
            "context": [
                "worker_tokens_estimated": 6_100, "digest_tokens": 400, "context_saved_tokens": 5_700,
            ],
            "residency": [
                "phases": ["running": 12.1], "phase_order": ["running"],
                "post_run_cache": ["prefix_hits": 3, "prefix_misses": 1],
            ],
        ]
        for (key, value) in extra { payload[key] = value }
        return ToolEnvelope.success(tool: "spawn_agent", result: payload)
    }

    private static func result(_ envelope: String) -> [String: Any] {
        (ToolEnvelope.resultPayload(envelope) as? [String: Any]) ?? [:]
    }

    @Test("telemetry objects collapse to one accounting line; handles and digest survive")
    func compactKeepsWhatTheModelNeeds() throws {
        let raw = Self.envelope(extra: ["artifact_paths": ["/Users/me/Reports/q3.md"]])
        let visible = SpawnResultCompaction.modelVisible(raw, prefersCompactPrompt: false)

        #expect(ToolEnvelope.isSuccess(visible))
        let payload = Self.result(visible)
        #expect(payload["kind"] as? String == "spawn_result")
        #expect(payload["agent"] as? String == "Writer")
        #expect(payload["summary"] as? String == "Wrote the report.")
        #expect(payload["session_id"] as? String == "7C1E7A6E-0000-4000-8000-000000000001")
        #expect(payload["artifact_paths"] as? [String] == ["/Users/me/Reports/q3.md"])

        // Telemetry-only structure is gone from the model's copy …
        for dropped in [
            "usage", "context", "residency", "handoff", "residency_mode", "agent_id", "delegated",
            "elapsed_seconds", "iterations",
        ] {
            #expect(payload[dropped] == nil, "\(dropped) should not reach the model")
        }
        // … replaced by one line that still carries turns, time, tokens, tok/s, savings.
        let accounting = try #require(payload["accounting"] as? String)
        #expect(accounting == "3 turns · 12.5s · 812 completion tok · 41.2 tok/s · saved ~5.7k tok of context")

        // `needs_input: false` is noise; only a true flag is forwarded.
        #expect(payload["needs_input"] == nil)

        // The raw envelope is untouched — the card / evaluator contract.
        let rawPayload = Self.result(raw)
        #expect((rawPayload["usage"] as? [String: Any])?["completion_tokens"] as? Int == 812)
        #expect((rawPayload["context"] as? [String: Any])?["context_saved_tokens"] as? Int == 5_700)
    }

    @Test("needs_input true is forwarded so the model answers via continue")
    func needsInputSurvives() {
        let raw = Self.envelope(summary: "NEEDS INPUT: which quarter?", extra: ["needs_input": true])
        let payload = Self.result(SpawnResultCompaction.modelVisible(raw, prefersCompactPrompt: true))
        #expect(payload["needs_input"] as? Bool == true)
        #expect(payload["summary"] as? String == "NEEDS INPUT: which quarter?")
    }

    @Test("a compact launcher gets a capped digest; a full launcher keeps the 8k envelope cap")
    func digestScalesWithTheLauncher() throws {
        let long = (0..<400).map { "line \($0): " + String(repeating: "x", count: 12) }
            .joined(separator: "\n")
        #expect(long.count > SpawnResultCompaction.compactDigestMaxChars)
        let raw = Self.envelope(summary: long)

        let full = Self.result(SpawnResultCompaction.modelVisible(raw, prefersCompactPrompt: false))
        #expect(full["summary"] as? String == long)

        let compact = Self.result(SpawnResultCompaction.modelVisible(raw, prefersCompactPrompt: true))
        let digest = try #require(compact["summary"] as? String)
        #expect(digest.hasSuffix(SpawnResultCompaction.truncationNotice))
        #expect(
            digest.count <= SpawnResultCompaction.compactDigestMaxChars
                + SpawnResultCompaction.truncationNotice.count)
        // Cut on a line boundary, not mid-line.
        let body = digest.dropLast(SpawnResultCompaction.truncationNotice.count)
        #expect(body.hasSuffix("xxxxxxxxxxxx"))
    }

    @Test("failures, acks and other tools pass through untouched")
    func nonResultsPassThrough() {
        let failure = ToolEnvelope.failure(
            kind: .unavailable, message: "Agent is offline.", tool: "spawn_agent", retryable: true)
        #expect(!SpawnResultCompaction.applies(to: failure))
        #expect(SpawnResultCompaction.modelVisible(failure, prefersCompactPrompt: true) == failure)

        let ack = ToolEnvelope.success(
            tool: "spawn_agent",
            result: ["dispatched": true, "background": true, "helper": "Writer"])
        #expect(!SpawnResultCompaction.applies(to: ack))
        #expect(SpawnResultCompaction.modelVisible(ack, prefersCompactPrompt: true) == ack)

        let other = ToolEnvelope.success(tool: "file_read", result: ["kind": "file", "text": "hi"])
        #expect(SpawnResultCompaction.modelVisible(other, prefersCompactPrompt: true) == other)
    }

    @Test("artifact_paths lists created/modified files; deleted and directories are skipped; capped")
    func artifactPathsFromNetChanges() {
        func change(
            _ path: String, kind root: SandboxWorkspaceRootKind = .hostFolder,
            rootId: String = "/Users/me/Reports", before: FilePathState? = nil,
            after: FilePathState? = FilePathState(type: .file, signature: "b")
        ) -> FileNetChange {
            FileNetChange(
                key: FilePathKey(rootKind: root, rootId: rootId, path: path),
                original: before, latest: after, setIds: [], lastChangedAt: Date(), lastTool: "file_write")
        }
        let changes = [
            change("q3.md"),
            change("notes/old.txt", before: FilePathState(type: .file, signature: "a"), after: nil),  // deleted
            change("notes", after: FilePathState(type: .directory, signature: "d")),
            change("draft.md", before: FilePathState(type: .file, signature: "a")),  // modified
            change("out/report.md", kind: .agentHome, rootId: "writer"),
        ]
        let paths = SpawnResultCompaction.artifactPaths(from: changes)
        #expect(paths.count == 3)
        #expect(paths.contains("/Users/me/Reports/q3.md"))
        #expect(paths.contains("/Users/me/Reports/draft.md"))
        #expect(paths.contains { $0.hasSuffix("/out/report.md") && !$0.hasPrefix("/Users/me/Reports") })

        let many = (0..<30).map { change("f\($0).md") }
        let capped = SpawnResultCompaction.artifactPaths(from: many)
        #expect(capped.count == SpawnResultCompaction.artifactPathsLimit + 1)
        #expect(capped.last == "… +10 more")
    }
}
