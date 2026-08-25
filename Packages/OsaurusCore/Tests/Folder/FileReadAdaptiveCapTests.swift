//
//  FileReadAdaptiveCapTests.swift
//  osaurusTests
//
//  Coverage for the adaptive `file_read` cap: a file that fits under
//  `ToolOutputCaps.fileReadMax` serves whole in one call, an explicit
//  `max_chars` may exceed the default 15K tier up to that ceiling, and
//  files above the ceiling keep the default tier + chunked continuation.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct FileReadAdaptiveCapTests {

    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-file-read-cap-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A deterministic multi-line body of approximately `chars` characters.
    private func body(chars: Int) -> String {
        let line = "item 0123456789 abcdefghijklmnopqrstuvwxyz\n"  // 44 chars
        return String(repeating: line, count: chars / line.count + 1)
    }

    @Test func fileUnderCeiling_servesWholeInOneCall() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // ~36K chars: the reported real-world case (previously 3 reads).
        let content = body(chars: 36_000)
        try content.write(
            to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let output = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"note.txt"}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["truncated"] as? Bool != true)
        #expect(payload["next_start_line"] == nil)
    }

    @Test func explicitMaxChars_mayExceedDefaultTier() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Above the ceiling so the default path would chunk; an explicit
        // max_chars of 40K must NOT be clamped down to 15K.
        let content = body(chars: Int(Double(ToolOutputCaps.fileReadMax) * 1.5))
        try content.write(
            to: root.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)

        let output = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"big.txt","max_chars":40000}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        let text = payload["text"] as? String ?? ""
        #expect(text.count > ToolOutputCaps.fileRead)
        #expect(text.count <= 40_000)
    }

    @Test func explicitMaxChars_clampedToAbsoluteCeiling() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = body(chars: ToolOutputCaps.fileReadMax * 2)
        try content.write(
            to: root.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)

        let output = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"big.txt","max_chars":999999}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        let text = payload["text"] as? String ?? ""
        #expect(text.count <= ToolOutputCaps.fileReadMax)
        #expect(payload["truncated"] as? Bool == true)
    }

    @Test func fileAboveCeiling_defaultsToChunkedTier() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = body(chars: ToolOutputCaps.fileReadMax * 2)
        try content.write(
            to: root.appendingPathComponent("huge.txt"), atomically: true, encoding: .utf8)

        let output = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"huge.txt"}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["truncated"] as? Bool == true)
        #expect(payload["next_start_line"] != nil)
        let text = payload["text"] as? String ?? ""
        // Default tier, not the ceiling: retained-context cost stays low
        // for files the model will read selectively anyway.
        #expect(text.count <= ToolOutputCaps.fileRead + 1_000)
    }

    @Test func smallExplicitMaxChars_stillRespected() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try body(chars: 5_000).write(
            to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let output = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"note.txt","max_chars":500}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        let text = payload["text"] as? String ?? ""
        #expect(text.count <= 600)
    }
}
