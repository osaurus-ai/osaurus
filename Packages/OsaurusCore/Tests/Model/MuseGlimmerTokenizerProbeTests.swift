import Foundation
import Testing

@testable import OsaurusCore

/// Live Muse output was multilingual token soup while the model itself ran
/// fine — the signature of prompt framing or detokenization being wrong, not
/// of a bad quant. These probes run against the REAL local bundle (no app
/// build, no weights load) and check the three text-side contracts:
///
/// 1. every special token encodes to exactly ONE id in the 200000+ range —
///    a special that shatters into pieces feeds the model literal `<`, `|`,
///    `start` fragments and garbage framing produces garbage output;
/// 2. the chat template renders with `reasoning_strength` and emits exactly
///    one `Reasoning strength:` line;
/// 3. a plain string round-trips through encode/decode unchanged.
@Suite("Muse Glimmer tokenizer probe")
struct MuseGlimmerTokenizerProbeTests {

    static let bundle = URL(
        fileURLWithPath: NSHomeDirectory()
    ).appendingPathComponent("models/JANGQ-AI/Muse-Glimmer-30B-JANG_4M")

    static var bundleExists: Bool {
        FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent("tokenizer.json").path)
    }

    @Test("special tokens encode as single ids", .enabled(if: bundleExists))
    func specialsAreAtomic() async throws {
        let tokenizer = try await SwiftTransformersTokenizerLoader()
            .load(from: Self.bundle)

        // <|start|>assistant is the generation prompt; if the wrapper
        // shatters, every turn begins with garbage framing.
        for special in ["<|start|>", "<|message|>", "<|eot|>", "<|eom|>"] {
            let ids = tokenizer.encode(text: special, addSpecialTokens: false)
            #expect(ids.count == 1, "\(special) split into \(ids) — specials not registered")
            if let id = ids.first {
                #expect(id >= 200_000, "\(special) → \(id), expected reserved range")
            }
        }
    }

    @Test("template renders one reasoning line and the assistant opener",
        .enabled(if: bundleExists))
    func templateRendersStrength() async throws {
        let tokenizer = try await SwiftTransformersTokenizerLoader()
            .load(from: Self.bundle)

        let ids = try tokenizer.applyChatTemplate(
            messages: [["role": "user", "content": "hi"]],
            tools: nil,
            additionalContext: ["reasoning_strength": "low", "add_generation_prompt": true])
        let rendered = tokenizer.decode(tokenIds: ids, skipSpecialTokens: false)

        let strengthLines = rendered.components(separatedBy: "Reasoning strength:").count - 1
        #expect(strengthLines == 1, "expected exactly 1 strength line, got \(strengthLines)")
        #expect(rendered.contains("Reasoning strength: low"),
            "reasoning_strength variable did not reach the template")
        #expect(rendered.contains("<|start|>assistant"),
            "generation prompt missing — template not applied")
        #expect(!rendered.hasSuffix("<|message|>"),
            "generation prompt must NOT end with <|message|>")
    }

    @Test("plain text round-trips", .enabled(if: bundleExists))
    func roundTrip() async throws {
        let tokenizer = try await SwiftTransformersTokenizerLoader()
            .load(from: Self.bundle)
        let text = "Insertion sort is fast on nearly-sorted arrays because shifts are short."
        let ids = tokenizer.encode(text: text, addSpecialTokens: false)
        let back = tokenizer.decode(tokenIds: ids, skipSpecialTokens: true)
        #expect(back == text, "round-trip mangled: \(back)")
    }

    @Test("all four strengths render, and only the strength line differs",
        .enabled(if: bundleExists))
    func allFourStrengthsRenderDistinctPrefixes() async throws {
        let tokenizer = try await SwiftTransformersTokenizerLoader()
            .load(from: Self.bundle)

        var rendered: [String: String] = [:]
        for level in ["low", "medium", "high", "xhigh"] {
            let ids = try tokenizer.applyChatTemplate(
                messages: [["role": "user", "content": "hi"]],
                tools: nil,
                additionalContext: [
                    "reasoning_strength": level, "add_generation_prompt": true,
                ])
            let text = tokenizer.decode(tokenIds: ids, skipSpecialTokens: false)
            rendered[level] = text

            let count = text.components(separatedBy: "Reasoning strength:").count - 1
            #expect(count == 1, "\(level): expected 1 strength line, got \(count)")
            #expect(text.contains("Reasoning strength: \(level)"),
                "\(level) did not reach the template")
        }

        // Every level must produce a DIFFERENT prompt — that is what forces a
        // cold prefill on an effort flip, and what the scope salt has to key on.
        let unique = Set(rendered.values)
        #expect(unique.count == 4, "levels collapsed to \(unique.count) distinct prompts")

        // …and they must differ ONLY at the strength word: erasing the level
        // from each should make them identical. If anything else moves, the
        // prefix divergence is wider than the salt models.
        let normalized = Set(rendered.map { level, text in
            text.replacingOccurrences(of: "Reasoning strength: \(level)",
                                      with: "Reasoning strength: <LEVEL>")
        })
        #expect(normalized.count == 1,
            "levels differ beyond the strength word: \(normalized.count) shapes")
    }

    @Test("the strength line lands in the system prefix, not the tail",
        .enabled(if: bundleExists))
    func strengthLineIsInThePrefix() async throws {
        let tokenizer = try await SwiftTransformersTokenizerLoader()
            .load(from: Self.bundle)
        let ids = try tokenizer.applyChatTemplate(
            messages: [["role": "user", "content": "hello there"]],
            tools: nil,
            additionalContext: ["reasoning_strength": "high", "add_generation_prompt": true])
        let text = tokenizer.decode(tokenIds: ids, skipSpecialTokens: false)

        guard let strengthAt = text.range(of: "Reasoning strength:"),
              let userAt = text.range(of: "hello there")
        else {
            Issue.record("template missing the strength line or the user turn")
            return
        }
        // Strength precedes the user turn ⇒ an effort flip invalidates the
        // whole prefix; no suffix-only reuse is possible for this family.
        #expect(strengthAt.lowerBound < userAt.lowerBound,
            "strength line is not in the prefix — cache reasoning would be wrong")
    }
}
