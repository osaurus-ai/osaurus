//
//  AppleScriptEvaluator.swift
//  OsaurusCore — AppleScript Computer Use (evals facade)
//
//  Public facade that drives the production `AppleScriptLoop` for the
//  OsaurusEvals `apple_script` domain, plus the `MockAppleScriptExecutor`
//  test-double the capability lanes run against. It mirrors how
//  `runComputerUseLoopCase` drives `ComputerUseLoop.run` directly: the loop is
//  the real thing, only the executor (and, for the scripted lane, the model
//  step) is injected, so a failure attributes to the model — never to eval
//  scaffolding.
//
//  Three lanes:
//   • scripted   — model-free: canned `run_applescript` calls + a mock
//                  executor. Deterministic, CI-safe, exercises the loop
//                  mechanics (gate / expansion / verification) with no model.
//   • live       — the real on-device AppleScript model + a mock executor: the
//                  capability/edge lane. No OS side effects; the mock "app
//                  world" answers read-backs so outcomes can be asserted.
//   • liveProof  — the real model + the REAL `AppleScriptExecutor`: verbatim
//                  ground truth against actual app state (permission-gated,
//                  run locally).
//
//  Per AGENTS.md this is a deterministic Swift harness: the mock simulates the
//  OS, it never coerces or repairs the model's output. Unrecognized scripts get
//  a per-case default result so harness ignorance can't score against the model.
//

import Foundation

// MARK: - Lane

/// Which execution lane an AppleScript eval case runs in.
public enum AppleScriptEvalLane: String, Sendable, Codable {
    /// Model-free: canned calls + mock executor (CI mechanics).
    case scripted
    /// Real on-device model + mock executor (capability/edges, no side effects).
    case live
    /// Real model + real `AppleScriptExecutor` (verbatim ground truth).
    case liveProof
}

// MARK: - Transcript

/// Decode-friendly record of one AppleScript eval run — the scored surface.
public struct AppleScriptEvalTranscript: Sendable {
    public let lane: AppleScriptEvalLane
    /// True when a real model drove the loop (live / liveProof, model installed).
    public let ranModel: Bool
    /// The model id that actually ran (nil for the scripted lane).
    public let modelId: String?
    /// True when the run was skipped (e.g. no AppleScript model installed).
    public let skipped: Bool
    public let skipReason: String?
    /// `done` / `interrupted` / `stepCapReached` / `failed`.
    public let outcome: String
    /// Aggregate task status: `succeeded` / `partial` / `failed`.
    public let status: String
    public let summary: String
    public let scriptsExecuted: Int
    public let succeeded: Int
    public let failed: Int
    public let modelTokens: Int
    /// The headline coerced value the run captured (the `values` a parent reads).
    public let lastOutput: String?
    /// Full per-step transcript (executed / declined / blocked / invalid).
    public let steps: [AppleScriptStepRecord]
    /// Every model proposal (pre- + post-expansion + effect) — placeholder-use
    /// and effect scoring read this.
    public let proposals: [AppleScriptProposalRecord]
    /// The expanded scripts actually handed to the executor, in order.
    public let executedScripts: [String]
    /// True when a write was blocked (query-mode / verification refusal).
    public let blockedWrite: Bool
    /// Mock-world final state (canonical key → value); empty for real / canned.
    public let finalState: [String: String]
    public let latencyMs: Double
    public let error: String?

    /// A skipped-run transcript (no model installed for a live lane).
    static func skippedRun(lane: AppleScriptEvalLane, reason: String) -> AppleScriptEvalTranscript {
        AppleScriptEvalTranscript(
            lane: lane,
            ranModel: false,
            modelId: nil,
            skipped: true,
            skipReason: reason,
            outcome: "skipped",
            status: "skipped",
            summary: reason,
            scriptsExecuted: 0,
            succeeded: 0,
            failed: 0,
            modelTokens: 0,
            lastOutput: nil,
            steps: [],
            proposals: [],
            executedScripts: [],
            blockedWrite: false,
            finalState: [:],
            latencyMs: 0,
            error: nil
        )
    }
}

// MARK: - Evaluator

public enum AppleScriptEvaluator {

    /// How the loop's `execute:` seam is satisfied for a run.
    public enum Executor: Sendable {
        /// Canned per-step results (scripted CI). After the sequence is
        /// exhausted the last result repeats.
        case mockResults([AppleScriptExecutionResult])
        /// A minimal keyed "app world" that records writes and answers reads.
        case mockWorld(MockAppleScriptWorld)
        /// The real in-process `AppleScriptExecutor` (liveProof).
        case real
    }

    /// Everything a single run needs. Built by the eval runner from an
    /// `expect.appleScript` block; defaults keep a minimal case runnable.
    public struct Config: Sendable {
        public var lane: AppleScriptEvalLane
        public var task: String
        public var mode: AppleScriptRunMode
        public var executionMode: AppleScriptExecutionMode
        /// Verbatim literals (merged `content` + `contents`) injected into the run.
        public var literals: [String: String]
        public var harness: AppleScriptHarnessOptions
        public var maxSteps: Int
        public var wallClockSeconds: TimeInterval
        /// Preferred AppleScript model id (resolved against the installed catalog).
        public var model: String?
        public var environmentContext: String?
        /// The confirm-each answer for `automate` runs (default: approve).
        public var confirmApproves: Bool
        /// Canned `run_applescript` arguments JSON, one per step (scripted lane).
        public var scriptedCalls: [String]
        public var executor: Executor
        /// Result returned for a script the mock world doesn't recognize.
        public var mockDefault: AppleScriptExecutionResult

        public init(
            lane: AppleScriptEvalLane,
            task: String,
            mode: AppleScriptRunMode = .automate,
            executionMode: AppleScriptExecutionMode = .autoRunWithWarning,
            literals: [String: String] = [:],
            harness: AppleScriptHarnessOptions = .default,
            maxSteps: Int = 12,
            wallClockSeconds: TimeInterval = 240,
            model: String? = nil,
            environmentContext: String? = nil,
            confirmApproves: Bool = true,
            scriptedCalls: [String] = [],
            executor: Executor = .mockResults([]),
            mockDefault: AppleScriptExecutionResult = AppleScriptExecutionResult(
                status: .success,
                output: nil,
                errorNumber: nil,
                errorMessage: nil
            )
        ) {
            self.lane = lane
            self.task = task
            self.mode = mode
            self.executionMode = executionMode
            self.literals = literals
            self.harness = harness
            self.maxSteps = maxSteps
            self.wallClockSeconds = wallClockSeconds
            self.model = model
            self.environmentContext = environmentContext
            self.confirmApproves = confirmApproves
            self.scriptedCalls = scriptedCalls
            self.executor = executor
            self.mockDefault = mockDefault
        }
    }

    /// Drive one AppleScript eval run and return its transcript. Live lanes
    /// resolve the dedicated AppleScript model and SKIP (rather than fail) when
    /// none is installed. `liveProof` always uses the real executor regardless
    /// of the configured one.
    public static func run(_ config: Config) async -> AppleScriptEvalTranscript {
        // Resolve the model + model-step seam per lane.
        var ranModel = false
        var resolvedModelId: String?
        var nextScript: AppleScriptStepProvider?
        switch config.lane {
        case .scripted:
            let sequencer = ScriptedCallSequencer(config.scriptedCalls)
            nextScript = { _ in await sequencer.next() }
        case .live, .liveProof:
            guard
                let modelId = AppleScriptModelCatalog.resolveInstalledModelId(preferred: config.model)
            else {
                return .skippedRun(
                    lane: config.lane,
                    reason:
                        "No AppleScript model installed; skipping the \(config.lane.rawValue) lane."
                )
            }
            resolvedModelId = modelId
            ranModel = true
        }

        // liveProof forces the real executor; other lanes honor the config.
        let effectiveExecutor: Executor = config.lane == .liveProof ? .real : config.executor

        // Executor seam + a script log that records every executed script for
        // regex / effect assertions across all lanes.
        let scriptLog = MutableScriptLog()
        let mockWorld = MutableMockWorld(effectiveExecutor)
        let baseRunner: AppleScriptRunner
        switch effectiveExecutor {
        case .real:
            baseRunner = { await AppleScriptExecutor.run(source: $0) }
        case .mockResults(let results):
            let cannedBox = MutableCannedResults(results, fallback: config.mockDefault)
            baseRunner = { _ in cannedBox.next() }
        case .mockWorld:
            let fallback = config.mockDefault
            baseRunner = { script in mockWorld.handle(script, fallback: fallback) }
        }
        let runner: AppleScriptRunner = { script in
            scriptLog.append(script)
            return await baseRunner(script)
        }

        let proposals = MutableProposalLog()
        let feed = SubagentFeed(
            toolCallId: "eval-as-\(UUID().uuidString)",
            kindId: "applescript",
            title: config.task
        )
        let limits = RunLimits(
            maxSteps: config.maxSteps,
            wallClockSeconds: config.wallClockSeconds
        )
        let started = Date()
        let result = await AppleScriptLoop.run(
            task: config.task,
            modelId: resolvedModelId ?? "applescript-eval-scripted",
            feed: feed,
            interrupt: InterruptToken(),
            executionMode: config.executionMode,
            confirm: { _ in config.confirmApproves },
            limits: limits,
            sessionId: "eval-as-\(UUID().uuidString)",
            mode: config.mode,
            environmentContext: config.environmentContext,
            literals: AppleScriptLiterals(config.literals),
            harness: config.harness,
            execute: runner,
            nextScript: nextScript,
            observeProposal: { proposals.append($0) }
        )
        let latencyMs = Date().timeIntervalSince(started) * 1000

        return AppleScriptEvalTranscript(
            lane: config.lane,
            ranModel: ranModel,
            modelId: resolvedModelId,
            skipped: false,
            skipReason: nil,
            outcome: outcomeName(result.outcome),
            status: aggregateStatus(result),
            summary: result.outcome.summary,
            scriptsExecuted: result.scriptsExecuted,
            succeeded: result.succeeded,
            failed: result.failed,
            modelTokens: result.modelTokens,
            lastOutput: result.lastOutput,
            steps: result.steps,
            proposals: proposals.all(),
            executedScripts: scriptLog.all(),
            blockedWrite: result.steps.contains { $0.status == "blocked" },
            finalState: mockWorld.snapshot(),
            latencyMs: latencyMs,
            error: nil
        )
    }

    // MARK: - Helpers

    private static func outcomeName(_ outcome: AppleScriptRunResult.Outcome) -> String {
        switch outcome {
        case .done: return "done"
        case .interrupted: return "interrupted"
        case .stepCapReached: return "stepCapReached"
        case .failed: return "failed"
        }
    }

    /// Honest aggregate status, matching `AppleScriptKind.aggregateStatus`.
    private static func aggregateStatus(_ result: AppleScriptRunResult) -> String {
        if result.scriptsExecuted == 0 { return result.outcome.isSuccess ? "succeeded" : "failed" }
        if result.failed == 0 { return result.outcome.isSuccess ? "succeeded" : "partial" }
        if result.succeeded == 0 { return "failed" }
        return "partial"
    }
}

// MARK: - Scripted model step (scripted lane)

/// Hands the loop a canned sequence of `run_applescript` calls (arguments JSON),
/// then `nil` to signal completion. After the sequence is exhausted it keeps
/// returning `nil`, so the loop's natural completion path fires.
private actor ScriptedCallSequencer {
    private let calls: [String]
    private var index = 0

    init(_ calls: [String]) { self.calls = calls }

    func next() -> ModelActionCall? {
        guard index < calls.count else { return nil }
        defer { index += 1 }
        return ModelActionCall(id: "eval-step-\(index)", arguments: calls[index])
    }
}

// MARK: - Thread-safe collectors

/// Records every executed (expanded) script. The loop's `execute:` seam is
/// `@Sendable` and may run off any actor, so a lock guards the buffer.
private final class MutableScriptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ script: String) {
        lock.lock()
        items.append(script)
        lock.unlock()
    }
    func all() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Collects proposal records surfaced by the loop's `observeProposal` seam.
private final class MutableProposalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AppleScriptProposalRecord] = []
    func append(_ record: AppleScriptProposalRecord) {
        lock.lock()
        items.append(record)
        lock.unlock()
    }
    func all() -> [AppleScriptProposalRecord] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Serves canned per-step results; repeats the last once exhausted.
private final class MutableCannedResults: @unchecked Sendable {
    private let lock = NSLock()
    private let results: [AppleScriptExecutionResult]
    private let fallback: AppleScriptExecutionResult
    private var index = 0

    init(_ results: [AppleScriptExecutionResult], fallback: AppleScriptExecutionResult) {
        self.results = results
        self.fallback = fallback
    }

    func next() -> AppleScriptExecutionResult {
        lock.lock()
        defer { lock.unlock() }
        guard !results.isEmpty else { return fallback }
        let result = index < results.count ? results[index] : (results.last ?? fallback)
        index += 1
        return result
    }
}

/// Wraps a mutable `MockAppleScriptWorld` behind a lock so the `@Sendable`
/// executor seam can mutate it. Inert unless the executor is `.mockWorld`.
private final class MutableMockWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var world: MockAppleScriptWorld?

    init(_ executor: AppleScriptEvaluator.Executor) {
        if case .mockWorld(let seed) = executor { self.world = seed }
    }

    func handle(_ script: String, fallback: AppleScriptExecutionResult) -> AppleScriptExecutionResult {
        lock.lock()
        defer { lock.unlock() }
        guard var current = world else { return fallback }
        let result = current.handle(script, fallback: fallback)
        world = current
        return result
    }

    func snapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return world?.snapshot() ?? [:]
    }
}
