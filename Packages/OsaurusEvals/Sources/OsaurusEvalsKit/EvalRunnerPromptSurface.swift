//
//  EvalRunnerPromptSurface.swift
//  OsaurusEvalsKit
//
//  Runner for the `prompt_surface` domain: deterministic composition
//  census with NO model call. Composes the production preview surface
//  through `PromptSurfaceEvaluator` (the same gates the real send path
//  uses), optionally under an inline `ExperimentProfile`, and scores
//  structural + budget + determinism pins. The census attribution rides
//  in the report's `context` block so the optimization loop can read
//  "where do the tokens go" for every toggle without a model run.
//

import Foundation
import OsaurusCore

extension EvalRunner {

    static func runPromptSurfaceCase(
        _ testCase: EvalCase,
        modelId: String
    ) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        guard let exp = testCase.expect.promptSurface else {
            return errored(
                testCase, label: label, modelId: modelId,
                note: "missing `expect.promptSurface`"
            )
        }

        // ── Profile validation lane ─────────────────────────────────
        // Runs BEFORE any compose so `expectInvalidProfile` cases pin the
        // refusal contract itself (protected sections/tools, unknown ids).
        let validationErrors = exp.profile?.validationErrors() ?? []
        if exp.expectInvalidProfile == true {
            guard exp.profile != nil else {
                return errored(
                    testCase, label: label, modelId: modelId,
                    note: "expectInvalidProfile requires `profile`"
                )
            }
            let rejected = !validationErrors.isEmpty
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: rejected ? .passed : .failed,
                notes: rejected
                    ? ["validator refused as expected: \(validationErrors.joined(separator: "; "))"]
                    : ["validator ACCEPTED a profile the case expected to be refused"],
                modelId: modelId
            )
        }
        if !validationErrors.isEmpty {
            return errored(
                testCase, label: label, modelId: modelId,
                note: "invalid profile '\(exp.profile?.name ?? "?")': "
                    + validationErrors.joined(separator: "; ")
            )
        }

        // Tiny-context models (Apple Foundation class) strip the entire
        // tool schema and most gated sections at compose time, so the
        // full-surface pins these cases carry would measure the wrong
        // thing. SKIP with the resolved class — same semantics as the
        // agent_loop tiny gate.
        let contextWindow = ContextSizeResolver.resolve(modelId: modelId)
        if contextWindow.sizeClass.disablesTools {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .skipped,
                notes: [
                    "tools auto-disabled for '\(modelId)': context size class "
                        + "\(contextWindow.sizeClass) strips the tool schema; the census "
                        + "pins the full surface"
                ],
                modelId: modelId
            )
        }

        // ── Census fixtures ─────────────────────────────────────────
        // Empty temp workspace (host-folder compose needs a real root);
        // optional temp eval agent so capability toggles gate exactly as
        // production would.
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-promptsurface-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        } catch {
            return errored(
                testCase, label: label, modelId: modelId,
                note: "workspace setup failed: \(error.localizedDescription)"
            )
        }
        defer { try? FileManager.default.removeItem(at: workspace) }

        var evalAgentId: UUID?
        if let caps = testCase.fixtures.agentCapabilities, caps.requestsAnyCapability {
            evalAgentId = installEvalAgent(caps)
        }
        defer {
            if let evalAgentId { removeEvalAgent(evalAgentId) }
        }

        // Warm-up (discarded): the preview path opens gated stores
        // (enabled-capabilities manifest DB) NON-blocking, so the first
        // compose in a process can see an empty manifest that every later
        // compose includes. Compose until two consecutive baselines hash
        // identically so the measured census is order-independent across
        // the suite.
        var warmHash = ""
        for _ in 0..<10 {
            let warm = await PromptSurfaceEvaluator.census(
                workspace: workspace,
                agentId: evalAgentId,
                model: modelId,
                experiment: nil
            )
            if warm.promptHash == warmHash { break }
            warmHash = warm.promptHash
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let started = Date()
        // Baseline is composed unconditionally: it anchors the savings
        // check and the per-case delta note even when no profile is set.
        let baseline = await PromptSurfaceEvaluator.census(
            workspace: workspace,
            agentId: evalAgentId,
            model: modelId,
            experiment: nil
        )
        let census: PromptSurfaceCensus
        if let profile = exp.profile {
            census = await PromptSurfaceEvaluator.census(
                workspace: workspace,
                agentId: evalAgentId,
                model: modelId,
                experiment: profile.experiment
            )
        } else {
            census = baseline
        }
        let latency = Date().timeIntervalSince(started) * 1000

        var score = PromptSurfaceScore()

        // ── Structural pins ─────────────────────────────────────────
        let sectionSet = Set(census.sectionIds)
        let toolSet = Set(census.toolNames)
        for id in exp.mustIncludeSections ?? [] {
            score.check(
                sectionSet.contains(id),
                pass: "section '\(id)' present",
                fail: "section '\(id)' MISSING (have: \(census.sectionIds.joined(separator: ",")))"
            )
        }
        for id in exp.mustExcludeSections ?? [] {
            score.check(
                !sectionSet.contains(id),
                pass: "section '\(id)' absent",
                fail: "section '\(id)' present but expected absent"
            )
        }
        for name in exp.mustIncludeTools ?? [] {
            score.check(
                toolSet.contains(name),
                pass: "tool '\(name)' in schema",
                fail: "tool '\(name)' MISSING from schema"
            )
        }
        for name in exp.mustExcludeTools ?? [] {
            score.check(
                !toolSet.contains(name),
                pass: "tool '\(name)' absent from schema",
                fail: "tool '\(name)' present but expected absent"
            )
        }

        // ── Budget pins ─────────────────────────────────────────────
        if let cap = exp.maxSystemPromptTokens {
            score.check(
                census.systemPromptTokens <= cap,
                pass: "prompt \(census.systemPromptTokens) ≤ max \(cap)",
                fail: "prompt \(census.systemPromptTokens) > max \(cap)"
            )
        }
        if let cap = exp.maxToolSchemaTokens {
            score.check(
                census.toolSchemaTokens <= cap,
                pass: "tool schema \(census.toolSchemaTokens) ≤ max \(cap)",
                fail: "tool schema \(census.toolSchemaTokens) > max \(cap)"
            )
        }
        if let cap = exp.maxSurfaceTokens {
            score.check(
                census.surfaceTokens <= cap,
                pass: "surface \(census.surfaceTokens) ≤ max \(cap)",
                fail: "surface \(census.surfaceTokens) > max \(cap)"
            )
        }

        // ── Selection + determinism pins ────────────────────────────
        if let expectCompact = exp.expectCompactPrompt {
            score.check(
                census.prefersCompactPrompt == expectCompact,
                pass: "compact selection = \(census.prefersCompactPrompt) as expected",
                fail: "compact selection = \(census.prefersCompactPrompt), expected \(expectCompact)"
            )
        }
        if exp.expectDeterministic == true {
            let second = await PromptSurfaceEvaluator.census(
                workspace: workspace,
                agentId: evalAgentId,
                model: modelId,
                experiment: exp.profile?.experiment
            )
            score.check(
                second.promptHash == census.promptHash,
                pass: "deterministic: repeat compose hash \(census.promptHash)",
                fail: "NON-deterministic: \(census.promptHash) vs \(second.promptHash)"
            )
        }
        if exp.requireSavingsVsBaseline == true {
            if exp.profile == nil {
                score.record(false, note: "requireSavingsVsBaseline requires `profile`")
            } else {
                let saved = baseline.surfaceTokens - census.surfaceTokens
                score.check(
                    saved > 0,
                    pass: "saves \(saved) tok vs baseline "
                        + "(\(baseline.surfaceTokens) → \(census.surfaceTokens))",
                    fail: "no savings vs baseline "
                        + "(\(baseline.surfaceTokens) → \(census.surfaceTokens))"
                )
            }
        }

        // ── Census summary (always, pass or fail) ───────────────────
        score.notes.append(
            "surface: prompt \(census.systemPromptTokens) + tools \(census.toolSchemaTokens)"
                + "/\(census.toolNames.count) = \(census.surfaceTokens) tok"
                + (exp.profile != nil
                    ? "  (baseline \(baseline.surfaceTokens); Δ \(census.surfaceTokens - baseline.surfaceTokens))"
                    : "")
        )
        if let profile = exp.profile {
            score.notes.append(
                "profile: \(profile.name)@\(profile.profileHash) "
                    + "[\(profile.resolvedFeatureVector.joined(separator: ", "))]"
            )
        }
        score.notes.append("promptHash: \(census.promptHash)")

        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: score.passed ? .passed : .failed,
            notes: score.notes,
            modelId: modelId,
            latencyMs: latency,
            context: census.attribution
        )
    }

    /// Local pass/notes accumulator (mirrors the agent-loop scorer).
    private struct PromptSurfaceScore {
        var passed = true
        var notes: [String] = []

        mutating func record(_ ok: Bool, note: String) {
            passed = passed && ok
            notes.append(note)
        }

        mutating func check(_ ok: Bool, pass: String, fail: String) {
            record(ok, note: ok ? pass : fail)
        }
    }
}
