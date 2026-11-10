//
//  LocalGrammarTokenizerProbeTests.swift
//  OsaurusCoreTests
//
//  The cheap tokenizer probe behind "can this local model return typed
//  results": it must agree with vmlx's `GrammarTokenVocabulary.fromTokenizerJSON`
//  on the declaring fields while never decoding the vocabulary.
//

import Foundation
import Testing
import struct MLXLMCommon.GrammarTokenVocabulary

@testable import OsaurusCore

struct LocalGrammarTokenizerProbeTests {

    /// A tokenizer.json in the Hugging Face field order: `decoder` before
    /// `model`, and inside `model` the declaring fields before `vocab`.
    static func tokenizerJSON(
        modelType: String = "BPE", decoder: String = #"{"type":"ByteLevel","add_prefix_space":false}"#,
        prefix: String = "null", suffix: String = "null", vocabEntries: Int = 300
    ) -> Data {
        // Pieces in the ByteLevel alphabet so the exact engine adapter admits them too.
        let pieces = (0 ..< vocabEntries).map { i in
            "\"\(String(UnicodeScalar(97 + (i % 26))!))\(i)\": \(i)"
        }.joined(separator: ", ")
        let text = """
            {"version":"1.0","truncation":null,"padding":null,
             "added_tokens":[{"id":\(vocabEntries),"content":"<|end|>","special":true,"single_word":false}],
             "normalizer":null,
             "pre_tokenizer":{"type":"ByteLevel","add_prefix_space":false,"trim_offsets":false,"use_regex":true},
             "post_processor":null,
             "decoder":\(decoder),
             "model":{"type":"\(modelType)","dropout":null,"unk_token":null,
                      "continuing_subword_prefix":\(prefix),"end_of_word_suffix":\(suffix),
                      "fuse_unk":false,"byte_fallback":false,"ignore_merges":false,
                      "vocab":{\(pieces), "<|end|>": \(vocabEntries)},
                      "merges":["a b","c d"]}}
            """
        return Data(text.utf8)
    }

    static func config(cleanup: String = "false") -> Data {
        Data(#"{"clean_up_tokenization_spaces":\#(cleanup),"eos_token":"<|end|>","model_max_length":4096}"#.utf8)
    }

    @Test
    func byteLevelBPE_isSupported_andAgreesWithTheEngineAdapter() {
        let tokenizer = Self.tokenizerJSON()
        #expect(LocalGrammarTokenizerProbe.declaresSupportedTokenizer(tokenizerJSON: tokenizer, tokenizerConfig: Self.config()))
        #expect(GrammarTokenVocabulary.fromTokenizerJSON(tokenizer, tokenizerConfig: Self.config()) != nil)
    }

    @Test
    func metadata_isReadWithoutTheVocabulary() throws {
        let meta = try #require(LocalGrammarTokenizerProbe.TokenizerMetadata(scanning: Self.tokenizerJSON(prefix: "\"##\"")))
        #expect(meta.modelType == "BPE")
        #expect(meta.decoderType == "ByteLevel")
        #expect(meta.continuingSubwordPrefix == "##")
        #expect(meta.endOfWordSuffix == nil)
    }

    @Test
    func otherDecoders_andTokenizers_areUnsupported() {
        let sequence = #"{"type":"Sequence","decoders":[{"type":"Replace"},{"type":"ByteFallback"}]}"#
        #expect(!LocalGrammarTokenizerProbe.declaresSupportedTokenizer(
            tokenizerJSON: Self.tokenizerJSON(decoder: sequence), tokenizerConfig: Self.config()))
        #expect(!LocalGrammarTokenizerProbe.declaresSupportedTokenizer(
            tokenizerJSON: Self.tokenizerJSON(modelType: "Unigram"), tokenizerConfig: Self.config()))
        #expect(!LocalGrammarTokenizerProbe.declaresSupportedTokenizer(
            tokenizerJSON: Self.tokenizerJSON(prefix: "\"##\""), tokenizerConfig: Self.config()))
        #expect(!LocalGrammarTokenizerProbe.declaresSupportedTokenizer(
            tokenizerJSON: Self.tokenizerJSON(suffix: "\"</w>\""), tokenizerConfig: Self.config()))
        // Empty strings are the same as absent, as in the engine adapter.
        #expect(LocalGrammarTokenizerProbe.declaresSupportedTokenizer(
            tokenizerJSON: Self.tokenizerJSON(prefix: "\"\"", suffix: "\"\""), tokenizerConfig: Self.config()))
    }

    @Test
    func cleanupMustBeDeclaredFalse() {
        let tokenizer = Self.tokenizerJSON()
        #expect(!LocalGrammarTokenizerProbe.declaresSupportedTokenizer(
            tokenizerJSON: tokenizer, tokenizerConfig: Self.config(cleanup: "true")))
        #expect(!LocalGrammarTokenizerProbe.declaresSupportedTokenizer(
            tokenizerJSON: tokenizer, tokenizerConfig: Data(#"{"eos_token":"<|end|>"}"#.utf8)))
        #expect(!LocalGrammarTokenizerProbe.declaresSupportedTokenizer(
            tokenizerJSON: tokenizer, tokenizerConfig: Self.config(cleanup: "0")))
        // The engine adapter draws the same lines.
        #expect(GrammarTokenVocabulary.fromTokenizerJSON(tokenizer, tokenizerConfig: Self.config(cleanup: "true")) == nil)
        #expect(GrammarTokenVocabulary.fromTokenizerJSON(tokenizer, tokenizerConfig: Data(#"{"eos_token":"x"}"#.utf8)) == nil)
    }

    @Test
    func modelBeforeDecoder_stillFindsBoth() throws {
        let text = """
            {"model":{"type":"BPE","continuing_subword_prefix":null,"end_of_word_suffix":null,
                      "vocab":{"a":0,"b":1,"{":2,"\\"":3},"merges":[]},
             "decoder":{"type":"ByteLevel"}}
            """
        let meta = try #require(LocalGrammarTokenizerProbe.TokenizerMetadata(scanning: Data(text.utf8)))
        #expect(meta.modelType == "BPE")
        #expect(meta.decoderType == "ByteLevel")
    }

    @Test
    func malformedOrMissingFiles_areUnsupported() throws {
        #expect(LocalGrammarTokenizerProbe.TokenizerMetadata(scanning: Data("[1,2]".utf8)) == nil)
        #expect(!LocalGrammarTokenizerProbe.declaresSupportedTokenizer(
            tokenizerJSON: Data("{\"model\":".utf8), tokenizerConfig: Self.config()))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("osaurus-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A bundle without tokenizer.json (SentencePiece-only exports).
        #expect(!LocalGrammarTokenizerProbe.declaresSupportedTokenizer(in: dir))
        try Self.tokenizerJSON().write(to: dir.appendingPathComponent("tokenizer.json"))
        try Self.config().write(to: dir.appendingPathComponent("tokenizer_config.json"))
        #expect(LocalGrammarTokenizerProbe.declaresSupportedTokenizer(in: dir))
    }

    @Test
    func answersAreCachedPerBundle() throws {
        LocalGrammarTokenizerProbe.resetCache()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("osaurus-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.tokenizerJSON().write(to: dir.appendingPathComponent("tokenizer.json"))
        try Self.config().write(to: dir.appendingPathComponent("tokenizer_config.json"))
        #expect(LocalGrammarTokenizerProbe.supports(bundle: dir))
        // Replacing the files does not change a cached answer for the same path.
        try Self.config(cleanup: "true").write(to: dir.appendingPathComponent("tokenizer_config.json"))
        #expect(LocalGrammarTokenizerProbe.supports(bundle: dir))
        LocalGrammarTokenizerProbe.resetCache()
        #expect(!LocalGrammarTokenizerProbe.supports(bundle: dir))
    }
}
