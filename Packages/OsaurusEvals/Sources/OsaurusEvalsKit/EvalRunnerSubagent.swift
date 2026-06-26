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
        default:
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: ["unknown subagent lane '\(exp.lane)' (expected scripted|spawn|image)"],
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
        let transcript = await SubagentJobEvaluator.runSpawn(agent: agent, input: input)
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
