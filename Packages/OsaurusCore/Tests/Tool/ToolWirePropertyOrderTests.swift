//
//  ToolWirePropertyOrderTests.swift
//  osaurusTests
//
//  Authored `properties` order on the provider wire — the fix for
//  constrained decoders dropping `new_string` because `.sortedKeys` put it
//  before `old_string`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ToolWirePropertyOrderTests {
    private func keyOrder(in json: String, of object: String) -> [String] {
        // Keys of the first `"<object>":{...}` block, in textual order.
        guard let start = json.range(of: "\"\(object)\":{") else { return [] }
        var depth = 0
        var keys: [String] = []
        var index = json.index(start.upperBound, offsetBy: -1)
        var pendingKey: String?
        var inString = false
        var current = ""
        var escaped = false
        while index < json.endIndex {
            let ch = json[index]
            if inString {
                if escaped { escaped = false; current.append(ch) }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false; if depth == 1 { pendingKey = current } }
                else { current.append(ch) }
            } else {
                switch ch {
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return keys }
                case "\"": inString = true; current = ""
                case ":":
                    if depth == 1, let key = pendingKey { keys.append(key); pendingKey = nil }
                default: break
                }
            }
            index = json.index(after: index)
        }
        return keys
    }

    private func body(toolName: String, schema: [String: Any], extra: [String: Any] = [:]) throws -> Data {
        var root: [String: Any] = [
            "model": "grok-4.3",
            "messages": [
                ["role": "user", "content": "héllo \"quoted\" / slash\n"],
                ["role": "tool", "name": toolName, "content": "{\"ok\":true}"],
            ],
            "temperature": 0.95,
            "max_completion_tokens": 4096,
            "stream": true,
            "tools": [
                ["type": "function", "function": ["name": toolName, "parameters": schema]]
            ],
        ]
        for (k, v) in extra { root[k] = v }
        return try JSONSerialization.data(withJSONObject: root, options: .osaurusCanonical)
    }

    private let editSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["path"],
        "properties": [
            "path": ["type": "string"],
            "old_string": ["type": "string"],
            "new_string": ["type": "string"],
            "replace_all": ["type": "boolean"],
            "dry_run": ["type": "boolean"],
            "edits": [
                "type": "array",
                "items": [
                    "type": "object",
                    "required": ["old_string", "new_string"],
                    "properties": [
                        "old_string": ["type": "string"],
                        "new_string": ["type": "string"],
                    ],
                ],
            ],
        ],
    ]

    @Test func canonicalBodyAlphabetizesThenApplyRestoresAuthoredOrder() throws {
        ToolWirePropertyOrder.register(toolName: "wire_test_edit", order: ["path", "old_string", "new_string", "replace_all", "edits", "dry_run"])
        defer { ToolWirePropertyOrder.register(toolName: "wire_test_edit", order: nil) }

        let encoded = try body(toolName: "wire_test_edit", schema: editSchema)
        let before = String(decoding: encoded, as: UTF8.self)
        #expect(keyOrder(in: before, of: "properties") == ["dry_run", "edits", "new_string", "old_string", "path", "replace_all"])

        let rewritten = ToolWirePropertyOrder.apply(to: encoded)
        let after = String(decoding: rewritten, as: UTF8.self)
        #expect(keyOrder(in: after, of: "properties") == ["path", "old_string", "new_string", "replace_all", "edits", "dry_run"])

        // Nested `edits.items.properties` follows the same order.
        let itemsRange = try #require(after.range(of: "\"items\":{"))
        let tail = String(after[itemsRange.lowerBound...])
        #expect(keyOrder(in: tail, of: "properties") == ["old_string", "new_string"])

        // Everything else stays canonical (sorted) and semantically identical.
        #expect(keyOrder(in: after, of: "function") == ["name", "parameters"])
        let original = try JSONSerialization.jsonObject(with: encoded) as? NSDictionary
        let roundTripped = try JSONSerialization.jsonObject(with: rewritten) as? NSDictionary
        #expect(original == roundTripped, "rewrite must not change values")
        #expect(after.contains("\"content\":\"héllo \\\"quoted\\\" / slash\\n\""), "\(after)")
        #expect(after.contains("\"temperature\":0.95"))
        #expect(after.contains("\"max_completion_tokens\":4096"))
        #expect(after.contains("\"stream\":true"))
        #expect(after.contains("\"additionalProperties\":false"))

        // Deterministic: two passes give identical bytes.
        #expect(ToolWirePropertyOrder.apply(to: encoded) == rewritten)
    }

    @Test func bodiesWithoutOrderedToolsAreReturnedUntouched() throws {
        ToolWirePropertyOrder.register(toolName: "wire_test_edit", order: ["path", "old_string", "new_string"])
        defer { ToolWirePropertyOrder.register(toolName: "wire_test_edit", order: nil) }
        let other = try body(toolName: "some_other_tool", schema: editSchema)
        #expect(ToolWirePropertyOrder.apply(to: other) == other)

        // Already-alphabetical authored order → no rewrite needed either.
        ToolWirePropertyOrder.register(toolName: "wire_test_sorted", order: ["a", "b"])
        defer { ToolWirePropertyOrder.register(toolName: "wire_test_sorted", order: nil) }
        let sorted = try body(toolName: "wire_test_sorted", schema: ["type": "object", "properties": ["a": ["type": "string"], "b": ["type": "string"]]])
        #expect(ToolWirePropertyOrder.apply(to: sorted) == sorted)

        let junk = Data("not json".utf8)
        #expect(ToolWirePropertyOrder.apply(to: junk) == junk)
    }

    @Test func anthropicAndGeminiShapesAreCovered() throws {
        ToolWirePropertyOrder.register(toolName: "wire_test_edit", order: ["path", "old_string", "new_string"])
        defer { ToolWirePropertyOrder.register(toolName: "wire_test_edit", order: nil) }
        let props: [String: Any] = ["properties": ["new_string": ["type": "string"], "old_string": ["type": "string"], "path": ["type": "string"]], "type": "object"]
        let anthropic = try JSONSerialization.data(
            withJSONObject: ["tools": [["name": "wire_test_edit", "input_schema": props]]],
            options: .osaurusCanonical
        )
        let anthropicOut = String(decoding: ToolWirePropertyOrder.apply(to: anthropic), as: UTF8.self)
        #expect(keyOrder(in: anthropicOut, of: "properties") == ["path", "old_string", "new_string"])

        let gemini = try JSONSerialization.data(
            withJSONObject: ["tools": [["function_declarations": [["name": "wire_test_edit", "parameters": props]]]]],
            options: .osaurusCanonical
        )
        let geminiOut = String(decoding: ToolWirePropertyOrder.apply(to: gemini), as: UTF8.self)
        #expect(keyOrder(in: geminiOut, of: "properties") == ["path", "old_string", "new_string"])
    }

    @Test @MainActor func registryPublishesFileEditOrder() {
        // Registering through ToolRegistry records the tool's authored order.
        ToolRegistry.shared.register(FileEditTool())
        #expect(ToolWirePropertyOrder.order(for: "file_edit") == ["path", "old_string", "new_string", "replace_all", "edits", "operations", "dry_run"])
        #expect(FileWriteTool().parameterOrder?.first == "path")
    }
}
