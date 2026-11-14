//
//  SpawnResultCompaction.swift
//  osaurus
//
//  The model-visible form of a `spawn_agent` result.
//
//  A `spawn_result` envelope carries two audiences' data at once: what the
//  launching model needs to continue (the digest, the `session_id` for
//  `continue`, whether the worker asked a question, which files it wrote)
//  and what telemetry, the Delegations card, and the eval harness need
//  (structured `usage` / `context` accounting, residency phases, cache
//  snapshots, handoff flags). The second set is pinned by
//  `SubagentJobEvaluator` and the Subagent eval lanes and must stay
//  structured in the envelope itself — so the envelope is never rewritten
//  at the source. Instead the two chat loops (`ChatSession.send`,
//  `AgentLoopEvaluator`) hand the model THIS compaction and keep the full
//  envelope for the card and the transcript, the same split `render_chart`
//  already uses (`RenderChartTool.compactModelResult`).
//
//  For a compact launcher (`ContextWindowInfo.prefersCompactPrompt` — small
//  local models such as a 4B Orchestrator) the digest is additionally capped
//  well below the envelope's 8,000 characters: every character of a tool
//  result is re-prefilled on each following iteration of the turn, and the
//  full digest stays readable in the worker's persisted session (Open Chat)
//  and in any file the worker wrote.
//

import Foundation

enum SpawnResultCompaction {
    /// Digest cap for the model-visible result of a compact launcher. The
    /// envelope itself keeps `TextSubagentKind.digestMaxChars` (8,000).
    static let compactDigestMaxChars = 2_000

    /// Upper bound on `artifact_paths` entries handed to the model.
    static let artifactPathsLimit = 20

    static let truncationNotice =
        "\n[digest truncated for context — the full result is in the worker's session; "
        + "`file_read` a listed deliverable or `continue` with a narrower question]"

    /// Whether `envelope` is a successful `spawn_result` this compaction
    /// applies to. Failures, refusals, background acks and non-spawn tools
    /// pass through untouched.
    static func applies(to envelope: String) -> Bool {
        guard ToolEnvelope.isSuccess(envelope),
            let payload = ToolEnvelope.resultPayload(envelope) as? [String: Any]
        else { return false }
        return payload["kind"] as? String == "spawn_result"
    }

    /// The result the launching model reads. Returns `envelope` unchanged
    /// when it is not a successful `spawn_result`.
    static func modelVisible(_ envelope: String, prefersCompactPrompt: Bool) -> String {
        guard ToolEnvelope.isSuccess(envelope),
            let root = decode(envelope),
            let payload = root["result"] as? [String: Any],
            payload["kind"] as? String == "spawn_result"
        else { return envelope }

        var compact: [String: Any] = ["kind": "spawn_result"]
        // Identity: what ran, and where.
        for key in ["agent", "workspace_agent", "workspace", "model"] {
            if let value = payload[key] { compact[key] = value }
        }
        if payload["remote"] as? Bool == true { compact["remote"] = true }

        // The digest, capped for a compact launcher.
        if let summary = payload["summary"] as? String {
            compact["summary"] = cappedDigest(summary, prefersCompactPrompt: prefersCompactPrompt)
        }

        // Continuation handles.
        if let sessionId = payload["session_id"] { compact["session_id"] = sessionId }
        if let needsInput = payload["needs_input"] as? Bool, needsInput {
            compact["needs_input"] = true
        } else if payload["needs_input_marker_off_prefix"] as? Bool == true {
            compact["needs_input_hint"] =
                "the worker wrote NEEDS INPUT mid-text (not as a prefix, so needs_input is "
                + "false); if it is a real question, answer it via `continue`"
        }

        // Deliverables.
        if let paths = payload["artifact_paths"] as? [String], !paths.isEmpty {
            compact["artifact_paths"] = paths
        }
        if let shared = payload["artifacts_shared"] as? Int, shared > 0 {
            compact["artifacts_shared"] = shared
        }

        // One accounting line instead of `usage` + `context` + `residency` +
        // `handoff` + `elapsed_seconds` + `iterations` objects.
        if let line = accountingLine(payload) { compact["accounting"] = line }

        var out: [String: Any] = ["ok": true, "result": compact]
        if let tool = root["tool"] { out["tool"] = tool }
        if let warnings = root["warnings"] { out["warnings"] = warnings }
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return envelope }
        return text
    }

    /// `summary`, capped to `compactDigestMaxChars` for a compact launcher.
    static func cappedDigest(_ summary: String, prefersCompactPrompt: Bool) -> String {
        guard prefersCompactPrompt, summary.count > compactDigestMaxChars else { return summary }
        // Cut at the last line break inside the cap when one is reasonably
        // close, so the model does not read a sentence sliced mid-word.
        let hardCut = summary.index(summary.startIndex, offsetBy: compactDigestMaxChars)
        let head = summary[..<hardCut]
        let softCut: Substring
        if let newline = head.lastIndex(of: "\n"),
            head.distance(from: newline, to: hardCut) < compactDigestMaxChars / 4
        {
            softCut = head[..<newline]
        } else {
            softCut = head
        }
        return String(softCut).trimmingCharacters(in: .whitespacesAndNewlines) + truncationNotice
    }

    /// "1 turn · 12.5s · 812 completion tok · 41.2 tok/s · saved ~5.7k tok of context".
    /// Nil when the payload carries none of these.
    static func accountingLine(_ payload: [String: Any]) -> String? {
        var parts: [String] = []
        if let iterations = intValue(payload["iterations"]) {
            parts.append("\(iterations) turn\(iterations == 1 ? "" : "s")")
        }
        if let elapsed = doubleValue(payload["elapsed_seconds"]) {
            parts.append(String(format: "%.1fs", elapsed))
        }
        let usage = payload["usage"] as? [String: Any]
        if let completion = intValue(usage?["completion_tokens"]) {
            parts.append("\(completion) completion tok")
        }
        if let tps = doubleValue(usage?["tokens_per_second"]) {
            parts.append(String(format: "%.1f tok/s", tps))
        }
        let context = payload["context"] as? [String: Any]
        if let saved = intValue(context?["context_saved_tokens"]), saved > 0 {
            parts.append("saved ~\(compactCount(saved)) tok of context")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Host paths a worker session wrote (created or modified, not deleted),
    /// for the payload's `artifact_paths`. Host-folder roots resolve to the
    /// absolute path the Orchestrator can `file_read`; sandbox roots keep
    /// their in-VM display path so the model can still name the file.
    static func artifactPaths(from changes: [FileNetChange]) -> [String] {
        var paths: [String] = []
        for change in changes where change.kind != .deleted && change.entryType != .directory {
            let path: String
            switch change.key.rootKind {
            case .hostFolder: path = change.key.hostURL.path
            case .agentHome, .shared: path = change.key.displayPath
            }
            if !paths.contains(path) { paths.append(path) }
        }
        if paths.count > artifactPathsLimit {
            let extra = paths.count - artifactPathsLimit
            paths = Array(paths.prefix(artifactPathsLimit)) + ["… +\(extra) more"]
        }
        return paths
    }

    /// Files the delegated worker session wrote, from the file-change journal.
    static func artifactPaths(forWorkerSession sessionId: UUID) async -> [String] {
        let changes = await FileChangeJournal.shared.netChanges(for: sessionId.uuidString)
        return artifactPaths(from: changes)
    }

    // MARK: - Helpers

    private static func decode(_ envelope: String) -> [String: Any]? {
        guard let data = envelope.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let int = any as? Int { return int }
        if let number = any as? NSNumber { return number.intValue }
        if let double = any as? Double { return Int(double) }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let double = any as? Double { return double }
        if let number = any as? NSNumber { return number.doubleValue }
        if let int = any as? Int { return Double(int) }
        return nil
    }

    private static func compactCount(_ value: Int) -> String {
        value >= 1_000 ? String(format: "%.1fk", Double(value) / 1_000) : "\(value)"
    }
}
