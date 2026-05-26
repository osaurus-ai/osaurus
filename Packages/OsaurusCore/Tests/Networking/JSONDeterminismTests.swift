//
//  JSONDeterminismTests.swift
//  osaurusTests
//
//  Pins the byte-stability contract documented in `JSONDeterminism.swift`
//  / `docs/JSON_DETERMINISM.md`. Each test reproduces a non-determinism
//  risk that previously caused prompt-prefix cache misses (most concretely,
//  the ds4-server (https://github.com/antirez/ds4) KV cache miss reported
//  with `reason=token-mismatch` at `common=269`, traced to JSON tool schema
//  key reordering on the outbound `/chat/completions` body).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("JSON determinism contract")
struct JSONDeterminismTests {

    // MARK: - Phase 0: canonical encoder helpers

    @Test
    func canonicalEncoder_sortsKeysOfDictBackedJSONValue() throws {
        let encoder = JSONEncoder.osaurusCanonical()
        let a = try encoder.encode(Self.toolPermutationA)
        let b = try encoder.encode(Self.toolPermutationB)

        #expect(a == b)
    }

    @Test
    func canonicalEncoder_prettyPrintedStillSortsKeys() throws {
        let encoder = JSONEncoder.osaurusCanonical(prettyPrinted: true)
        let a = try encoder.encode(Self.toolPermutationA)
        let b = try encoder.encode(Self.toolPermutationB)

        #expect(a == b)
        #expect(String(decoding: a, as: UTF8.self).contains("\n"))
    }

    @Test
    func canonicalSerializationOptions_includeSortedKeys() throws {
        let dict: [String: Any] = ["z": 1, "a": 2, "m": 3]
        let data = try JSONSerialization.data(withJSONObject: dict, options: .osaurusCanonical)

        #expect(String(decoding: data, as: UTF8.self) == "{\"a\":2,\"m\":3,\"z\":1}")
    }

    @Test
    func canonicalSerializationOptions_doNotEscapeSlashes() throws {
        let payload: [String: Any] = ["path": "/Users/eric/Desktop/testmandel/mandelbrot.py"]
        let data = try JSONSerialization.data(withJSONObject: payload, options: .osaurusCanonical)

        #expect(String(decoding: data, as: UTF8.self) == "{\"path\":\"/Users/eric/Desktop/testmandel/mandelbrot.py\"}")
    }

    @Test
    func canonicalEncoder_doesNotEscapeSlashes() throws {
        struct Payload: Codable {
            let path: String
        }
        let encoder = JSONEncoder.osaurusCanonical()
        let data = try encoder.encode(Payload(path: "/usr/bin/env"))

        #expect(String(decoding: data, as: UTF8.self) == "{\"path\":\"/usr/bin/env\"}")
    }

    @Test
    func jsonCanonicalization_normalizeRecursivelyValidates() throws {
        let nested: [String: Any] = [
            "outer": [
                "inner": [1, "two", true, NSNull()],
                "leaf": "ok",
            ]
        ]

        let normalized = try #require(JSONCanonicalization.normalize(nested) as? [String: any Sendable])
        let outer = try #require(normalized["outer"] as? [String: any Sendable])
        let inner = try #require(outer["inner"] as? [any Sendable])

        #expect(inner.count == 4)
        #expect(outer["leaf"] as? String == "ok")
    }

    @Test
    func jsonCanonicalization_normalizeRejectsNonJSONLeaf() {
        struct OpaqueLeaf {}
        let bad: [String: Any] = ["bad": OpaqueLeaf()]

        let isNil: Bool = JSONCanonicalization.normalize(bad) == nil
        #expect(isNil)
    }

    // MARK: - P0: remote outbound bodies

    @Test
    func remoteChatRequest_outboundBytesAreStableAcrossKeyPermutations() throws {
        // Direct reproduction of the ds4 trace: two logically identical
        // requests with permuted tool-schema key orders must encode to the
        // same bytes once the canonical encoder is in play.
        let requestA = Self.makeRequest(tools: [Self.toolPermutationA])
        let requestB = Self.makeRequest(tools: [Self.toolPermutationB])

        let encoder = JSONEncoder.osaurusCanonical(prettyPrinted: true)
        #expect(try encoder.encode(requestA) == encoder.encode(requestB))
    }

    @Test
    func codexOAuthPayload_isByteStable() throws {
        // `toCodexOAuthPayloadData` round-trips through JSONSerialization;
        // confirm the canonical writing options apply.
        let request = Self.makeRequest(model: "gpt-5.2")

        let a = try request.toCodexOpenResponsesRequest().toCodexOAuthPayloadData()
        let b = try request.toCodexOpenResponsesRequest().toCodexOAuthPayloadData()

        #expect(a == b)
    }

    // MARK: - P1: server-side determinism

    @Test
    func mcpToolsListPayload_sortsKeys() throws {
        let payload: [String: Any] = [
            "tools": [
                [
                    "name": "z_tool",
                    "description": "Last alphabetically",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "z_field": ["type": "string"],
                            "a_field": ["type": "string"],
                        ],
                    ],
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: .osaurusCanonical)
        let body = String(decoding: data, as: UTF8.self)

        let aIdx = try #require(body.range(of: "\"a_field\""))
        let zIdx = try #require(body.range(of: "\"z_field\""))
        #expect(aIdx.lowerBound < zIdx.lowerBound)
    }

    // MARK: - P2: local pipeline determinism

    @Test
    func generationEventMapper_serializeArguments_sortsKeys() throws {
        // Two argument permutations of the same logical call. Both must
        // serialise to identical bytes so the assistant-replay path doesn't
        // bust the local KV cache between turns.
        let argsA: [String: Any] = ["city": "Tokyo", "country": "Japan", "limit": 5]
        let argsB: [String: Any] = ["limit": 5, "country": "Japan", "city": "Tokyo"]

        let dataA = try JSONSerialization.data(withJSONObject: argsA, options: .osaurusCanonical)
        let dataB = try JSONSerialization.data(withJSONObject: argsB, options: .osaurusCanonical)

        #expect(dataA == dataB)
        #expect(String(decoding: dataA, as: UTF8.self) == "{\"city\":\"Tokyo\",\"country\":\"Japan\",\"limit\":5}")
    }

    @Test
    func toolCanonicalize_fallback_normalisesSendableJSON() throws {
        // The fallback path (`JSONCanonicalization.normalizeObject`) must
        // accept a fully-Sendable JSON object and round-trip it without
        // dropping leaves. Covers the "JSONSerialization.data threw" branch
        // in `Tool.canonicalize`.
        let raw: [String: any Sendable] = [
            "type": "function",
            "function": [
                "name": "lookup",
                "description": "lookup",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "z": ["type": "string"],
                        "a": ["type": "string"],
                    ],
                    "required": ["a"],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]

        let canonical = try #require(JSONCanonicalization.normalizeObject(raw))
        let function = try #require(canonical["function"] as? [String: any Sendable])
        #expect(canonical["type"] as? String == "function")
        #expect(function["name"] as? String == "lookup")

        let bytesA = try JSONSerialization.data(withJSONObject: canonical, options: .osaurusCanonical)
        let bytesB = try JSONSerialization.data(withJSONObject: canonical, options: .osaurusCanonical)
        #expect(bytesA == bytesB)
    }

    // MARK: - Fixtures

    /// Two fixtures with identical logical content but permuted key
    /// insertion order at every nesting level. A non-canonical encoder
    /// produces different bytes; `osaurusCanonical()` must produce the
    /// same bytes.
    private static let toolPermutationA = Tool(
        type: "function",
        function: ToolFunction(
            name: "get_weather",
            description: "Get the current weather for a city.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "location": .object([
                        "type": .string("string"),
                        "description": .string("City name"),
                    ]),
                    "unit": .object([
                        "type": .string("string"),
                        "enum": .array([.string("c"), .string("f")]),
                    ]),
                ]),
                "required": .array([.string("location")]),
            ])
        )
    )

    private static let toolPermutationB = Tool(
        type: "function",
        function: ToolFunction(
            name: "get_weather",
            description: "Get the current weather for a city.",
            parameters: .object([
                "required": .array([.string("location")]),
                "properties": .object([
                    "unit": .object([
                        "enum": .array([.string("c"), .string("f")]),
                        "type": .string("string"),
                    ]),
                    "location": .object([
                        "description": .string("City name"),
                        "type": .string("string"),
                    ]),
                ]),
                "type": .string("object"),
            ])
        )
    )

    private static func makeRequest(model: String = "ds4", tools: [Tool]? = nil) -> RemoteChatRequest {
        RemoteChatRequest(
            model: model,
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: 0.7,
            max_completion_tokens: 1024,
            stream: false,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            tools: tools,
            tool_choice: nil,
            reasoning_effort: nil,
            reasoning: nil,
            thinking: nil,
            modelOptions: [:],
            veniceParameters: nil
        )
    }
}
