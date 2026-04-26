//
//  LocalGenerationDefaultsTests.swift
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("LocalGenerationDefaults parse")
struct LocalGenerationDefaultsTests {

    private static func defaults(fromJSON json: String) -> LocalGenerationDefaults.Defaults {
        LocalGenerationDefaults.parse(data: Data(json.utf8))
    }

    @Test("Gemma-4 26B-A4B-it: temperature=1.0, top_k=64, top_p=0.95")
    func gemma4() {
        // Copied verbatim from
        // models--mlx-community--gemma-4-26b-a4b-it-4bit/snapshots/.../generation_config.json
        let d = Self.defaults(
            fromJSON: #"""
                {
                  "bos_token_id": 2,
                  "do_sample": true,
                  "eos_token_id": [1, 106, 50],
                  "pad_token_id": 0,
                  "temperature": 1.0,
                  "top_k": 64,
                  "top_p": 0.95,
                  "transformers_version": "5.5.0.dev0"
                }
                """#
        )
        #expect(d.temperature == 1.0)
        #expect(d.topK == 64)
        #expect(d.topP == 0.95)
        #expect(d.repetitionPenalty == nil)
    }

    @Test("Qwen 3.5 397B-A17B-JANG_2L: temperature=0.6")
    func qwen35() {
        // Qwen 3.5 specifies LOWER temperature than the 0.7 osaurus used to
        // hardcode; this is the headline reason the feature exists.
        let d = Self.defaults(
            fromJSON: #"""
                {
                  "bos_token_id": 248044,
                  "do_sample": true,
                  "eos_token_id": [248046, 248044],
                  "pad_token_id": 248044,
                  "temperature": 0.6,
                  "top_k": 20,
                  "top_p": 0.95,
                  "transformers_version": "4.57.0.dev0"
                }
                """#
        )
        #expect(d.temperature == 0.6)
        #expect(d.topK == 20)
        #expect(d.topP == 0.95)
    }

    @Test("MiniMax M2.7: top_k=40")
    func minimax() {
        let d = Self.defaults(
            fromJSON: #"""
                {
                  "bos_token_id": 200019,
                  "do_sample": true,
                  "eos_token_id": 200020,
                  "temperature": 1.0,
                  "top_p": 0.95,
                  "top_k": 40,
                  "transformers_version": "4.46.1"
                }
                """#
        )
        #expect(d.temperature == 1.0)
        #expect(d.topK == 40)
        #expect(d.topP == 0.95)
    }

    @Test("Nemotron-Cascade-2: no sampling fields, only EOS")
    func nemotronNoSamplingFields() {
        // Real Nemotron generation_config.json ships nothing but EOS/BOS/pad.
        // We should return `.empty` sampling defaults so the caller's existing
        // fallback ladder (request → runtime → hardcoded 0.7) kicks in.
        let d = Self.defaults(
            fromJSON: #"""
                {
                  "_from_model_config": true,
                  "bos_token_id": 1,
                  "eos_token_id": [2, 11],
                  "pad_token_id": 0,
                  "transformers_version": "4.55.4"
                }
                """#
        )
        #expect(d.temperature == nil)
        #expect(d.topK == nil)
        #expect(d.topP == nil)
        #expect(d.repetitionPenalty == nil)
    }

    @Test("Mistral-Small-4: sampling fields absent — defaults empty")
    func mistralNoSamplingFields() {
        let d = Self.defaults(
            fromJSON: #"""
                {
                  "bos_token_id": 1,
                  "eos_token_id": 2,
                  "max_length": 1048576,
                  "pad_token_id": 11,
                  "transformers_version": "5.3.0.dev0"
                }
                """#
        )
        #expect(d == .empty)
    }

    @Test("repetition_penalty field honored when present")
    func repetitionPenaltyFieldHonored() {
        // Uncommon but permitted — HF spec allows repetition_penalty in
        // generation_config. Make sure we don't drop it on the floor.
        let d = Self.defaults(
            fromJSON: #"""
                {"temperature": 0.8, "repetition_penalty": 1.05}
                """#
        )
        #expect(d.temperature == 0.8)
        #expect(d.repetitionPenalty == 1.05)
    }

    @Test("Integer-typed temperature decodes as Float")
    func integerTemperatureDecodes() {
        // Some generators emit `"temperature": 1` (no decimal). Without the
        // NSNumber conversion helper, Swift's `as? Double` rejects these.
        let d = Self.defaults(
            fromJSON: #"""
                {"temperature": 1, "top_k": 40}
                """#
        )
        #expect(d.temperature == 1.0)
        #expect(d.topK == 40)
    }

    @Test("Malformed JSON returns empty defaults, does not throw")
    func malformedJsonReturnsEmpty() {
        let d = Self.defaults(fromJSON: #"not json"#)
        #expect(d == .empty)
    }

    @Test("Empty object returns empty defaults")
    func emptyObject() {
        let d = Self.defaults(fromJSON: #"{}"#)
        #expect(d == .empty)
    }

    // MARK: - Filesystem round-trip (integration)

    /// Write a `generation_config.json` to a scratch directory and verify
    /// the `load(fromDirectory:)` entry point hits the full filesystem path.
    /// This protects against silent breakage of the file-lookup side of the
    /// feature (e.g. mis-named filename, wrong subpath assumption, etc.).
    @Test("Filesystem round-trip: writes and reads generation_config.json")
    func filesystemRoundTrip() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("osaurus-gencfg-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cfg = tmp.appendingPathComponent("generation_config.json")
        try #"""
        {"temperature": 0.6, "top_p": 0.9, "top_k": 32}
        """#.write(to: cfg, atomically: true, encoding: .utf8)

        let d = LocalGenerationDefaults.load(fromDirectory: tmp)
        #expect(d.temperature == 0.6)
        #expect(d.topP == 0.9)
        #expect(d.topK == 32)
    }

    @Test("Missing generation_config.json returns empty, does not throw")
    func missingFile() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("osaurus-gencfg-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let d = LocalGenerationDefaults.load(fromDirectory: tmp)
        #expect(d == .empty)
    }

    // MARK: - Edge cases for the overlay precedence ladder

    /// Verify the `?? modelDefaults ?? fallback` ladder pattern used in
    /// `MLXBatchAdapter.generate`. Client-supplied values MUST win over
    /// model defaults; model defaults win over the hardcoded fallback.
    ///
    /// This test documents the exact semantics the adapter relies on — if
    /// this test fails, the adapter's precedence contract is broken.
    @Test("Precedence: client wins over model defaults")
    func clientWinsOverModel() {
        let modelDefaults = LocalGenerationDefaults.Defaults(
            temperature: 0.6,
            topP: 0.95,
            topK: 20,
            repetitionPenalty: nil
        )
        let clientTemp: Float? = 0.2
        let clientTopP: Float? = 0.5
        let serverFallbackTopP: Float = 1.0

        let temp = clientTemp ?? modelDefaults.temperature ?? 0.7
        let topP = clientTopP ?? modelDefaults.topP ?? serverFallbackTopP
        let topK = modelDefaults.topK ?? 0

        #expect(temp == 0.2)
        #expect(topP == 0.5)
        #expect(topK == 20)
    }

    @Test("Precedence: model defaults fill omitted client fields")
    func modelDefaultsFillGaps() {
        let modelDefaults = LocalGenerationDefaults.Defaults(
            temperature: 0.6,
            topP: 0.95,
            topK: 20,
            repetitionPenalty: nil
        )
        let clientTemp: Float? = nil
        let clientTopP: Float? = nil
        let serverFallbackTopP: Float = 1.0

        let temp = clientTemp ?? modelDefaults.temperature ?? 0.7
        let topP = clientTopP ?? modelDefaults.topP ?? serverFallbackTopP
        let topK = modelDefaults.topK ?? 0

        #expect(temp == 0.6)
        #expect(topP == 0.95)
        #expect(topK == 20)
    }

    @Test("Precedence: hardcoded fallback when neither client nor model set fields")
    func hardcodedFallbackWhenBothAbsent() {
        let modelDefaults = LocalGenerationDefaults.Defaults.empty
        let clientTemp: Float? = nil
        let clientTopP: Float? = nil
        let serverFallbackTopP: Float = 1.0

        let temp = clientTemp ?? modelDefaults.temperature ?? 0.7
        let topP = clientTopP ?? modelDefaults.topP ?? serverFallbackTopP
        let topK = modelDefaults.topK ?? 0

        #expect(temp == 0.7)
        #expect(topP == 1.0)
        #expect(topK == 0)
    }

    @Test("Precedence: temperature=0 (greedy) from client is honored, NOT replaced")
    func greedyDecodingHonored() {
        // OpenAI clients send `temperature: 0` to request deterministic
        // greedy decoding. Our overlay uses `??` which treats 0 as a
        // valid non-nil value — so the model's default should NOT replace it.
        // This test documents the invariant.
        let modelDefaults = LocalGenerationDefaults.Defaults(
            temperature: 0.6,
            topP: nil,
            topK: nil,
            repetitionPenalty: nil
        )
        let clientTemp: Float? = 0.0

        let temp = clientTemp ?? modelDefaults.temperature ?? 0.7

        #expect(temp == 0.0)
    }

    @Test("Cache: defaults(forModelId:) returns empty for unknown model")
    func unknownModelReturnsEmpty() {
        // `findInstalledModel` returns nil for a name we definitely didn't
        // install; the load path must short-circuit to `.empty` without
        // crashing or reaching the filesystem.
        let d = LocalGenerationDefaults.defaults(
            forModelId: "definitely-not-a-real-model-\(UUID().uuidString)"
        )
        #expect(d == .empty)
    }

    // MARK: - jang_config.json chat.sampling_defaults

    /// DSV4-Flash-JANGTQ: upstream HF `generation_config.json` specifies
    /// temperature=1.0, but DeepSeek's own `inference/generate.py` uses 0.6,
    /// and `convert_dsv4_jangtq.py` stamps the latter into
    /// `jang_config.json > chat > sampling_defaults`. osaurus must prefer it.
    @Test("jang_config: DSV4 chat.sampling_defaults (temp=0.6)")
    func jangConfigDSV4() {
        // Trimmed to the relevant keys; real jang_config.json carries
        // quantization + source_model + crack_surgery + more.
        let d = LocalGenerationDefaults.parseJangConfig(data: Data(#"""
            {
              "model_family": "deepseek_v4",
              "chat": {
                "encoder": "encoding_dsv4",
                "reasoning": {"supported": true, "modes": ["chat", "thinking"]},
                "tool_calling": {"parser": "dsml"},
                "sampling_defaults": {
                  "temperature": 0.6,
                  "top_p": 0.95,
                  "max_new_tokens": 300
                }
              },
              "quantization": {"profile": "JANGTQ4"}
            }
            """#.utf8))
        #expect(d.temperature == 0.6)
        #expect(d.topP == 0.95)
        // `max_new_tokens` is not a GenerationParameters field we honor at
        // the sampling layer; intentionally ignored.
        #expect(d.topK == nil)
        #expect(d.repetitionPenalty == nil)
    }

    @Test("jang_config: all sampling fields populate when present")
    func jangConfigAllFields() {
        let d = LocalGenerationDefaults.parseJangConfig(data: Data(#"""
            {
              "chat": {
                "sampling_defaults": {
                  "temperature": 0.8,
                  "top_p": 0.9,
                  "top_k": 50,
                  "repetition_penalty": 1.05
                }
              }
            }
            """#.utf8))
        #expect(d.temperature == 0.8)
        #expect(d.topP == 0.9)
        #expect(d.topK == 50)
        #expect(d.repetitionPenalty == 1.05)
    }

    @Test("jang_config: older JANG bundles without chat subtree return empty")
    func jangConfigNoChatSubtree() {
        // Older JANG schema — only quantization + source_model + crack_surgery.
        // No chat metadata. Must return empty, not throw.
        let d = LocalGenerationDefaults.parseJangConfig(data: Data(#"""
            {
              "quantization": {"profile": "JANG_2S", "actual_bits": 2.11},
              "source_model": {"name": "Qwen3.5-122B-A10B"},
              "format": "jang"
            }
            """#.utf8))
        #expect(d == .empty)
    }

    @Test("jang_config: chat present but no sampling_defaults returns empty")
    func jangConfigChatWithoutSampling() {
        // Schema transition: a bundle might have `chat.reasoning` and
        // `chat.tool_calling` but omit `chat.sampling_defaults`. Must not
        // throw; must return empty so caller falls through to HF file.
        let d = LocalGenerationDefaults.parseJangConfig(data: Data(#"""
            {"chat": {"reasoning": {"supported": true}}}
            """#.utf8))
        #expect(d == .empty)
    }

    @Test("jang_config: malformed JSON returns empty")
    func jangConfigMalformed() {
        let d = LocalGenerationDefaults.parseJangConfig(data: Data("not json".utf8))
        #expect(d == .empty)
    }

    // MARK: - merge(primary:fallback:) — overlay semantics

    @Test("merge: primary fills first, fallback fills gaps (DSV4 real case)")
    func mergePrimaryWinsFallbackFills() {
        // jang_config says temp=0.6. generation_config.json says
        // temp=1.0, top_k=64 (Gemma-4 shape). Result: temp from JANG
        // (primary), top_k from HF (fallback).
        let jang = LocalGenerationDefaults.Defaults(
            temperature: 0.6, topP: nil, topK: nil, repetitionPenalty: nil)
        let hf = LocalGenerationDefaults.Defaults(
            temperature: 1.0, topP: 0.95, topK: 64, repetitionPenalty: nil)
        let merged = LocalGenerationDefaults.merge(primary: jang, fallback: hf)
        #expect(merged.temperature == 0.6)
        #expect(merged.topP == 0.95)
        #expect(merged.topK == 64)
    }

    @Test("merge: primary-only fields preserved")
    func mergePrimaryOnly() {
        let jang = LocalGenerationDefaults.Defaults(
            temperature: 0.6, topP: 0.9, topK: 32, repetitionPenalty: 1.05)
        let merged = LocalGenerationDefaults.merge(
            primary: jang, fallback: LocalGenerationDefaults.Defaults.empty)
        #expect(merged.temperature == 0.6)
        #expect(merged.topP == 0.9)
        #expect(merged.topK == 32)
        #expect(merged.repetitionPenalty == 1.05)
    }

    @Test("merge: fallback-only fields preserved when primary empty")
    func mergeFallbackOnly() {
        let hf = LocalGenerationDefaults.Defaults(
            temperature: 1.0, topP: 0.95, topK: 64, repetitionPenalty: nil)
        let merged = LocalGenerationDefaults.merge(
            primary: LocalGenerationDefaults.Defaults.empty, fallback: hf)
        #expect(merged.temperature == 1.0)
        #expect(merged.topP == 0.95)
        #expect(merged.topK == 64)
    }

    // MARK: - Integration: filesystem with BOTH files

    @Test("Filesystem: bundle with BOTH jang_config and generation_config merges")
    func bothFilesMerge() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "osaurus-gencfg-both-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // HF file ships upstream's training defaults.
        try #"""
            {"temperature": 1.0, "top_p": 0.95, "top_k": 64}
            """#.write(
                to: tmp.appendingPathComponent("generation_config.json"),
                atomically: true, encoding: .utf8)
        // JANG config overrides ONLY temperature (DSV4 pattern).
        try #"""
            {"chat": {"sampling_defaults": {"temperature": 0.6}}}
            """#.write(
                to: tmp.appendingPathComponent("jang_config.json"),
                atomically: true, encoding: .utf8)

        let d = LocalGenerationDefaults.load(fromDirectory: tmp)
        // JANG overrides for the field it sets…
        #expect(d.temperature == 0.6)
        // …HF fills the rest.
        #expect(d.topP == 0.95)
        #expect(d.topK == 64)
    }

    @Test("Filesystem: jang_config alone suffices (HF file absent)")
    func jangOnlyLoad() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "osaurus-gencfg-jang-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try #"""
            {"chat": {"sampling_defaults": {"temperature": 0.6, "top_p": 0.95}}}
            """#.write(
                to: tmp.appendingPathComponent("jang_config.json"),
                atomically: true, encoding: .utf8)

        let d = LocalGenerationDefaults.load(fromDirectory: tmp)
        #expect(d.temperature == 0.6)
        #expect(d.topP == 0.95)
    }

    @Test("Filesystem: jang_config with NO sampling_defaults, HF file has them")
    func jangConfigNoSamplingFallsThroughToHF() throws {
        // An older JANG bundle (no chat metadata) alongside an HF
        // generation_config.json. Merge must NOT use jang_config (nothing
        // useful in it) and must surface HF's values.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "osaurus-gencfg-jang-noop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try #"""
            {"quantization": {"profile": "JANG_2S"}, "format": "jang"}
            """#.write(
                to: tmp.appendingPathComponent("jang_config.json"),
                atomically: true, encoding: .utf8)
        try #"""
            {"temperature": 1.0, "top_k": 64, "top_p": 0.95}
            """#.write(
                to: tmp.appendingPathComponent("generation_config.json"),
                atomically: true, encoding: .utf8)

        let d = LocalGenerationDefaults.load(fromDirectory: tmp)
        #expect(d.temperature == 1.0)
        #expect(d.topK == 64)
        #expect(d.topP == 0.95)
    }
}
