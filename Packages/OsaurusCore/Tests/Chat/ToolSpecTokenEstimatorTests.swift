//
//  ToolSpecTokenEstimatorTests.swift
//
//  Regression coverage for APPLE-MACOS-2VT: the preview pipeline prices tool
//  specs on the main thread for every debounced recompose, so the estimator
//  counts scalars with a byte loop instead of grapheme segmentation. Its
//  results must still match `String.count` for the built-in descriptions.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
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

    @Test("Character count matches String.count for multi-byte punctuation")
    func characterCountMatchesStringCount() {
        for sample in ["", "plain ascii", "Settings → Vault — done…", "≤6 short choices", "caf\u{E9}"] {
            #expect(ToolSpecTokenEstimator.characterCount(sample) == sample.count)
        }
    }

    @Test("ASCII estimates are unchanged")
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
    func largeSchemaTotalMatchesPerSpecSum() async {
        let tools = (0..<5).map { i in
            Tool(
                type: "function",
                function: ToolFunction(
                    name: "big_tool_\(i)",
                    description: "A tool with a large schema",
                    parameters: largeSchema(keys: 100)
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
        // Touch the shared registry only under the process-wide catalog lock,
        // like every other suite that reads `ToolRegistry.shared`, so this
        // suite can't be the one that cold-initializes the registry while
        // another suite is registering tools or asserting on the catalog.
        let total = await DynamicCatalogTestLock.shared.run {
            ToolRegistry.shared.totalEstimatedTokens(for: tools)
        }
        #expect(total == expected)
    }
}
