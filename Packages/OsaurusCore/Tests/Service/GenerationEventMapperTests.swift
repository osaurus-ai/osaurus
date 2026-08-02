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

    @Test func toolCallProgress_passes_through_with_committed_call() async throws {
        // While the engine buffers a tool-call envelope it now streams
        // `.toolCallProgress` deltas (raw envelope text), then the committed
        // `.toolCall` once it closes. The bridge must forward each progress
        // delta as `.toolCallProgress` AND still surface the final call as
        // `.toolInvocation` — the progress event never replaces the call.
        let args: [String: any Sendable] = ["path": "/tmp/a.txt"]
        let call = MLXLMCommon.ToolCall(
            function: MLXLMCommon.ToolCall.Function(
                name: "write_file",
                arguments: args
            )
        )
        let events: [Generation] = [
            .toolCallProgress("<tool_call>{\"name\": \"write_"),
            .toolCallProgress("file\", \"arguments\": {\"path\":"),
            .toolCallProgress(" \"/tmp/a.txt\"}}"),
            .toolCall(call),
        ]
        let out = try await collect(events: events)

        let progressDeltas = out.compactMap { ev -> String? in
            if case .toolCallProgress(let s) = ev { return s } else { return nil }
        }
        #expect(progressDeltas.count == 3)
        #expect(progressDeltas.joined().contains("write_file"))

        #expect(
            out.contains { if case .toolInvocation(let n, _) = $0 { n == "write_file" } else { false } }
        )
    }

    @Test func toolCall_preserves_valid_native_argument_order() async throws {
        let call = MLXLMCommon.ToolCall(
            function: MLXLMCommon.ToolCall.Function(
                name: "ordered",
                arguments: [
                    "zeta": .int(7),
                    "alpha": .string("ready"),
                ],
                rawArgumentsJSON: "{\"zeta\": 7, \"alpha\": \"ready\"}"
            )
        )
        let out = try await collect(events: [.toolCall(call)])
        guard case .toolInvocation(_, let argsJSON) = out.first else {
            Issue.record("expected toolInvocation")
            return
        }
        #expect(argsJSON == "{\"zeta\": 7, \"alpha\": \"ready\"}")
    }

    @Test func toolCall_rejects_mismatched_raw_argument_text() async throws {
        let call = MLXLMCommon.ToolCall(
            function: MLXLMCommon.ToolCall.Function(
                name: "ordered",
                arguments: ["count": .int(2)],
                rawArgumentsJSON: "{\"count\": 999}"
            )
        )
        let out = try await collect(events: [.toolCall(call)])
        guard case .toolInvocation(_, let argsJSON) = out.first else {
            Issue.record("expected toolInvocation")
            return
        }
        let decoded = try JSONDecoder().decode(
            [String: MLXLMCommon.JSONValue].self,
            from: Data(argsJSON.utf8)
        )
        #expect(decoded == ["count": .int(2)])
        #expect(argsJSON != "{\"count\": 999}")
    }

    @Test func toolCallProgress_drops_empty_deltas() async throws {
        // Empty envelope deltas carry no preview and must not produce events.
        let events: [Generation] = [.toolCallProgress("")]
        let out = try await collect(events: events)
        #expect(!out.contains { if case .toolCallProgress = $0 { true } else { false } })
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

    @Test("consumer cancellation directly cancels the owned runtime generation")
    func consumerCancellationInvokesDirectGenerationCancellation() async {
        let (events, producer) = AsyncStream<Generation>.makeStream()
        let probe = MapperCancellationProbe()
        let mapped = GenerationEventMapper.map(
            events: events,
            modelName: "cancel-owned-generation",
            onConsumerCancellation: {
                probe.markCancellation()
            }
        )

        let consumer = Task {
            do {
                for try await _ in mapped {
                    probe.markEvent()
                }
            } catch {
                // Cancellation is the expected test exit.
            }
        }

        producer.yield(.chunk("started"))
        for _ in 0 ..< 100 where !probe.sawEvent {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(probe.sawEvent)

        consumer.cancel()
        await consumer.value
        for _ in 0 ..< 100 where !probe.sawCancellation {
            try? await Task.sleep(for: .milliseconds(10))
        }
        producer.finish()

        #expect(
            probe.sawCancellation,
            "dropping a cancelled consumer must directly cancel its exact ModelRuntime generation wrapper"
        )
    }

    @Test("terminal info finishes the surface while upstream cleanup remains open")
    func terminalInfoFinishesSurfaceBeforeCleanupDrain() async throws {
        let (events, producer) = AsyncStream<Generation>.makeStream()
        let cancellationProbe = MapperCancellationProbe()
        let mapped = GenerationEventMapper.map(
            events: events,
            modelName: "slow-cache-store",
            onConsumerCancellation: { cancellationProbe.markCancellation() }
        )

        let consumer = Task { () throws -> [ModelRuntimeEvent] in
            var output: [ModelRuntimeEvent] = []
            for try await event in mapped { output.append(event) }
            return output
        }

        producer.yield(.chunk("ready"))
        producer.yield(.info(GenerateCompletionInfo(
            promptTokenCount: 32,
            generationTokenCount: 1,
            promptTime: 0.25,
            generationTime: 0.05,
            stopReason: .stop
        )))

        let output = try await withThrowingTaskGroup(
            of: [ModelRuntimeEvent].self
        ) { group in
            group.addTask { try await consumer.value }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw MapperTestTimeout()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }

        #expect(output.contains { if case .tokens("ready") = $0 { true } else { false } })
        #expect(output.contains { if case .completionInfo = $0 { true } else { false } })
        #expect(!cancellationProbe.sawCancellation)

        // The user-facing consumer has completed even though the producer is
        // intentionally still open, modelling vmlx's serialized cache drain.
        producer.finish()
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

private struct MapperTestTimeout: Error {}

private final class MapperCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var event = false
    private var cancellation = false

    func markEvent() {
        lock.lock()
        event = true
        lock.unlock()
    }

    func markCancellation() {
        lock.lock()
        cancellation = true
        lock.unlock()
    }

    var sawEvent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return event
    }

    var sawCancellation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellation
    }
}
