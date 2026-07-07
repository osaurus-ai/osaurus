//
//  BatchAutoscalerTests.swift
//  osaurusTests
//
//  Covers the auto batch-sizing pathway: the pure escalation/stickiness
//  decision rules, the tier caps derived from ChipProfile, the actor's
//  sliding-window behavior under an injected clock (escalate on overlap,
//  stick during a busy window, decay to 1 after a full quiet window and
//  tear the engine down so the compiled single-slot path can be rebuilt),
//  and the InferenceFeatureFlags resolution contract: with the opt-in flag
//  off (the default) behavior is bit-identical to the legacy path.
//

import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct BatchAutoscalerTests {

    // MARK: - Test doubles

    /// Manually advanced clock so window expiry never needs wall time.
    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 1_000

        var now: TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func advance(by seconds: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            value += seconds
        }
    }

    private actor TeardownRecorder {
        private(set) var models: [String] = []
        var result = true

        func record(_ model: String) -> Bool {
            models.append(model)
            return result
        }

        func setResult(_ value: Bool) { result = value }
    }

    /// Parks the decay loop until cancellation so tests drive `sweep`
    /// deterministically via the injected clock instead of real sleeps.
    private static let parkedSleeper: BatchAutoscaler.Sleeper = { _ in
        try? await Task.sleep(nanoseconds: 3_600 * 1_000_000_000)
    }

    private func makeAutoscaler(
        clock: ManualClock,
        recorder: TeardownRecorder? = nil
    ) -> BatchAutoscaler {
        BatchAutoscaler(
            now: { clock.now },
            sleep: Self.parkedSleeper,
            onReturnToOne: { model in
                guard let recorder else { return true }
                return await recorder.record(model)
            }
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "BatchAutoscalerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Tier caps

    /// Base and unknown must NEVER escalate: on those dies the memory
    /// bandwidth can't feed a second concurrent decode stream, so any
    /// escalation would only forfeit the 9× compiled-decode TTFT win.
    @Test func tierCapMapping() {
        #expect(BatchAutoscalerPolicy.tierCap(for: .base) == 1)
        #expect(BatchAutoscalerPolicy.tierCap(for: .pro) == 4)
        #expect(BatchAutoscalerPolicy.tierCap(for: .max) == 8)
        #expect(BatchAutoscalerPolicy.tierCap(for: .ultra) == 16)
        #expect(BatchAutoscalerPolicy.tierCap(for: .unknown) == 1)
    }

    // MARK: - Pure decision rules

    @Test func nextPowerOfTwo() {
        #expect(BatchAutoscalerPolicy.nextPowerOfTwo(0) == 1)
        #expect(BatchAutoscalerPolicy.nextPowerOfTwo(1) == 1)
        #expect(BatchAutoscalerPolicy.nextPowerOfTwo(2) == 2)
        #expect(BatchAutoscalerPolicy.nextPowerOfTwo(3) == 4)
        #expect(BatchAutoscalerPolicy.nextPowerOfTwo(5) == 8)
        #expect(BatchAutoscalerPolicy.nextPowerOfTwo(16) == 16)
        #expect(BatchAutoscalerPolicy.nextPowerOfTwo(17) == 32)
    }

    @Test func decision_noOverlapAlwaysReturnsToOne() {
        #expect(BatchAutoscalerPolicy.decision(windowMax: 0, tierCap: 8, previous: 1) == 1)
        #expect(BatchAutoscalerPolicy.decision(windowMax: 1, tierCap: 8, previous: 1) == 1)
        // Even a previously escalated recommendation falls back once the
        // window is quiet — this is the ONLY downsizing path.
        #expect(BatchAutoscalerPolicy.decision(windowMax: 1, tierCap: 8, previous: 8) == 1)
    }

    @Test func decision_overlapRoundsUpToNextPowerOfTwo() {
        #expect(BatchAutoscalerPolicy.decision(windowMax: 2, tierCap: 8, previous: 1) == 2)
        #expect(BatchAutoscalerPolicy.decision(windowMax: 3, tierCap: 8, previous: 1) == 4)
        #expect(BatchAutoscalerPolicy.decision(windowMax: 5, tierCap: 16, previous: 1) == 8)
    }

    @Test func decision_respectsTierCap() {
        #expect(BatchAutoscalerPolicy.decision(windowMax: 9, tierCap: 8, previous: 1) == 8)
        #expect(BatchAutoscalerPolicy.decision(windowMax: 30, tierCap: 16, previous: 1) == 16)
        // Base/unknown cap of 1 means overlap can never escalate.
        #expect(BatchAutoscalerPolicy.decision(windowMax: 6, tierCap: 1, previous: 1) == 1)
    }

    /// Never resize DOWN while the window still shows overlap: mid-burst
    /// downsizing thrashes engine rebuilds without recovering compile.
    @Test func decision_stickyWhileWindowStillHasOverlap() {
        #expect(BatchAutoscalerPolicy.decision(windowMax: 2, tierCap: 8, previous: 8) == 8)
        #expect(BatchAutoscalerPolicy.decision(windowMax: 3, tierCap: 8, previous: 4) == 4)
        // A stale previous above the cap is still clamped.
        #expect(BatchAutoscalerPolicy.decision(windowMax: 2, tierCap: 4, previous: 8) == 4)
    }

    // MARK: - Actor: window behavior under an injected clock

    @Test func noOverlapRecommendsSingleSlot() async {
        let clock = ManualClock()
        let scaler = makeAutoscaler(clock: clock)
        await scaler.recordSubmission(model: "m", pendingAndActive: 1)
        clock.advance(by: 5)
        await scaler.recordSubmission(model: "m", pendingAndActive: 1)
        #expect(await scaler.recommendedBatchSize(for: "m", tierCap: 8) == 1)
    }

    @Test func overlapOfThreeRecommendsFour() async {
        let clock = ManualClock()
        let scaler = makeAutoscaler(clock: clock)
        await scaler.recordSubmission(model: "m", pendingAndActive: 3)
        #expect(await scaler.recommendedBatchSize(for: "m", tierCap: 8) == 4)
    }

    @Test func tierCapBoundsTheRecommendation() async {
        let clock = ManualClock()
        let scaler = makeAutoscaler(clock: clock)
        await scaler.recordSubmission(model: "m", pendingAndActive: 7)
        #expect(await scaler.recommendedBatchSize(for: "m", tierCap: 4) == 4)
        // Base tier (cap 1) never escalates regardless of demand.
        #expect(await scaler.recommendedBatchSize(for: "other", tierCap: 1) == 1)
        await scaler.recordSubmission(model: "other", pendingAndActive: 6)
        #expect(await scaler.recommendedBatchSize(for: "other", tierCap: 1) == 1)
    }

    @Test func recommendationsAreTrackedPerModel() async {
        let clock = ManualClock()
        let scaler = makeAutoscaler(clock: clock)
        await scaler.recordSubmission(model: "busy", pendingAndActive: 3)
        await scaler.recordSubmission(model: "solo", pendingAndActive: 1)
        #expect(await scaler.recommendedBatchSize(for: "busy", tierCap: 8) == 4)
        #expect(await scaler.recommendedBatchSize(for: "solo", tierCap: 8) == 1)
    }

    /// During a busy window the recommendation never drops, even when the
    /// window max itself has fallen (peak sample aged out, smaller overlap
    /// remains).
    @Test func stickyWithinBusyWindow() async {
        let clock = ManualClock()
        let scaler = makeAutoscaler(clock: clock)
        await scaler.recordSubmission(model: "m", pendingAndActive: 3)
        #expect(await scaler.recommendedBatchSize(for: "m", tierCap: 8) == 4)

        // 40s later a smaller overlap arrives; 25s after that the original
        // demand-3 sample has aged out (65s old) but the demand-2 sample is
        // still in the window. windowMax == 2 would naively recommend 2 —
        // sticky keeps 4.
        clock.advance(by: 40)
        await scaler.recordSubmission(model: "m", pendingAndActive: 2)
        clock.advance(by: 25)
        #expect(await scaler.recommendedBatchSize(for: "m", tierCap: 8) == 4)
    }

    @Test func decaysToOneAfterFullQuietWindow() async {
        let clock = ManualClock()
        let scaler = makeAutoscaler(clock: clock)
        await scaler.recordSubmission(model: "m", pendingAndActive: 3)
        #expect(await scaler.recommendedBatchSize(for: "m", tierCap: 8) == 4)

        // 59s of quiet: still inside the window, still escalated.
        clock.advance(by: 59)
        #expect(await scaler.recommendedBatchSize(for: "m", tierCap: 8) == 4)

        // Past the full 60s quiet window: back to the compile-friendly 1.
        clock.advance(by: 2)
        #expect(await scaler.recommendedBatchSize(for: "m", tierCap: 8) == 1)
    }

    // MARK: - Decay teardown

    /// Returning to 1 must shut the (idle) engine down so the next request
    /// rebuilds fresh at 1: a hot-resize down does not recover the compiled
    /// decode path.
    @Test func decaySweepTriggersTeardownHookOnce() async {
        let clock = ManualClock()
        let recorder = TeardownRecorder()
        let scaler = makeAutoscaler(clock: clock, recorder: recorder)

        await scaler.recordSubmission(model: "m", pendingAndActive: 3)
        #expect(await scaler.recommendedBatchSize(for: "m", tierCap: 8) == 4)

        // Mid-window sweep: still busy, no decay, no teardown.
        clock.advance(by: 30)
        await scaler.sweep(model: "m")
        #expect(await recorder.models.isEmpty)
        #expect(await scaler.recommendedBatchSize(for: "m", tierCap: 8) == 4)

        // Quiet window elapsed: sweep decays to 1 and tears down.
        clock.advance(by: 31)
        await scaler.sweep(model: "m")
        #expect(await recorder.models == ["m"])
        #expect(await scaler.recommendedBatchSize(for: "m", tierCap: 8) == 1)

        // A second sweep must not double-shutdown.
        await scaler.sweep(model: "m")
        #expect(await recorder.models == ["m"])
    }

    /// A busy engine (pending/active work) defers the teardown; the flag
    /// stays pending and a later sweep retries.
    @Test func decayTeardownRetriesWhileEngineBusy() async {
        let clock = ManualClock()
        let recorder = TeardownRecorder()
        await recorder.setResult(false)
        let scaler = makeAutoscaler(clock: clock, recorder: recorder)

        await scaler.recordSubmission(model: "m", pendingAndActive: 2)
        #expect(await scaler.recommendedBatchSize(for: "m", tierCap: 8) == 2)

        clock.advance(by: 61)
        await scaler.sweep(model: "m")
        #expect(await recorder.models == ["m"])

        // Engine reported busy — the retrying sweep calls the hook again,
        // and once it succeeds the pending flag clears.
        await recorder.setResult(true)
        await scaler.sweep(model: "m")
        #expect(await recorder.models == ["m", "m"])
        await scaler.sweep(model: "m")
        #expect(await recorder.models == ["m", "m"])
    }

    // MARK: - Recommendation-change log gating

    @Test func logsOnlyOnRecommendationChange() async {
        let clock = ManualClock()
        let scaler = makeAutoscaler(clock: clock)

        // Reads that keep returning 1 log nothing.
        _ = await scaler.recommendedBatchSize(for: "m", tierCap: 8)
        _ = await scaler.recommendedBatchSize(for: "m", tierCap: 8)
        #expect(await scaler.recentChangeLogs.isEmpty)

        // 1 → 4 logs exactly once, repeats stay silent.
        await scaler.recordSubmission(model: "m", pendingAndActive: 3)
        _ = await scaler.recommendedBatchSize(for: "m", tierCap: 8)
        _ = await scaler.recommendedBatchSize(for: "m", tierCap: 8)
        _ = await scaler.recommendedBatchSize(for: "m", tierCap: 8)
        let afterEscalation = await scaler.recentChangeLogs
        #expect(afterEscalation == ["[Osaurus] autobatch: model=m 1→4 (windowMax=3, tierCap=8)"])

        // Decay 4 → 1 logs the second line.
        clock.advance(by: 61)
        _ = await scaler.recommendedBatchSize(for: "m", tierCap: 8)
        _ = await scaler.recommendedBatchSize(for: "m", tierCap: 8)
        let afterDecay = await scaler.recentChangeLogs
        #expect(afterDecay.count == 2)
        #expect(afterDecay.last == "[Osaurus] autobatch: model=m 4→1 (windowMax=0, tierCap=8)")
    }

    // MARK: - InferenceFeatureFlags resolution

    /// The auto flag defaults to FALSE: resolution must be bit-identical to
    /// the legacy path so nothing changes for anyone who hasn't opted in.
    @Test func flagOffByDefault_resolutionMatchesLegacyPath() async {
        let defaults = isolatedDefaults()
        var runtime = VMLXServerRuntimeSettings()

        #expect(!InferenceFeatureFlags.autoBatchSizingEnabled(in: defaults, runtime: runtime))
        let resolvedDefault = await InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(
            in: defaults,
            runtime: runtime,
            model: "m"
        )
        #expect(
            resolvedDefault
                == InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(in: defaults, runtime: runtime)
        )
        #expect(resolvedDefault == 1)

        // Legacy override still wins on the flag-off path.
        defaults.set(8, forKey: "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize")
        let resolvedLegacy = await InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(
            in: defaults,
            runtime: runtime,
            model: "m"
        )
        #expect(resolvedLegacy == 8)

        // Runtime override too.
        runtime.concurrency.maxConcurrentSequences = 6
        let resolvedRuntime = await InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(
            in: defaults,
            runtime: runtime,
            model: "m"
        )
        #expect(resolvedRuntime == 6)
    }

    /// Explicit sizing is a deliberate choice of the compile-vs-throughput
    /// trade-off; auto never overrides it even when the flag is on.
    @Test func explicitSizingDisablesAutoEvenWhenFlagOn() async {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "ai.osaurus.scheduler.autoBatchSize")

        var runtime = VMLXServerRuntimeSettings()
        runtime.concurrency.maxConcurrentSequences = 6
        #expect(!InferenceFeatureFlags.autoBatchSizingEnabled(in: defaults, runtime: runtime))
        let resolved = await InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(
            in: defaults,
            runtime: runtime,
            model: "m"
        )
        #expect(resolved == 6)

        // Legacy UserDefaults value also counts as explicit.
        let legacyDefaults = isolatedDefaults()
        legacyDefaults.set(true, forKey: "ai.osaurus.scheduler.autoBatchSize")
        legacyDefaults.set(2, forKey: "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize")
        #expect(
            !InferenceFeatureFlags.autoBatchSizingEnabled(
                in: legacyDefaults,
                runtime: VMLXServerRuntimeSettings()
            )
        )
    }

    @Test func flagOnWithNoExplicitSizing_resolvesViaAutoscaler() async {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "ai.osaurus.scheduler.autoBatchSize")
        let runtime = VMLXServerRuntimeSettings()
        #expect(InferenceFeatureFlags.autoBatchSizingEnabled(in: defaults, runtime: runtime))

        let clock = ManualClock()
        let scaler = makeAutoscaler(clock: clock)

        // No overlap observed yet: stays at the compiled-decode 1.
        let coldValue = await InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(
            in: defaults,
            runtime: runtime,
            model: "m",
            autoscaler: scaler,
            tierCapOverride: 8
        )
        #expect(coldValue == 1)

        // Observed overlap of 3 escalates to the next power of two.
        await scaler.recordSubmission(model: "m", pendingAndActive: 3)
        let busyValue = await InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(
            in: defaults,
            runtime: runtime,
            model: "m",
            autoscaler: scaler,
            tierCapOverride: 8
        )
        #expect(busyValue == 4)
    }
}
