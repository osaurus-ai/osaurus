//
//  GenerationParameterPlumbingTests.swift
//  osaurus
//
//  Regression tests for OpenAI generation-parameter plumbing:
//  - `stop` decodes from both the single-string and array shapes
//  - `min_p` decodes and rides the request
//  - `seed` / presence / frequency penalties reach vmlx
//    `GenerateParameters` (they used to die between the request and the
//    engine: seed went to a global-RNG no-op, presence_penalty was
//    dropped, frequency_penalty was mis-mapped to a multiplicative
//    repetition penalty).
//

import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

struct GenerationParameterPlumbingTests {

    private func decodeRequest(_ json: String) throws -> ChatCompletionRequest {
        try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
    }

    @Test("stop decodes from a plain string (OpenAI-legal shape)")
    func stopDecodesFromString() throws {
        let req = try decodeRequest(
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"stop":"five"}"#)
        #expect(req.stop == ["five"])
    }

    @Test("stop decodes from an array of strings")
    func stopDecodesFromArray() throws {
        let req = try decodeRequest(
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"stop":["a","b"]}"#)
        #expect(req.stop == ["a", "b"])
    }

    @Test("stop absent and stop null both decode to nil")
    func stopAbsentAndNull() throws {
        let absent = try decodeRequest(
            #"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#)
        #expect(absent.stop == nil)
        let null = try decodeRequest(
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"stop":null}"#)
        #expect(null.stop == nil)
    }

    @Test("min_p decodes and survives withModel/withContext copies")
    func minPDecodesAndCopies() throws {
        let req = try decodeRequest(
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"min_p":0.05}"#)
        #expect(req.min_p == 0.05)
        #expect(req.withModel("other").min_p == 0.05)
        #expect(req.withContext(messages: req.messages, tools: nil, toolChoice: nil).min_p == 0.05)
    }

    @Test("full sampling field set decodes together")
    func fullFieldSetDecodes() throws {
        let req = try decodeRequest(
            #"""
            {"model":"m","messages":[{"role":"user","content":"hi"}],
             "temperature":0.7,"top_p":0.9,"top_k":40,"min_p":0.02,
             "frequency_penalty":0.5,"presence_penalty":-0.25,
             "seed":42,"max_tokens":128,"stop":"END","stream":false}
            """#)
        #expect(req.temperature == 0.7)
        #expect(req.top_k == 40)
        #expect(req.min_p == 0.02)
        #expect(req.frequency_penalty == 0.5)
        #expect(req.presence_penalty == -0.25)
        #expect(req.seed == 42)
        #expect(req.stop == ["END"])
    }

    @Test("seed and penalties reach GenerateParameters")
    func seedAndPenaltiesReachEngineParameters() {
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.8,
            maxTokens: 100,
            topP: 0.95,
            repetitionPenalty: nil,
            presencePenalty: 1.5,
            frequencyPenalty: -0.5,
            randomSeed: 42
        )
        #expect(params.randomSeed == 42)
        #expect(params.presencePenalty == 1.5)
        #expect(params.frequencyPenalty == -0.5)
    }

    @Test("zero penalties (OpenAI no-op default) stay unset")
    func zeroPenaltiesStayUnset() {
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0.8,
            maxTokens: 100,
            topP: 0.95,
            repetitionPenalty: nil,
            presencePenalty: 0,
            frequencyPenalty: 0,
            randomSeed: nil
        )
        #expect(params.presencePenalty == nil)
        #expect(params.frequencyPenalty == nil)
        #expect(params.randomSeed == nil)
    }
}
