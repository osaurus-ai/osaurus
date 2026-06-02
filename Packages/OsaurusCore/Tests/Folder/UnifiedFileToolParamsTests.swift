//
//  UnifiedFileToolParamsTests.swift
//  osaurusTests
//
//  Host-side coverage for the unified file-tool capabilities restored in
//  combined mode but implemented on the shared host tools (a net win in
//  plain folder mode too):
//    - `file_read` `tail_lines` (log-style read) + `max_chars` cap
//    - `file_search` `target: "files"` (filename-glob find)
//  Plus the combined-mode secret-refusal gate: a relative (host-route)
//  secret read still refuses even when a sandbox bridge is bound, so the
//  bridge can't be used to bypass the denylist.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct UnifiedFileToolParamsTests {

    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-unified-file-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The `path` field of every candidate in a `kind:"search"` envelope.
    private func searchPaths(_ output: String) -> [String] {
        let payload = ToolEnvelope.successPayload(output) as? [String: Any]
        let entries = payload?["entries"] as? [[String: Any]] ?? []
        return entries.compactMap { $0["path"] as? String }
    }

    /// Top-level `warnings` array of an envelope (steer / broaden notes live here).
    private func envelopeWarnings(_ output: String) -> [String] {
        guard let data = output.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return dict["warnings"] as? [String] ?? []
    }

    // MARK: - file_read tail_lines / max_chars (host route)

    @Test func fileRead_tailLines_returnsLastLines() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "l1\nl2\nl3\nl4\nl5".write(
            to: root.appendingPathComponent("log.txt"),
            atomically: true,
            encoding: .utf8
        )

        let output = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"log.txt","tail_lines":2}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        let text = payload["text"] as? String ?? ""
        // Last two lines only.
        #expect(text.contains("l4"))
        #expect(text.contains("l5"))
        #expect(!text.contains("| l1"))
        #expect(!text.contains("| l2"))
    }

    @Test func fileRead_maxChars_capsOutput() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = (1 ... 200).map { "line-\($0)" }.joined(separator: "\n")
        try big.write(
            to: root.appendingPathComponent("big.txt"),
            atomically: true,
            encoding: .utf8
        )

        let output = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"big.txt","max_chars":80}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        let text = payload["text"] as? String ?? ""
        // The cap kicked in before the whole file was emitted.
        #expect(text.contains("truncated"))
        #expect(!text.contains("line-200"))
    }

    // MARK: - file_read on a directory (host route — merged file_tree)

    /// `file_read` pointed at a host DIRECTORY returns a listing instead of
    /// failing — the path decides file-vs-directory, so there is no separate
    /// `file_tree` tool for the model to mis-select.
    @Test func fileRead_directory_returnsListing() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        let sub = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "y".write(to: sub.appendingPathComponent("beta.txt"), atomically: true, encoding: .utf8)

        let output = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"."}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        // Structured, actionable listing shape — entries, not a tree string.
        #expect(payload["kind"] as? String == "listing")
        #expect(payload["text"] == nil, "a listing must not hand the model a prose tree")
        let entries = try #require(payload["entries"] as? [[String: Any]])
        let names = entries.compactMap { $0["name"] as? String }
        #expect(names.contains("alpha.txt"))
        #expect(names.contains("nested"))
        // The directory entry is typed so the model can branch without parsing.
        let nested = try #require(entries.first { $0["name"] as? String == "nested" })
        #expect(nested["type"] as? String == "directory")
        // Each entry's `path` is a ready-to-use next `file_read` argument.
        #expect(entries.allSatisfy { ($0["path"] as? String)?.isEmpty == false })
    }

    /// `file_read(max_depth:)` on a directory bounds how deep the listing
    /// recurses — the listing parameter the merged tool inherited from
    /// `file_tree`.
    @Test func fileRead_directory_honorsMaxDepth() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let level1 = root.appendingPathComponent("level1")
        let level2 = level1.appendingPathComponent("level2")
        try FileManager.default.createDirectory(at: level2, withIntermediateDirectories: true)
        try "deep".write(
            to: level2.appendingPathComponent("deep.txt"),
            atomically: true,
            encoding: .utf8
        )

        let shallow = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"path":".","max_depth":1}"#
        )
        let shallowEntries =
            (ToolEnvelope.successPayload(shallow) as? [String: Any])?["entries"]
            as? [[String: Any]] ?? []
        let shallowNames = shallowEntries.compactMap { $0["name"] as? String }
        #expect(shallowNames.contains("level1"))
        // Depth 1 must not descend to the depth-2 file.
        #expect(!shallowNames.contains("deep.txt"))
    }

    // MARK: - file_search target=files (host route)

    @Test func fileSearch_targetFiles_findsByNameGlob() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "x".write(to: sub.appendingPathComponent("c.swift"), atomically: true, encoding: .utf8)

        let output = try await FileSearchTool(rootPath: root).execute(
            argumentsJSON: #"{"pattern":"*.swift","target":"files"}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["kind"] as? String == "search")
        let paths = searchPaths(output)
        #expect(paths.contains("a.swift"))
        #expect(paths.contains { $0.hasSuffix("c.swift") })
        #expect(!paths.contains { $0.hasSuffix("b.txt") })
    }

    @Test func fileSearch_targetFiles_bareWordIsSubstring() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "x".write(
            to: docs.appendingPathComponent("q4_sales_report.xlsx"),
            atomically: true,
            encoding: .utf8
        )
        try "x".write(to: docs.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        // A bare word matches as a (recursive) substring of the basename.
        let lower = try await FileSearchTool(rootPath: root).execute(
            argumentsJSON: #"{"pattern":"q4","target":"files"}"#
        )
        let lowerPaths = searchPaths(lower)
        #expect(lowerPaths.contains { $0.hasSuffix("q4_sales_report.xlsx") })
        #expect(!lowerPaths.contains { $0.hasSuffix("notes.txt") })

        // Matching is case-insensitive.
        let upper = try await FileSearchTool(rootPath: root).execute(
            argumentsJSON: #"{"pattern":"Q4","target":"files"}"#
        )
        #expect(searchPaths(upper).contains { $0.hasSuffix("q4_sales_report.xlsx") })
    }

    @Test func fileSearch_targetFiles_prunesBuildArtifactDirs() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let nodeModules = root.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try "x".write(
            to: nodeModules.appendingPathComponent("widget.js"),
            atomically: true,
            encoding: .utf8
        )
        try "x".write(to: root.appendingPathComponent("widget.js"), atomically: true, encoding: .utf8)

        let output = try await FileSearchTool(rootPath: root).execute(
            argumentsJSON: #"{"pattern":"widget","target":"files"}"#
        )
        let paths = searchPaths(output)
        // The top-level file is returned; the node_modules copy is pruned.
        #expect(paths.contains("widget.js"))
        #expect(!paths.contains { $0.contains("node_modules") })
    }

    @Test func fileSearch_content_skipsOversizedAndBinaryFiles() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Normal text file with the needle.
        try "the needle is here".write(
            to: root.appendingPathComponent("normal.txt"),
            atomically: true,
            encoding: .utf8
        )
        // Binary-extension file containing the needle as text -> skipped by extension.
        try "needle".write(
            to: root.appendingPathComponent("image.png"),
            atomically: true,
            encoding: .utf8
        )
        // Oversized text file (> 2 MiB cap) containing the needle -> skipped by size.
        let big = String(repeating: "a", count: 3 * 1024 * 1024) + " needle"
        try big.write(to: root.appendingPathComponent("huge.txt"), atomically: true, encoding: .utf8)

        let output = try await FileSearchTool(rootPath: root).execute(
            argumentsJSON: #"{"pattern":"needle","target":"content"}"#
        )
        let text = (ToolEnvelope.successPayload(output) as? [String: Any])?["text"] as? String ?? ""
        #expect(text.contains("normal.txt"))
        #expect(!text.contains("image.png"))
        #expect(!text.contains("huge.txt"))
    }

    // MARK: - file_search find-by-name mechanics (Fix 3)

    /// A files-mode search returns structured candidates (`kind:"search"`,
    /// `entries[]`, `match_count`, `query`) the model can copy a `path` from.
    @Test func fileSearch_files_returnsStructuredCandidates() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(
            to: root.appendingPathComponent("budget_q4.xlsx"),
            atomically: true,
            encoding: .utf8
        )

        let output = try await FileSearchTool(rootPath: root).execute(
            argumentsJSON: #"{"pattern":"q4","target":"files"}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["kind"] as? String == "search")
        #expect(payload["query"] as? String == "q4")
        #expect(payload["match_count"] as? Int == 1)
        let entry = try #require((payload["entries"] as? [[String: Any]])?.first)
        #expect(entry["path"] as? String == "budget_q4.xlsx")
        #expect(entry["type"] as? String == "file")
    }

    /// Mode correction: a `target:"content"` search that finds no content
    /// matches falls back to a files-mode search and returns those candidates
    /// (so a model that grepped bodies when it meant filenames still wins),
    /// annotated so it's clear the mode was corrected.
    @Test func fileSearch_content_emptyCorrectsToFiles() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // The token appears in the NAME, never in any body.
        try "unrelated body text".write(
            to: root.appendingPathComponent("q4_report.xlsx"),
            atomically: true,
            encoding: .utf8
        )

        let output = try await FileSearchTool(rootPath: root).execute(
            argumentsJSON: #"{"pattern":"q4","target":"content"}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["kind"] as? String == "search")
        #expect(searchPaths(output).contains("q4_report.xlsx"))
        #expect(envelopeWarnings(output).contains { $0.contains("no content matches") })
    }

    /// Broaden-on-empty: a multi-word filename query that matches nothing
    /// retries with the longest token and returns the candidates, annotated
    /// with what it broadened to. The tool never decides which file was meant.
    @Test func fileSearch_files_broadensMultiWordOnEmpty() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(
            to: root.appendingPathComponent("q4_sales_report.xlsx"),
            atomically: true,
            encoding: .utf8
        )

        // The whole phrase doesn't substring-match the basename; "report" (the
        // longest token) does.
        let output = try await FileSearchTool(rootPath: root).execute(
            argumentsJSON: #"{"pattern":"report q4 sales","target":"files"}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["kind"] as? String == "search")
        #expect(searchPaths(output).contains("q4_sales_report.xlsx"))
        // Echoes the token actually matched (post-broaden) + an explanatory note.
        #expect(payload["query"] as? String == "report")
        #expect(envelopeWarnings(output).contains { $0.contains("broadened to") })
    }

    /// Multiple matches are ALL returned as candidates — the tool does not
    /// rank or auto-select; picking the right one is the model's judgement.
    @Test func fileSearch_files_multipleMatchesReturnsAllCandidates() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for n in ["q4_a.xlsx", "q4_b.xlsx", "q4_c.xlsx"] {
            try "x".write(to: root.appendingPathComponent(n), atomically: true, encoding: .utf8)
        }

        let output = try await FileSearchTool(rootPath: root).execute(
            argumentsJSON: #"{"pattern":"q4","target":"files"}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["match_count"] as? Int == 3)
        let paths = Set(searchPaths(output))
        #expect(paths == ["q4_a.xlsx", "q4_b.xlsx", "q4_c.xlsx"])
    }

    /// An unresolvable query (nothing matches, broaden exhausted) returns an
    /// empty `search` envelope plus a steer to list the parent or ask — never
    /// a guess.
    @Test func fileSearch_files_unresolvableReturnsSteer() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let output = try await FileSearchTool(rootPath: root).execute(
            argumentsJSON: #"{"pattern":"nonexistent thing","target":"files"}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["kind"] as? String == "search")
        #expect(payload["match_count"] as? Int == 0)
        let warnings = envelopeWarnings(output)
        #expect(warnings.contains { $0.contains("List the parent directory") || $0.contains("ask the user") })
    }

    // MARK: - file_search traversal guards (cancellation + visit budget)

    @Test func fileSearch_targetFiles_visitBudgetTruncates() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0 ..< 8 {
            try "x".write(
                to: root.appendingPathComponent("f\(i).txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        // A tiny injected budget stops the walk well before all 8 entries,
        // even though nothing matches, so the result is marked truncated and
        // carries the budget warning.
        let output = try await FileSearchTool(rootPath: root, maxEntriesVisited: 3).execute(
            argumentsJSON: #"{"pattern":"nomatchzzz","target":"files"}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["truncated"] as? Bool == true)
        #expect(envelopeWarnings(output).contains { $0.contains("scanning the entry limit") })
    }

    @Test func fileSearch_content_visitBudgetTruncates() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0 ..< 8 {
            try "nothing here".write(
                to: root.appendingPathComponent("f\(i).txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let output = try await FileSearchTool(rootPath: root, maxEntriesVisited: 3).execute(
            argumentsJSON: #"{"pattern":"needle","target":"content"}"#
        )
        let text = (ToolEnvelope.successPayload(output) as? [String: Any])?["text"] as? String ?? ""
        #expect(text.contains("search stopped after scanning"))
    }

    /// Best-effort: a cancelled search observes cancellation and bails rather
    /// than running the full walk. `Task { }` enqueues the body, so the
    /// synchronous `cancel()` lands before the loop's first
    /// `Task.checkCancellation()`. Timing-tolerant by construction.
    @Test func fileSearch_respectsCancellation() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0 ..< 50 {
            try "x".write(
                to: root.appendingPathComponent("f\(i).txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let tool = FileSearchTool(rootPath: root)
        let task = Task { () throws -> String in
            try await tool.execute(argumentsJSON: #"{"pattern":"nomatch_zzz","target":"files"}"#)
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected the cancelled search to throw CancellationError")
        } catch is CancellationError {
            // Expected.
        }
    }

    // MARK: - Secret refusal can't be bypassed via a bound bridge

    @Test func fileRead_relativeSecret_refusesEvenWithBridgeBound() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "SECRET=1".write(
            to: root.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )

        let bridge = SandboxReadBridge(agentName: "test-agent", home: "/workspace/agents/test-agent")
        let output = try await ChatExecutionContext.$hostReadOnlyScope.withValue(root) {
            try await ChatExecutionContext.$sandboxReadBridge.withValue(bridge) {
                try await FileReadTool(rootPath: root).execute(
                    argumentsJSON: #"{"path":".env"}"#
                )
            }
        }

        // Relative path = host route; the secret denylist applies and the
        // bound sandbox bridge does not provide an escape hatch.
        #expect(ToolEnvelope.isError(output))
        #expect(EnvelopeAssertions.failureKind(output) == "rejected")
    }
}
