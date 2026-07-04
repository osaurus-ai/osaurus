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

        // Sandbox availability gate (same "didn't apply" semantics as
        // `requirePlugins`): a host without a working, fully-set-up sandbox
        // SKIPS the case instead of failing it, so contributors without
        // Apple Containerization can still run the rest of the suite. This
        // cheap OS/setup check runs BEFORE the tiny-context skip below so
        // that for sandbox cases an unusable host reports an honest
        // "sandbox unavailable" reason for EVERY model — including
        // tiny-context ones (Apple Foundation) that would otherwise mask it
        // as "tools auto-disabled". Runtime boot/cool-down failures this
        // cheap check can't see are caught later at the registrar probe and
        // likewise mapped to SKIP.
        let sandboxFixture = testCase.fixtures.sandbox
        let sandboxMode: AgentLoopSandboxMode? = sandboxFixture.map {
            $0.hostFolder == true ? .combined : .pure
        }
        if sandboxFixture != nil {
            let availability = await SandboxManager.shared.refreshAvailability()
            let config = SandboxConfigurationStore.load()
            if let skipReason = sandboxSkipReason(
                availability: availability,
                setupComplete: config.setupComplete
            ) {
                return .terminal(
                    id: testCase.id,
                    label: label,
                    domain: testCase.domain,
                    outcome: .skipped,
                    notes: [skipReason],
                    modelId: modelId
                )
            }
        }

        // Capability skip (same "didn't apply, not regressed" semantics): a
        // model whose context size class auto-disables tool calling — Apple
        // Foundation and any other ≤4K-token-window model
        // (`ContextSizeClass.tiny`) — cannot be handed the folder/sandbox
        // tools every `agent_loop` case requires. Osaurus strips the entire
        // tool schema at compose time for such models, so the run would
        // otherwise score a wall of FAILs against an empty toolset (a
        // capability mismatch, not an agentic-quality result). Surface it as
        // SKIP with the resolved size class so cross-model reports stay honest.
        let contextWindow = ContextSizeResolver.resolve(modelId: modelId)
        if contextWindow.sizeClass.disablesTools {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .skipped,
                notes: [
                    "tools auto-disabled for '\(modelId)': context size class "
                        + "\(contextWindow.sizeClass) (≤\(ContextSizeResolver.tinyCeiling)-token "
                        + "window) strips the tool schema; agent_loop requires folder tools"
                ],
                modelId: modelId
            )
        }

        // AppleScript delegation cases need an installed AppleScript model —
        // the tool schema is withheld otherwise (same semantics as the
        // apple_script suite's live lanes).
        let wantsAppleScript =
            testCase.fixtures.agentCapabilities?.appleScriptEnabled == true
            || (testCase.expect.agentLoop?.mustCallTools ?? []).contains(where: {
                $0 == "applescript" || $0 == "mac_query"
            })
            || (testCase.expect.agentLoop?.mustCallAnyTools ?? []).contains(where: {
                $0 == "applescript" || $0 == "mac_query"
            })
        if wantsAppleScript {
            let ready = await MainActor.run { EvalHostBootstrap.hasReadyAppleScriptModel }
            if !ready {
                return .terminal(
                    id: testCase.id,
                    label: label,
                    domain: testCase.domain,
                    outcome: .skipped,
                    notes: [
                        "no AppleScript model installed; applescript/mac_query delegation "
                            + "tools withheld — case skipped"
                    ],
                    modelId: modelId
                )
            }
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
                let body = try workspaceFileContents(file)
                try body.write(to: target, atomically: true, encoding: .utf8)
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
        //
        // Sandbox cases ALWAYS install an eval agent: tool registration
        // reads `autonomousExec` off the persisted agent record, so an
        // ephemeral (unsaved) agent id would never get sandbox tools.
        var evalAgentId: UUID?
        if let sandboxFixture {
            evalAgentId = installEvalAgent(
                testCase.fixtures.agentCapabilities,
                autonomousExec: autonomousExecConfig(from: sandboxFixture)
            )
        } else if let caps = testCase.fixtures.agentCapabilities, caps.requestsAnyCapability {
            evalAgentId = installEvalAgent(caps)
        }
        defer {
            if let evalAgentId {
                removeEvalAgent(evalAgentId)
            }
        }

        // Sandbox provisioning + fixture seeding. Boot/provision goes
        // through the SAME registrar the chat surface uses (idempotent —
        // the evaluator re-registers cheaply). Seeds are written via
        // guest-side exec so ownership matches the agent user, and
        // secrets land in the eval agent's keychain namespace. Plugin
        // library state is snapshotted so post-case cleanup removes only
        // what the case created.
        let pluginIdsBeforeRun = Set(SandboxPluginLibrary.shared.plugins.map(\.id))
        var sandboxHome: URL?
        if let sandboxFixture, let evalAgentId {
            /// Setup failed before the loop could run: tear down the
            /// per-case sandbox state and report an errored row.
            func sandboxSetupFailed(_ note: String) async -> EvalCaseReport {
                await cleanupSandboxCase(
                    agentId: evalAgentId,
                    pluginIdsBeforeRun: pluginIdsBeforeRun
                )
                return .terminal(
                    id: testCase.id,
                    label: label,
                    domain: testCase.domain,
                    outcome: .errored,
                    notes: [note],
                    modelId: modelId
                )
            }

            /// Host can't provide a sandbox at all (no container, boot
            /// failed, or in failure cool-down): tear down and SKIP — the
            /// same "didn't apply" signal as a missing plugin, not a model
            /// failure. Distinct from `sandboxSetupFailed` so a real
            /// per-agent provisioning bug still ERRORs.
            func sandboxUnavailableSkip(_ note: String) async -> EvalCaseReport {
                await cleanupSandboxCase(
                    agentId: evalAgentId,
                    pluginIdsBeforeRun: pluginIdsBeforeRun
                )
                return .terminal(
                    id: testCase.id,
                    label: label,
                    domain: testCase.domain,
                    outcome: .skipped,
                    notes: [note],
                    modelId: modelId
                )
            }

            await SandboxToolRegistrar.shared.registerTools(for: evalAgentId)
            if let reason = SandboxToolRegistrar.shared.unavailabilityReason(for: evalAgentId) {
                // Host-capability failures (no container, startup/boot
                // failed, or in failure cool-down) mean this host simply
                // can't provide a sandbox — SKIP, don't ERROR, matching the
                // OS/setup gate above and `requirePlugins` semantics. A
                // per-agent `provisioningFailed` is a real setup bug worth
                // surfacing, so it still ERRORs.
                if Self.sandboxKindIsHostCapability(reason.kind) {
                    return await sandboxUnavailableSkip(
                        "sandbox unavailable (\(reason.kind.rawValue)): \(reason.message)"
                    )
                }
                return await sandboxSetupFailed(
                    "sandbox boot/provision failed (\(reason.kind.rawValue)): \(reason.message)"
                )
            }
            let linuxName = SandboxAgentProvisioner.linuxName(for: evalAgentId.uuidString)
            sandboxHome = OsaurusPaths.containerAgentDir(linuxName)
            for file in sandboxFixture.seedFiles ?? [] {
                if let seedError = await seedSandboxFile(file, agentName: linuxName) {
                    return await sandboxSetupFailed(
                        "sandbox seed failed for '\(file.path)': \(seedError)"
                    )
                }
            }
            for secret in sandboxFixture.seedSecrets ?? [] {
                _ = AgentSecretsKeychain.saveSecret(
                    secret.value,
                    id: secret.key,
                    agentId: evalAgentId
                )
            }
        }

        // Pre-seed the agent DB (requires dbEnabled). Each entry runs through
        // the same multi-statement `db_execute` path the agent uses, so a
        // case can stage baseline rows ("yesterday") before the model sees
        // the task. Runs after the eval agent + any sandbox setup so the
        // per-agent DB exists; failures error the case rather than scoring a
        // misleading FAIL against an unseeded DB.
        if let seeds = testCase.fixtures.seedSql, !seeds.isEmpty {
            guard let seedAgentId = evalAgentId else {
                return .terminal(
                    id: testCase.id,
                    label: label,
                    domain: testCase.domain,
                    outcome: .errored,
                    notes: ["seedSql requires fixtures.agentCapabilities.dbEnabled"],
                    modelId: modelId
                )
            }
            do {
                for sql in seeds {
                    _ = try LocalAgentBridge.shared.execute(
                        agentId: seedAgentId,
                        sql: sql,
                        params: []
                    )
                }
            } catch {
                if sandboxFixture != nil {
                    await cleanupSandboxCase(
                        agentId: seedAgentId,
                        pluginIdsBeforeRun: pluginIdsBeforeRun
                    )
                }
                return .terminal(
                    id: testCase.id,
                    label: label,
                    domain: testCase.domain,
                    outcome: .errored,
                    notes: ["seedSql failed: \(error.localizedDescription)"],
                    modelId: modelId
                )
            }
        }

        let judgeModel = EvalJudgeModel.resolveAndWarnOnce(runModelId: modelId)
        let started = Date()
        let transcript = await AgentLoopEvaluator.run(
            task: testCase.query,
            workspace: workspace,
            agentId: evalAgentId,
            maxIterations: exp.maxIterations ?? 10,
            contextWindowOverride: exp.contextWindowOverride,
            stopOnToolRejection: exp.stopOnToolRejection ?? false,
            sandbox: sandboxMode
        )

        var verdicts: [CapabilityClaimsJudgement] = []
        var judgeAudit: EvalJudgeAudit?
        var judgeElapsed: Double?
        if transcript.error == nil, let rubric = exp.rubric, !rubric.isEmpty {
            // Self-heal the ephemeral judge provider before grading — a
            // provider-mutating suite earlier in the same process (e.g.
            // `default_agent`'s `osaurus_provider`) can have evicted it,
            // which would otherwise fail every rubric row spuriously.
            await ensureJudgeProviderRoutable(judgeModel)
            let judgeStarted = Date()
            let audit = await CapabilityClaimsEvaluator.judgeDetailed(
                finalText: transcript.finalText,
                conditions: rubric,
                model: judgeModel
            )
            judgeElapsed = Date().timeIntervalSince(judgeStarted) * 1000
            verdicts = audit.verdicts
            judgeAudit = EvalJudgeAudit.from(audit, rubric: rubric, selfJudge: judgeModel == nil)
        }
        let elapsed = Date().timeIntervalSince(started) * 1000
        // Report loop-only latency (model steps + tool execution), not
        // wall time inflated by judge calls and workspace setup; judge
        // time rides in `judgeLatencyMs`.
        let latency = transcript.loopDurationMs > 0 ? transcript.loopDurationMs : elapsed

        if let err = transcript.error {
            if sandboxFixture != nil, let evalAgentId {
                await cleanupSandboxCase(
                    agentId: evalAgentId,
                    pluginIdsBeforeRun: pluginIdsBeforeRun
                )
            }
            return persistAgentLoopTranscript(
                transcript,
                for: EvalCaseReport(
                    id: testCase.id,
                    label: label,
                    domain: testCase.domain,
                    query: testCase.query,
                    outcome: .errored,
                    notes: ["agent loop error: \(err)"],
                    modelId: modelId,
                    latencyMs: latency,
                    toolUsage: toolUsageStats(transcript),
                    telemetry: telemetry(from: transcript)
                ),
                query: testCase.query
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

        // 2d. Context-cost ceilings (advisory pins). Estimated input (prompt
        // + frozen tool schema, summed across model steps) and input+output.
        // Only scored when the case opts in AND a measurement exists.
        if let maxPrompt = exp.scoredMaxPromptTokens, let prompt = transcript.promptTokensTotal {
            score.check(
                prompt <= maxPrompt,
                pass: "ctx tokens \(prompt) <= max \(maxPrompt)",
                fail: "ctx tokens \(prompt) > max \(maxPrompt)"
            )
        }
        if let maxTotal = exp.scoredMaxTotalTokens, let prompt = transcript.promptTokensTotal {
            let total = prompt + (transcript.completionTokens ?? 0)
            score.check(
                total <= maxTotal,
                pass: "total tokens \(total) <= max \(maxTotal)",
                fail: "total tokens \(total) > max \(maxTotal)"
            )
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
        // 3b. Sandbox-home outcomes: the VM's /workspace is a VirtioFS
        // mount of ~/.osaurus/container/workspace/, so the agent home is
        // readable directly from the host — no guest exec needed. Must
        // run BEFORE sandbox cleanup (which deletes the home dir).
        for assertion in exp.sandboxFiles ?? [] {
            if let sandboxHome {
                let result = scoreFileAssertion(
                    assertion,
                    workspace: sandboxHome,
                    labelPrefix: "sandbox file"
                )
                score.record(result.passed, note: result.note)
            } else {
                score.record(
                    false,
                    note: "sandboxFiles assertion '\(assertion.path)' requires fixtures.sandbox"
                )
            }
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
        for needle in exp.finalTextMustNotContain ?? [] {
            score.check(
                !transcript.finalText.localizedCaseInsensitiveContains(needle),
                pass: "finalText free of '\(needle)'",
                fail: "finalText LEAKED '\(needle)'"
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

        // Sandbox teardown AFTER all scoring (sandboxFiles reads the
        // home dir this deletes). The container itself stays up — boot
        // is the expensive part; per-agent state is what must not leak.
        if sandboxFixture != nil, let evalAgentId {
            await cleanupSandboxCase(
                agentId: evalAgentId,
                pluginIdsBeforeRun: pluginIdsBeforeRun
            )
        }

        return persistAgentLoopTranscript(
            transcript,
            for: EvalCaseReport(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                query: testCase.query,
                outcome: score.passed ? .passed : .failed,
                notes: score.notes,
                modelId: modelId,
                latencyMs: latency,
                judgeLatencyMs: judgeElapsed,
                toolUsage: toolUsageStats(transcript),
                telemetry: telemetry(from: transcript),
                judge: judgeAudit
            ),
            query: testCase.query
        )
    }

    /// Hand the full loop transcript to the transcript store (a no-op
    /// unless `--transcripts` configured it, and it only keeps
    /// failed/errored rows). Returns the report unchanged so call sites
    /// stay single-expression returns.
    private static func persistAgentLoopTranscript(
        _ transcript: AgentLoopTranscript,
        for report: EvalCaseReport,
        query: String
    ) -> EvalCaseReport {
        EvalTranscriptStore.persistIfEnabled(
            EvalCaseTranscript(
                caseId: report.id,
                domain: report.domain,
                modelId: report.modelId,
                outcome: report.outcome.rawValue,
                query: query,
                systemPrompt: transcript.systemPrompt,
                toolSchemaNames: transcript.toolSchemaNames,
                toolCalls: transcript.toolCalls.map {
                    EvalCaseTranscript.ToolEvent(
                        name: $0.name,
                        arguments: $0.arguments,
                        resultPreview: $0.resultPreview,
                        wasDeduped: $0.wasDeduped,
                        wasError: $0.wasError
                    )
                },
                finalText: transcript.finalText,
                iterations: transcript.iterations,
                exit: transcript.exit,
                notices: transcript.notices,
                error: transcript.error
            )
        )
        return report
    }

    /// Project the agent-loop transcript's generation metrics into the
    /// report's telemetry block (resource metrics — peak RAM, KV delta —
    /// are folded in later by `EvalRunner.runOne`). Returns nil when the
    /// run captured no streaming stats (remote/non-streaming).
    private static func telemetry(from transcript: AgentLoopTranscript) -> EvalCaseTelemetry? {
        // Total = input + output. Only meaningful once we have an input
        // estimate; completion is 0 on remote/non-streaming runs that never
        // surfaced a stats hint, which is the existing `completionTokens`
        // semantic — so the total there is the input estimate alone.
        let total = transcript.promptTokensTotal.map { $0 + (transcript.completionTokens ?? 0) }
        let t = EvalCaseTelemetry(
            decodeTokensPerSecond: transcript.decodeTokensPerSecond,
            prefillTokensPerSecond: transcript.prefillTokensPerSecond,
            ttftMs: transcript.ttftMs,
            completionTokens: transcript.completionTokens,
            promptTokensTotal: transcript.promptTokensTotal,
            peakContextTokens: transcript.peakContextTokens,
            totalModelTokens: total,
            modelSteps: transcript.modelSteps
        )
        return t.isEmpty ? nil : t
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
        _ caps: EvalCase.AgentCapabilitiesFixture?,
        autonomousExec: AutonomousExecConfig? = nil
    ) -> UUID {
        let agent = Agent(
            id: UUID(),
            name: "Osaurus Eval Agent",
            description: "Temporary agent registered by OsaurusEvals; safe to delete.",
            autonomousExec: autonomousExec,
            settings: AgentSettings(
                dbEnabled: caps?.dbEnabled ?? false,
                schedule: AgentScheduleSettings.defaults(for: .reactive),
                renderChartEnabled: caps?.renderChartEnabled ?? false,
                speakEnabled: caps?.speakEnabled ?? false,
                searchMemoryEnabled: caps?.searchMemoryEnabled ?? false,
                selfSchedulingEnabled: caps?.selfSchedulingEnabled ?? false,
                appleScriptEnabled: caps?.appleScriptEnabled ?? false
            )
        )
        AgentStore.save(agent)
        AgentManager.shared.refresh()
        return agent.id
    }

    /// Stand up an isolated, fully-enabled auto-mode eval agent for a
    /// `capability_claims` abstention case. Its allowlist is the live
    /// dynamic-tool registry minus the case's `ensureToolsDisabled` names,
    /// so `effectiveEnabledToolNames` is authoritative (non-nil) and the
    /// must-be-absent tools are verifiably absent. This makes the
    /// `ensureToolsDisabled` gate satisfiable instead of force-skipping on
    /// the Default agent's legacy global tool mode. Auto mode + an allowlist
    /// mirrors a real fully-enabled agent (manifest grounds "do you have X";
    /// the lean hot set + always-loaded `capabilities_discover`/`_load` let
    /// the model discover/abstain). Tear down with `removeEvalAgent`.
    static func installCapabilityClaimsAgent(excluding forbidden: [String]) -> UUID {
        let agentId = installEvalAgent(nil)
        AgentManager.shared.updateToolSelectionMode(.auto, for: agentId)
        let forbiddenSet = Set(forbidden)
        let allowlist = EvalHostBootstrap.dynamicToolNames()
            .filter { !forbiddenSet.contains($0) }
        AgentManager.shared.updateEnabledToolNames(allowlist, for: agentId)
        return agentId
    }

    // MARK: - Sandbox fixtures

    /// Skip-decision for sandbox cases: a host without a working,
    /// fully-set-up sandbox SKIPS instead of failing — same semantics
    /// as `requirePlugins`. Pure so it's unit-testable without a VM.
    static func sandboxSkipReason(
        availability: SandboxAvailability,
        setupComplete: Bool
    ) -> String? {
        if !availability.isAvailable {
            return "sandbox unavailable: \(availability.reason ?? "unknown")"
        }
        if !setupComplete {
            return "sandbox setup incomplete on this host"
        }
        return nil
    }

    /// Which `SandboxToolRegistrar.UnavailabilityReason.Kind`s mean "this
    /// host can't provide a sandbox at all" (so the case SKIPS, same as a
    /// missing plugin) vs a real per-run setup bug (which ERRORs). The
    /// cheap `sandboxSkipReason` gate above only sees OS version + setup
    /// flag; the registrar surfaces actual boot/cool-down failures only
    /// after a `registerTools` probe, so this classifies that result.
    static func sandboxKindIsHostCapability(
        _ kind: SandboxToolRegistrar.UnavailabilityReason.Kind
    ) -> Bool {
        switch kind {
        case .containerUnavailable, .startupFailed:
            return true
        case .provisioningFailed:
            return false
        }
    }

    /// Map the case's sandbox fixture onto the eval agent's
    /// `AutonomousExecConfig`. Omitted flags use the production defaults
    /// for an autonomous-enabled agent.
    static func autonomousExecConfig(
        from fixture: EvalCase.SandboxFixture
    ) -> AutonomousExecConfig {
        AutonomousExecConfig(
            enabled: true,
            maxCommandsPerTurn: fixture.maxCommandsPerTurn ?? 10,
            pluginCreate: fixture.pluginCreate ?? true,
            allowHostSecretReads: fixture.allowHostSecretReads ?? false,
            sandboxNetworkEnabled: fixture.networkEnabled ?? true,
            backgroundProcessEnabled: fixture.backgroundProcessEnabled ?? false
        )
    }

    /// Write one seed file into the eval agent's VM home via guest-side
    /// exec (as the agent user, so ownership matches what `sandbox_*`
    /// tools later read/write). Contents ride base64 so arbitrary code
    /// fixtures survive the shell pipeline. Returns an error string on
    /// failure, nil on success.
    /// Resolve a `WorkspaceFile`'s body: inline `contents` wins; otherwise
    /// load `contentsFromFixture` from the committed fixtures tree; an empty
    /// file when neither is set.
    static func workspaceFileContents(_ file: EvalCase.WorkspaceFile) throws -> String {
        if let inline = file.contents { return inline }
        if let fixture = file.contentsFromFixture, !fixture.isEmpty {
            return try resolveFixtureFileContents(fixture)
        }
        return ""
    }

    /// Load a fixture file's text, trying the candidate locations in order.
    private static func resolveFixtureFileContents(_ relative: String) throws -> String {
        let candidates = fixtureContentCandidateURLs(relative)
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return try String(contentsOf: url, encoding: .utf8)
        }
        throw NSError(
            domain: "OsaurusEvals",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "contentsFromFixture '\(relative)' not found (looked in: "
                    + candidates.map(\.path).joined(separator: ", ") + ")"
            ]
        )
    }

    /// On-disk candidates for a `contentsFromFixture` path, most specific
    /// first. Two launch CWDs must both resolve: `make evals` runs from the
    /// repo root (repo-root-relative `Packages/OsaurusEvals/Fixtures/…`),
    /// while `scripts/evals/optimization-loop.sh` `cd`s into the package dir
    /// before invoking the CLI (package-relative `Fixtures/…`). Without the
    /// package-relative forms the loop doubled the prefix
    /// (`Packages/OsaurusEvals/Packages/OsaurusEvals/Fixtures/…`) and every
    /// `contentsFromFixture` AgentDB case ERRORED on a missing fixture. An
    /// absolute or already-correct CWD-relative path is honored as-is first.
    private static func fixtureContentCandidateURLs(_ relative: String) -> [URL] {
        [
            URL(fileURLWithPath: relative),
            // Launched from the repo root (`make evals`).
            URL(fileURLWithPath: "Packages/OsaurusEvals/Fixtures/\(relative)"),
            URL(fileURLWithPath: "Packages/OsaurusEvals/Fixtures/AgentDB/\(relative)"),
            // Launched from the package dir (optimization-loop.sh cd's in).
            URL(fileURLWithPath: "Fixtures/\(relative)"),
            URL(fileURLWithPath: "Fixtures/AgentDB/\(relative)"),
        ]
    }

    private static func seedSandboxFile(
        _ file: EvalCase.WorkspaceFile,
        agentName: String
    ) async -> String? {
        let home = OsaurusPaths.inContainerAgentHome(agentName)
        let absolute = home + "/" + file.path
        let directory = (absolute as NSString).deletingLastPathComponent
        let contents: String
        do {
            contents = try workspaceFileContents(file)
        } catch {
            return error.localizedDescription
        }
        let encoded = Data(contents.utf8).base64EncodedString()
        do {
            let result = try await SandboxManager.shared.execAsAgent(
                agentName,
                command:
                    "mkdir -p '\(directory)' && printf '%s' '\(encoded)' | base64 -d > '\(absolute)'"
            )
            guard result.succeeded else {
                return result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Post-case sandbox teardown: delete the eval agent's keychain
    /// secrets, uninstall + unregister any plugin the case created
    /// (diffed against the pre-run library snapshot), and unprovision
    /// the agent (Linux user, VM home dir via the host mount, plugin
    /// state, background jobs). The container intentionally stays
    /// running — boot is minutes, per-agent provisioning is cheap, and
    /// the next sandbox case reuses it.
    private static func cleanupSandboxCase(
        agentId: UUID,
        pluginIdsBeforeRun: Set<String>
    ) async {
        AgentSecretsKeychain.deleteAllSecrets(agentId: agentId)

        let createdPluginIds = Set(SandboxPluginLibrary.shared.plugins.map(\.id))
            .subtracting(pluginIdsBeforeRun)
        for pluginId in createdPluginIds {
            try? await SandboxPluginManager.shared.uninstall(
                pluginId: pluginId,
                from: agentId.uuidString
            )
            SandboxToolRegistrar.shared.unregisterPluginTools(pluginId: pluginId)
            SandboxPluginLibrary.shared.delete(id: pluginId)
        }

        _ = await SandboxAgentProvisioner.shared.unprovision(agentId: agentId)
    }

    /// Tear down the temporary eval agent: clear any next-run slot it
    /// scheduled (so the host app's scheduler never wakes a deleted
    /// agent), then delete the agent record — `AgentStore.delete` also
    /// drops the per-agent database directory and scheduler rows.
    /// Internal (not private) so the capability_claims path in
    /// `EvalRunner.swift` can tear down its isolated eval agent too.
    static func removeEvalAgent(_ agentId: UUID) {
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
        if let anyMust = exp.mustCallAnyTools, !anyMust.isEmpty {
            let hit = anyMust.first(where: { calledSet.contains($0) })
            score.check(
                hit != nil,
                pass: "mustCallAnyTools ok: \(hit ?? anyMust[0])",
                fail: "mustCallAnyTools missing all: [\(anyMust.joined(separator: ","))]"
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
        // Substring checks are case-INSENSITIVE, matching the sibling
        // default-agent matcher (`scoreArgsMustContain`): the model's
        // arg/value casing must not flake the assertion. e.g. a model that
        // pages with SQL `... LIMIT 1 OFFSET 22` satisfies `offset` just as
        // one that passes the typed `offset` parameter does — both are real
        // offset paging, and the audit shouldn't reject one on casing alone.
        if let needle = audit.argsMustContain {
            let lowerNeedle = needle.lowercased()
            if !calls.contains(where: { $0.arguments.lowercased().contains(lowerNeedle) }) {
                failures.append("no call args contain '\(needle)'")
            }
        }
        if let forbidden = audit.argsMustNotContain {
            let lowerForbidden = forbidden.lowercased()
            let offenders = calls.filter { $0.arguments.lowercased().contains(lowerForbidden) }
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
        if let exact = assertion.expectRowCountEquals, result.rows.count != exact {
            return (
                false,
                "dbState (\(assertion.sql)): \(result.rows.count) rows != expected \(exact)"
            )
        }
        if let expectedColumns = assertion.expectColumns, result.columns != expectedColumns {
            return (
                false,
                "dbState (\(assertion.sql)): columns \(result.columns) != expected \(expectedColumns)"
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
        if let expectedValues = assertion.expectValues {
            guard let firstRow = result.rows.first else {
                return (
                    false,
                    "dbState (\(assertion.sql)): no rows, expected values \(expectedValues)"
                )
            }
            guard firstRow.count >= expectedValues.count else {
                return (
                    false,
                    "dbState (\(assertion.sql)): row has \(firstRow.count) columns, "
                        + "expected at least \(expectedValues.count) values"
                )
            }
            for (index, expected) in expectedValues.enumerated() {
                let actual = canonicalSQLValueString(firstRow[index])
                guard actual == expected else {
                    return (
                        false,
                        "dbState (\(assertion.sql)): value[\(index)] '\(actual)' "
                            + "!= expected '\(expected)'"
                    )
                }
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

    /// Score one file assertion against `workspace` (the case temp dir
    /// for `files`, the agent home's host mount for `sandboxFiles` —
    /// `labelPrefix` keeps the report lines distinguishable).
    static func scoreFileAssertion(
        _ assertion: EvalCase.AgentLoopExpectations.FileAssertion,
        workspace: URL,
        labelPrefix: String = "file"
    ) -> (passed: Bool, note: String) {
        let url = workspace.appendingPathComponent(assertion.path)
        let exists = FileManager.default.fileExists(atPath: url.path)
        let shouldExist = assertion.exists ?? true

        if !shouldExist {
            return exists
                ? (false, "\(labelPrefix) '\(assertion.path)' exists but was expected absent")
                : (true, "\(labelPrefix) '\(assertion.path)' correctly absent")
        }
        guard exists else {
            return (false, "\(labelPrefix) '\(assertion.path)' missing")
        }
        guard assertion.contains != nil || assertion.equals != nil else {
            return (true, "\(labelPrefix) '\(assertion.path)' exists")
        }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return (false, "\(labelPrefix) '\(assertion.path)' unreadable as UTF-8")
        }
        if let exact = assertion.equals {
            return contents == exact
                ? (true, "\(labelPrefix) '\(assertion.path)' equals expected contents")
                : (false, "\(labelPrefix) '\(assertion.path)' contents differ from expected")
        }
        if let needle = assertion.contains {
            let hit =
                assertion.caseInsensitive == true
                ? contents.range(of: needle, options: .caseInsensitive) != nil
                : contents.contains(needle)
            return hit
                ? (true, "\(labelPrefix) '\(assertion.path)' contains '\(needle)'")
                : (false, "\(labelPrefix) '\(assertion.path)' missing '\(needle)'")
        }
        return (true, "\(labelPrefix) '\(assertion.path)' exists")
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
