//
//  CompletionRequestTests.swift
//  osaurusTests
//
//  Decoding coverage for the OpenAI-legacy `/v1/completions` request used by
//  FIM autocomplete tools. Pins the string-or-array shapes for `prompt` and
//  `stop`, and the `max_tokens` default.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct CompletionRequestTests {

    private func decode(_ json: String) throws -> CompletionRequest {
        try JSONDecoder().decode(CompletionRequest.self, from: Data(json.utf8))
    }

    @Test func decodesStringPromptAndStop() throws {
        let req = try decode(
            #"""
            {
              "model": "qwen2.5-coder-1.5b-instruct-4bit",
              "prompt": "<|fim_prefix|>def f():<|fim_suffix|>\n    return x<|fim_middle|>",
              "max_tokens": 50,
              "temperature": 0.2,
              "top_p": 0.9,
              "stop": "<|fim_pad|>",
              "stream": true
            }
            """#
        )
        #expect(req.model == "qwen2.5-coder-1.5b-instruct-4bit")
        #expect(req.prompt.contains("<|fim_prefix|>"))
        #expect(req.prefix == nil)
        #expect(req.suffix == nil)
        #expect(req.middle == nil)
        #expect(req.unsupportedFIMReason == nil)
        #expect(req.maxTokens == 50)
        #expect(req.resolvedMaxTokens == 50)
        #expect(req.temperature == 0.2)
        #expect(req.topP == 0.9)
        #expect(req.stop == ["<|fim_pad|>"])
        #expect(req.stream == true)
    }

    @Test func decodesArrayPromptTakesFirstAndArrayStop() throws {
        let req = try decode(
            #"""
            {
              "model": "m",
              "prompt": ["first prompt", "second prompt"],
              "stop": ["\n\n", "<|endoftext|>"]
            }
            """#
        )
        #expect(req.prompt == "first prompt")
        #expect(req.stop == ["\n\n", "<|endoftext|>"])
    }

    @Test func defaultsMaxTokensWhenOmitted() throws {
        let req = try decode(#"{"model": "m", "prompt": "hello"}"#)
        #expect(req.maxTokens == nil)
        #expect(req.resolvedMaxTokens == 256)
        #expect(req.stop.isEmpty)
        #expect(req.stream == nil)
        #expect(req.temperature == nil)
    }

    @Test func decodesPrefixAsPromptFallback() throws {
        let req = try decode(
            #"""
            {
              "model": "m",
              "prefix": "func f() -> Int {\n    ",
              "max_tokens": 24
            }
            """#
        )
        #expect(req.prompt == "func f() -> Int {\n    ")
        #expect(req.prefix == "func f() -> Int {\n    ")
        #expect(req.suffix == nil)
        #expect(req.middle == nil)
        #expect(req.unsupportedFIMReason == nil)
    }

    @Test func decodesOpenAIInsertionSuffixAndRejectsUnsupportedSeparateContext() throws {
        let req = try decode(
            #"""
            {
              "model": "m",
              "prompt": "func f() -> Int {\n    ",
              "suffix": "\n}",
              "max_tokens": 24
            }
            """#
        )
        #expect(req.prompt == "func f() -> Int {\n    ")
        #expect(req.suffix == "\n}")
        let reason = try #require(req.unsupportedFIMReason)
        #expect(reason.contains("suffix"))
        #expect(reason.contains("/v1/completions"))
    }

    @Test func decodesPrefixSuffixMiddleFieldsAndRejectsUnsupportedMiddle() throws {
        let req = try decode(
            #"""
            {
              "model": "m",
              "prefix": "before",
              "suffix": "after",
              "middle": "existing edit"
            }
            """#
        )
        #expect(req.prompt == "before")
        #expect(req.prefix == "before")
        #expect(req.suffix == "after")
        #expect(req.middle == "existing edit")
        let reason = try #require(req.unsupportedFIMReason)
        #expect(reason.contains("suffix"))
        #expect(reason.contains("middle"))
    }

    @Test func emptySuffixDoesNotRejectPlainPrefixCompletion() throws {
        let req = try decode(
            #"""
            {
              "model": "m",
              "prefix": "continue from here",
              "suffix": ""
            }
            """#
        )
        #expect(req.prompt == "continue from here")
        #expect(req.unsupportedFIMReason == nil)
    }
}
