//
//  EvalRunnerAgentLoop.swift
//  OsaurusEvalsKit
//
//  Runner for the `agent_loop` domain: end-to-end agentic evals that
//  drive the canonical `AgentToolLoop` (via `AgentLoopEvaluator`)
//  against a fixture-seeded temp workspace in host-folder mode, then
//  score transcript assertions and workspace OUTCOMES (file contents,
//  command exit codes) — the proof lane for "small local → frontier".
//

import Foundation
import OsaurusCore

extension EvalRunner {

    /// Agent-loop evaluator for `domain == "agent_loop"`. Off-CI
    /// (token cost + filesystem effects): seeds a temp workspace from
    /// `fixtures.workspaceFiles`, runs the shared loop, asserts on the
    /// transcript and the workspace, then deletes the workspace.
    static func runAgentLoopCase(
        _ testCase: EvalCase,
        modelId: String
    ) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id

        guard let exp = testCase.expect.agentLoop else {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: ["missing `expect.agentLoop`"],
                modelId: modelId
            )
        }

        // Fresh per-case workspace. Deleted in all exits below.
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-agentloop-eval-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            for file in testCase.fixtures.workspaceFiles ?? [] {
                let target = workspace.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try file.contents.write(to: target, atomically: true, encoding: .utf8)
            }
        } catch {
            try? FileManager.default.removeItem(at: workspace)
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: ["workspace fixture setup failed: \(error.localizedDescription)"],
                modelId: modelId
            )
        }
        defer { try? FileManager.default.removeItem(at: workspace) }

        let judgeModel = ProcessInfo.processInfo.environment["JUDGE_MODEL"]
        let started = Date()
        let transcript = await AgentLoopEvaluator.run(
            task: testCase.query,
            workspace: workspace,
            maxIterations: exp.maxIterations ?? 10,
            contextWindowOverride: exp.contextWindowOverride,
            stopOnToolRejection: exp.stopOnToolRejection ?? false
        )

        var verdicts: [CapabilityClaimsJudgement] = []
        if transcript.error == nil, let rubric = exp.rubric, !rubric.isEmpty {
            verdicts = await CapabilityClaimsEvaluator.judge(
                finalText: transcript.finalText,
                conditions: rubric,
                model: judgeModel
            )
        }
        let elapsed = Date().timeIntervalSince(started) * 1000
        // Report loop-only latency (model steps + tool execution), not
        // wall time inflated by judge calls and workspace setup.
        let latency = transcript.loopDurationMs > 0 ? transcript.loopDurationMs : elapsed

        if let err = transcript.error {
            return EvalCaseReport(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                query: testCase.query,
                outcome: .errored,
                notes: ["agent loop error: \(err)"],
                modelId: modelId,
                latencyMs: latency
            )
        }

        var score = AgentLoopScore()

        // 1+2. Exit shape + transcript assertions.
        scoreTranscriptAssertions(exp, transcript: transcript, into: &score)

        // 3. Workspace outcomes.
        for assertion in exp.files ?? [] {
            let result = scoreFileAssertion(assertion, workspace: workspace)
            score.record(result.passed, note: result.note)
        }
        for assertion in exp.commands ?? [] {
            let result = await scoreCommandAssertion(assertion, workspace: workspace)
            score.record(result.passed, note: result.note)
        }

        // 4. Final-text checks.
        for needle in exp.finalTextContains ?? [] {
            score.check(
                transcript.finalText.localizedCaseInsensitiveContains(needle),
                pass: "finalText contains '\(needle)'",
                fail: "finalText missing '\(needle)'"
            )
        }

        // 5. LLM-judge rubric — every condition must pass.
        let rubric = exp.rubric ?? []
        for (index, verdict) in verdicts.enumerated() {
            let condition = index < rubric.count ? rubric[index] : "(condition \(index))"
            score.check(
                verdict.pass,
                pass: "judge ok: \(condition)",
                fail: "judge FAIL: \(condition) — \(verdict.reason)"
            )
        }
        if !rubric.isEmpty && verdicts.count != rubric.count {
            score.record(
                false,
                note: "judge produced \(verdicts.count) verdicts for \(rubric.count) conditions"
            )
        }

        if !score.passed {
            appendFailureForensics(transcript, into: &score)
        }
        score.notes.append(
            "summary: toolCalls=[\(transcript.toolCalls.map(\.name).joined(separator: ","))] "
                + "iters=\(transcript.iterations) exit=\(transcript.exit)"
        )
        score.notes.append(
            "final: \(transcript.finalText.replacingOccurrences(of: "\n", with: " "))"
        )

        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: score.passed ? .passed : .failed,
            notes: score.notes,
            modelId: modelId,
            latencyMs: latency
        )
    }

    // MARK: - Transcript scoring

    /// Pass/notes accumulator threaded through the scoring layers.
    private struct AgentLoopScore {
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

    /// Deterministic transcript assertions (exit shape, tool-call sets,
    /// duplicate discipline, dedupe replays, notices, compaction).
    private static func scoreTranscriptAssertions(
        _ exp: EvalCase.AgentLoopExpectations,
        transcript: AgentLoopTranscript,
        into score: inout AgentLoopScore
    ) {
        let allowedExits = exp.allowedExits ?? ["finalResponse"]
        score.check(
            allowedExits.contains(transcript.exit),
            pass: "exit ok: \(transcript.exit)",
            fail: "exit '\(transcript.exit)' not in allowed \(allowedExits)"
        )

        let calledSet = Set(transcript.toolCalls.map(\.name))
        if let must = exp.mustCallTools {
            let missing = must.filter { !calledSet.contains($0) }
            score.check(
                missing.isEmpty,
                pass: "mustCallTools ok: [\(must.joined(separator: ","))]",
                fail: "mustCallTools missing: [\(missing.joined(separator: ","))]"
            )
        }
        if let mustNot = exp.mustNotCallTools {
            let offenders = mustNot.filter { calledSet.contains($0) }
            score.check(
                offenders.isEmpty,
                pass: "mustNotCallTools ok",
                fail: "mustNotCallTools called: [\(offenders.joined(separator: ","))]"
            )
        }
        if let cap = exp.maxToolCalls {
            score.check(
                transcript.toolCalls.count <= cap,
                pass: "maxToolCalls ok: \(transcript.toolCalls.count) ≤ \(cap)",
                fail: "maxToolCalls breached: \(transcript.toolCalls.count) > \(cap)"
            )
        }
        if exp.noDuplicateExecutedCalls == true {
            // Replays through the loop's dedupe (`wasDeduped`) are the
            // mechanism WORKING; only repeated real executions fail.
            // Keys use the loop's own canonicalisation so the scorer and
            // the dedupe agree on what "identical arguments" means.
            var seen: Set<String> = []
            var duplicates: [String] = []
            for call in transcript.toolCalls where !call.wasDeduped {
                let key = call.name + "\u{1F}" + AgentTaskState.canonicalArgs(call.arguments)
                if !seen.insert(key).inserted {
                    duplicates.append(call.name)
                }
            }
            score.check(
                duplicates.isEmpty,
                pass: "noDuplicateExecutedCalls ok",
                fail: "duplicate executions: [\(duplicates.joined(separator: ","))]"
            )
        }
        if exp.noToolErrors == true {
            let errored = transcript.toolCalls.filter(\.wasError)
            score.check(
                errored.isEmpty,
                pass: "noToolErrors ok",
                fail: "tool errors present: [\(errored.map(\.name).joined(separator: ","))]"
            )
        }
        if let minReplays = exp.minDedupedReplays {
            let replays = transcript.toolCalls.filter(\.wasDeduped).count
            score.check(
                replays >= minReplays,
                pass: "minDedupedReplays ok: \(replays) ≥ \(minReplays)",
                fail: "dedupe replays: \(replays) < required \(minReplays)"
            )
        }
        for needle in exp.noticesContain ?? [] {
            score.check(
                transcript.notices.contains(where: { $0.contains(needle) }),
                pass: "notice fired containing '\(needle)'",
                fail: "no notice containing '\(needle)' (saw \(transcript.notices.count) notices)"
            )
        }
        if exp.expectCompaction == true {
            score.check(
                transcript.compacted,
                pass: "compaction occurred",
                fail: "expected compaction but the watermark never recorded one"
            )
        }
        if exp.todoUpdatedBeforeComplete == true {
            // "Mark items done as you go": some `todo` call carrying at
            // least one checked box must precede the first `complete`
            // call (or the end of the run when no `complete` fired). A
            // single list creation with all boxes unchecked does NOT pass.
            let completeIndex =
                transcript.toolCalls.firstIndex(where: { $0.name == "complete" })
                ?? transcript.toolCalls.count
            let updated = transcript.toolCalls.prefix(completeIndex).contains { call in
                call.name == "todo"
                    && call.arguments.range(of: "[x]", options: .caseInsensitive) != nil
            }
            score.check(
                updated,
                pass: "todo updated (≥1 checked box) before complete",
                fail: "no todo call with a checked box before complete/run end"
            )
        }
    }

    /// Failure-only forensics: error envelopes, the tool schema the model
    /// saw, the call-by-call trace (a bare name list can't distinguish
    /// "re-read the same file 6 times" from "walked 6 files once"), and
    /// every driver-staged notice.
    private static func appendFailureForensics(
        _ transcript: AgentLoopTranscript,
        into score: inout AgentLoopScore
    ) {
        for call in transcript.toolCalls where call.wasError {
            score.notes.append(
                "tool error: \(call.name)(\(call.arguments.prefix(160))) → \(call.resultPreview.prefix(200))"
            )
        }
        score.notes.append("tool schemas: [\(transcript.toolSchemaNames.joined(separator: ","))]")
        for (index, call) in transcript.toolCalls.enumerated() {
            let flags = [call.wasDeduped ? "deduped" : nil, call.wasError ? "error" : nil]
                .compactMap { $0 }
            let suffix = flags.isEmpty ? "" : " [\(flags.joined(separator: ","))]"
            score.notes.append("call[\(index)]\(suffix): \(call.name)(\(call.arguments.prefix(120)))")
        }
        for (index, notice) in transcript.notices.enumerated() {
            score.notes.append("notice[\(index)]: \(notice.prefix(160))")
        }
    }

    // MARK: - Outcome scoring

    private static func scoreFileAssertion(
        _ assertion: EvalCase.AgentLoopExpectations.FileAssertion,
        workspace: URL
    ) -> (passed: Bool, note: String) {
        let url = workspace.appendingPathComponent(assertion.path)
        let exists = FileManager.default.fileExists(atPath: url.path)
        let shouldExist = assertion.exists ?? true

        if !shouldExist {
            return exists
                ? (false, "file '\(assertion.path)' exists but was expected absent")
                : (true, "file '\(assertion.path)' correctly absent")
        }
        guard exists else {
            return (false, "file '\(assertion.path)' missing")
        }
        guard assertion.contains != nil || assertion.equals != nil else {
            return (true, "file '\(assertion.path)' exists")
        }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return (false, "file '\(assertion.path)' unreadable as UTF-8")
        }
        if let exact = assertion.equals {
            return contents == exact
                ? (true, "file '\(assertion.path)' equals expected contents")
                : (false, "file '\(assertion.path)' contents differ from expected")
        }
        if let needle = assertion.contains {
            return contents.contains(needle)
                ? (true, "file '\(assertion.path)' contains '\(needle)'")
                : (false, "file '\(assertion.path)' missing '\(needle)'")
        }
        return (true, "file '\(assertion.path)' exists")
    }

    private static func scoreCommandAssertion(
        _ assertion: EvalCase.AgentLoopExpectations.CommandAssertion,
        workspace: URL
    ) async -> (passed: Bool, note: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", assertion.command]
        process.currentDirectoryURL = workspace
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return (false, "command '\(assertion.command)' failed to launch: \(error.localizedDescription)")
        }
        // Off-main wait so a slow verification command can't wedge the
        // main-actor runner.
        let exitCode: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
        }
        if Int(exitCode) == assertion.expectExitCode {
            return (true, "command '\(assertion.command)' exited \(exitCode) as expected")
        }
        return (
            false,
            "command '\(assertion.command)' exited \(exitCode), expected \(assertion.expectExitCode)"
        )
    }
}
