//
//  EvalRunnerSubagent.swift
//  OsaurusEvalsKit
//
//  Runner for the `subagent` domain: drives the shared `SubagentSession`
//  host through `SubagentJobEvaluator` and scores the compact result
//  envelope + the unified `SubagentFeed`. Three lanes mirror the four
//  subagent paths the unified framework collapsed onto one host:
//
//    - scripted: model-free. The full host lifecycle (resolve → permission
//      → handoff → run → normalize → cleanup), the unified recursion guard,
//      and the feed lifecycle run in CI with no tokens — the deterministic
//      seam the whole subagent family rides on. This lane also runs as
//      eval-kit unit tests (mirror `ComputerUseLoopEvalTests`).
//    - spawn: live. The real `spawn_agent` path (host + `TextSubagentKind`)
//      against a user-configured spawnable agent — the text-subagent path.
//    - spawn_model: live. The real `spawn_model` path (host + `TextSubagentKind`)
//      against a bare spawnable model id with NO agent/system prompt.
//    - spawn_model_residency: live. The PRODUCTION residency path (no eval
//      passthrough seam) with an independent orchestrator + target, proving the
//      real unload/reload across all four directions (local↔local, local↔remote,
//      remote↔local, remote↔remote) with RAM footprint.
//    - image: live. The real `ImageTool` (host + `ImageSubagentKind`);
//      `sourcePaths` non-empty selects the edit path, empty selects generate.
//
//  Live lanes SKIP (not fail) when the host can't satisfy a happy-path case
//  (no spawnable agent, image delegation off, model not ready) — same
//  `requirePlugins`-style semantics the other domains use so a report shared
//  across machines reads "didn't apply" rather than "regressed".
//

import Foundation
import OsaurusCore

extension EvalRunner {

    /// Subagent host evaluator for `domain == "subagent"`.
    static func runSubagentCase(
        _ testCase: EvalCase,
        modelId: String
    ) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id

        guard let exp = testCase.expect.subagent else {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: ["missing `expect.subagent`"],
                modelId: modelId
            )
        }

        switch exp.lane {
        case "scripted":
            return await scoreScriptedLane(testCase, exp: exp, modelId: modelId, label: label)
        case "spawn":
            return await scoreSpawnLane(testCase, exp: exp, modelId: modelId, label: label)
        case "spawn_model":
            return await scoreSpawnModelLane(testCase, exp: exp, modelId: modelId, label: label)
        case "spawn_model_residency":
            return await scoreSpawnModelResidencyLane(testCase, exp: exp, modelId: modelId, label: label)
        case "image":
            return await scoreImageLane(testCase, exp: exp, modelId: modelId, label: label)
        case "computer_use":
            return await scoreComputerUseLane(testCase, exp: exp, modelId: modelId, label: label)
        default:
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: [
                    "unknown subagent lane '\(exp.lane)' "
                        + "(expected scripted|spawn|spawn_model|spawn_model_residency|image|computer_use)"
                ],
                modelId: modelId
            )
        }
    }

    // MARK: - Scripted lane (model-free, CI-safe)

    private static func scoreScriptedLane(
        _ testCase: EvalCase,
        exp: EvalCase.SubagentExpectations,
        modelId: String,
        label: String
    ) async -> EvalCaseReport {
        // Reject malformed failure enum values up front so a typo in a case
        // file errors instead of silently degrading to "no failure".
        if let raw = exp.resolveFailure, ScriptedSubagentSpec.Failure(rawValue: raw) == nil {
            return scriptedSpecError(testCase, label: label, modelId: modelId, field: "resolveFailure", raw: raw)
        }
        if let raw = exp.runFailure, ScriptedSubagentSpec.Failure(rawValue: raw) == nil {
            return scriptedSpecError(testCase, label: label, modelId: modelId, field: "runFailure", raw: raw)
        }

        let parallel = exp.parallel ?? 1
        let spec = ScriptedSubagentSpec(
            kindId: "scripted",
            needsHandoff: exp.needsHandoff ?? false,
            decision: mapDecision(exp.decision),
            resolveFailure: exp.resolveFailure.flatMap(ScriptedSubagentSpec.Failure.init(rawValue:)),
            runFailure: exp.runFailure.flatMap(ScriptedSubagentSpec.Failure.init(rawValue:)),
            recurse: exp.recurse ?? false,
            phases: exp.phases ?? ["running"],
            remote: exp.remote ?? false,
            runDelayMs: exp.runDelayMs ?? 0,
            includeUsageAccounting: exp.includeUsageAccounting ?? false,
            rendezvousArrivals: (exp.rendezvous ?? false) ? max(2, parallel) : 0
        )
        // `parallel ≥ 2` drives the parallel-batch path (one batch, N
        // concurrent host runs, shared overlap probe); otherwise one run,
        // optionally stopped mid-run through the real interrupt center.
        let transcript: SubagentJobTranscript
        if parallel >= 2 {
            transcript = await SubagentJobEvaluator.runScriptedParallelBatch(spec, count: parallel)
        } else {
            transcript = await SubagentJobEvaluator.runScripted(
                spec,
                interruptAfterMs: exp.interruptAfterMs
            )
        }
        let (passed, notes) = score(transcript, against: exp)
        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: passed ? .passed : .failed,
            notes: notes,
            modelId: modelId,
            latencyMs: transcript.latencyMs
        )
    }

    // MARK: - Live spawn lane

    private static func scoreSpawnLane(
        _ testCase: EvalCase,
        exp: EvalCase.SubagentExpectations,
        modelId: String,
        label: String
    ) async -> EvalCaseReport {
        guard let agent = exp.agent, let input = exp.input else {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: ["spawn lane needs `agent` + `input`"],
                modelId: modelId
            )
        }
        // Pass the run `modelId` so the spawned agent runs on it (instead of
        // its own pinned model), making `spawn` a real cross-model column.
        // Positive cases opt into agent seeding (so they RUN anywhere across
        // models); negative guards (not-spawnable) must NOT be seeded.
        let interruptAfterMs = exp.interruptAfterMs
        let transcript: SubagentJobTranscript
        if exp.seedSpawnableAgent == true {
            transcript = await SubagentJobEvaluator.withSpawnableAgent(name: agent) {
                await SubagentJobEvaluator.runSpawn(
                    agent: agent,
                    input: input,
                    modelId: modelId,
                    interruptAfterMs: interruptAfterMs
                )
            }
        } else {
            transcript = await SubagentJobEvaluator.runSpawn(
                agent: agent,
                input: input,
                modelId: modelId,
                interruptAfterMs: interruptAfterMs
            )
        }
        return finishLive(testCase, exp: exp, transcript: transcript, lane: "spawn", modelId: modelId, label: label)
    }

    // MARK: - Live spawn_model lane

    private static func scoreSpawnModelLane(
        _ testCase: EvalCase,
        exp: EvalCase.SubagentExpectations,
        modelId: String,
        label: String
    ) async -> EvalCaseReport {
        guard let input = exp.input else {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: ["spawn_model lane needs `input`"],
                modelId: modelId
            )
        }
        // Target model: an explicit `model` (negative guards target an
        // unseeded id) else the RUN model, so a seeded happy-path case is a real
        // cross-model column. Positive cases opt into seeding the model into the
        // spawnable pool (so they RUN anywhere); negative guards (not-spawnable)
        // must NOT be seeded.
        let target = exp.model ?? modelId
        let interruptAfterMs = exp.interruptAfterMs
        let transcript: SubagentJobTranscript
        if exp.seedSpawnableModel == true {
            // `seedSpawnToolAccess: "readOnly"` additionally grants the child
            // the curated read-only toolset for the run (tool-capable lane).
            // Accept the friendly camelCase spelling and the stored raw value.
            let toolAccess: SpawnToolAccess? = exp.seedSpawnToolAccess.flatMap {
                switch $0 {
                case "readOnly", "read_only": return .readOnly
                case "none": return SpawnToolAccess.none
                default: return SpawnToolAccess(rawValue: $0)
                }
            }
            transcript = await SubagentJobEvaluator.withSpawnableModel(
                id: target,
                toolAccess: toolAccess
            ) {
                await SubagentJobEvaluator.runSpawnModel(
                    model: target,
                    input: input,
                    interruptAfterMs: interruptAfterMs
                )
            }
        } else {
            transcript = await SubagentJobEvaluator.runSpawnModel(
                model: target,
                input: input,
                interruptAfterMs: interruptAfterMs
            )
        }
        return finishLive(
            testCase,
            exp: exp,
            transcript: transcript,
            lane: "spawn_model",
            modelId: modelId,
            label: label
        )
    }

    // MARK: - Live spawn_model residency-direction lane

    /// Drive the PRODUCTION `spawn_model` residency path (NOT the eval
    /// passthrough seam) with an independent `orchestrator` (resident chat
    /// model) + `model` (target) so the real `SubagentResidency.resolve`
    /// decision + `ResidencyHandoff` run end-to-end — the only lane that proves
    /// the actual unload/reload across all four directions. Peak RAM is captured
    /// by the outer resource-sampled dispatch (`subagent` is a sampled domain),
    /// so a local→local swap records its footprint automatically. SKIPS (via the
    /// facade's `unavailable` envelope + `finishLive`) when a required local
    /// model isn't installed or a remote target isn't routable.
    ///
    /// The run `modelId` does NOT drive the decision (the case pins
    /// orchestrator + target); it only governs which remote provider the CLI
    /// bootstrapped, so run the suite with a REMOTE `--model` (e.g.
    /// `xai/grok-4.3`) whenever a direction targets a remote model — local
    /// targets stay routable regardless.
    private static func scoreSpawnModelResidencyLane(
        _ testCase: EvalCase,
        exp: EvalCase.SubagentExpectations,
        modelId: String,
        label: String
    ) async -> EvalCaseReport {
        guard let orchestrator = exp.orchestrator, let target = exp.model, let input = exp.input
        else {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: [
                    "spawn_model_residency lane needs `orchestrator` + `model` (target) + `input`"
                ],
                modelId: modelId
            )
        }

        // Matrix-lane extensions over the single-shot direction case: repeated
        // rapid cycles, sentinel context-recall, marker-leak and
        // restore-verified checks per cycle, and a before/after crash-report
        // count around the whole case.
        let cycles = max(1, exp.cycles ?? 1)
        let effectiveInput = composedInput(input, sentinel: exp.sentinel)
        let crashBaseline: Set<String>? =
            (exp.expectNoNewCrashReports == true) ? crashReportSnapshot() : nil

        var cycleNotes: [String] = []
        var cyclesPassed = true
        var lastTranscript: SubagentJobTranscript?

        for cycle in 1 ... cycles {
            let transcript = await SubagentJobEvaluator.runSpawnModelResidency(
                orchestrator: orchestrator,
                target: target,
                handoffEnabled: exp.handoffEnabled ?? true,
                ensureResident: exp.ensureResident ?? false,
                input: effectiveInput
            )

            // Availability-skip: when the FIRST cycle can't run on this host
            // (model not installed / remote not routable) and the case didn't
            // expect that envelope, the whole case reads "didn't apply".
            let availabilitySkipKinds: Set<String> = ["rejected", "unavailable", "user_denied"]
            if cycle == 1,
                !transcript.succeeded,
                availabilitySkipKinds.contains(transcript.envelopeKind),
                exp.expectEnvelopeKind != transcript.envelopeKind
            {
                return .terminal(
                    id: testCase.id,
                    label: label,
                    domain: testCase.domain,
                    outcome: .skipped,
                    notes: [
                        "live spawn_model_residency lane unavailable on this host: "
                            + (transcript.error ?? transcript.envelopeKind)
                    ],
                    modelId: modelId
                )
            }

            // Per-cycle checks (multi-cycle cases must hold EVERY cycle; the
            // standard matchers run once against the last transcript below).
            func cycleCheck(_ ok: Bool, _ pass: String, _ fail: String) {
                cyclesPassed = cyclesPassed && ok
                cycleNotes.append(ok ? "cycle \(cycle): \(pass)" : "cycle \(cycle): \(fail)")
            }
            if cycles > 1 || exp.sentinel != nil || exp.expectNoMarkerLeaks == true
                || exp.expectRestoredResident == true
            {
                if let wantSuccess = exp.expectSuccess {
                    cycleCheck(
                        transcript.succeeded == wantSuccess,
                        "success \(transcript.succeeded)",
                        "expected success=\(wantSuccess), got \(transcript.succeeded) "
                            + "(\(transcript.envelopeKind): \(transcript.error ?? "-"))"
                    )
                }
            }
            if let sentinel = exp.sentinel {
                cycleCheck(
                    transcript.summary.localizedCaseInsensitiveContains(sentinel),
                    "sentinel '\(sentinel)' recalled",
                    "sentinel '\(sentinel)' MISSING from digest (got: \(transcript.summary.prefix(120)))"
                )
            }
            if exp.expectNoMarkerLeaks == true {
                let leaks = markerLeaks(in: transcript.summary)
                cycleCheck(
                    leaks.isEmpty,
                    "no marker leaks",
                    "raw markers leaked into the digest: \(leaks)"
                )
            }
            if exp.expectRestoredResident == true {
                cycleCheck(
                    transcript.restoredResident == true,
                    "orchestrator restored resident",
                    "orchestrator NOT verified resident after the run "
                        + "(restoredResident=\(String(describing: transcript.restoredResident)))"
                )
            }
            lastTranscript = transcript
        }

        guard let final = lastTranscript else {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: ["residency matrix lane produced no transcript"],
                modelId: modelId
            )
        }

        // Standard matchers against the last cycle's transcript.
        var (passed, notes) = score(final, against: exp)
        passed = passed && cyclesPassed
        notes.append(contentsOf: cycleNotes)
        if cycles > 1 { notes.append("cycles: \(cycles) rapid cycles completed") }

        // Crash-report gate: zero NEW osaurus-related reports across the case.
        if let baseline = crashBaseline {
            let fresh = crashReportSnapshot().subtracting(baseline)
            if fresh.isEmpty {
                notes.append("crash reports: none new")
            } else {
                passed = false
                notes.append("NEW crash reports appeared: \(fresh.sorted().joined(separator: ", "))")
            }
        }

        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: passed ? .passed : .failed,
            notes: notes,
            modelId: modelId,
            latencyMs: final.latencyMs
        )
    }

    /// Compose the effective residency-lane input: the case input plus the
    /// sentinel echo instruction, so recall across the handoff is assertable.
    nonisolated static func composedInput(_ input: String, sentinel: String?) -> String {
        guard let sentinel, !sentinel.isEmpty else { return input }
        return input + " Include the exact token \"\(sentinel)\" verbatim in your reply."
    }

    /// Raw parser/template/tool markers that must never reach a digest a
    /// parent agent consumes. Curated from the chat-template families the
    /// runtime hosts (think tags, ChatML/Gemma turn markers, tool-call tags,
    /// llama instruction markers).
    nonisolated static let leakMarkers: [String] = [
        "<think>", "</think>",
        "<|",
        "<tool_call>", "</tool_call>", "[TOOL_CALLS]",
        "<start_of_turn>", "<end_of_turn>",
        "[/INST]", "<<SYS>>",
    ]

    /// The subset of `leakMarkers` present in `text` (empty = clean).
    nonisolated static func markerLeaks(in text: String) -> [String] {
        leakMarkers.filter { text.contains($0) }
    }

    /// Names of osaurus-related crash reports currently on disk
    /// (`~/Library/Logs/DiagnosticReports/*.ips|*.crash` whose filename
    /// mentions osaurus, case-insensitive). Compared before/after a matrix
    /// case to assert zero new reports — the crash-count gate.
    nonisolated static func crashReportSnapshot() -> Set<String> {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        guard
            let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        return Set(
            names.filter { name in
                let lower = name.lowercased()
                return (lower.hasSuffix(".ips") || lower.hasSuffix(".crash"))
                    && lower.contains("osaurus")
            }
        )
    }

    // MARK: - Live image lane

    private static func scoreImageLane(
        _ testCase: EvalCase,
        exp: EvalCase.SubagentExpectations,
        modelId: String,
        label: String
    ) async -> EvalCaseReport {
        guard let prompt = exp.prompt else {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: ["image lane needs `prompt`"],
                modelId: modelId
            )
        }
        let transcript = await SubagentJobEvaluator.runImage(
            prompt: prompt,
            sourcePaths: exp.sourcePaths ?? [],
            model: exp.model
        )
        return finishLive(testCase, exp: exp, transcript: transcript, lane: "image", modelId: modelId, label: label)
    }

    // MARK: - Live computer_use lane (host + scripted driver)

    /// Drive the real `computer_use` host (`SubagentSession` + `ComputerUseKind`)
    /// against an in-memory `ScriptedCUDriver`, then score BOTH the host-parity
    /// transcript (envelope/feed/summary) AND the resulting world state (field
    /// values, clicks, verb trace) read back from the driver. Deterministic
    /// `scriptedActions` cases run for every model; live cases drive the run
    /// `modelId` and SKIP tiny-context models (which can't emit tool calls).
    private static func scoreComputerUseLane(
        _ testCase: EvalCase,
        exp: EvalCase.SubagentExpectations,
        modelId: String,
        label: String
    ) async -> EvalCaseReport {
        guard let app = exp.app, let elements = exp.elements else {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: ["computer_use lane needs `app` + `elements`"],
                modelId: modelId
            )
        }

        // A scripted scene drives the loop with no model call; otherwise the
        // live `modelId` does. nil OR empty `scriptedActions` ⇒ live.
        let isLive = (exp.scriptedActions?.isEmpty ?? true)
        if isLive {
            let window = ContextSizeResolver.resolve(modelId: modelId)
            if window.sizeClass.disablesTools {
                return .terminal(
                    id: testCase.id,
                    label: label,
                    domain: testCase.domain,
                    outcome: .skipped,
                    notes: [
                        "tools auto-disabled for '\(modelId)': context size class "
                            + "\(window.sizeClass) (≤\(ContextSizeResolver.tinyCeiling)-token window) "
                            + "strips the agent_action tool schema the Computer Use loop forces; "
                            + "live model-driven case skipped"
                    ],
                    modelId: modelId
                )
            }
        }

        // The driver is OURS, so we read back the world state after the host
        // run; the gate is permissive-by-default (`autonomous` auto-runs every
        // effect) unless the case picks a stricter preset (confirms auto-approve).
        let driver = ScriptedCUDriver(app: app, elements: elements)
        let preset = AutonomyPreset(rawValue: exp.preset ?? "autonomous") ?? .autonomous
        let gate = ComputerUseGate(policy: AutonomyPolicy(globalPreset: preset))

        let transcript = await SubagentJobEvaluator.runComputerUse(
            goal: testCase.query,
            modelId: modelId,
            driver: driver,
            gate: gate,
            vision: .none,
            scriptedActions: isLive ? nil : exp.scriptedActions,
            maxSteps: exp.maxSteps ?? 16
        )

        // Host-parity matchers (envelope/feed/summary/resultKind).
        var (passed, notes) = score(transcript, against: exp)

        // World-state read-back — the substantive "did it work" check.
        let finalValues = await driver.finalValues()
        let verbTrace = await driver.verbTrace()
        func check(_ ok: Bool, pass: String, fail: String) {
            passed = passed && ok
            notes.append(ok ? pass : fail)
        }
        for predicate in exp.successValues ?? [] {
            let value = (finalValues[predicate.id] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let exact = predicate.equals {
                check(
                    value == exact.trimmingCharacters(in: .whitespacesAndNewlines),
                    pass: "value[\(predicate.id)] == '\(exact)'",
                    fail: "value[\(predicate.id)] = '\(value)' != '\(exact)'"
                )
            }
            if let needle = predicate.contains {
                check(
                    value.localizedCaseInsensitiveContains(needle),
                    pass: "value[\(predicate.id)] contains '\(needle)'",
                    fail: "value[\(predicate.id)] = '\(value)' missing '\(needle)'"
                )
            }
        }
        for id in exp.successClicked ?? [] {
            let clicked = await driver.wasClicked(id)
            check(clicked, pass: "clicked '\(id)'", fail: "never clicked '\(id)'")
        }
        for id in exp.failIfClicked ?? [] {
            let clicked = await driver.wasClicked(id)
            check(!clicked, pass: "correctly avoided '\(id)'", fail: "clicked forbidden '\(id)'")
        }
        if let order = exp.expectVerbsInOrder, !order.isEmpty {
            check(
                containsSubsequence(verbTrace, order),
                pass: "verb order ok: \(order) ⊑ [\(verbTrace.joined(separator: ","))]",
                fail: "verb order \(order) not a subsequence of [\(verbTrace.joined(separator: ","))]"
            )
        }
        notes.append("verbs: [\(verbTrace.joined(separator: ","))]")
        if !passed {
            notes.append(
                "final values: "
                    + finalValues.keys.sorted()
                    .map { "\($0)='\(finalValues[$0] ?? "")'" }
                    .joined(separator: " ")
            )
        }

        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: passed ? .passed : .failed,
            notes: notes,
            modelId: modelId,
            latencyMs: transcript.latencyMs,
            toolUsage: verbUsageStats(verbTrace)
        )
    }

    // MARK: - Shared scoring

    /// Convert a live-lane transcript into a report, applying the
    /// availability-skip rule: when the run failed with a host-availability
    /// envelope (`rejected`/`unavailable`/`user_denied`) that the case did NOT
    /// ask for, SKIP rather than fail — a machine without a spawnable agent,
    /// image delegation, or a ready model reads as "didn't apply" instead of
    /// "regressed" (same semantics as `requirePlugins`). A negative case that
    /// EXPECTS exactly that envelope (e.g. "delegation off → rejected") still
    /// scores normally, and a real runtime failure (`execution_error` /
    /// `timeout` / `invalid_args` on a configured host) still fails.
    private static func finishLive(
        _ testCase: EvalCase,
        exp: EvalCase.SubagentExpectations,
        transcript: SubagentJobTranscript,
        lane: String,
        modelId: String,
        label: String
    ) -> EvalCaseReport {
        let availabilitySkipKinds: Set<String> = ["rejected", "unavailable", "user_denied"]
        let gotAvailabilityEnvelope =
            !transcript.succeeded && availabilitySkipKinds.contains(transcript.envelopeKind)
        let caseExpectedThisEnvelope = (exp.expectEnvelopeKind == transcript.envelopeKind)
        if gotAvailabilityEnvelope && !caseExpectedThisEnvelope {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .skipped,
                notes: [
                    "live \(lane) lane unavailable on this host: "
                        + (transcript.error ?? transcript.envelopeKind)
                ],
                modelId: modelId
            )
        }
        let (passed, notes) = score(transcript, against: exp)
        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: passed ? .passed : .failed,
            notes: notes,
            modelId: modelId,
            latencyMs: transcript.latencyMs
        )
    }

    /// Score every present matcher against the transcript. Returns
    /// `(passed, notes)`; an empty expectation set just records a summary line.
    private static func score(
        _ t: SubagentJobTranscript,
        against exp: EvalCase.SubagentExpectations
    ) -> (Bool, [String]) {
        var passed = true
        var notes: [String] = []
        func check(_ ok: Bool, pass: String, fail: String) {
            passed = passed && ok
            notes.append(ok ? pass : fail)
        }

        if let wantSuccess = exp.expectSuccess {
            check(
                t.succeeded == wantSuccess,
                pass: "success ok: \(t.succeeded)",
                fail: "expected success=\(wantSuccess), got \(t.succeeded) (\(t.envelopeKind))"
            )
        }
        if let kind = exp.expectEnvelopeKind {
            check(
                t.envelopeKind == kind,
                pass: "envelope kind ok: \(kind)",
                fail: "envelope kind '\(t.envelopeKind)' != '\(kind)'"
            )
        }
        if let resultKind = exp.expectResultKind {
            check(
                t.resultKind == resultKind,
                pass: "result kind ok: \(resultKind)",
                fail: "result kind '\(t.resultKind ?? "nil")' != '\(resultKind)'"
            )
        }
        // The terminal summary on success, or the error message on failure —
        // so a negative case can assert the rejection text.
        let haystack = t.succeeded ? t.summary : (t.error ?? t.summary)
        for needle in exp.summaryContains ?? [] {
            check(
                haystack.localizedCaseInsensitiveContains(needle),
                pass: "summary contains '\(needle)'",
                fail: "summary missing '\(needle)' (got: \(haystack.prefix(160)))"
            )
        }
        if let kinds = exp.expectFeedKinds {
            let present = Set(t.feedEventKinds)
            let missing = kinds.filter { !present.contains($0) }
            check(
                missing.isEmpty,
                pass: "feed kinds ok: \(kinds)",
                fail: "feed missing kinds \(missing) (got: [\(t.feedEventKinds.joined(separator: ","))])"
            )
        }
        if let order = exp.expectPhasesInOrder, !order.isEmpty {
            check(
                containsSubsequence(t.feedPhases, order),
                pass: "phase order ok: \(order)",
                fail: "phase order \(order) not a subsequence of [\(t.feedPhases.joined(separator: ","))]"
            )
        }
        if let wantHandoff = exp.expectHandoffWrapped {
            check(
                t.handoffWrapped == wantHandoff,
                pass: "handoffWrapped ok: \(wantHandoff)",
                fail: "handoffWrapped=\(String(describing: t.handoffWrapped)) != \(wantHandoff)"
            )
        }
        if let wantRefused = exp.expectNestedRefused {
            check(
                t.nestedRefused == wantRefused,
                pass: "nestedRefused ok: \(wantRefused)",
                fail: "nestedRefused=\(String(describing: t.nestedRefused)) != \(wantRefused)"
            )
        }
        if let mode = exp.expectImageMode {
            check(
                t.mode == mode,
                pass: "mode ok: \(mode)",
                fail: "mode '\(t.mode ?? "nil")' != '\(mode)'"
            )
        }
        if let minImages = exp.minImages {
            check(
                (t.imageCount ?? 0) >= minImages,
                pass: "images ok: \(t.imageCount ?? 0) ≥ \(minImages)",
                fail: "images \(t.imageCount ?? 0) < \(minImages)"
            )
        }
        if let want = exp.expectMaxConcurrent {
            check(
                t.maxConcurrent == want,
                pass: "maxConcurrent ok: \(want)",
                fail: "maxConcurrent \(t.maxConcurrent.map(String.init) ?? "nil") != \(want)"
            )
        }
        if let want = exp.expectRunsCompleted {
            check(
                t.runsCompleted == want,
                pass: "runsCompleted ok: \(want)",
                fail: "runsCompleted \(t.runsCompleted.map(String.init) ?? "nil") != \(want)"
            )
        }
        if exp.expectUsageRecorded == true {
            let prompt = t.usage?["prompt_tokens"] ?? 0
            let completion = t.usage?["completion_tokens"] ?? 0
            check(
                prompt > 0 && completion > 0,
                pass: "usage ok: prompt=\(Int(prompt)) completion=\(Int(completion))",
                fail: "usage missing/zero: prompt=\(Int(prompt)) completion=\(Int(completion))"
            )
        }
        if exp.expectContextAccounting == true {
            let worker = t.contextAccounting?["worker_tokens"] ?? 0
            let digest = t.contextAccounting?["digest_tokens"] ?? 0
            let recorded = t.contextAccounting?["context_saved_tokens"] != nil
            check(
                worker > 0 && digest > 0 && recorded,
                pass: "context accounting ok: worker=\(worker) digest=\(digest)",
                fail:
                    "context accounting missing: worker=\(worker) digest=\(digest) "
                    + "saved_recorded=\(recorded)"
            )
        }
        if let minSaved = exp.minContextSavedTokens {
            let saved = t.contextAccounting?["context_saved_tokens"] ?? -1
            check(
                saved >= minSaved,
                pass: "context saved ok: \(saved) ≥ \(minSaved)",
                fail: "context saved \(saved) < \(minSaved)"
            )
        }
        if let requiredPhases = exp.expectResidencyPhases, !requiredPhases.isEmpty {
            let recorded = t.residencyPhases ?? [:]
            let missing = requiredPhases.filter { recorded[$0] == nil }
            check(
                missing.isEmpty,
                pass: "residency phases ok: \(requiredPhases)",
                fail:
                    "residency phases missing \(missing) "
                    + "(recorded: \(recorded.keys.sorted()))"
            )
        }
        if let ceilings = exp.maxPhaseSeconds, !ceilings.isEmpty {
            let recorded = t.residencyPhases ?? [:]
            for (phase, ceiling) in ceilings.sorted(by: { $0.key < $1.key }) {
                guard let seconds = recorded[phase] else {
                    check(false, pass: "", fail: "phase '\(phase)' not recorded (ceiling \(ceiling)s)")
                    continue
                }
                check(
                    seconds <= ceiling,
                    pass: String(format: "phase %@ ok: %.2fs ≤ %.0fs", phase, seconds, ceiling),
                    fail: String(format: "phase %@ %.2fs > ceiling %.0fs", phase, seconds, ceiling)
                )
            }
        }
        if exp.expectPostRunCache == true {
            check(
                t.postRunCache != nil,
                pass: "post-run cache counters captured",
                fail: "post-run cache counters missing (local run should capture prefix/L2 stats)"
            )
        }

        notes.append(
            "transcript: tool=\(t.tool) envelope=\(t.envelopeKind) "
                + "resultKind=\(t.resultKind ?? "-") "
                + "phases=[\(t.feedPhases.joined(separator: ","))] "
                + "latencyMs=\(Int(t.latencyMs))"
        )
        if let usage = t.usage, !usage.isEmpty {
            let tps = usage["tokens_per_second"].map { String(format: " tok/s=%.1f", $0) } ?? ""
            notes.append(
                "usage: prompt=\(Int(usage["prompt_tokens"] ?? 0)) "
                    + "completion=\(Int(usage["completion_tokens"] ?? 0))\(tps)"
            )
        }
        if let context = t.contextAccounting, !context.isEmpty {
            notes.append(
                "context: worker=\(context["worker_tokens"] ?? 0) "
                    + "digest=\(context["digest_tokens"] ?? 0) "
                    + "saved=\(context["context_saved_tokens"] ?? 0)"
            )
        }
        if let phases = t.residencyPhases, !phases.isEmpty {
            let joined = phases.sorted(by: { $0.key < $1.key })
                .map { String(format: "%@=%.2fs", $0.key, $0.value) }
                .joined(separator: " ")
            notes.append("residency: \(joined)")
        }
        return (passed, notes)
    }

    // MARK: - Helpers

    private static func mapDecision(_ raw: String?) -> ScriptedSubagentSpec.Decision {
        switch raw {
        case "deny": return .deny
        case "userDeny": return .userDeny
        default: return .allow
        }
    }

    /// Whether `needles` appear in `haystack` in order (a subsequence — gaps
    /// allowed). Local copy so this file doesn't depend on the computer-use
    /// runner's private helper.
    private static func containsSubsequence(_ haystack: [String], _ needles: [String]) -> Bool {
        var i = 0
        for item in haystack where i < needles.count && item == needles[i] {
            i += 1
        }
        return i == needles.count
    }

    /// Fold the executed-verb trace into per-verb counters for the suite-wide
    /// usage table (the action mix: type vs click vs observe …). Local copy of
    /// the computer-use runner's file-private helper.
    private static func verbUsageStats(_ verbs: [String]) -> [ToolUsageStat]? {
        guard !verbs.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for verb in verbs { counts[verb, default: 0] += 1 }
        return counts.keys.sorted().map {
            ToolUsageStat(tool: $0, calls: counts[$0] ?? 0, errors: 0, deduped: 0)
        }
    }

    private static func scriptedSpecError(
        _ testCase: EvalCase,
        label: String,
        modelId: String,
        field: String,
        raw: String
    ) -> EvalCaseReport {
        .terminal(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            outcome: .errored,
            notes: [
                "unknown `\(field)` value '\(raw)' — expected a SubagentError case "
                    + "(denied|userDenied|unavailable|invalidArgs|timedOut|iterationCap|"
                    + "toolRejected|overBudget|emptyExhausted|executionFailed)"
            ],
            modelId: modelId
        )
    }
}
