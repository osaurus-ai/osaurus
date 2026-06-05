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

    // MARK: - Relative image URL resolution

    @Test func rewritesRelativeMarkdownImagePaths() {
        let input = "![banner](assets/banner.png)"
        let output = HuggingFaceService.resolvingRelativeImageURLs(in: input, repoId: "org/model")
        #expect(
            output == "![banner](https://huggingface.co/org/model/resolve/main/assets/banner.png)"
        )
    }

    @Test func stripsLeadingDotSlashAndRootSlash() {
        let dotSlash = HuggingFaceService.resolvingRelativeImageURLs(
            in: "![a](./fig.png)",
            repoId: "org/model"
        )
        #expect(dotSlash.contains("/resolve/main/fig.png)"))
        let rootSlash = HuggingFaceService.resolvingRelativeImageURLs(
            in: "![a](/images/x.png)",
            repoId: "org/model"
        )
        #expect(rootSlash.contains("/resolve/main/images/x.png)"))
    }

    @Test func leavesAbsoluteAndDataImageURLsUntouched() {
        let input = """
            ![remote](https://cdn.example.com/a.png)
            ![inline](data:image/png;base64,AAAA)
            ![proto](//example.com/b.png)
            """
        let output = HuggingFaceService.resolvingRelativeImageURLs(in: input, repoId: "org/model")
        #expect(output == input)
    }

    @Test func resolvesRelativeHTMLImageViaNormalizePipeline() {
        // HTML `<img>` is converted to markdown first, then its relative src
        // is resolved — mirroring the order `fetchReadme` uses.
        let input = #"<img src="docs/diagram.png" width="400">"#
        let normalized = HuggingFaceService.normalizingModelCardHTML(input)
        let output = HuggingFaceService.resolvingRelativeImageURLs(
            in: normalized,
            repoId: "org/model"
        )
        #expect(
            output.contains("![](https://huggingface.co/org/model/resolve/main/docs/diagram.png)")
        )
    }

    @Test func encodesSpacesWhenConvertingHTMLImage() {
        // HTML `src` may contain spaces; the emitted markdown URL must encode
        // them so `URL(string:)` accepts it.
        let output = HuggingFaceService.normalizingModelCardHTML(
            #"<img src="my images/pic.png">"#
        )
        #expect(output.contains("![](my%20images/pic.png)"))
    }

    // MARK: - HTML normalization

    @Test func convertsCenteredHTMLImageToMarkdown() {
        let input =
            #"<p align="center"><img src="https://huggingface.co/org/model/resolve/main/banner.png" width="100%"/></p>"#
        let output = HuggingFaceService.normalizingModelCardHTML(input)
        #expect(
            output.contains(
                "![](https://huggingface.co/org/model/resolve/main/banner.png)"
            )
        )
        #expect(!output.lowercased().contains("<img"))
        #expect(!output.lowercased().contains("<p"))
    }

    @Test func keepsImageAltTextWhenConverting() {
        let input = #"<img alt="Logo" src="https://x/y.png">"#
        let output = HuggingFaceService.normalizingModelCardHTML(input)
        #expect(output.contains("![Logo](https://x/y.png)"))
    }

    @Test func convertsAnchorToMarkdownLink() {
        let input = #"See <a href="https://example.com">the docs</a> now."#
        let output = HuggingFaceService.normalizingModelCardHTML(input)
        #expect(output.contains("[the docs](https://example.com)"))
        #expect(!output.lowercased().contains("<a "))
    }

    @Test func convertsBreakTagsToNewlines() {
        let input = "a<br>b<br/>c"
        let output = HuggingFaceService.normalizingModelCardHTML(input)
        #expect(output.contains("a\nb\nc"))
    }

    @Test func leavesHTMLInsideCodeFencesIntact() {
        let input = """
            Intro <p>strip me</p>

            ```html
            <p align="center"><img src="x.png"></p>
            ```
            """
        let output = HuggingFaceService.normalizingModelCardHTML(input)
        // Prose wrapper is stripped...
        #expect(!output.contains("<p>strip me</p>"))
        // ...but the fenced sample keeps its raw HTML verbatim.
        #expect(output.contains(#"<p align="center"><img src="x.png"></p>"#))
    }
}
