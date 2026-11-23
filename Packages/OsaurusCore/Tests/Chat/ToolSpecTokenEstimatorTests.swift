//
//  ToolSpecTokenEstimatorTests.swift
//
//  Regression coverage for APPLE-MACOS-2VT: the preview pipeline prices tool
//  specs on the main thread for every debounced recompose, so the estimator
//  counts UTF-8 bytes (O(1) per string) instead of grapheme clusters.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
@MainActor
struct ToolSpecTokenEstimatorTests {

    private func largeSchema(keys: Int) -> JSONValue {
        var properties: [String: JSONValue] = [:]
        for i in 0..<keys {
            properties["property_\(i)"] = .object([
                "type": .string("string"),
                "description": .string(String(repeating: "lorem ipsum dolor ", count: 8)),
            ])
        }
        return .object(["type": .string("object"), "properties": .object(properties)])
    }

    @Test("ASCII estimates are unchanged by byte counting")
    func asciiEstimateIsStable() {
        let params: JSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("path")]),
        ])
        // name 4 + description 11 + params 41 + overhead 72 = 128 chars.
        let tokens = ToolSpecTokenEstimator.estimate(
            name: "read",
            description: "Read a file",
            parameters: params
        )
        #expect(tokens == 128 / TokenEstimator.charsPerToken)
    }

    @Test("Total for large schemas equals the per-spec sum")
    func largeSchemaTotalMatchesPerSpecSum() {
        let tools = (0..<20).map { i in
            Tool(
                type: "function",
                function: ToolFunction(
                    name: "big_tool_\(i)",
                    description: "A tool with a large schema",
                    parameters: largeSchema(keys: 500)
                )
            )
        }
        let expected = tools.reduce(0) { total, tool in
            total
                + ToolSpecTokenEstimator.estimate(
                    name: tool.function.name,
                    description: tool.function.description,
                    parameters: tool.function.parameters
                )
        }
        #expect(ToolRegistry.shared.totalEstimatedTokens(for: tools) == expected)
    }
}
