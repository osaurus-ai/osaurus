//
//  EvalRunnerSubagent.swift
//  OsaurusEvalsKit
//
//  Runner for the `subagent` domain: drives the shared `SubagentSession`
//  host through `SubagentJobEvaluator` and scores the compact result
//  envelope + the unified `SubagentFeed`. Three lanes mirror the four
//  sub-agent paths the unified framework collapsed onto one host:
//
//    - scripted: model-free. The full host lifecycle (resolve → permission
//      → handoff → run → normalize → cleanup), the unified recursion guard,
//      and the feed lifecycle run in CI with no tokens — the deterministic
//      seam the whole sub-agent family rides on. This lane also runs as
//      eval-kit unit tests (mirror `ComputerUseLoopEvalTests`).
//    - spawn: live. The real `SpawnTool` (host + `TextSubagentKind`) against
//      a user-configured spawnable persona — the text-subagent path.
//    - image: live. The real `ImageTool` (host + `ImageSubagentKind`);
//      `sourcePaths` non-empty selects the edit path, empty selects generate.
//
//  Live lanes SKIP (not fail) when the host can't satisfy a happy-path case
//  (no spawnable persona, image delegation off, model not ready) — same
//  `requirePlugins`-style semantics the other domains use so a report shared
//  across machines reads "didn't apply" rather than "regressed".
//

import Foundation
import OsaurusCore

extension EvalRunner {

    /// Sub-agent host evaluator for `domain == "subagent"`.
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
        case "image":
            return await scoreImageLane(testCase, exp: exp, modelId: modelId, label: label)
        case "computer_use":
            return await scoreComputerUseLane(testCase, exp: exp, modelId: modelId, label: label)
        case "sandbox_reduce":
            return await scoreSandboxReduceLane(testCase, exp: exp, modelId: modelId, label: label)
        default:
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: [
                    "unknown subagent lane '\(exp.lane)' "
                        + "(expected scripted|spawn|image|computer_use|sandbox_reduce)"
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

        let spec = ScriptedSubagentSpec(
            kindId: "scripted",
            needsHandoff: exp.needsHandoff ?? false,
            decision: mapDecision(exp.decision),
            resolveFailure: exp.resolveFailure.flatMap(ScriptedSubagentSpec.Failure.init(rawValue:)),
            runFailure: exp.runFailure.flatMap(ScriptedSubagentSpec.Failure.init(rawValue:)),
            recurse: exp.recurse ?? false,
            phases: exp.phases ?? ["running"]
        )
        let transcript = await SubagentJobEvaluator.runScripted(spec)
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
        // Pass the run `modelId` so the spawned persona runs on it (instead of
        // its own pinned model), making `spawn` a real cross-model column.
        // Positive cases opt into persona seeding (so they RUN anywhere across
        // models); negative guards (not-spawnable) must NOT be seeded.
        let transcript: SubagentJobTranscript
        if exp.seedSpawnablePersona == true {
            transcript = await SubagentJobEvaluator.withSpawnablePersona(name: agent) {
                await SubagentJobEvaluator.runSpawn(agent: agent, input: input, modelId: modelId)
            }
        } else {
            transcript = await SubagentJobEvaluator.runSpawn(
                agent: agent,
                input: input,
                modelId: modelId
            )
        }
        return finishLive(testCase, exp: exp, transcript: transcript, lane: "spawn", modelId: modelId, label: label)
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

    // MARK: - Live sandbox_reduce lane (host + container)

    /// Drive the real `sandbox_reduce` host (`SubagentSession` +
    /// `SandboxReduceKind`) on the run `modelId`. SKIPS cleanly when the
    /// sandbox child tools aren't registered (no container) — the facade
    /// pre-flight returns an `unavailable` envelope, and `finishLive` treats
    /// an unexpected availability envelope as a skip. Tiny-context models
    /// (which can't drive a tool loop) are pre-skipped.
    private static func scoreSandboxReduceLane(
        _ testCase: EvalCase,
        exp: EvalCase.SubagentExpectations,
        modelId: String,
        label: String
    ) async -> EvalCaseReport {
        guard let task = exp.task ?? optionalNonEmpty(testCase.query) else {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: ["sandbox_reduce lane needs `task` (or a non-empty query)"],
                modelId: modelId
            )
        }
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
                        + "strips the tools the reduction loop needs; live case skipped"
                ],
                modelId: modelId
            )
        }
        let transcript = await SubagentJobEvaluator.runSandboxReduce(
            task: task,
            modelId: modelId,
            paths: exp.paths ?? [],
            maxIterations: exp.maxIterations
        )
        return finishLive(
            testCase,
            exp: exp,
            transcript: transcript,
            lane: "sandbox_reduce",
            modelId: modelId,
            label: label
        )
    }

    private static func optionalNonEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Shared scoring

    /// Convert a live-lane transcript into a report, applying the
    /// availability-skip rule: when the run failed with a host-availability
    /// envelope (`rejected`/`unavailable`/`user_denied`) that the case did NOT
    /// ask for, SKIP rather than fail — a machine without a spawnable persona,
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

        notes.append(
            "transcript: tool=\(t.tool) envelope=\(t.envelopeKind) "
                + "resultKind=\(t.resultKind ?? "-") "
                + "phases=[\(t.feedPhases.joined(separator: ","))] "
                + "latencyMs=\(Int(t.latencyMs))"
        )
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
