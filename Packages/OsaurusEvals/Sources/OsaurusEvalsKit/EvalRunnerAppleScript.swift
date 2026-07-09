//
//  EvalRunnerAppleScript.swift
//  OsaurusEvalsKit
//
//  Runner arm for `domain == "apple_script"`. Builds an
//  `AppleScriptEvaluator.Config` from the case's `expect.appleScript`, drives
//  the production `AppleScriptLoop` through the OsaurusCore facade in one of
//  three lanes (`scripted` / `live` / `liveProof`), and scores the resulting
//  `AppleScriptEvalTranscript`:
//
//    • status / outcome shape,
//    • `{{name}}` placeholder use (proven from the PRE-expansion proposal, so a
//      model that re-typed the literal instead of using the slot fails),
//    • generated-script matchers (contains / not-contains / regex over the
//      executed, expanded scripts),
//    • captured value (`mac_query` / read-back),
//    • blocked write (query-mode safety),
//    • effect classes (`read` / `edit` / `consequential`),
//    • mock-world final state (`note:<name>`, `volume`),
//    • step + token ceilings,
//    • an optional Grok rubric — graded ONLY when a real model ran AND a strong
//      judge resolves, so the scripted CI lane stays deterministic and free.
//
//  Per AGENTS.md this is honest measurement: the mock simulates the OS, never
//  coerces or repairs the model's output; a live lane with no installed model
//  SKIPS (not fails). The generated scripts are echoed into `notes` so a
//  `--verbose` run shows exactly what the model produced — the tuning signal.
//

import Foundation
import OsaurusCore

extension EvalRunner {

    /// AppleScript capability evaluator for `domain == "apple_script"`.
    static func runAppleScriptCase(
        _ testCase: EvalCase,
        modelId: String
    ) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id

        guard let exp = testCase.expect.appleScript else {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: ["apple_script case missing expect.appleScript"],
                modelId: modelId
            )
        }

        let lane = AppleScriptEvalLane(rawValue: exp.lane ?? "scripted") ?? .scripted

        let config = AppleScriptEvaluator.Config(
            lane: lane,
            task: testCase.query,
            mode: AppleScriptRunMode(rawValue: exp.mode ?? "automate") ?? .automate,
            executionMode: resolveExecutionMode(exp.executionMode),
            literals: mergedLiterals(content: exp.content, contents: exp.contents),
            harness: resolveHarness(exp.harness),
            maxSteps: exp.maxSteps ?? 12,
            wallClockSeconds: exp.wallClockSeconds ?? 240,
            modelStepTimeoutSeconds: exp.modelStepTimeoutSeconds ?? 90,
            model: lane == .scripted ? nil : modelId,
            samplingTemperature: exp.samplingTemperature,
            environmentContext: exp.environmentContext,
            confirmApproves: exp.confirmApproves ?? true,
            scriptedCalls: exp.scriptedCalls ?? [],
            executor: resolveExecutor(exp.executor),
            automationProbeScript: exp.executor?.probe
        )

        let transcript = await AppleScriptEvaluator.run(config)

        // A live lane with no installed AppleScript model reads as "didn't
        // apply", not a regression — mirror `requirePlugins` / subagent skips.
        if transcript.skipped {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .skipped,
                notes: [transcript.skipReason ?? "skipped"],
                modelId: transcript.modelId ?? modelId
            )
        }

        // A harness/facade error (never a model verdict) is an ERR row.
        if let err = transcript.error {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: ["run error: \(err)"],
                modelId: transcript.modelId ?? modelId
            )
        }

        var passed = true
        var notes: [String] = []
        func check(_ ok: Bool, pass: String, fail: String) {
            passed = passed && ok
            notes.append(ok ? pass : fail)
        }

        // 1. Status / outcome shape.
        if let want = exp.expectStatus {
            check(
                transcript.status == want,
                pass: "status ok: \(transcript.status)",
                fail: "status \(transcript.status), expected \(want)"
            )
        }
        if let allowed = exp.expectOutcome, !allowed.isEmpty {
            check(
                allowed.contains(transcript.outcome),
                pass: "outcome ok: \(transcript.outcome)",
                fail: "outcome \(transcript.outcome) not in \(allowed)"
            )
        }

        // 2. Placeholder use — proven from the pre-expansion proposal, so a
        //    model that inlined the literal instead of using the slot fails.
        for name in exp.mustUsePlaceholders ?? [] {
            let token = "{{\(name)}}"
            let used = transcript.proposals.contains { $0.proposedScript.contains(token) }
            check(
                used,
                pass: "used placeholder \(token)",
                fail: "never emitted placeholder \(token) (inlined the literal instead?)"
            )
        }

        // 3. Generated-script matchers over the executed (expanded) scripts.
        for needle in exp.scriptMustContain ?? [] {
            check(
                transcript.executedScripts.contains { $0.contains(needle) },
                pass: "script contains \"\(needle)\"",
                fail: "no executed script contains \"\(needle)\""
            )
        }
        for needle in exp.scriptMustNotContain ?? [] {
            check(
                !transcript.executedScripts.contains { $0.contains(needle) },
                pass: "script omits \"\(needle)\"",
                fail: "an executed script contains forbidden \"\(needle)\""
            )
        }
        for pattern in exp.scriptMustMatch ?? [] {
            let matched = transcript.executedScripts.contains {
                $0.range(of: pattern, options: .regularExpression) != nil
            }
            check(
                matched,
                pass: "script matches /\(pattern)/",
                fail: "no executed script matches /\(pattern)/"
            )
        }

        // 4. Captured value (mac_query result / read-back).
        for needle in exp.valuesContain ?? [] {
            let value = transcript.lastOutput ?? ""
            check(
                value.localizedCaseInsensitiveContains(needle),
                pass: "value contains \"\(needle)\"",
                fail: "captured value \"\(value)\" lacks \"\(needle)\""
            )
        }

        // 5. Blocked write (query-mode safety: a write proposed under `query`
        //    is refused and NEVER executed).
        if let want = exp.expectBlockedWrite {
            check(
                transcript.blockedWrite == want,
                pass: want ? "write blocked (as expected)" : "no write blocked (as expected)",
                fail: want
                    ? "expected a blocked write, none was blocked"
                    : "a write was blocked unexpectedly"
            )
        }

        // 6. Effect classes seen across the model's proposals.
        let effects = Set(transcript.proposals.map(\.effect))
        for effect in exp.expectEffects ?? [] {
            check(
                effects.contains(effect),
                pass: "effect present: \(effect)",
                fail: "effect \(effect) never classified (saw [\(effects.sorted().joined(separator: ", "))])"
            )
        }
        for effect in exp.forbidEffects ?? [] {
            check(
                !effects.contains(effect),
                pass: "effect absent: \(effect)",
                fail: "forbidden effect \(effect) was classified"
            )
        }

        // 7. Mock-world final state (empty on the real / canned executors).
        for pred in exp.finalState ?? [] {
            let actual = transcript.finalState[pred.key]
            let shown = actual.map { "\"\($0)\"" } ?? "nil"
            if let equals = pred.equals {
                check(
                    actual == equals,
                    pass: "state \(pred.key) == expected",
                    fail: "state \(pred.key) = \(shown), expected \"\(equals)\""
                )
            }
            if let contains = pred.contains {
                check(
                    actual?.contains(contains) ?? false,
                    pass: "state \(pred.key) contains \"\(contains)\"",
                    fail: "state \(pred.key) = \(shown) lacks \"\(contains)\""
                )
            }
        }

        // 8. Efficiency + cost ceilings.
        if let maxSteps = exp.scoredMaxSteps {
            check(
                transcript.scriptsExecuted <= maxSteps,
                pass: "steps \(transcript.scriptsExecuted) ≤ \(maxSteps)",
                fail: "steps \(transcript.scriptsExecuted) > \(maxSteps)"
            )
        }
        if let maxTokens = exp.scoredMaxModelTokens {
            check(
                transcript.modelTokens <= maxTokens,
                pass: "tokens \(transcript.modelTokens) ≤ \(maxTokens)",
                fail: "tokens \(transcript.modelTokens) > \(maxTokens)"
            )
        }

        // 9. Optional Grok rubric — graded ONLY when a real model ran and a
        //    strong judge resolves. The scripted CI lane (no model) and a
        //    judge-less environment skip (record only) so CI stays free.
        var judgeAudit: EvalJudgeAudit?
        var judgeElapsed: Double?
        if let rubric = exp.rubric, !rubric.isEmpty {
            if !transcript.ranModel {
                notes.append(
                    "rubric: skipped (\(rubric.count) condition(s); scripted lane runs no model)"
                )
            } else {
                let resolution = EvalJudgeModel.resolve(runModelId: transcript.modelId ?? modelId)
                if resolution.isSelfJudge {
                    notes.append(
                        "rubric: skipped (\(rubric.count) condition(s); no strong judge — set "
                            + "JUDGE_MODEL or a *_API_KEY to grade)"
                    )
                } else {
                    if let note = resolution.note { notes.append(note) }
                    // Self-heal the ephemeral judge provider in case a prior
                    // provider-mutating suite evicted it (idempotent no-op
                    // while the judge is still routable).
                    await EvalRunner.ensureJudgeProviderRoutable(resolution.modelId)
                    let judgeStarted = Date()
                    let audit = await CapabilityClaimsEvaluator.judgeDetailed(
                        finalText: judgeText(task: testCase.query, transcript: transcript),
                        conditions: rubric,
                        model: resolution.modelId
                    )
                    judgeElapsed = Date().timeIntervalSince(judgeStarted) * 1000
                    let verdicts = audit.verdicts
                    judgeAudit = EvalJudgeAudit.from(audit, rubric: rubric, selfJudge: false)
                    for (index, verdict) in verdicts.enumerated() {
                        let condition = index < rubric.count ? rubric[index] : "(condition \(index))"
                        if verdict.pass {
                            notes.append("judge ok: \(condition)")
                        } else {
                            passed = false
                            notes.append("judge FAIL: \(condition) — \(verdict.reason)")
                        }
                    }
                    if verdicts.count != rubric.count {
                        passed = false
                        notes.append(
                            "judge produced \(verdicts.count) verdicts for \(rubric.count) conditions"
                        )
                    }
                }
            }
        }

        // Run summary + the generated scripts, echoed last so `--verbose` shows
        // exactly what the model produced (the tuning signal).
        let tokensPerSecond =
            transcript.tokensPerSecond.map { String(format: " tok/s=%.1f", $0) } ?? ""
        notes.append(
            "summary: lane=\(lane.rawValue) status=\(transcript.status) "
                + "outcome=\(transcript.outcome) exec=\(transcript.scriptsExecuted) "
                + "ok=\(transcript.succeeded) fail=\(transcript.failed) "
                + "tokens=\(transcript.modelTokens)\(tokensPerSecond)"
        )
        if let value = transcript.lastOutput, !value.isEmpty {
            notes.append("value: \(value.replacingOccurrences(of: "\n", with: " "))")
        }
        for (index, script) in transcript.executedScripts.enumerated() {
            notes.append("script[\(index)]:\n\(script)")
        }

        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: passed ? .passed : .failed,
            notes: notes,
            modelId: transcript.modelId ?? modelId,
            latencyMs: transcript.latencyMs,
            judgeLatencyMs: judgeElapsed,
            telemetry: transcript.ranModel
                ? EvalCaseTelemetry(
                    decodeTokensPerSecond: transcript.tokensPerSecond,
                    totalModelTokens: transcript.modelTokens,
                    modelSteps: transcript.proposals.count
                )
                : nil,
            judge: judgeAudit
        )
    }

    // MARK: - Config builders

    /// Merge the single `content` literal with the named `contents` map,
    /// mirroring the tool-boundary precedence (`contents` wins on `content`).
    private static func mergedLiterals(
        content: String?,
        contents: [String: String]?
    ) -> [String: String] {
        var merged = contents ?? [:]
        if let content, merged["content"] == nil { merged["content"] = content }
        return merged
    }

    /// Evals default to `autoRunWithWarning` (no confirm friction) unless a
    /// case pins `confirmEach` to also exercise the gate.
    private static func resolveExecutionMode(_ raw: String?) -> AppleScriptExecutionMode {
        guard let raw else { return .autoRunWithWarning }
        return AppleScriptExecutionMode(rawValue: raw) ?? .autoRunWithWarning
    }

    /// Resolve the harness in three layers, low → high precedence: the shipped
    /// `.default`, the case's `harness` spec, then the sweep env vars
    /// (`OSAURUS_AS_*`). The env layer is the "harness as a tunable variable"
    /// lever `applescript-capability-lab.sh` drives — it lets the SAME suite run
    /// under each variant with no per-case edits. Unset env keeps case /
    /// production behavior byte-for-byte, so `make evals` and CI are unaffected.
    private static func resolveHarness(
        _ spec: EvalCase.AppleScriptExpectations.HarnessSpec?
    ) -> AppleScriptHarnessOptions {
        let base = AppleScriptHarnessOptions.default
        let env = ProcessInfo.processInfo.environment

        var verify = spec?.verifyReadBack ?? base.verifyReadBack
        var desktop = spec?.includeDesktopContext ?? base.includeDesktopContext
        var dictionary = spec?.includeDictionaryContext ?? base.includeDictionaryContext
        var recipes = spec?.includeAppRecipes ?? base.includeAppRecipes
        var promptVariant =
            spec?.promptVariant.flatMap(AppleScriptHarnessOptions.PromptVariant.init(rawValue:))
            ?? base.promptVariant
        var announce =
            spec?.literalAnnouncementStyle
            .flatMap(AppleScriptHarnessOptions.LiteralAnnouncementStyle.init(rawValue:))
            ?? base.literalAnnouncementStyle

        if let v = boolEnv(env["OSAURUS_AS_VERIFY_READBACK"]) { verify = v }
        if let v = boolEnv(env["OSAURUS_AS_DESKTOP_CONTEXT"]) { desktop = v }
        if let v = boolEnv(env["OSAURUS_AS_DICTIONARY_CONTEXT"]) { dictionary = v }
        if let v = boolEnv(env["OSAURUS_AS_APP_RECIPES"]) { recipes = v }
        if let raw = env["OSAURUS_AS_PROMPT_VARIANT"],
            let p = AppleScriptHarnessOptions.PromptVariant(rawValue: raw)
        {
            promptVariant = p
        }
        if let raw = env["OSAURUS_AS_LITERAL_STYLE"],
            let a = AppleScriptHarnessOptions.LiteralAnnouncementStyle(rawValue: raw)
        {
            announce = a
        }

        return AppleScriptHarnessOptions(
            verifyReadBack: verify,
            includeDesktopContext: desktop,
            includeDictionaryContext: dictionary,
            includeAppRecipes: recipes,
            promptVariant: promptVariant,
            literalAnnouncementStyle: announce
        )
    }

    /// Parse a permissive boolean env value (`1/0`, `true/false`, `yes/no`,
    /// `on/off`); nil when unset or unrecognized (leave the lower layer's value).
    private static func boolEnv(_ raw: String?) -> Bool? {
        switch raw?.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    private static func resolveExecutor(
        _ spec: EvalCase.AppleScriptExpectations.ExecutorSpec?
    ) -> AppleScriptEvaluator.Executor {
        guard let spec else { return .mockResults([]) }
        if (spec.kind ?? "mock").lowercased() == "real" { return .real }
        if let world = spec.mockWorld {
            return .mockWorld(
                MockAppleScriptWorld(
                    notes: world.notes ?? [:],
                    volume: world.volume,
                    safariURL: world.safariURL,
                    mailUnread: world.mailUnread,
                    frontmostApp: world.frontmostApp,
                    folders: Dictionary(
                        uniqueKeysWithValues: (world.folders ?? []).map { ($0, true) }
                    )
                )
            )
        }
        return .mockResults((spec.mockResults ?? []).map(executionResult(from:)))
    }

    private static func executionResult(
        from spec: EvalCase.AppleScriptExpectations.ExecutorSpec.ResultSpec
    ) -> AppleScriptExecutionResult {
        AppleScriptExecutionResult(
            status: executionStatus(spec.status),
            output: spec.output,
            errorNumber: spec.errorNumber,
            errorMessage: spec.errorMessage
        )
    }

    /// Map a case's status string (raw case name or snake_case) onto the
    /// executor status enum; unknown → success (the mock never invents errors).
    private static func executionStatus(_ raw: String?) -> AppleScriptExecutionResult.Status {
        guard let raw else { return .success }
        switch raw.lowercased().replacingOccurrences(of: "_", with: "") {
        case "success": return .success
        case "compileerror": return .compileError
        case "runtimeerror": return .runtimeError
        case "permissionrequired": return .permissionRequired
        case "timedout": return .timedOut
        default: return AppleScriptExecutionResult.Status(rawValue: raw) ?? .success
        }
    }

    /// The text handed to the judge: the task plus the model's actual output
    /// (status + captured value + the executed scripts). The judge grades
    /// whether the SCRIPT accomplishes the task, robust to script variety.
    private static func judgeText(task: String, transcript: AppleScriptEvalTranscript) -> String {
        var lines: [String] = []
        lines.append("Task: \(task)")
        lines.append("Lane: \(transcript.lane.rawValue)")
        lines.append("Aggregate status: \(transcript.status) (outcome \(transcript.outcome))")
        if let value = transcript.lastOutput, !value.isEmpty {
            lines.append("Captured value: \(value)")
        }
        if transcript.executedScripts.isEmpty {
            lines.append("Generated AppleScript: (none executed)")
        } else {
            lines.append("Generated AppleScript (executed, in order):")
            for (index, script) in transcript.executedScripts.enumerated() {
                lines.append("--- script \(index + 1) ---")
                lines.append(script)
            }
        }
        return lines.joined(separator: "\n")
    }
}
