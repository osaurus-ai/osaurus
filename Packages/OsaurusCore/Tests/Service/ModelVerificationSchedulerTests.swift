//
//  ModelVerificationSchedulerTests.swift
//  osaurus
//
//  Scheduler logic only — idle-checker and prober are injected fakes, so no
//  test ever touches the GPU, real models, or the real ledger file.
//

import Foundation
import Testing
import os

@testable import OsaurusCore

// MARK: - Fakes

/// Scripted idle signal: pops `responses` in order, then repeats `fallback`.
private final class ScriptedIdleChecker: VerificationIdleChecking, Sendable {
    private struct State {
        var responses: [Bool]
        var callCount = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let fallback: Bool

    init(responses: [Bool] = [], fallback: Bool) {
        self.state = OSAllocatedUnfairLock(initialState: State(responses: responses))
        self.fallback = fallback
    }

    func isRuntimeIdle() async -> Bool {
        state.withLock { s in
            s.callCount += 1
            if s.responses.isEmpty { return fallback }
            return s.responses.removeFirst()
        }
    }

    var calls: Int {
        state.withLock { $0.callCount }
    }
}

/// Records probe invocations and asserts they never overlap (the scheduler
/// must strictly serialize runs).
private final class FakeProber: VerificationProbing, Sendable {
    private struct State {
        var probedModels: [String] = []
        var activeProbes = 0
        var sawOverlap = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let outcome: VerificationProbeOutcome

    init(outcome: VerificationProbeOutcome = .passing) {
        self.outcome = outcome
    }

    func runProbes(modelName: String, localDirectory: URL?) async -> VerificationProbeOutcome {
        state.withLock { s in
            s.probedModels.append(modelName)
            s.activeProbes += 1
            if s.activeProbes > 1 { s.sawOverlap = true }
        }

        // Give a hypothetical concurrent run a chance to overlap.
        try? await Task.sleep(for: .milliseconds(20))

        state.withLock { $0.activeProbes -= 1 }
        return outcome
    }

    var models: [String] {
        state.withLock { $0.probedModels }
    }

    var sawOverlap: Bool {
        state.withLock { $0.sawOverlap }
    }
}

private final class FakeRecorder: VerificationRecording, Sendable {
    private struct Entry {
        let model: String
        let outcome: VerificationProbeOutcome
    }

    private let state = OSAllocatedUnfairLock<[Entry]>(initialState: [])

    func record(modelName: String, outcome: VerificationProbeOutcome) async {
        state.withLock { $0.append(Entry(model: modelName, outcome: outcome)) }
    }

    var recordedModels: [String] {
        state.withLock { $0.map(\.model) }
    }

    var recordedOutcomes: [VerificationProbeOutcome] {
        state.withLock { $0.map(\.outcome) }
    }
}

extension VerificationProbeOutcome {
    fileprivate static let passing = VerificationProbeOutcome(
        loadVerdict: .pass,
        loadEvidence: "loaded and generated 8-token greedy sample in 0.1s",
        templateLeakVerdict: .pass,
        templateLeakEvidence: "no template control tokens in 8-token greedy sample",
        elapsedSeconds: 0.1
    )
}

private func makeConfiguration(
    enabled: Bool = true,
    pollInterval: TimeInterval = 0.01,
    deadline: TimeInterval = 5
) -> ModelVerificationScheduler.Configuration {
    var config = ModelVerificationScheduler.Configuration()
    config.initialPollInterval = pollInterval
    config.maxPollInterval = pollInterval * 4
    config.idleWaitDeadline = deadline
    config.isAutoRunEnabled = { enabled }
    return config
}

// MARK: - Tests

struct ModelVerificationSchedulerTests {

    @Test func flag_off_is_a_complete_noop() async {
        let idle = ScriptedIdleChecker(fallback: true)
        let prober = FakeProber()
        let recorder = FakeRecorder()
        let scheduler = ModelVerificationScheduler(
            configuration: makeConfiguration(enabled: false),
            idleChecker: idle,
            prober: prober,
            recorder: recorder
        )

        let result = await scheduler.verifyNow(name: "some-model", localDirectory: nil)

        #expect(result == .disabled)
        #expect(idle.calls == 0)
        #expect(prober.models.isEmpty)
        #expect(recorder.recordedModels.isEmpty)
    }

    @Test func runs_immediately_when_runtime_is_idle() async {
        let prober = FakeProber()
        let recorder = FakeRecorder()
        let scheduler = ModelVerificationScheduler(
            configuration: makeConfiguration(),
            idleChecker: ScriptedIdleChecker(fallback: true),
            prober: prober,
            recorder: recorder
        )

        let result = await scheduler.verifyNow(name: "qwen3-4b", localDirectory: nil)

        #expect(result == .completed(.passing))
        #expect(prober.models == ["qwen3-4b"])
        #expect(recorder.recordedModels == ["qwen3-4b"])
    }

    @Test func waits_through_busy_polls_then_runs() async {
        let idle = ScriptedIdleChecker(responses: [false, false, false], fallback: true)
        let prober = FakeProber()
        let recorder = FakeRecorder()
        let scheduler = ModelVerificationScheduler(
            configuration: makeConfiguration(),
            idleChecker: idle,
            prober: prober,
            recorder: recorder
        )

        let result = await scheduler.verifyNow(name: "busy-then-idle", localDirectory: nil)

        #expect(result == .completed(.passing))
        #expect(idle.calls >= 4)  // three busy polls + the idle one
        #expect(prober.models == ["busy-then-idle"])
        #expect(recorder.recordedModels == ["busy-then-idle"])
    }

    @Test func skips_without_probing_when_busy_past_deadline() async {
        let idle = ScriptedIdleChecker(fallback: false)
        let prober = FakeProber()
        let recorder = FakeRecorder()
        let scheduler = ModelVerificationScheduler(
            configuration: makeConfiguration(pollInterval: 0.005, deadline: 0.05),
            idleChecker: idle,
            prober: prober,
            recorder: recorder
        )

        let result = await scheduler.verifyNow(name: "never-idle", localDirectory: nil)

        #expect(result == .skippedBusy)
        #expect(prober.models.isEmpty)
        #expect(recorder.recordedModels.isEmpty)
    }

    @Test func failing_probe_outcome_is_still_recorded() async {
        let failing = VerificationProbeOutcome(
            loadVerdict: .fail,
            loadEvidence: "load/generate failed: boom",
            templateLeakVerdict: .skipped,
            templateLeakEvidence: "load probe did not produce output",
            elapsedSeconds: 0.2
        )
        let recorder = FakeRecorder()
        let scheduler = ModelVerificationScheduler(
            configuration: makeConfiguration(),
            idleChecker: ScriptedIdleChecker(fallback: true),
            prober: FakeProber(outcome: failing),
            recorder: recorder
        )

        let result = await scheduler.verifyNow(name: "broken-model", localDirectory: nil)

        #expect(result == .completed(failing))
        #expect(recorder.recordedModels == ["broken-model"])
        #expect(recorder.recordedOutcomes == [failing])
    }

    @Test func install_events_are_serialized_and_all_processed() async {
        let prober = FakeProber()
        let recorder = FakeRecorder()
        let scheduler = ModelVerificationScheduler(
            configuration: makeConfiguration(),
            idleChecker: ScriptedIdleChecker(fallback: true),
            prober: prober,
            recorder: recorder
        )

        scheduler.modelInstalled(name: "model-a", localDirectory: nil)
        scheduler.modelInstalled(name: "model-b", localDirectory: nil)

        // Fire-and-forget path: wait (bounded) for both runs to land.
        let deadline = Date().addingTimeInterval(5)
        while recorder.recordedModels.count < 2, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(Set(recorder.recordedModels) == ["model-a", "model-b"])
        #expect(Set(prober.models) == ["model-a", "model-b"])
        #expect(!prober.sawOverlap)
    }
}
