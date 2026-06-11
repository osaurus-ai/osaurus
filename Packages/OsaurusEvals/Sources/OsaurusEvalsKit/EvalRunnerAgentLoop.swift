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

        // Per-case capability fixtures: register a TEMPORARY agent whose
        // settings carry the requested flags so prompt gating / tool
        // resolution see them exactly as production would. The agent (and
        // its per-agent database + scheduler rows) is deleted after the
        // outcome assertions run — `dbState` / `scheduledRun` read the
        // isolated stores BEFORE teardown.
        var evalAgentId: UUID?
        if let caps = testCase.fixtures.agentCapabilities, caps.requestsAnyCapability {
            evalAgentId = installEvalAgent(caps)
        }
        defer {
            if let evalAgentId {
                removeEvalAgent(evalAgentId)
            }
        }

        let judgeModel = ProcessInfo.processInfo.environment["JUDGE_MODEL"]
        let started = Date()
        let transcript = await AgentLoopEvaluator.run(
            task: testCase.query,
            workspace: workspace,
            agentId: evalAgentId,
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
                latencyMs: latency,
                toolUsage: toolUsageStats(transcript)
            )
        }

        var score = AgentLoopScore()

        // 1+2. Exit shape + transcript assertions.
        scoreTranscriptAssertions(exp, transcript: transcript, into: &score)

        // 2b. Frontier-lane transcript assertions (ordering, artifact
        // delivery, per-tool hygiene audits).
        if let ordered = exp.mustCallToolsInOrder {
            let result = scoreOrderedSubsequence(ordered, transcript: transcript)
            score.record(result.passed, note: result.note)
        }
        if let artifact = exp.artifactShared {
            let result = scoreArtifactShared(artifact, transcript: transcript)
            score.record(result.passed, note: result.note)
        }
        for audit in exp.toolUsageAudit ?? [] {
            let result = scoreToolUsageAudit(audit, transcript: transcript)
            score.record(result.passed, note: result.note)
        }

        // 2c. Capability-store outcomes (isolated per-eval-agent stores;
        // must run BEFORE the deferred agent teardown — which is
        // guaranteed, since defers run after this whole function body).
        if let scheduled = exp.scheduledRun {
            let result = scoreScheduledRun(scheduled, agentId: evalAgentId)
            score.record(result.passed, note: result.note)
        }
        for assertion in exp.dbState ?? [] {
            let result = scoreDbState(assertion, agentId: evalAgentId)
            score.record(result.passed, note: result.note)
        }

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
            latencyMs: latency,
            toolUsage: toolUsageStats(transcript)
        )
    }

    // MARK: - Capability fixtures (temp eval agent)

    /// Register a temporary agent carrying the fixture's capability
    /// flags. Persisted via `AgentStore.save` directly (NOT
    /// `AgentManager.add`) so the eval path never trips telemetry,
    /// agent-added notifications, or the crypto-address assignment
    /// (which can prompt for the master key in a headless CLI).
    /// The schedule preset is `reactive` — no quiet hours and a
    /// 5-minute min interval — so self-scheduling cases aren't
    /// quiet-hours-clamped depending on when the eval runs.
    private static func installEvalAgent(
        _ caps: EvalCase.AgentCapabilitiesFixture
    ) -> UUID {
        let agent = Agent(
            id: UUID(),
            name: "Osaurus Eval Agent",
            description: "Temporary agent registered by OsaurusEvals; safe to delete.",
            settings: AgentSettings(
                dbEnabled: caps.dbEnabled ?? false,
                schedule: AgentScheduleSettings.defaults(for: .reactive),
                renderChartEnabled: caps.renderChartEnabled ?? false,
                speakEnabled: caps.speakEnabled ?? false,
                searchMemoryEnabled: caps.searchMemoryEnabled ?? false,
                selfSchedulingEnabled: caps.selfSchedulingEnabled ?? false
            )
        )
        AgentStore.save(agent)
        AgentManager.shared.refresh()
        return agent.id
    }

    /// Tear down the temporary eval agent: clear any next-run slot it
    /// scheduled (so the host app's scheduler never wakes a deleted
    /// agent), then delete the agent record — `AgentStore.delete` also
    /// drops the per-agent database directory and scheduler rows.
    private static func removeEvalAgent(_ agentId: UUID) {
        _ = try? LocalAgentBridge.shared.cancelNextRun(agentId: agentId)
        AgentStore.delete(id: agentId)
        AgentManager.shared.refresh()
    }

    // MARK: - Telemetry

    /// Fold the transcript into per-tool usage counters for the report.
    private static func toolUsageStats(_ transcript: AgentLoopTranscript) -> [ToolUsageStat]? {
        guard !transcript.toolCalls.isEmpty else { return nil }
        var calls: [String: Int] = [:]
        var errors: [String: Int] = [:]
        var deduped: [String: Int] = [:]
        for call in transcript.toolCalls {
            calls[call.name, default: 0] += 1
            if call.wasError { errors[call.name, default: 0] += 1 }
            if call.wasDeduped { deduped[call.name, default: 0] += 1 }
        }
        return calls.keys.sorted().map {
            ToolUsageStat(
                tool: $0,
                calls: calls[$0] ?? 0,
                errors: errors[$0] ?? 0,
                deduped: deduped[$0] ?? 0
            )
        }
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

    /// Ordered-subsequence assertion: `ordered` must appear in the
    /// transcript's call sequence in order (other calls may interleave).
    private static func scoreOrderedSubsequence(
        _ ordered: [String],
        transcript: AgentLoopTranscript
    ) -> (passed: Bool, note: String) {
        var cursor = 0
        for call in transcript.toolCalls where cursor < ordered.count {
            if call.name == ordered[cursor] { cursor += 1 }
        }
        if cursor == ordered.count {
            return (true, "mustCallToolsInOrder ok: [\(ordered.joined(separator: " → "))]")
        }
        return (
            false,
            "mustCallToolsInOrder failed at step \(cursor) ('\(ordered[cursor])'): "
                + "sequence [\(transcript.toolCalls.map(\.name).joined(separator: ","))]"
        )
    }

    /// Artifact-delivery assertion: count successful `share_artifact`
    /// calls whose result carries the real artifact header (the marker
    /// blob `SharedArtifact.processToolResult` parses downstream), not
    /// just a tool-name match. Result previews are capped at 300 chars
    /// but the header (`Artifact shared:` / `- Filename:` /
    /// `- Description:`) always leads the payload, so the checks below
    /// see it regardless of artifact size.
    private static func scoreArtifactShared(
        _ assertion: EvalCase.AgentLoopExpectations.ArtifactSharedAssertion,
        transcript: AgentLoopTranscript
    ) -> (passed: Bool, note: String) {
        let qualifying = transcript.toolCalls.filter { call in
            guard call.name == "share_artifact", !call.wasError else { return false }
            guard call.resultPreview.contains("Artifact shared:") else { return false }
            if let needle = assertion.filenameContains {
                guard
                    call.resultPreview.range(
                        of: "Filename: [^\\\\n]*\(NSRegularExpression.escapedPattern(for: needle))",
                        options: [.regularExpression, .caseInsensitive]
                    ) != nil
                else { return false }
            }
            if assertion.descriptionRequired == true {
                guard call.resultPreview.contains("Description:") else { return false }
            }
            return true
        }
        let minCount = assertion.minCount ?? 1
        if qualifying.count >= minCount {
            return (true, "artifactShared ok: \(qualifying.count) qualifying call(s)")
        }
        let attempts = transcript.toolCalls.filter { $0.name == "share_artifact" }
        return (
            false,
            "artifactShared failed: \(qualifying.count)/\(minCount) qualifying "
                + "(\(attempts.count) share_artifact call(s), "
                + "\(attempts.filter(\.wasError).count) errored)"
        )
    }

    /// Per-tool hygiene audit over the transcript.
    private static func scoreToolUsageAudit(
        _ audit: EvalCase.AgentLoopExpectations.ToolUsageAudit,
        transcript: AgentLoopTranscript
    ) -> (passed: Bool, note: String) {
        let calls = transcript.toolCalls.filter { $0.name == audit.tool }
        var failures: [String] = []
        if let maxCalls = audit.maxCalls, calls.count > maxCalls {
            failures.append("calls \(calls.count) > max \(maxCalls)")
        }
        if let minCalls = audit.minCalls, calls.count < minCalls {
            failures.append("calls \(calls.count) < min \(minCalls)")
        }
        if let maxErrors = audit.maxErrors {
            let errs = calls.filter(\.wasError).count
            if errs > maxErrors {
                failures.append("errors \(errs) > max \(maxErrors)")
            }
        }
        if let needle = audit.argsMustContain,
            !calls.contains(where: { $0.arguments.contains(needle) })
        {
            failures.append("no call args contain '\(needle)'")
        }
        if let forbidden = audit.argsMustNotContain {
            let offenders = calls.filter { $0.arguments.contains(forbidden) }
            if !offenders.isEmpty {
                failures.append("\(offenders.count) call(s) args contain forbidden '\(forbidden)'")
            }
        }
        if failures.isEmpty {
            return (true, "toolUsageAudit ok: \(audit.tool) (\(calls.count) calls)")
        }
        return (false, "toolUsageAudit \(audit.tool): \(failures.joined(separator: "; "))")
    }

    /// Scheduler-store outcome: a next-run row must exist for the eval
    /// agent. Reads the same store `schedule_next_run` wrote through, so
    /// a clamped-to-rejection call (daily cap, manual mode) fails here
    /// even though the tool call itself returned a success envelope.
    private static func scoreScheduledRun(
        _ assertion: EvalCase.AgentLoopExpectations.ScheduledRunAssertion,
        agentId: UUID?
    ) -> (passed: Bool, note: String) {
        guard let agentId else {
            return (
                false,
                "scheduledRun requires fixtures.agentCapabilities.selfSchedulingEnabled"
            )
        }
        let entry: NextRunEntry?
        do {
            entry = try LocalAgentBridge.shared.nextRun(agentId: agentId)
        } catch {
            return (false, "scheduledRun: scheduler store read failed: \(error.localizedDescription)")
        }
        guard let entry else {
            return (false, "scheduledRun: no next-run row landed in the scheduler store")
        }
        if let needle = assertion.instructionsContain,
            !entry.instructions.localizedCaseInsensitiveContains(needle)
        {
            return (
                false,
                "scheduledRun: instructions missing '\(needle)' (got: \(entry.instructions.prefix(120)))"
            )
        }
        return (
            true,
            "scheduledRun ok: scheduled_at=\(entry.scheduledAt) instructions=\(entry.instructions.prefix(80))"
        )
    }

    /// Post-run SQL check against the eval agent's database, through the
    /// same bridge the `db_*` tools write through.
    private static func scoreDbState(
        _ assertion: EvalCase.AgentLoopExpectations.DbStateAssertion,
        agentId: UUID?
    ) -> (passed: Bool, note: String) {
        guard let agentId else {
            return (false, "dbState requires fixtures.agentCapabilities.dbEnabled")
        }
        let result: AgentQueryResult
        do {
            result = try LocalAgentBridge.shared.query(
                agentId: agentId,
                sql: assertion.sql,
                params: []
            )
        } catch {
            return (false, "dbState query failed (\(assertion.sql)): \(error.localizedDescription)")
        }
        if let floor = assertion.expectRowCountAtLeast, result.rows.count < floor {
            return (
                false,
                "dbState (\(assertion.sql)): \(result.rows.count) rows < required \(floor)"
            )
        }
        if let expected = assertion.expectFirstValue {
            guard let first = result.rows.first?.first else {
                return (false, "dbState (\(assertion.sql)): no rows, expected first value '\(expected)'")
            }
            let actual = canonicalSQLValueString(first)
            guard actual == expected else {
                return (
                    false,
                    "dbState (\(assertion.sql)): first value '\(actual)' != expected '\(expected)'"
                )
            }
        }
        return (true, "dbState ok (\(assertion.sql)): \(result.rows.count) rows")
    }

    /// Canonical string form for first-value comparisons: integers render
    /// without decimals, doubles drop a trailing `.0` so a SUM() that
    /// comes back as REAL still compares equal to "42".
    private static func canonicalSQLValueString(_ value: AgentSQLValue) -> String {
        switch value {
        case .null: return "null"
        case .integer(let n): return String(n)
        case .double(let d):
            if d == d.rounded(), abs(d) < 1e15 {
                return String(Int64(d))
            }
            return String(d)
        case .text(let s): return s
        case .blob: return "<blob>"
        case .bool(let b): return b ? "1" : "0"
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
