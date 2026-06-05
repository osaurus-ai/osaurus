//
//  HuggingFaceParsingTests.swift
//  osaurusTests
//
//  Covers the pure parsing helpers added for the enriched model detail
//  modal: README front-matter stripping and the `base_model`
//  string-or-array decoder.
//

import Foundation
import Testing

@testable import OsaurusCore

struct HuggingFaceParsingTests {

    // MARK: - Front-matter stripping

    @Test func stripsLeadingYAMLFrontMatter() {
        let input = """
            ---
            license: mit
            tags:
              - text-generation
            ---
            # Model Title

            Body text.
            """
        let output = HuggingFaceService.strippingFrontMatter(input)
        #expect(!output.contains("license: mit"))
        #expect(output.contains("# Model Title"))
        #expect(output.contains("Body text."))
    }

    @Test func leavesBodyUntouchedWhenNoFrontMatter() {
        let input = "# Title\n\nNo front matter here."
        #expect(HuggingFaceService.strippingFrontMatter(input) == input)
    }

    @Test func leavesUnterminatedFrontMatterIntact() {
        // A lone opening delimiter shouldn't eat the whole document.
        let input = "---\nlicense: mit\n# still here"
        #expect(HuggingFaceService.strippingFrontMatter(input) == input)
    }

    // MARK: - base_model decoding

    private struct Holder: Decodable {
        let base_model: HuggingFaceService.StringOrArray?
    }

    @Test func decodesBaseModelAsString() throws {
        let json = #"{"base_model": "org/upstream"}"#
        let holder = try JSONDecoder().decode(Holder.self, from: Data(json.utf8))
        #expect(holder.base_model?.values == ["org/upstream"])
    }

    @Test func decodesBaseModelAsArray() throws {
        let json = #"{"base_model": ["a/one", "b/two"]}"#
        let holder = try JSONDecoder().decode(Holder.self, from: Data(json.utf8))
        #expect(holder.base_model?.values == ["a/one", "b/two"])
    }
}
