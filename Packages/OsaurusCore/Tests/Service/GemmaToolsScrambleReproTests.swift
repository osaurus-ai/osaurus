//
//  GemmaToolsScrambleReproTests.swift
//  osaurusTests
//
//  Regression guard for the "Gemma + tools (Sandbox) scrambles text" bug.
//
//  Root cause (proven, model-free): when a Gemma tool format is active, every
//  chunk flows through `ToolCallProcessor`. Gemma's bare-call fallback buffers
//  any trailing "c"/"ca"/"cal"/"call" (a possible start of the `call:` tool
//  marker). When the buffered fragment did NOT continue into a tool call, the
//  held text was neither flushed in order nor cleared, so ordinary prose lost
//  and reordered characters ("cobblestone" -> "obblestone", "calm" emitted at
//  EOS, etc.). Gemma is the only family with bare-call fallback, which is why
//  only Gemma corrupted prose.
//
//  Fix: in the bare-call `.normal` path, flush the held fragment together with
//  the current chunk, in order, once it is no longer a `call:` prefix; and emit
//  partial-fragment leading text verbatim instead of dropping whitespace-only
//  leads.
//
//  These tests are model-free and deterministic: they drive the exact server
//  routing layer (`routeGenerationText`) with text we control, so a failure
//  here isolates the bug to `ToolCallProcessor` (not the model, KV, quant, or
//  detokenization).
//

import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

struct GemmaToolsScrambleReproTests {

    private func weatherToolSchema() -> [[String: any Sendable]] {
        let parameters: [String: any Sendable] = [
            "type": "object",
            "properties": ["location": ["type": "string"] as [String: any Sendable]]
                as [String: any Sendable],
            "required": ["location"],
        ]
        let function: [String: any Sendable] = ["name": "get_weather", "parameters": parameters]
        return [["type": "function", "function": function] as [String: any Sendable]]
    }

    private func reassembleVisible(_ chunks: [String], through proc: ToolCallProcessor?)
        -> (text: String, calls: [MLXLMCommon.ToolCall])
    {
        var out = ""
        var calls: [MLXLMCommon.ToolCall] = []
        for c in chunks {
            for ev in routeGenerationText(c, channel: .content, through: proc) {
                if case .chunk(let s) = ev { out += s }
                if case .toolCall(let t) = ev { calls.append(t) }
            }
        }
        for ev in flushGenerationText(channel: .content, through: proc) {
            if case .chunk(let s) = ev { out += s }
            if case .toolCall(let t) = ev { calls.append(t) }
        }
        return (out, calls)
    }

    private func chunked(_ s: String, size: Int) -> [String] {
        var r: [String] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: size, limitedBy: s.endIndex) ?? s.endIndex
            r.append(String(s[i ..< j]))
            i = j
        }
        return r
    }

    private func firstDiff(_ a: String, _ b: String) -> String {
        let x = Array(a), y = Array(b)
        var k = 0
        while k < min(x.count, y.count), x[k] == y[k] { k += 1 }
        let ca = String(x[max(0, k - 18) ..< min(x.count, k + 18)])
        let cb = String(y[max(0, k - 18) ..< min(y.count, k + 18)])
        return "len in=\(x.count) out=\(b.count); first diff @\(k)\n      IN : …\(ca)…\n      OUT: …\(cb)…"
    }

    // Plain prose that contains many `c` words (each a false `call:` prefix) plus
    // whitespace/markdown — the exact regime that scrambled live on Gemma 12B.
    private let prose = """
        Palm Springs is a spectacular desert oasis. Many resorts feature massive \
        pools with kids' areas, perfect for beating the desert heat. Ivory towers \
        with gilded domes rise above cobblestone streets, a masterpiece of \
        architectural elegance and a breathtaking getaway. Stay at the \
        Ritz-Carlton; it often has family-friendly exhibits.
        """

    @Test("through:nil is verbatim at every chunk size (no-tools path)")
    func nilProcessorIsVerbatim() {
        for size in [1, 2, 3, 4, 8] {
            let got = reassembleVisible(chunked(prose, size: size), through: ToolCallProcessor?.none)
            #expect(got.text == prose, "through:nil size=\(size):\n      \(firstDiff(prose, got.text))")
        }
    }

    @Test("gemma4 + tools preserves plain prose byte-exact (the bug)")
    func gemma4PreservesProse() {
        for size in [1, 2, 3, 4, 8] {
            let proc = ToolCallProcessor(format: .gemma4, tools: weatherToolSchema())
            let got = reassembleVisible(chunked(prose, size: size), through: proc)
            #expect(got.text == prose, "gemma4 size=\(size):\n      \(firstDiff(prose, got.text))")
            #expect(got.calls.isEmpty, "gemma4 size=\(size) hallucinated a tool call from prose")
        }
    }

    @Test("gemma (legacy) + tools also preserves plain prose byte-exact")
    func gemmaLegacyPreservesProse() {
        for size in [1, 2, 3, 4, 8] {
            let proc = ToolCallProcessor(format: .gemma, tools: weatherToolSchema())
            let got = reassembleVisible(chunked(prose, size: size), through: proc)
            #expect(got.text == prose, "gemma size=\(size):\n      \(firstDiff(prose, got.text))")
        }
    }

    @Test("no tool format corrupts plain prose")
    func noFormatCorruptsProse() {
        let formats: [ToolCallFormat] = [
            .json, .gemma, .gemma4, .xmlFunction, .glm4, .nemotron, .dsml, .lfm2, .step,
        ]
        for f in formats {
            let proc = ToolCallProcessor(format: f, tools: nil)
            let got = reassembleVisible(chunked(prose, size: 3), through: proc)
            #expect(got.text == prose, "format \(f.rawValue) corrupted prose:\n      \(firstDiff(prose, got.text))")
        }
    }

    // POSITIVE: prose preceding a real bare `call:` tool call is still emitted
    // byte-exact — proves the prose-preservation fix did not eat the lead-in.
    // (Note: streaming of the *unwrapped* `call:` form can leave a residual
    // marker — a pre-existing limitation, identical before this fix; Gemma
    // emits the wrapped `<|tool_call>…` envelope in practice, covered below.)
    @Test("gemma4 keeps prose before a bare call: tool marker")
    func gemma4KeepsProseBeforeBareCall() {
        for size in [1, 2, 3, 8] {
            let proc = ToolCallProcessor(format: .gemma4, tools: weatherToolSchema())
            let stream = "The weather report follows next.call:get_weather{location:'Tokyo'}"
            let got = reassembleVisible(chunked(stream, size: size), through: proc)
            #expect(
                got.text.hasPrefix("The weather report follows next."),
                "size=\(size) corrupted prose before tool call: \(got.text.debugDescription)"
            )
        }
    }

    // POSITIVE: the full native envelope still parses with no visible leak.
    @Test("gemma4 still parses the native <|tool_call> envelope")
    func gemma4ParsesNativeEnvelope() throws {
        for size in [1, 3, 8] {
            let proc = ToolCallProcessor(format: .gemma4, tools: weatherToolSchema())
            let stream = "<|tool_call>call:get_weather{location:<|\"|>Tokyo<|\"|>}<tool_call|>"
            let got = reassembleVisible(chunked(stream, size: size), through: proc)
            #expect(
                got.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "size=\(size) leaked envelope text: \(got.text.debugDescription)"
            )
            #expect(got.calls.count == 1, "size=\(size) expected 1 tool call, got \(got.calls.count)")
            #expect(got.calls.first?.function.name == "get_weather")
        }
    }
}
