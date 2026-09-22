//
//  HuggingFaceModelDeepLinkTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct HuggingFaceModelDeepLinkTests {

    private func url(_ s: String) throws -> URL {
        try #require(URL(string: s))
    }

    // MARK: - osaurus://open_from_hf (the shape huggingface.js generates)

    @Test func osaurusOpenFromHF_rawSlash_parsesModel() throws {
        // `new URL(`osaurus://open_from_hf?model=${model.id}`)` keeps the slash raw.
        let link = HuggingFaceModelDeepLink.parse(
            try url("osaurus://open_from_hf?model=mlx-community/Llama-3.2-3B-Instruct-4bit")
        )
        #expect(link == HuggingFaceModelDeepLink(modelId: "mlx-community/Llama-3.2-3B-Instruct-4bit", file: nil))
    }

    @Test func osaurusOpenFromHF_percentEncodedSlash_decodes() throws {
        // `url.searchParams.set("model", model.id)` encodes the slash as %2F.
        let link = HuggingFaceModelDeepLink.parse(
            try url("osaurus://open_from_hf?model=OsaurusAI%2FRaptor-0.6-4B-JANG_6M")
        )
        #expect(link?.modelId == "OsaurusAI/Raptor-0.6-4B-JANG_6M")
        #expect(link?.file == nil)
    }

    @Test func osaurusOpenFromHF_withFile_parsesBoth() throws {
        let link = HuggingFaceModelDeepLink.parse(
            try url("osaurus://open_from_hf?model=org/repo&file=model.safetensors")
        )
        #expect(link == HuggingFaceModelDeepLink(modelId: "org/repo", file: "model.safetensors"))
    }

    @Test func osaurusOpenFromHF_hostIsCaseInsensitive() throws {
        #expect(HuggingFaceModelDeepLink.parse(try url("osaurus://Open_From_HF?model=org/repo"))?.modelId == "org/repo")
    }

    @Test func osaurusOpenFromHF_missingModel_isNil() throws {
        #expect(HuggingFaceModelDeepLink.parse(try url("osaurus://open_from_hf")) == nil)
        #expect(HuggingFaceModelDeepLink.parse(try url("osaurus://open_from_hf?file=x.safetensors")) == nil)
        #expect(HuggingFaceModelDeepLink.parse(try url("osaurus://open_from_hf?model=%20%20")) == nil)
    }

    // MARK: - huggingface://?model= (original link)

    @Test func legacyHuggingFaceScheme_stillParses() throws {
        let link = HuggingFaceModelDeepLink.parse(
            try url("huggingface://?model=mlx-community/Qwen3-4B-4bit&file=config.json")
        )
        #expect(link == HuggingFaceModelDeepLink(modelId: "mlx-community/Qwen3-4B-4bit", file: "config.json"))
    }

    // MARK: - Other osaurus:// hosts are not claimed

    @Test func otherOsaurusHosts_areNotModelLinks() throws {
        for s in [
            "osaurus://plugins-install?tool=x",
            "osaurus://themes-install?hash=abc",
            "osaurus://settings?tab=models",
            "osaurus://0xabc?pair=def",
            "osaurus://?model=org/repo",  // no host: pairing shape, not a model link
        ] {
            let u = try url(s)
            #expect(!HuggingFaceModelDeepLink.matches(u), "\(s) must not be claimed")
            #expect(HuggingFaceModelDeepLink.parse(u) == nil, "\(s) must not parse")
        }
    }

    @Test func unrelatedScheme_isNil() throws {
        #expect(HuggingFaceModelDeepLink.parse(try url("https://huggingface.co/org/repo?model=org/repo")) == nil)
    }
}
