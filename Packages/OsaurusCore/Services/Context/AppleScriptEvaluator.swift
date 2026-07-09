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
    /// Model-generation throughput (tokens per second over model-step time
    /// only), `nil` when the run generated nothing. AGENTS.md: every generation
    /// row records token/s.
    public let tokensPerSecond: Double?
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
            tokensPerSecond: nil,
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
        /// Per-model-step inference budget (seconds). Slow models on
        /// multi-step cases need more than the 90s loop default.
        public var modelStepTimeoutSeconds: TimeInterval
        /// Preferred AppleScript model id (resolved against the installed catalog).
        public var model: String?
        /// EXPLICIT sampling-temperature override for A/B isolation runs
        /// (recorded in the case). `nil` = the model bundle's own defaults.
        public var samplingTemperature: Double?
        public var environmentContext: String?
        /// The confirm-each answer for `automate` runs (default: approve).
        public var confirmApproves: Bool
        /// Canned `run_applescript` arguments JSON, one per step (scripted lane).
        public var scriptedCalls: [String]
        public var executor: Executor
        /// Result returned for a script the mock world doesn't recognize.
        public var mockDefault: AppleScriptExecutionResult
        /// Real-executor readiness probe (liveProof): a tiny READ-ONLY script
        /// against the same app the task automates, run with a short bound
        /// BEFORE the model loop. On an unattended machine the first Apple
        /// event to an ungrantable app parks the OSA queue thread inside the
        /// TCC consent send — observed live as a 600s per-case watchdog trip
        /// that terminated the suite and skipped every scripted case queued
        /// behind it, identically for local and remote models. The probe
        /// converts that environment into an honest ≤`probeTimeout` SKIP
        /// ("permission not grantable here") while a granted machine pays
        /// <1s and runs the real case unchanged.
        public var automationProbeScript: String?
        /// Wall-clock bound for the probe. A pending consent dialog never
        /// returns, so this is the entire cost of skipping on an unattended
        /// host. 15s absorbs a cold target-app launch on a granted machine.
        public var automationProbeTimeout: TimeInterval
        /// Test seam for the probe execution (nil → the real bounded
        /// `AppleScriptExecutor.run`). Never used for the scored run itself.
        public var automationProbeRunner: AppleScriptRunner?

        public init(
            lane: AppleScriptEvalLane,
            task: String,
            mode: AppleScriptRunMode = .automate,
            executionMode: AppleScriptExecutionMode = .autoRunWithWarning,
            literals: [String: String] = [:],
            harness: AppleScriptHarnessOptions = .default,
            maxSteps: Int = 12,
            wallClockSeconds: TimeInterval = 240,
            modelStepTimeoutSeconds: TimeInterval = 90,
            model: String? = nil,
            samplingTemperature: Double? = nil,
            environmentContext: String? = nil,
            confirmApproves: Bool = true,
            scriptedCalls: [String] = [],
            executor: Executor = .mockResults([]),
            mockDefault: AppleScriptExecutionResult = AppleScriptExecutionResult(
                status: .success,
                output: nil,
                errorNumber: nil,
                errorMessage: nil
            ),
            automationProbeScript: String? = nil,
            automationProbeTimeout: TimeInterval = 15,
            automationProbeRunner: AppleScriptRunner? = nil
        ) {
            self.lane = lane
            self.task = task
            self.mode = mode
            self.executionMode = executionMode
            self.literals = literals
            self.harness = harness
            self.maxSteps = maxSteps
            self.wallClockSeconds = wallClockSeconds
            self.modelStepTimeoutSeconds = modelStepTimeoutSeconds
            self.model = model
            self.samplingTemperature = samplingTemperature
            self.environmentContext = environmentContext
            self.confirmApproves = confirmApproves
            self.scriptedCalls = scriptedCalls
            self.executor = executor
            self.mockDefault = mockDefault
            self.automationProbeScript = automationProbeScript
            self.automationProbeTimeout = automationProbeTimeout
            self.automationProbeRunner = automationProbeRunner
        }
    }

    /// Drive one AppleScript eval run and return its transcript. Live lanes
    /// resolve the dedicated AppleScript model and SKIP (rather than fail) when
    /// none is installed. `liveProof` always uses the real executor regardless
    /// of the configured one.
    public static func run(_ config: Config) async -> AppleScriptEvalTranscript {
        // liveProof forces the real executor; other lanes honor the config.
        let effectiveExecutor: Executor = config.lane == .liveProof ? .real : config.executor

        // Real-executor readiness probe, FIRST — before model resolution, so
        // an unattended machine yields a fast honest SKIP without touching
        // the model catalog or burning tokens, instead of parking the suite
        // on an Automation consent dialog nobody can click.
        if case .real = effectiveExecutor, let probeScript = config.automationProbeScript {
            let probe: AppleScriptExecutionResult
            if let probeRunner = config.automationProbeRunner {
                probe = await probeRunner(probeScript, .appleScript)
            } else {
                probe = await AppleScriptExecutor.run(
                    source: probeScript,
                    timeout: config.automationProbeTimeout
                )
            }
            if !probe.isSuccess {
                let detail: String
                switch probe.status {
                case .timedOut:
                    detail =
                        "the probe did not answer within \(Int(config.automationProbeTimeout))s "
                        + "— usually a pending macOS Automation consent dialog no one can "
                        + "approve in an unattended run"
                case .permissionRequired:
                    detail =
                        "Automation permission is denied for this process "
                        + "(error \(probe.errorNumber.map(String.init) ?? "-1743"))"
                default:
                    detail =
                        "probe \(probe.status.rawValue)"
                        + (probe.errorMessage.map { ": \($0)" } ?? "")
                }
                return .skippedRun(
                    lane: config.lane,
                    reason:
                        "liveProof environment not ready — \(detail). Grant Osaurus access to "
                        + "the target app under System Settings → Privacy & Security → "
                        + "Automation, then re-run locally."
                )
            }
        }

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

        // Executor seam + a script log that records every executed script for
        // regex / effect assertions across all lanes.
        let scriptLog = MutableScriptLog()
        let mockWorld = MutableMockWorld(effectiveExecutor)
        let baseRunner: AppleScriptRunner
        switch effectiveExecutor {
        case .real:
            baseRunner = { await AppleScriptExecutor.run(source: $0, language: $1) }
        case .mockResults(let results):
            let cannedBox = MutableCannedResults(results, fallback: config.mockDefault)
            baseRunner = { _, _ in cannedBox.next() }
        case .mockWorld:
            let fallback = config.mockDefault
            baseRunner = { script, _ in mockWorld.handle(script, fallback: fallback) }
        }
        let runner: AppleScriptRunner = { script, language in
            scriptLog.append(script)
            return await baseRunner(script, language)
        }
        // The script-log wrapper makes `execute` non-nil, which would disable
        // the loop's default compile-before-confirm; restore it explicitly for
        // the REAL executor so liveProof exercises the production gate. Mock
        // lanes stay checker-free (deterministic, no OSA dependency).
        var compileCheck: AppleScriptCompileCheck?
        if case .real = effectiveExecutor {
            compileCheck = { await AppleScriptExecutor.compileCheck(source: $0, language: $1) }
        }

        let proposals = MutableProposalLog()
        let feed = SubagentFeed(
            toolCallId: "eval-as-\(UUID().uuidString)",
            kindId: "applescript",
            title: config.task
        )
        let limits = RunLimits(
            maxSteps: config.maxSteps,
            wallClockSeconds: config.wallClockSeconds,
            modelStepTimeoutSeconds: config.modelStepTimeoutSeconds
        )
        // App knowledge (dictionary + recipes) for live lanes, composed exactly
        // as production does — from the task plus the case's environment
        // context (the `desktopContext()` format). The scripted lane runs no
        // model, so composing prompt knowledge there would be dead weight.
        var dictionaryContext: String?
        var recipeContext: String?
        if ranModel, config.harness.includeDictionaryContext || config.harness.includeAppRecipes {
            let parsed = AppleScriptAppKnowledge.parseEnvironmentContext(config.environmentContext)
            let apps = AppleScriptAppKnowledge.detectTargetApps(
                task: config.task,
                frontmost: parsed.frontmost,
                runningAppNames: parsed.runningNames
            )
            let sections = AppleScriptAppKnowledge.compose(
                apps: apps,
                runningApps: parsed.runningNames.map {
                    AppleScriptAppKnowledge.RunningApp(name: $0, bundleURL: nil)
                }
            )
            dictionaryContext = sections.dictionary
            recipeContext = sections.recipes
        }
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
            dictionaryContext: dictionaryContext,
            recipeContext: recipeContext,
            literals: AppleScriptLiterals(config.literals),
            harness: config.harness,
            execute: runner,
            nextScript: nextScript,
            observeProposal: { proposals.append($0) },
            compileCheck: compileCheck,
            samplingTemperature: config.samplingTemperature
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
            tokensPerSecond: result.tokensPerSecond,
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
