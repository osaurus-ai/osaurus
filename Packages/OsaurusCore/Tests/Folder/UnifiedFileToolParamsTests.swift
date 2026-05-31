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
        let text = payload["text"] as? String ?? ""
        #expect(text.contains("alpha.txt"))
        #expect(text.contains("nested"))
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
        let shallowText = (ToolEnvelope.successPayload(shallow) as? [String: Any])?["text"] as? String ?? ""
        #expect(shallowText.contains("level1"))
        // Depth 1 must not descend to the depth-2 file.
        #expect(!shallowText.contains("deep.txt"))
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
        let text = payload["text"] as? String ?? ""
        #expect(text.contains("a.swift"))
        #expect(text.contains("c.swift"))
        #expect(!text.contains("b.txt"))
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
