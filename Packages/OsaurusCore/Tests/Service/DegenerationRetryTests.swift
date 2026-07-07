//
//  DegenerationRetryTests.swift
//  osaurusTests
//
//  Caller-side degeneration retry (DegenerationRetry.swift): mapper-level
//  integration with fake `Generation` event streams, mirroring the
//  fake-stream pattern of StreamGuardrailsIntegrationTests. Attempt 1 flows
//  through the real `GenerationEventMapper` (so the real detector triggers
//  the real typed abort) and the splice must:
//
//    - retry once, transparently, when the abort precedes any
//      content-bearing event (the reasoning-channel loop case);
//    - propagate the error untouched once content was already forwarded;
//    - propagate when the retry attempt degenerates too (one retry max);
//    - do nothing at all when the flag is off.
//
//  Plus unit coverage for the safe-settings rebuild and the flag resolve.
//

import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite("DegenerationRetry splice")
struct DegenerationRetrySpliceTests {

    private static let guardrailsOn = StreamGuardrailSettings(
        degenerationDetection: true,
        templateLeakDetection: true
    )

    /// A degenerating reasoning-channel stream: the 3-gram rule trips on the
    /// 8th consecutive repeat, well before the 12th delta.
    private static let reasoningLoop: [Generation] =
        Array(repeating: .reasoning("loop token here "), count: 12)

    /// A clean second attempt with both channels active.
    private static let cleanAttempt: [Generation] = [
        .reasoning("fresh thinking "),
        .chunk("The answer "),
        .chunk("is 42."),
    ]

    /// Counts invocations of the retry closure across attempts.
    private actor RetryProbe {
        private(set) var calls = 0
        func record() { calls += 1 }
    }

    private func makeGenerationStream(_ events: [Generation]) -> AsyncStream<Generation> {
        AsyncStream { continuation in
            for ev in events { continuation.yield(ev) }
            continuation.finish()
        }
    }

    /// Run fake upstream events through the REAL mapper (real detector, real
    /// typed abort) — the splice under test consumes exactly what
    /// `ModelRuntime` would hand it.
    private func mapped(_ events: [Generation]) -> AsyncThrowingStream<ModelRuntimeEvent, Error> {
        GenerationEventMapper.map(
            events: makeGenerationStream(events),
            modelName: "retry-test-model",
            guardrails: Self.guardrailsOn
        )
    }

    /// Hand-built ModelRuntimeEvent stream for shapes the mapper can't
    /// easily fabricate (e.g. a tool invocation followed by an abort).
    private func eventStream(
        _ events: [ModelRuntimeEvent],
        throwing error: Error? = nil
    ) -> AsyncThrowingStream<ModelRuntimeEvent, Error> {
        AsyncThrowingStream { continuation in
            for ev in events { continuation.yield(ev) }
            continuation.finish(throwing: error)
        }
    }

    private func collect(
        _ stream: AsyncThrowingStream<ModelRuntimeEvent, Error>
    ) async throws -> [ModelRuntimeEvent] {
        var out: [ModelRuntimeEvent] = []
        for try await ev in stream { out.append(ev) }
        return out
    }

    private func tokenDeltas(_ events: [ModelRuntimeEvent]) -> [String] {
        events.compactMap { if case .tokens(let s) = $0 { s } else { nil } }
    }

    private func reasoningDeltas(_ events: [ModelRuntimeEvent]) -> [String] {
        events.compactMap { if case .reasoning(let s) = $0 { s } else { nil } }
    }

    // MARK: - Eligible: transparent retry

    @Test func reasoning_degeneration_with_zero_content_retries_transparently() async throws {
        let probe = RetryProbe()
        let spliced = DegenerationRetry.withRetry(
            events: mapped(Self.reasoningLoop),
            modelName: "retry-test-model",
            isEnabled: true
        ) {
            await probe.record()
            return self.mapped(Self.cleanAttempt)
        }
        // No error reaches the consumer, and every content delta it sees is
        // attempt 2's — attempt 1 aborted before yielding any content.
        let out = try await collect(spliced)
        #expect(tokenDeltas(out) == ["The answer ", "is 42."])
        // Attempt 1's pre-trigger reasoning deltas were already forwarded
        // (un-yielding is impossible); attempt 2's reasoning follows them.
        #expect(reasoningDeltas(out).last == "fresh thinking ")
        #expect(await probe.calls == 1)
    }

    @Test func degeneration_inside_first_content_delta_is_retry_eligible() async throws {
        // The mapper checks the detector BEFORE yielding a content delta, so
        // a loop contained entirely in the first chunk aborts with zero
        // content forwarded — retry is transparent and therefore allowed.
        let loopInOneDelta = String(repeating: "idea ", count: 60)
        let probe = RetryProbe()
        let spliced = DegenerationRetry.withRetry(
            events: mapped([.chunk(loopInOneDelta)]),
            modelName: "retry-test-model",
            isEnabled: true
        ) {
            await probe.record()
            return self.mapped(Self.cleanAttempt)
        }
        let out = try await collect(spliced)
        #expect(tokenDeltas(out) == ["The answer ", "is 42."])
        #expect(await probe.calls == 1)
    }

    // MARK: - Ineligible: error propagates

    @Test func content_already_yielded_propagates_without_retry() async {
        // Clean content first, then a chunk-channel loop across many deltas:
        // by trigger time the consumer has already received content, so the
        // typed abort must propagate and the retry closure must not run.
        let events: [Generation] =
            [.chunk("Sure thing. ")] + Array(repeating: .chunk("idea "), count: 60)
        let probe = RetryProbe()
        let spliced = DegenerationRetry.withRetry(
            events: mapped(events),
            modelName: "retry-test-model",
            isEnabled: true
        ) {
            await probe.record()
            return self.mapped(Self.cleanAttempt)
        }
        await #expect(throws: StreamGuardrailError.self) {
            _ = try await self.collect(spliced)
        }
        #expect(await probe.calls == 0)
    }

    @Test func tool_invocation_already_yielded_propagates_without_retry() async {
        // A forwarded tool call is content: retrying would double-dispatch
        // it. Hand-built stream because the mapper can't fabricate this shape.
        let probe = RetryProbe()
        let spliced = DegenerationRetry.withRetry(
            events: eventStream(
                [.toolInvocation(name: "get_weather", argsJSON: "{}")],
                throwing: StreamGuardrailError.degeneration(fragment: "post-tool loop")
            ),
            modelName: "retry-test-model",
            isEnabled: true
        ) {
            await probe.record()
            return self.mapped(Self.cleanAttempt)
        }
        await #expect(throws: StreamGuardrailError.self) {
            _ = try await self.collect(spliced)
        }
        #expect(await probe.calls == 0)
    }

    @Test func retry_that_also_degenerates_propagates_the_second_error() async {
        // One retry maximum: attempt 2's degeneration must reach the consumer.
        let probe = RetryProbe()
        let spliced = DegenerationRetry.withRetry(
            events: mapped(Self.reasoningLoop),
            modelName: "retry-test-model",
            isEnabled: true
        ) {
            await probe.record()
            return self.mapped(Self.reasoningLoop)
        }
        await #expect(throws: StreamGuardrailError.self) {
            _ = try await self.collect(spliced)
        }
        #expect(await probe.calls == 1)
    }

    @Test func retry_stream_construction_failure_propagates() async {
        struct RetryStartError: Error {}
        let probe = RetryProbe()
        let spliced = DegenerationRetry.withRetry(
            events: mapped(Self.reasoningLoop),
            modelName: "retry-test-model",
            isEnabled: true
        ) {
            await probe.record()
            throw RetryStartError()
        }
        await #expect(throws: RetryStartError.self) {
            _ = try await self.collect(spliced)
        }
        #expect(await probe.calls == 1)
    }

    @Test func non_guardrail_errors_never_trigger_a_retry() async {
        struct UpstreamError: Error {}
        let probe = RetryProbe()
        let spliced = DegenerationRetry.withRetry(
            events: eventStream([.reasoning("thinking ")], throwing: UpstreamError()),
            modelName: "retry-test-model",
            isEnabled: true
        ) {
            await probe.record()
            return self.mapped(Self.cleanAttempt)
        }
        await #expect(throws: UpstreamError.self) {
            _ = try await self.collect(spliced)
        }
        #expect(await probe.calls == 0)
    }

    // MARK: - Flag off

    @Test func flag_off_propagates_the_abort_without_retry() async {
        let probe = RetryProbe()
        let spliced = DegenerationRetry.withRetry(
            events: mapped(Self.reasoningLoop),
            modelName: "retry-test-model",
            isEnabled: false
        ) {
            await probe.record()
            return self.mapped(Self.cleanAttempt)
        }
        await #expect(throws: StreamGuardrailError.self) {
            _ = try await self.collect(spliced)
        }
        #expect(await probe.calls == 0)
    }

    // MARK: - Clean pass-through

    @Test func clean_stream_passes_through_untouched_and_never_retries() async throws {
        let probe = RetryProbe()
        let spliced = DegenerationRetry.withRetry(
            events: mapped(Self.cleanAttempt),
            modelName: "retry-test-model",
            isEnabled: true
        ) {
            await probe.record()
            return self.mapped(Self.cleanAttempt)
        }
        let out = try await collect(spliced)
        #expect(tokenDeltas(out) == ["The answer ", "is 42."])
        #expect(reasoningDeltas(out) == ["fresh thinking "])
        #expect(await probe.calls == 0)
    }
}

@Suite("DegenerationRetry policy")
struct DegenerationRetryPolicyTests {

    // MARK: - Safe settings

    @Test func safe_parameters_raise_greedy_temperature_and_add_repetition_penalty() {
        let base = GenerationParameters(
            temperature: 0,
            maxTokens: 512,
            seed: 7,
            jsonMode: true,
            sessionId: "session-1"
        )
        let safe = DegenerationRetry.safeParameters(retrying: base, modelDefaults: .empty)
        #expect(safe.temperature == 0.7)
        #expect(safe.repetitionPenalty == 1.1)
        #expect(!safe.samplingParametersAreImplicit)
        // Everything else must survive the rebuild untouched.
        #expect(safe.maxTokens == 512)
        #expect(safe.seed == 7)
        #expect(safe.jsonMode)
        #expect(safe.sessionId == "session-1")
    }

    @Test func safe_parameters_never_cool_down_an_already_hot_request() {
        let base = GenerationParameters(temperature: 0.95, maxTokens: 128)
        let safe = DegenerationRetry.safeParameters(retrying: base, modelDefaults: .empty)
        #expect(safe.temperature == 0.95)
    }

    @Test func safe_parameters_preserve_an_explicit_repetition_penalty() {
        let base = GenerationParameters(
            temperature: nil,
            maxTokens: 128,
            repetitionPenalty: 1.3
        )
        let safe = DegenerationRetry.safeParameters(retrying: base, modelDefaults: .empty)
        #expect(safe.repetitionPenalty == 1.3)
    }

    @Test func safe_parameters_resolve_current_temperature_from_model_defaults() {
        // Request silent + bundle ships a hot default: keep the hotter value.
        let hotDefaults = LocalGenerationDefaults.Defaults(temperature: 0.9)
        let base = GenerationParameters(temperature: nil, maxTokens: 128)
        let safe = DegenerationRetry.safeParameters(retrying: base, modelDefaults: hotDefaults)
        #expect(safe.temperature == 0.9)

        // `do_sample=false` means the bundle asked for greedy — that IS the
        // loop-prone configuration, so the floor applies even when the
        // bundle also ships a nominal temperature.
        let greedyDefaults = LocalGenerationDefaults.Defaults(temperature: 0.9, doSample: false)
        let safeGreedy = DegenerationRetry.safeParameters(
            retrying: base,
            modelDefaults: greedyDefaults
        )
        #expect(safeGreedy.temperature == 0.7)
    }

    // MARK: - Flag resolve

    @Test func flag_defaults_to_on_when_key_is_absent() {
        #expect(DegenerationRetry.isEnabled(defaults: isolatedDefaults()))
    }

    @Test func flag_honors_explicit_opt_out() {
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: DegenerationRetry.flagKey)
        #expect(!DegenerationRetry.isEnabled(defaults: defaults))
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "DegenerationRetryPolicyTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
