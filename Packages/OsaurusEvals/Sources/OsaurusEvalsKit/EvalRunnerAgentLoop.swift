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
            contextWindowOverride: exp.contextWindowOverride
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

        if let err = transcript.error {
            return EvalCaseReport(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                query: testCase.query,
                outcome: .errored,
                notes: ["agent loop error: \(err)"],
                modelId: modelId,
                latencyMs: elapsed
            )
        }

        var notes: [String] = []
        var passed = true

        // 1. Exit shape.
        let allowedExits = exp.allowedExits ?? ["finalResponse"]
        if allowedExits.contains(transcript.exit) {
            notes.append("exit ok: \(transcript.exit)")
        } else {
            passed = false
            notes.append("exit '\(transcript.exit)' not in allowed \(allowedExits)")
        }

        // 2. Transcript assertions.
        let calledNames = transcript.toolCalls.map(\.name)
        let calledSet = Set(calledNames)
        if let must = exp.mustCallTools {
            let missing = must.filter { !calledSet.contains($0) }
            if missing.isEmpty {
                notes.append("mustCallTools ok: [\(must.joined(separator: ","))]")
            } else {
                passed = false
                notes.append("mustCallTools missing: [\(missing.joined(separator: ","))]")
            }
        }
        if let mustNot = exp.mustNotCallTools {
            let offenders = mustNot.filter { calledSet.contains($0) }
            if offenders.isEmpty {
                notes.append("mustNotCallTools ok")
            } else {
                passed = false
                notes.append("mustNotCallTools called: [\(offenders.joined(separator: ","))]")
            }
        }
        if let cap = exp.maxToolCalls {
            if transcript.toolCalls.count <= cap {
                notes.append("maxToolCalls ok: \(transcript.toolCalls.count) ≤ \(cap)")
            } else {
                passed = false
                notes.append("maxToolCalls breached: \(transcript.toolCalls.count) > \(cap)")
            }
        }
        if exp.noDuplicateExecutedCalls == true {
            // Replays through the loop's dedupe (`wasDeduped`) are the
            // mechanism WORKING; only repeated real executions fail.
            var seen: Set<String> = []
            var duplicates: [String] = []
            for call in transcript.toolCalls where !call.wasDeduped {
                let key = call.name + "\u{1F}" + call.arguments
                if !seen.insert(key).inserted {
                    duplicates.append(call.name)
                }
            }
            if duplicates.isEmpty {
                notes.append("noDuplicateExecutedCalls ok")
            } else {
                passed = false
                notes.append(
                    "duplicate executions: [\(duplicates.joined(separator: ","))]"
                )
            }
        }

        // 3. Workspace outcomes.
        for assertion in exp.files ?? [] {
            let result = scoreFileAssertion(assertion, workspace: workspace)
            passed = passed && result.passed
            notes.append(result.note)
        }
        for assertion in exp.commands ?? [] {
            let result = await scoreCommandAssertion(assertion, workspace: workspace)
            passed = passed && result.passed
            notes.append(result.note)
        }

        // 4. Final-text checks.
        for needle in exp.finalTextContains ?? [] {
            if transcript.finalText.localizedCaseInsensitiveContains(needle) {
                notes.append("finalText contains '\(needle)'")
            } else {
                passed = false
                notes.append("finalText missing '\(needle)'")
            }
        }

        // 5. LLM-judge rubric — every condition must pass.
        let rubric = exp.rubric ?? []
        for (index, verdict) in verdicts.enumerated() {
            let condition = index < rubric.count ? rubric[index] : "(condition \(index))"
            if verdict.pass {
                notes.append("judge ok: \(condition)")
            } else {
                passed = false
                notes.append("judge FAIL: \(condition) — \(verdict.reason)")
            }
        }
        if !rubric.isEmpty && verdicts.count != rubric.count {
            passed = false
            notes.append("judge produced \(verdicts.count) verdicts for \(rubric.count) conditions")
        }

        // Surface error envelopes from the transcript on failure —
        // repeated tool errors are invisible in the summary line alone
        // and are the first thing needed to debug a failing case.
        if !passed {
            for call in transcript.toolCalls where call.resultPreview.contains("\"ok\":false") {
                notes.append(
                    "tool error: \(call.name)(\(call.arguments.prefix(160))) → \(call.resultPreview.prefix(200))"
                )
            }
            notes.append("tool schemas: [\(transcript.toolSchemaNames.joined(separator: ","))]")
        }
        notes.append(
            "summary: toolCalls=[\(calledNames.joined(separator: ","))] "
                + "iters=\(transcript.iterations) exit=\(transcript.exit)"
        )
        notes.append("final: \(transcript.finalText.replacingOccurrences(of: "\n", with: " "))")

        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: passed ? .passed : .failed,
            notes: notes,
            modelId: modelId,
            latencyMs: elapsed
        )
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
