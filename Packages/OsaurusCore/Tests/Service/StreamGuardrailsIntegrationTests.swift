//
//  StreamGuardrailsIntegrationTests.swift
//  osaurusTests
//
//  Template-leak detector unit coverage plus the GenerationEventMapper
//  wiring for both live guardrails: a degenerating stream must finish with
//  a thrown `StreamGuardrailError`, a clean stream must pass through
//  byte-for-byte, leak detection must be log-only (never mutate, never
//  throw) and content-channel-only, and each flag must disable exactly its
//  own detector.
//

import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite("StreamTemplateLeakDetector")
struct StreamTemplateLeakDetectorTests {

    @Test func tokenSplitAcrossTwoDeltasIsDetected() {
        var detector = StreamTemplateLeakDetector()
        #expect(detector.observe("Sure! <|im_st") == nil)
        #expect(detector.observe("art|> hello") == "<|im_start|>")
    }

    @Test func everyLeakTokenIsDetectedWhole() {
        for token in StreamTemplateLeakDetector.leakTokens {
            var detector = StreamTemplateLeakDetector()
            #expect(
                detector.observe("prefix \(token) suffix") == token,
                "leak token must be detected: \(token)"
            )
        }
    }

    @Test func detectorLatchesAfterFirstHit() {
        // One log line per stream is enough signal; later hits stay silent.
        var detector = StreamTemplateLeakDetector()
        #expect(detector.observe("<|im_end|>") == "<|im_end|>")
        #expect(detector.observe("<|im_end|>") == nil)
        #expect(detector.observe("<tool_call>") == nil)
    }

    @Test func thinkTagIsDeliberatelyNotALeak() {
        // Divergence from the CLI gauntlet's leak list: some families
        // legitimately emit <think> in content on the fallback path and the
        // engine owns reasoning-channel routing. If this expectation breaks,
        // someone re-added <think> — read the leakTokens doc comment first.
        var detector = StreamTemplateLeakDetector()
        #expect(detector.observe("<think>reasoning in content</think>") == nil)
    }

    @Test func cleanTextWithNearMissesIsClean() {
        var detector = StreamTemplateLeakDetector()
        // Near-misses: unfinished/lookalike markers must not match, across
        // many deltas (the bounded carry must not glue false positives —
        // note adjacent deltas here never concatenate into a real token).
        for delta in ["<|im_", "middle|>", " tool_call ", "]~! ", "b[ ", "[e~"] {
            #expect(detector.observe(delta) == nil, "false positive on \(delta)")
        }
    }

    @Test func sentinelCharacterIsDetected() {
        var detector = StreamTemplateLeakDetector()
        #expect(detector.observe("before\u{FFFE}after") == "\u{FFFE}")
    }
}

@Suite("GenerationEventMapper guardrail wiring")
struct StreamGuardrailsMapperTests {

    private static let allOn = StreamGuardrailSettings(
        degenerationDetection: true,
        templateLeakDetection: true
    )

    private func makeStream(_ events: [Generation]) -> AsyncStream<Generation> {
        AsyncStream { continuation in
            for ev in events { continuation.yield(ev) }
            continuation.finish()
        }
    }

    private func collect(
        events: [Generation],
        modelName: String = "guardrail-test-model",
        guardrails: StreamGuardrailSettings = Self.allOn
    ) async throws -> [ModelRuntimeEvent] {
        let mapped = GenerationEventMapper.map(
            events: makeStream(events),
            modelName: modelName,
            guardrails: guardrails
        )
        var out: [ModelRuntimeEvent] = []
        for try await ev in mapped { out.append(ev) }
        return out
    }

    private func tokenDeltas(_ events: [ModelRuntimeEvent]) -> [String] {
        events.compactMap { if case .tokens(let s) = $0 { s } else { nil } }
    }

    private func reasoningDeltas(_ events: [ModelRuntimeEvent]) -> [String] {
        events.compactMap { if case .reasoning(let s) = $0 { s } else { nil } }
    }

    // MARK: - Degeneration abort

    @Test func degenerating_chunk_stream_throws_typed_error() async {
        // 30 "idea " chunks: the 3-gram rule trips at the 24th token; the
        // mapped stream must finish with the typed guardrail error instead
        // of streaming the loop forever.
        let events: [Generation] = Array(repeating: .chunk("idea "), count: 30)
        do {
            _ = try await collect(events: events)
            Issue.record("expected StreamGuardrailError.degeneration to be thrown")
        } catch let error as StreamGuardrailError {
            guard case .degeneration(let fragment) = error else {
                Issue.record("expected .degeneration, got \(error)")
                return
            }
            #expect(fragment.contains("idea idea idea"))
        } catch {
            Issue.record("expected StreamGuardrailError, got \(error)")
        }
    }

    @Test func degenerating_reasoning_stream_throws_typed_error() async {
        // Loops routinely start inside the thinking channel; `.reasoning`
        // deltas must feed the same detector.
        let events: [Generation] = Array(repeating: .reasoning("loop token here "), count: 10)
        do {
            _ = try await collect(events: events)
            Issue.record("expected StreamGuardrailError.degeneration to be thrown")
        } catch let error as StreamGuardrailError {
            guard case .degeneration(let fragment) = error else {
                Issue.record("expected .degeneration, got \(error)")
                return
            }
            #expect(fragment.contains("loop token here"))
        } catch {
            Issue.record("expected StreamGuardrailError, got \(error)")
        }
    }

    @Test func character_run_split_across_chunks_throws() async {
        let events: [Generation] = Array(repeating: .chunk("!!!!!!!"), count: 10)
        await #expect(throws: StreamGuardrailError.self) {
            _ = try await collect(events: events)
        }
    }

    @Test func clean_stream_is_unaffected_byte_for_byte() async throws {
        let chunks = ["The sky ", "appears blue ", "because sunlight ", "is scattered."]
        var events: [Generation] = [.reasoning("thinking "), .reasoning("more thinking ")]
        events += chunks.map { .chunk($0) }
        let out = try await collect(events: events)
        // Every delta must arrive unmodified and unsplit — the guardrails
        // observe, they never rewrite.
        #expect(tokenDeltas(out) == chunks)
        #expect(reasoningDeltas(out) == ["thinking ", "more thinking "])
    }

    // MARK: - Template leak (log-only)

    @Test func leak_token_split_across_chunks_passes_through_unmodified() async throws {
        // Detect-and-log ONLY: the leaked marker is template-mismatch data
        // for the capability ledger, never something to hide by filtering.
        let chunks = ["answer <|im_", "end|> trailing"]
        let out = try await collect(events: chunks.map { .chunk($0) })
        #expect(tokenDeltas(out) == chunks)
    }

    @Test func leak_token_in_reasoning_passes_through_and_does_not_trip_content_detector() async throws {
        // The leak detector observes `.tokens` only — reasoning-channel
        // markers are engine-internal and legitimate there.
        let events: [Generation] = [
            .reasoning("<|im_start|>internal"),
            .chunk("clean answer"),
        ]
        let out = try await collect(events: events)
        #expect(reasoningDeltas(out) == ["<|im_start|>internal"])
        #expect(tokenDeltas(out) == ["clean answer"])
    }

    // MARK: - Flags

    @Test func degeneration_flag_off_streams_the_loop_untouched() async throws {
        let events: [Generation] = Array(repeating: .chunk("idea "), count: 30)
        let out = try await collect(
            events: events,
            guardrails: StreamGuardrailSettings(
                degenerationDetection: false,
                templateLeakDetection: true
            )
        )
        #expect(tokenDeltas(out).count == 30)
    }

    @Test func leak_flag_off_streams_marker_untouched() async throws {
        let events: [Generation] = [.chunk("<|im_start|>leaked")]
        let out = try await collect(
            events: events,
            guardrails: StreamGuardrailSettings(
                degenerationDetection: true,
                templateLeakDetection: false
            )
        )
        #expect(tokenDeltas(out) == ["<|im_start|>leaked"])
    }

    @Test func settings_resolve_defaults_to_both_on() {
        // Default-true is the contract: detection+abort beats unbounded
        // garbage, and leak logging is free. Absent keys must read as ON.
        let defaults = isolatedDefaults()
        let settings = StreamGuardrailSettings.resolve(from: defaults)
        #expect(settings.degenerationDetection)
        #expect(settings.templateLeakDetection)
    }

    @Test func settings_resolve_honors_explicit_opt_out() {
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: StreamGuardrailSettings.degenerationDetectionKey)
        defaults.set(false, forKey: StreamGuardrailSettings.templateLeakDetectionKey)
        let settings = StreamGuardrailSettings.resolve(from: defaults)
        #expect(!settings.degenerationDetection)
        #expect(!settings.templateLeakDetection)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "StreamGuardrailsMapperTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
