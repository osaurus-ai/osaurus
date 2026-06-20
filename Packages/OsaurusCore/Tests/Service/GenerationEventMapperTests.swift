//
//  GenerationEventMapperTests.swift
//  osaurusTests
//
//  Tests for `GenerationEventMapper` — translates vmlx-swift-lm `Generation`
//  events into osaurus `ModelRuntimeEvent`. Tool-call parsing, reasoning
//  extraction, and text-level stop matching are all owned by vmlx; these
//  tests only exercise the bridge.
//

import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite("GenerationEventMapper bridge behaviour")
struct GenerationEventMapperTests {

    private func makeStream(_ events: [Generation]) -> AsyncStream<Generation> {
        AsyncStream { continuation in
            for ev in events { continuation.yield(ev) }
            continuation.finish()
        }
    }

    private func collect(
        events: [Generation],
        modelName: String = ""
    ) async throws -> [ModelRuntimeEvent] {
        let stream = makeStream(events)
        let mapped = GenerationEventMapper.map(events: stream, modelName: modelName)
        var out: [ModelRuntimeEvent] = []
        for try await ev in mapped { out.append(ev) }
        return out
    }

    @Test func chunk_passes_through_as_tokens() async throws {
        let events: [Generation] = [
            .chunk("Hello, "),
            .chunk("world!"),
        ]
        let out = try await collect(events: events)
        var assembled = ""
        for ev in out {
            if case .tokens(let s) = ev { assembled += s }
        }
        #expect(assembled == "Hello, world!")
    }

    @Test func toolCall_emits_serialized_arguments() async throws {
        // ToolCall.Function only exposes
        //   `init(name:, arguments: [String: any Sendable])`
        // which internally maps each value through `JSONValue.from(_:)`.
        // Pass primitive Sendable values so the conversion picks the
        // matching JSONValue case (string/int/...).
        let args: [String: any Sendable] = [
            "q": "hi",
            "n": 3,
        ]
        let call = MLXLMCommon.ToolCall(
            function: MLXLMCommon.ToolCall.Function(
                name: "lookup",
                arguments: args
            )
        )
        let events: [Generation] = [.toolCall(call)]
        let out = try await collect(events: events)
        guard case .toolInvocation(let name, let argsJSON) = out.first else {
            Issue.record("expected toolInvocation, got \(String(describing: out.first))")
            return
        }
        #expect(name == "lookup")
        // JSON is unordered; assert by parsing back.
        let parsed = try JSONSerialization.jsonObject(with: Data(argsJSON.utf8)) as? [String: Any]
        #expect(parsed?["q"] as? String == "hi")
        #expect((parsed?["n"] as? Int) == 3 || (parsed?["n"] as? Double) == 3.0)
    }

    @Test func info_emits_completionInfo() async throws {
        let info = GenerateCompletionInfo(
            promptTokenCount: 12,
            generationTokenCount: 8,
            promptTime: 0.1,
            generationTime: 0.2
        )
        let events: [Generation] = [.chunk("ok"), .info(info)]
        let out = try await collect(events: events)
        guard case .completionInfo(let count, let tps, let unclosed, let stopReason, _) = out.last else {
            Issue.record("expected completionInfo at end, got \(String(describing: out.last))")
            return
        }
        #expect(count == 8)
        #expect(tps > 0)
        // Default-constructed GenerateCompletionInfo carries unclosedReasoning=false;
        // a healthy stream that emitted </think> properly should mirror that here.
        #expect(unclosed == false)
        #expect(stopReason == "stop")
    }

    @Test func info_propagates_unclosedReasoning_when_trapped() async throws {
        let info = GenerateCompletionInfo(
            promptTokenCount: 11,
            generationTokenCount: 1024,
            promptTime: 0.1,
            generationTime: 90.0,
            stopReason: .length,
            unclosedReasoning: true
        )
        let events: [Generation] = [.reasoning("Self-Correction…"), .info(info)]
        let out = try await collect(events: events)
        guard case .completionInfo(_, _, let unclosed, let stopReason, _) = out.last else {
            Issue.record("expected completionInfo at end, got \(String(describing: out.last))")
            return
        }
        #expect(
            unclosed == true,
            "vmlx flagged trapped-thinking; mapper must surface it on the runtime event."
        )
        #expect(stopReason == "length")
    }

    @Test func info_propagates_unclosedReasoning_for_minimax_thinkingRail() async throws {
        let info = GenerateCompletionInfo(
            promptTokenCount: 11,
            generationTokenCount: 32,
            promptTime: 0.1,
            generationTime: 2.0,
            stopReason: .stop,
            unclosedReasoning: true
        )
        let out = try await collect(
            events: [.reasoning("The user is straightforward greeting"), .info(info)],
            modelName: "JANGQ-AI/MiniMax-M2.7-JANGTQ"
        )
        guard case .completionInfo(_, _, let unclosed, _, _) = out.last else {
            Issue.record("expected completionInfo at end, got \(String(describing: out.last))")
            return
        }
        #expect(
            unclosed == true,
            "MiniMax thinking-on output must preserve trapped-thinking diagnostics on the reasoning rail."
        )
    }

    @Test func empty_chunks_are_ignored() async throws {
        let events: [Generation] = [.chunk(""), .chunk("text"), .chunk("")]
        let out = try await collect(events: events)
        let texts: [String] = out.compactMap {
            if case .tokens(let s) = $0 { return s } else { return nil }
        }
        #expect(texts == ["text"])
    }

    @Test func reasoning_event_emits_reasoning_runtime_event() async throws {
        // vmlx-swift-lm's BatchEngine emits `Generation.reasoning(String)`
        // deltas on a separate channel from `.chunk`. The mapper must
        // forward each one as `ModelRuntimeEvent.reasoning` while keeping
        // chunk tokens on the `.tokens` channel.
        let events: [Generation] = [
            .reasoning("alpha"),
            .reasoning("beta"),
            .chunk("answer"),
        ]
        let out = try await collect(events: events)

        var reasoningPieces: [String] = []
        var tokenPieces: [String] = []
        for ev in out {
            switch ev {
            case .reasoning(let s): reasoningPieces.append(s)
            case .tokens(let s): tokenPieces.append(s)
            default: continue
            }
        }
        #expect(reasoningPieces == ["alpha", "beta"])
        #expect(tokenPieces == ["answer"])
    }

    @Test func prefillProgress_emits_runtime_progress_event() async throws {
        let events: [Generation] = [
            .prefillProgress(
                PrefillProgress(
                    stage: .cacheRestore,
                    completedUnitCount: 512,
                    totalUnitCount: 2048,
                    detail: "disk L2"
                )
            ),
            .prefillProgress(
                PrefillProgress(
                    stage: .prefill,
                    completedUnitCount: 1024,
                    totalUnitCount: 2048,
                    detail: "model.prepare"
                )
            ),
            .chunk("answer"),
        ]
        let out = try await collect(events: events)
        let progress = out.compactMap {
            if case .prefillProgress(let state) = $0 { state } else { nil }
        }
        #expect(progress.count == 2)
        #expect(progress[0].stage == .cacheRestore)
        #expect(progress[0].completedUnitCount == 512)
        #expect(progress[0].totalUnitCount == 2048)
        #expect(progress[0].detail == "disk L2")
        #expect(progress[1].stage == .prefill)
        #expect(progress[1].percentCompleted == 50)
    }

    @Test func empty_reasoning_is_skipped() async throws {
        let events: [Generation] = [
            .reasoning(""),
            .reasoning("kept"),
            .reasoning(""),
        ]
        let out = try await collect(events: events)
        let reasoning: [String] = out.compactMap {
            if case .reasoning(let s) = $0 { return s } else { return nil }
        }
        #expect(reasoning == ["kept"])
    }

    /// Ling/Bailing uses the same typed reasoning channel as other local
    /// reasoning-capable families. If a no-thinking prompt still emits
    /// `.reasoning`, that is a runtime/template/parser row to root-cause, not
    /// something Osaurus should hide by merging reasoning into visible content.
    @Test func reasoning_stays_separate_for_ling_family() async throws {
        let events: [Generation] = [
            .chunk("Hi! "),
            .reasoning("(silent thinking that would otherwise hang the UI)"),
            .chunk(" 7×6=42."),
        ]
        for modelName in [
            "OsaurusAI/Ling-2.6-flash-MXFP4",
            "ling-2.6-flash-mxfp4",
            "JANGQ-AI/Ling-2.6-flash-JANGTQ2-CRACK",
        ] {
            let out = try await collect(events: events, modelName: modelName)
            #expect(
                out.contains(where: { if case .reasoning = $0 { true } else { false } }),
                "Ling reasoning must stay on the reasoning rail for root-cause visibility: \(modelName)"
            )
            let assembled = out.compactMap {
                if case .tokens(let s) = $0 { s } else { nil }
            }.joined()
            #expect(
                assembled == "Hi!  7×6=42.",
                "Ling visible content must not include hidden reasoning text: \(modelName) — got \(assembled)"
            )
        }
    }

    /// MiniMax M2/M2.7 opens `<think>` directly in the assistant generation
    /// prompt when Thinking is enabled. That output must remain on the
    /// reasoning rail so ChatView renders the Thinking block and can switch to
    /// visible content only after vmlx observes `</think>`.
    @Test func reasoning_stays_separate_for_minimax_family() async throws {
        let events: [Generation] = [
            .reasoning("The user is straightforward greeting. "),
            .reasoning("I should answer briefly."),
        ]
        for modelName in [
            "MiniMax-M2.7-JANGTQ",
            "JANGQ-AI/MiniMax-M2.7-JANGTQ",
            "OsaurusAI/MiniMax-M2.7-JANGTQ4",
            "minimax_m2",
        ] {
            let out = try await collect(events: events, modelName: modelName)
            #expect(
                !out.contains(where: { if case .tokens = $0 { true } else { false } }),
                "MiniMax thinking-on deltas must not be promoted to content before `</think>`: \(modelName)"
            )
            let reasoning = out.compactMap {
                if case .reasoning(let s) = $0 { s } else { nil }
            }.joined()
            #expect(
                reasoning == "The user is straightforward greeting. I should answer briefly.",
                "MiniMax thinking-on deltas must remain renderable in the Thinking block: \(modelName)"
            )
        }
    }

    @Test func missing_terminal_info_synthesizes_completion_for_reasoning_only_stream() async throws {
        let out = try await collect(
            events: [
                .reasoning("The user is straightforward greeting. "),
                .reasoning("I should answer briefly."),
            ],
            modelName: "JANGQ-AI/MiniMax-M2.7-JANGTQ"
        )
        guard case .completionInfo(let count, _, let unclosed, let stopReason, _) = out.last else {
            Issue.record("expected synthesized completionInfo at end, got \(String(describing: out.last))")
            return
        }
        #expect(count > 0)
        #expect(unclosed == true)
        #expect(stopReason == nil)
    }

    /// ZAYA1 (Zyphra; `model_type=zaya`) is reasoning-capable. Unlike Ling,
    /// its `.reasoning` stream must stay on the reasoning channel so the UI
    /// can render the Thinking panel when the user opts in.
    @Test func reasoning_stays_separate_for_zaya_family() async throws {
        let events: [Generation] = [
            .chunk("Hello! "),
            .reasoning("(zaya hidden reasoning)"),
        ]
        for modelName in [
            "Zyphra/Zaya1-8B-JANGTQ4",
            "zaya1-8b-mxfp4",
            "Zyphra/Zaya-S-7B-Future",
        ] {
            let out = try await collect(events: events, modelName: modelName)
            let assembled = out.compactMap {
                if case .tokens(let s) = $0 { s } else { nil }
            }.joined()
            let reasoning = out.compactMap {
                if case .reasoning(let s) = $0 { s } else { nil }
            }
            #expect(assembled == "Hello! ")
            #expect(reasoning == ["(zaya hidden reasoning)"])
        }
    }

    /// Reasoning-capable families (Qwen3, Nemotron, OpenAI o-series, Auto)
    /// must keep the channel split so the UI can render thinking panels.
    /// ZAYA is included here to guard the corrected policy: it is
    /// reasoning-capable and must not trip the Ling-only merge.
    @Test func reasoning_stays_separate_for_other_families() async throws {
        let events: [Generation] = [
            .chunk("answer "),
            .reasoning("alpha"),
            .reasoning("beta"),
        ]
        for modelName in [
            "OsaurusAI/Qwen3.6-35B-A3B-mxfp4",
            "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4",
            "Zyphra/Zaya1-8B-JANGTQ4",
            "lmstudio-community/gpt-oss-20b-MLX-8bit",
            "dataset/notminimax_m2",
            "not-minimaxed",
            "dataset/zayasaurus",  // ZAYA boundary regression
            "lazyaardvark",  // ZAYA boundary regression
            "",  // empty — default branch
        ] {
            let out = try await collect(events: events, modelName: modelName)
            let reasoning = out.compactMap {
                if case .reasoning(let s) = $0 { s } else { nil }
            }
            #expect(
                reasoning == ["alpha", "beta"],
                "non-Ling families must keep reasoning channel split: \(modelName)"
            )
        }
    }

    @Test func toolCall_serialization_failure_emits_error_envelope() async throws {
        // `JSONSerialization` rejects non-finite Doubles unless
        // `.fragmentsAllowed` is passed. Feed a `Double.infinity`
        // primitive so `JSONValue.from(_:)` produces `.double(.infinity)`
        // and the mapper's `serializeArguments` hits its error-envelope
        // branch — asserting the structured error reaches the emitted
        // `argsJSON` instead of the silent `{}` fallback we used to ship.
        let args: [String: any Sendable] = [
            "value": Double.infinity
        ]
        let call = MLXLMCommon.ToolCall(
            function: MLXLMCommon.ToolCall.Function(
                name: "broken",
                arguments: args
            )
        )
        let out = try await collect(events: [.toolCall(call)])
        guard case .toolInvocation(let name, let argsJSON) = out.first else {
            Issue.record("expected toolInvocation, got \(String(describing: out.first))")
            return
        }
        #expect(name == "broken")
        #expect(argsJSON.contains("\"_error\":\"argument_serialization_failed\""))
        #expect(argsJSON.contains("\"_tool\":\"broken\""))
    }
}
