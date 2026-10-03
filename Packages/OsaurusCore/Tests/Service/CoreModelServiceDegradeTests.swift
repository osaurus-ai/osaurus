//
//  CoreModelServiceDegradeTests.swift
//  OsaurusCoreTests
//
//  Pins how `CoreModelService` degrades from a failing *primary* core model
//  (the configured / override model) to the caller's chat-model fallback.
//  Motivation: users with `foundation` as the Core Model but Apple
//  Intelligence off, assets missing, or a wedged framework session saw
//  follow-ups and titles stall for 3 × timeout and then silently fail —
//  the healthy chat model was never tried.
//
//  Contract under test:
//
//    * A typed, non-transient Foundation failure gets ONE primary attempt,
//      no retry backoff, then the fallback runs.
//    * A primary whose service declares a `firstTokenDeadline` and produces
//      no token within it is abandoned as `.unresponsive` and the fallback
//      runs — well before the caller's overall timeout.
//    * Once the first token arrives, a slow generation is never cut off.
//    * Services without a first-token deadline (local load phase) keep the
//      whole timeout for their first output.
//    * Primary failures count toward the breaker even when the fallback
//      rescued the call; two hangs open it; a fallback success does not
//      clear it; a primary success does.
//    * With the breaker open, calls that carry a distinct fallback skip the
//      primary and serve from the fallback; calls without one see
//      `circuitBreakerOpen`.
//
//  Every test injects fake services via `CoreModelService(localServices:)`
//  and names the primary through `modelOverride`, so no test touches the
//  user's chat configuration or the shared singleton's breaker state.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct CoreModelServiceDegradeTests {

    // MARK: - Fakes

    /// Scriptable `ModelService`. `generateOneShot` and `streamDeltas` both
    /// follow `behavior`; the counters pin which path `CoreModelService`
    /// actually took.
    private actor ScriptedService: ModelService {
        enum Behavior: Sendable {
            case succeed(String)
            case fail(FoundationModelServiceError)
            /// Never returns / never yields until cancelled.
            case hang
            /// First delta after `first` seconds, remainder at `total`.
            /// `generateOneShot` returns the whole text at `total`.
            case slow(first: TimeInterval, total: TimeInterval, text: String)
        }

        nonisolated let id: String
        nonisolated let deadline: TimeInterval?
        private var behavior: Behavior
        private(set) var oneShotCalls = 0
        private(set) var streamCalls = 0

        init(id: String, firstTokenDeadline: TimeInterval? = nil, behavior: Behavior) {
            self.id = id
            self.deadline = firstTokenDeadline
            self.behavior = behavior
        }

        func set(_ behavior: Behavior) { self.behavior = behavior }

        nonisolated var firstTokenDeadline: TimeInterval? { deadline }
        nonisolated func isAvailable() -> Bool { true }
        nonisolated func handles(requestedModel: String?) -> Bool { requestedModel == id }

        func generateOneShot(
            messages: [ChatMessage],
            parameters: GenerationParameters,
            requestedModel: String?
        ) async throws -> String {
            oneShotCalls += 1
            switch behavior {
            case .succeed(let text):
                return text
            case .fail(let error):
                throw error
            case .hang:
                try await Task.sleep(for: .seconds(3600))
                return ""
            case .slow(_, let total, let text):
                try await Task.sleep(for: .seconds(total))
                return text
            }
        }

        func streamDeltas(
            messages: [ChatMessage],
            parameters: GenerationParameters,
            requestedModel: String?,
            stopSequences: [String]
        ) async throws -> AsyncThrowingStream<String, Error> {
            streamCalls += 1
            let behavior = self.behavior
            return AsyncThrowingStream { continuation in
                let producer = Task {
                    switch behavior {
                    case .succeed(let text):
                        continuation.yield(text)
                        continuation.finish()
                    case .fail(let error):
                        continuation.finish(throwing: error)
                    case .hang:
                        try? await Task.sleep(for: .seconds(3600))
                        continuation.finish()
                    case .slow(let first, let total, let text):
                        try? await Task.sleep(for: .seconds(first))
                        if Task.isCancelled { continuation.finish(); return }
                        continuation.yield(String(text.prefix(1)))
                        try? await Task.sleep(for: .seconds(max(0, total - first)))
                        if Task.isCancelled { continuation.finish(); return }
                        continuation.yield(String(text.dropFirst()))
                        continuation.finish()
                    }
                }
                continuation.onTermination = { _ in producer.cancel() }
            }
        }
    }

    private static let localeFailure = FoundationModelServiceError.generation(
        .unsupportedLanguageOrLocale, detail: "test")

    private static func elapsed(_ since: Date) -> TimeInterval {
        Date().timeIntervalSince(since)
    }

    // MARK: - Typed failure → single attempt, immediate fallback

    @Test("a non-transient Foundation failure gets one attempt and the fallback answers at once")
    func typedFailure_singleAttemptThenFallback() async throws {
        let primary = ScriptedService(id: "p", behavior: .fail(Self.localeFailure))
        let fallback = ScriptedService(id: "f", behavior: .succeed("FB"))
        let service = CoreModelService(localServices: [primary, fallback])

        let started = Date()
        let result = try await service.generate(
            prompt: "ping", timeout: 10, fallbackModel: fallback.id, modelOverride: primary.id)

        #expect(result == "FB")
        #expect(await primary.oneShotCalls == 1, "no retry loop on the primary when a fallback exists")
        #expect(await fallback.oneShotCalls == 1)
        // The old path spent 1s + 2s of backoff before falling back.
        #expect(Self.elapsed(started) < 0.9)
    }

    @Test("a non-transient Foundation failure without a fallback is not retried")
    func typedFailure_withoutFallback_notRetried() async throws {
        let primary = ScriptedService(id: "p", behavior: .fail(Self.localeFailure))
        let service = CoreModelService(localServices: [primary])

        await #expect(throws: FoundationModelServiceError.self) {
            _ = try await service.generate(prompt: "ping", timeout: 10, modelOverride: primary.id)
        }
        #expect(await primary.oneShotCalls == 1)
    }

    // MARK: - First-token deadline

    @Test("a primary that never produces a first token is abandoned at its deadline, not the caller timeout")
    func hangingPrimary_fallsBackAtFirstTokenDeadline() async throws {
        let primary = ScriptedService(id: "p", firstTokenDeadline: 0.5, behavior: .hang)
        let fallback = ScriptedService(id: "f", behavior: .succeed("FB"))
        let service = CoreModelService(localServices: [primary, fallback])

        let started = Date()
        let result = try await service.generate(
            prompt: "ping", timeout: 20, fallbackModel: fallback.id, modelOverride: primary.id)

        #expect(result == "FB")
        let took = Self.elapsed(started)
        #expect(took >= 0.4 && took < 3, "fell back after ~\(took)s; deadline was 0.5s, timeout 20s")
        #expect(await primary.streamCalls == 1, "primary with a deadline runs through streamDeltas")
        #expect(await primary.oneShotCalls == 0)
    }

    @Test("a primary that streams its first token in time is never cut off while it keeps producing")
    func slowProgressingPrimary_isNotCutOff() async throws {
        let primary = ScriptedService(
            id: "p", firstTokenDeadline: 0.5,
            behavior: .slow(first: 0.2, total: 1.5, text: "HELLO"))
        let fallback = ScriptedService(id: "f", behavior: .succeed("FB"))
        let service = CoreModelService(localServices: [primary, fallback])

        let result = try await service.generate(
            prompt: "ping", timeout: 10, fallbackModel: fallback.id, modelOverride: primary.id)

        #expect(result == "HELLO")
        #expect(await fallback.oneShotCalls == 0)
    }

    @Test("a service without a first-token deadline keeps the whole timeout for its first output")
    func loadPhasePrimary_hasNoFirstTokenDeadline() async throws {
        let primary = ScriptedService(
            id: "p", firstTokenDeadline: nil,
            behavior: .slow(first: 1.0, total: 1.0, text: "LOADED"))
        let fallback = ScriptedService(id: "f", behavior: .succeed("FB"))
        let service = CoreModelService(localServices: [primary, fallback])

        let result = try await service.generate(
            prompt: "ping", timeout: 10, fallbackModel: fallback.id, modelOverride: primary.id)

        #expect(result == "LOADED")
        #expect(await primary.oneShotCalls == 1, "no deadline → plain generateOneShot path")
        #expect(await primary.streamCalls == 0)
        #expect(await fallback.oneShotCalls == 0)
    }

    @Test("without a fallback a hung primary still times out at the caller's budget")
    func hangingPrimary_withoutFallback_timesOut() async throws {
        let primary = ScriptedService(id: "p", firstTokenDeadline: 0.1, behavior: .hang)
        let service = CoreModelService(localServices: [primary])

        do {
            _ = try await service.generate(prompt: "ping", timeout: 0.2, modelOverride: primary.id)
            Issue.record("expected timedOut")
        } catch let error as CoreModelError {
            #expect(error == .timedOut)
        }
        // Solo role: full retry budget, and `.timedOut` is retryable.
        #expect(await primary.oneShotCalls == 3)
        #expect(await primary.streamCalls == 0, "first-token deadline only applies when a fallback exists")
    }

    // MARK: - Breaker

    @Test("two consecutive hangs open the breaker; further calls skip the primary")
    func twoHangs_openBreaker_andSkipPrimary() async throws {
        let primary = ScriptedService(id: "p", firstTokenDeadline: 0.2, behavior: .hang)
        let fallback = ScriptedService(id: "f", behavior: .succeed("FB"))
        let service = CoreModelService(localServices: [primary, fallback])

        for _ in 0 ..< CoreModelService.hangBreakerThreshold {
            let result = try await service.generate(
                prompt: "ping", timeout: 10, fallbackModel: fallback.id, modelOverride: primary.id)
            #expect(result == "FB")
        }
        #expect(await service.breakerOpenUntil() != nil, "hang threshold reached")
        #expect(await primary.streamCalls == CoreModelService.hangBreakerThreshold)

        let started = Date()
        let result = try await service.generate(
            prompt: "ping", timeout: 10, fallbackModel: fallback.id, modelOverride: primary.id)
        #expect(result == "FB")
        #expect(Self.elapsed(started) < 0.15, "breaker-open path must not touch the primary at all")
        #expect(await primary.streamCalls == CoreModelService.hangBreakerThreshold, "primary skipped")

        // Without a fallback the open breaker is the caller's error.
        do {
            _ = try await service.generate(prompt: "ping", timeout: 10, modelOverride: primary.id)
            Issue.record("expected circuitBreakerOpen")
        } catch let error as CoreModelError {
            #expect(error == .circuitBreakerOpen)
        }
    }

    @Test("typed failures rescued by the fallback still count toward the breaker")
    func rescuedFailures_countTowardBreaker() async throws {
        let primary = ScriptedService(id: "p", behavior: .fail(Self.localeFailure))
        let fallback = ScriptedService(id: "f", behavior: .succeed("FB"))
        let service = CoreModelService(localServices: [primary, fallback])

        for _ in 0 ..< CoreModelService.circuitBreakerThreshold {
            #expect(await service.breakerOpenUntil() == nil)
            let result = try await service.generate(
                prompt: "ping", timeout: 10, fallbackModel: fallback.id, modelOverride: primary.id)
            #expect(result == "FB", "fallback success must not reset the primary's count")
        }
        #expect(await service.breakerOpenUntil() != nil)
    }

    @Test("a primary success clears the hang count; a fallback success does not")
    func primarySuccess_clearsBreakerCounters() async throws {
        let primary = ScriptedService(id: "p", firstTokenDeadline: 0.2, behavior: .hang)
        let fallback = ScriptedService(id: "f", behavior: .succeed("FB"))
        let service = CoreModelService(localServices: [primary, fallback])

        // One hang (rescued) → count 1 of 2.
        _ = try await service.generate(
            prompt: "ping", timeout: 10, fallbackModel: fallback.id, modelOverride: primary.id)
        #expect(await service.breakerOpenUntil() == nil)

        // Primary recovers → counters reset.
        await primary.set(.succeed("PRIMARY"))
        let recovered = try await service.generate(
            prompt: "ping", timeout: 10, fallbackModel: fallback.id, modelOverride: primary.id)
        #expect(recovered == "PRIMARY")

        // A single fresh hang must not open the breaker (would need 2 again).
        await primary.set(.hang)
        _ = try await service.generate(
            prompt: "ping", timeout: 10, fallbackModel: fallback.id, modelOverride: primary.id)
        #expect(await service.breakerOpenUntil() == nil)
    }

    @Test("configuration errors never count toward the breaker")
    func modelUnavailable_neverOpensBreaker() async throws {
        let fallback = ScriptedService(id: "f", behavior: .succeed("FB"))
        let service = CoreModelService(localServices: [fallback])

        for _ in 0 ..< (CoreModelService.circuitBreakerThreshold + 1) {
            let result = try await service.generate(
                prompt: "ping", timeout: 10, fallbackModel: fallback.id, modelOverride: "nobody/has-this")
            #expect(result == "FB")
        }
        #expect(await service.breakerOpenUntil() == nil)
    }

    // MARK: - Pure decision functions

    @Test
    func fallbackDecision_hangsFallBack_breakerOpenDoesNot() {
        #expect(CoreModelService.shouldFallBackToChatModel(for: .timedOut, allowResidencyRefusal: false))
        #expect(
            CoreModelService.shouldFallBackToChatModel(
                for: .unresponsive("foundation"), allowResidencyRefusal: false))
        #expect(
            !CoreModelService.shouldFallBackToChatModel(
                for: .circuitBreakerOpen, allowResidencyRefusal: true))
    }

    @Test
    func isRetryable_honoursFoundationTransience() {
        #expect(CoreModelService.isRetryable(FoundationModelServiceError.generation(.rateLimited, detail: "")))
        #expect(
            CoreModelService.isRetryable(
                FoundationModelServiceError.generation(.concurrentRequests, detail: "")))
        #expect(
            !CoreModelService.isRetryable(
                FoundationModelServiceError.generation(.assetsUnavailable, detail: "")))
        #expect(
            !CoreModelService.isRetryable(
                FoundationModelServiceError.generation(.guardrailViolation, detail: "")))
        #expect(
            !CoreModelService.isRetryable(FoundationModelServiceError.notAvailable(.appleIntelligenceNotEnabled)))
        #expect(!CoreModelService.isRetryable(FoundationModelServiceError.notAvailable(.modelNotReady)))
        #expect(!CoreModelService.isRetryable(CoreModelError.unresponsive("foundation")))
        #expect(CoreModelService.isRetryable(CoreModelError.timedOut))
    }

    @Test
    func breakerAccounting_classifiesErrors() {
        #expect(!CoreModelService.countsTowardBreaker(CoreModelError.modelUnavailable("x")))
        #expect(!CoreModelService.countsTowardBreaker(CoreModelError.backgroundWouldEvictUserModel("x")))
        #expect(!CoreModelService.countsTowardBreaker(CancellationError()))
        #expect(CoreModelService.countsTowardBreaker(CoreModelError.timedOut))
        #expect(CoreModelService.countsTowardBreaker(CoreModelError.unresponsive("x")))
        #expect(CoreModelService.countsTowardBreaker(Self.localeFailure))

        #expect(CoreModelService.isHang(CoreModelError.timedOut))
        #expect(CoreModelService.isHang(CoreModelError.unresponsive("x")))
        #expect(!CoreModelService.isHang(Self.localeFailure))
        #expect(!CoreModelService.isHang(CoreModelError.modelUnavailable("x")))
    }

    @Test
    func unavailableReason_forFoundation_usesFrameworkReason() {
        let reason = CoreModelService.unavailableReason(modelId: "foundation")
        if let expected = FoundationModelService.defaultModelAvailability().unavailableReason {
            #expect(reason == expected.userDescription)
        } else {
            // Foundation is available on this Mac; the router would never ask.
            #expect(reason == "Foundation Model is not available on this Mac.")
        }
    }
}
