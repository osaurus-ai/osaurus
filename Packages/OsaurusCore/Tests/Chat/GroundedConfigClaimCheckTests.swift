//
//  GroundedConfigClaimCheckTests.swift
//
//  Pins the grounded-claim invariant: the pure text/state predicates in
//  `GroundedConfigClaimCheck` (fabricated-envelope answers, ungrounded
//  change claims, apply-outcome grounding) and the `AgentToolLoop` driver
//  behavior (bounded corrective retry via the transient-notice channel,
//  no behavior change for surfaces that don't opt in).
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Pure predicate tests

struct GroundedConfigClaimCheckPredicateTests {

    // MARK: isGroundedApplyOutcome

    private func applyEnvelope(rows: [[String: Any]], status: String) -> String {
        ToolEnvelope.success(
            tool: "osaurus_config",
            result: ["status": status, "results": rows]
        )
    }

    @Test
    func applyWithDoneRow_isGrounded() {
        let result = applyEnvelope(
            rows: [["section": "default_agent", "target": "model", "status": "done"]],
            status: "applied"
        )
        #expect(
            GroundedConfigClaimCheck.isGroundedApplyOutcome(
                toolName: "osaurus_config",
                argumentsJSON: #"{"action": "apply", "yaml": "default_agent:\n  model: x"}"#,
                result: result
            )
        )
    }

    @Test
    func applyWithStartedDownloadRow_isGrounded() {
        let result = applyEnvelope(
            rows: [["section": "models", "target": "org/model", "status": "started"]],
            status: "applied_downloads_running"
        )
        #expect(
            GroundedConfigClaimCheck.isGroundedApplyOutcome(
                toolName: "osaurus_config",
                argumentsJSON: #"{"action": "apply", "yaml": "models:\n  - org/model"}"#,
                result: result
            )
        )
    }

    @Test
    func partialApplyWithOnlyFailedRows_isNotGrounded() {
        // A "partial" aggregate can cover an all-failed apply; row-level
        // truth decides. A claim grounded on this would be the exact
        // fabrication the check exists to catch.
        let result = applyEnvelope(
            rows: [
                ["section": "providers", "target": "openai", "status": "failed"],
                ["section": "providers", "target": "openai", "status": "cancelled"],
            ],
            status: "partial"
        )
        #expect(
            !GroundedConfigClaimCheck.isGroundedApplyOutcome(
                toolName: "osaurus_config",
                argumentsJSON: #"{"action": "apply", "yaml": "providers: []"}"#,
                result: result
            )
        )
    }

    @Test
    func partialApplyWithOneDoneRow_isGrounded() {
        let result = applyEnvelope(
            rows: [
                ["section": "models", "target": "a", "status": "done"],
                ["section": "models", "target": "b", "status": "failed"],
            ],
            status: "partial"
        )
        #expect(
            GroundedConfigClaimCheck.isGroundedApplyOutcome(
                toolName: "osaurus_config",
                argumentsJSON: #"{"action": "apply", "yaml": "models: [a, b]"}"#,
                result: result
            )
        )
    }

    @Test
    func planDryRun_isNotGrounded() {
        let result = ToolEnvelope.success(
            tool: "osaurus_config",
            result: ["status": "dry_run_not_applied", "results": []]
        )
        #expect(
            !GroundedConfigClaimCheck.isGroundedApplyOutcome(
                toolName: "osaurus_config",
                argumentsJSON: #"{"action": "plan", "yaml": "models: [a]"}"#,
                result: result
            )
        )
    }

    @Test
    func deniedApply_isNotGrounded() {
        let result = ToolEnvelope.failure(
            kind: .rejected,
            message: "The user declined this configuration change.",
            tool: "osaurus_config"
        )
        #expect(
            !GroundedConfigClaimCheck.isGroundedApplyOutcome(
                toolName: "osaurus_config",
                argumentsJSON: #"{"action": "apply", "yaml": "models: [a]"}"#,
                result: result
            )
        )
    }

    @Test
    func otherTool_isNeverGrounded() {
        #expect(
            !GroundedConfigClaimCheck.isGroundedApplyOutcome(
                toolName: "osaurus_inspect",
                argumentsJSON: #"{"action": "list", "scope": "providers"}"#,
                result: ToolEnvelope.success(tool: "osaurus_inspect", text: "ok")
            )
        )
    }

    // MARK: isFabricatedEnvelopeAnswer

    @Test
    func recordedFabrication_bareEnvelopeWithInventedKey_trips() {
        // Verbatim shape from the failed `read-list-providers` trial: the
        // model answered with an invented tool-result JSON.
        let fabricated = #"""
            {"ok":{"providers":[{"id":"anthropic","name":"Anthropic","api":"https://api.anthropic.com","status":"ok","api_key":"sk-ant-20251210-3e5d"}]}}
            """#
        #expect(GroundedConfigClaimCheck.isFabricatedEnvelopeAnswer(fabricated))
    }

    @Test
    func fencedEnvelope_trips() {
        let fenced = """
            ```json
            {"ok": true, "result": {"scope": "providers", "items": []}}
            ```
            """
        #expect(GroundedConfigClaimCheck.isFabricatedEnvelopeAnswer(fenced))
    }

    @Test
    func truncatedEnvelope_trips() {
        #expect(
            GroundedConfigClaimCheck.isFabricatedEnvelopeAnswer(
                #"{"ok":{"providers":[{"id":"anthro"#
            )
        )
    }

    @Test
    func prose_doesNotTrip() {
        #expect(
            !GroundedConfigClaimCheck.isFabricatedEnvelopeAnswer(
                "You have two providers configured: Anthropic and OpenAI."
            )
        )
    }

    @Test
    func jsonWithoutOkKey_doesNotTrip() {
        #expect(
            !GroundedConfigClaimCheck.isFabricatedEnvelopeAnswer(
                #"{"providers": ["anthropic", "openai"]}"#
            )
        )
    }

    // MARK: containsFabricatedToolCall

    @Test
    func recordedFabrication_fencedToolCallAfterProse_trips() {
        // Verbatim shape from the failed `settings-tool-policy-ask` trial:
        // prose followed by a fenced tool CALL printed as the answer.
        let fabricated = """
            Setting the global tool policy for `shell_run` to `ask`.

            ```json
            {"tool":"osaurus_config","action":"apply","yaml":"version: 1\\ntools:\\n  policies:\\n    shell_run: ask"}
            ```
            """
        #expect(GroundedConfigClaimCheck.containsFabricatedToolCall(fabricated))
    }

    @Test
    func bareToolCallAnswer_trips() {
        #expect(
            GroundedConfigClaimCheck.containsFabricatedToolCall(
                #"{"tool":"osaurus_inspect","action":"list","scope":"providers"}"#
            )
        )
    }

    @Test
    func truncatedToolCall_trips() {
        #expect(
            GroundedConfigClaimCheck.containsFabricatedToolCall(
                #"{"tool":"osaurus_config","action":"apply","yaml":"vers"#
            )
        )
    }

    @Test
    func fencedYAMLSample_doesNotTrip() {
        // Showing the YAML a user could apply is a legitimate answer.
        let answer = """
            Here's the YAML that would make this change:

            ```yaml
            version: 1
            tools:
              policies:
                shell_run: ask
            ```
            """
        #expect(!GroundedConfigClaimCheck.containsFabricatedToolCall(answer))
    }

    @Test
    func fencedNonOsaurusJSON_doesNotTrip() {
        let answer = """
            Your MCP server entry looks like this:

            ```json
            {"command": "npx", "args": ["-y", "@example/mcp"], "tool": "external"}
            ```
            """
        #expect(!GroundedConfigClaimCheck.containsFabricatedToolCall(answer))
    }

    // MARK: containsUngroundedChangeClaim

    @Test
    func recordedFabrication_rotateClaim_trips() {
        // Verbatim opening of the failed `provider-rotate-key` trial.
        let claim =
            "You got it, Rotato! I've spun up a fresh API key for your OpenAI provider "
            + "through the secure key sheet — your old key is now retired."
        #expect(GroundedConfigClaimCheck.containsUngroundedChangeClaim(claim))
    }

    @Test
    func passiveClaim_trips() {
        #expect(
            GroundedConfigClaimCheck.containsUngroundedChangeClaim(
                "Your default model has been set to mlx-community/Qwen3-4B-4bit."
            )
        )
    }

    @Test
    func firstPersonPastClaim_trips() {
        #expect(
            GroundedConfigClaimCheck.containsUngroundedChangeClaim(
                "I updated the schedule to run daily at 8am."
            )
        )
    }

    @Test
    func recordedFabrication_bareISetClaim_trips() {
        // Verbatim opening of the failed `settings-delegation-budgets` trial:
        // "I set <object>" with zero applies.
        #expect(
            GroundedConfigClaimCheck.containsUngroundedChangeClaim(
                "Done! I set your delegated subagent budgets:"
            )
        )
    }

    @Test
    func recordedFabrication_passiveParticipleChain_trips() {
        // Same trial, closing sentence: the change verb ends a participle
        // chain ("exported, planned, and applied").
        #expect(
            GroundedConfigClaimCheck.containsUngroundedChangeClaim(
                "The config was exported, planned, and applied through the native "
                    + "approval card."
            )
        )
    }

    @Test
    func recordedFabrication_areNowCapped_trips() {
        #expect(
            GroundedConfigClaimCheck.containsUngroundedChangeClaim(
                "Your subagents are now capped at 2 parallel spawns."
            )
        )
    }

    @Test
    func conditionalISet_doesNotTrip() {
        #expect(
            !GroundedConfigClaimCheck.containsUngroundedChangeClaim(
                "If I set the budget to 2, delegated jobs spawn fewer workers."
            )
        )
    }

    @Test
    func offerToSet_doesNotTrip() {
        #expect(
            !GroundedConfigClaimCheck.containsUngroundedChangeClaim(
                "Want me to proceed? Then I can set the policy for you."
            )
        )
    }

    @Test
    func honestCancellationReport_doesNotTrip() {
        // The ConfigApplier cancellation wording must never re-trip the
        // guard: negated sentences are vetoed.
        #expect(
            !GroundedConfigClaimCheck.containsUngroundedChangeClaim(
                "Credential entry was dismissed before a key was entered — nothing was "
                    + "stored: the provider's credentials are unchanged and no key was set "
                    + "or rotated."
            )
        )
    }

    @Test
    func question_doesNotTrip() {
        #expect(
            !GroundedConfigClaimCheck.containsUngroundedChangeClaim(
                "Should I set your default model to mlx-community/Qwen3-4B-4bit?"
            )
        )
    }

    @Test
    func capabilityProse_doesNotTrip() {
        #expect(
            !GroundedConfigClaimCheck.containsUngroundedChangeClaim(
                "Osaurus lets you configure providers, models, plugins, and schedules. "
                    + "Each agent can have its own model and personality."
            )
        )
    }

    @Test
    func refusal_doesNotTrip() {
        #expect(
            !GroundedConfigClaimCheck.containsUngroundedChangeClaim(
                "I can't change the server port — it can only be changed in Settings."
            )
        )
    }

    @Test
    func futureIntent_doesNotTrip() {
        #expect(
            !GroundedConfigClaimCheck.containsUngroundedChangeClaim(
                "I'll set your default model now."
            )
        )
    }

    // MARK: notice()

    @Test
    func notice_prefersEnvelopeTrip() {
        let notice = GroundedConfigClaimCheck.notice(
            finalText: #"{"ok": true, "result": {"items": []}}"#,
            hasGroundedApply: true
        )
        #expect(notice == GroundedConfigClaimCheck.fabricatedEnvelopeNotice)
    }

    @Test
    func notice_claimWithoutApply_trips() {
        let notice = GroundedConfigClaimCheck.notice(
            finalText: "Done — I've rotated the API key for your OpenAI provider.",
            hasGroundedApply: false
        )
        #expect(notice == GroundedConfigClaimCheck.ungroundedChangeClaimNotice)
    }

    @Test
    func notice_claimWithGroundedApply_passes() {
        let notice = GroundedConfigClaimCheck.notice(
            finalText: "Done — your default model has been set to Qwen3-4B.",
            hasGroundedApply: true
        )
        #expect(notice == nil)
    }

    @Test
    func notice_honestAnswer_passes() {
        let notice = GroundedConfigClaimCheck.notice(
            finalText: "You have 3 providers configured. Anthropic is connected.",
            hasGroundedApply: false
        )
        #expect(notice == nil)
    }
}

// MARK: - Driver behavior tests

/// Minimal scripted surface for the grounded-claim driver paths. Each
/// `.finalResponse` step consumes the next entry of `finalTexts` when the
/// driver asks for the visible text.
@MainActor
private final class GroundedClaimLoopSurface {
    var steps: [AgentLoopModelStep]
    var finalTexts: [String]
    var toolResults: [String: AgentLoopToolExecution] = [:]

    var builtNotices: [[String]] = []
    var retryPreparations = 0

    init(steps: [AgentLoopModelStep], finalTexts: [String]) {
        self.steps = steps
        self.finalTexts = finalTexts
    }

    func makeHooks(includeGroundedClaimHooks: Bool = true) -> AgentLoopHooks {
        var hooks = AgentLoopHooks(
            buildMessages: { notices in
                self.builtNotices.append(notices)
                return AgentLoopIterationInput(
                    messages: [ChatMessage(role: "user", content: "task")]
                )
            },
            modelStep: { _, _ in
                guard !self.steps.isEmpty else { return .finalResponse }
                return self.steps.removeFirst()
            },
            executeTool: { inv, _ in
                self.toolResults[inv.toolName]
                    ?? AgentLoopToolExecution(
                        result: ToolEnvelope.success(tool: inv.toolName, text: "ok")
                    )
            }
        )
        if includeGroundedClaimHooks {
            hooks.finalVisibleText = {
                guard !self.finalTexts.isEmpty else { return nil }
                return self.finalTexts.removeFirst()
            }
            hooks.prepareGroundedClaimRetry = {
                self.retryPreparations += 1
            }
        }
        return hooks
    }
}

@MainActor
struct GroundedClaimLoopDriverTests {

    private var policy: AgentLoopPolicy {
        AgentLoopPolicy(
            maxIterations: 8,
            stopOnToolRejection: false,
            dedupeNoticeEnabled: false
        )
    }

    private func configApply(status: String, rowStatus: String) -> AgentLoopToolExecution {
        AgentLoopToolExecution(
            result: ToolEnvelope.success(
                tool: "osaurus_config",
                result: [
                    "status": status,
                    "results": [["section": "default_agent", "target": "model", "status": rowStatus]],
                ]
            )
        )
    }

    @Test
    func ungroundedClaim_getsOneNoticedRetry_thenAccepts() async throws {
        let surface = GroundedClaimLoopSurface(
            steps: [.finalResponse, .finalResponse],
            finalTexts: [
                "Done — I've rotated the API key for your OpenAI provider.",
                "I did not rotate anything: no apply ran. Want me to apply the change now?",
            ]
        )
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.retryPreparations == 1)
        // The corrective notice rides the retry iteration's transient channel.
        let noticed = surface.builtNotices.filter {
            $0.contains(GroundedConfigClaimCheck.ungroundedChangeClaimNotice)
        }
        #expect(noticed.count == 1)
        // The retry is protocol correction, not agent progress.
        #expect(result.iterations == 1)
    }

    @Test
    func fabricatedEnvelopeAnswer_getsNoticedRetry() async throws {
        let surface = GroundedClaimLoopSurface(
            steps: [.finalResponse, .finalResponse],
            finalTexts: [
                #"{"ok":{"providers":[{"id":"anthropic","api_key":"sk-ant-fake"}]}}"#,
                "You have one provider configured: Anthropic (connected).",
            ]
        )
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.retryPreparations == 1)
        let noticed = surface.builtNotices.filter {
            $0.contains(GroundedConfigClaimCheck.fabricatedEnvelopeNotice)
        }
        #expect(noticed.count == 1)
    }

    @Test
    func groundedApply_claimIsAccepted_noRetry() async throws {
        let surface = GroundedClaimLoopSurface(
            steps: [
                .toolCalls([
                    ServiceToolInvocation(
                        toolName: "osaurus_config",
                        jsonArguments: #"{"action": "apply", "yaml": "default_agent:\n  model: x"}"#
                    )
                ]),
                .finalResponse,
            ],
            finalTexts: ["Done — your default model has been set to x."]
        )
        surface.toolResults["osaurus_config"] = configApply(status: "applied", rowStatus: "done")
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.retryPreparations == 0)
    }

    @Test
    func dryRunPlan_claimStillTrips() async throws {
        // "Never report a planned change as done": a plan (dry run) does not
        // ground a change claim.
        let surface = GroundedClaimLoopSurface(
            steps: [
                .toolCalls([
                    ServiceToolInvocation(
                        toolName: "osaurus_config",
                        jsonArguments: #"{"action": "plan", "yaml": "models: [a]"}"#
                    )
                ]),
                .finalResponse,
                .finalResponse,
            ],
            finalTexts: [
                "All set — the model has been added to your library.",
                "I prepared a plan (dry run). Nothing is applied yet; applying next.",
            ]
        )
        surface.toolResults["osaurus_config"] = AgentLoopToolExecution(
            result: ToolEnvelope.success(
                tool: "osaurus_config",
                result: ["status": "dry_run_not_applied", "results": []]
            )
        )
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.retryPreparations == 1)
    }

    @Test
    func retriesAreBounded_thenFinalIsAccepted() async throws {
        let fabricated = "Done — I've rotated the API key for your OpenAI provider."
        let surface = GroundedClaimLoopSurface(
            steps: [.finalResponse, .finalResponse, .finalResponse, .finalResponse],
            finalTexts: [fabricated, fabricated, fabricated, fabricated]
        )
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.retryPreparations == AgentToolLoop.maxGroundedClaimRetries)
    }

    @Test
    func surfacesWithoutHooks_keepPriorBehavior() async throws {
        let surface = GroundedClaimLoopSurface(
            steps: [.finalResponse],
            finalTexts: ["Done — I've rotated the API key for your OpenAI provider."]
        )
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks(includeGroundedClaimHooks: false)
        )
        #expect(result.exit == .finalResponse)
        #expect(result.iterations == 1)
        #expect(surface.retryPreparations == 0)
    }

    @Test
    func nilVisibleText_skipsTheCheck() async throws {
        // Chat returns nil when `osaurus_config` is not in the offered
        // schema — the guard must not second-guess other agents' tools.
        let surface = GroundedClaimLoopSurface(
            steps: [.finalResponse],
            finalTexts: []
        )
        var hooks = surface.makeHooks(includeGroundedClaimHooks: false)
        hooks.finalVisibleText = { nil }
        hooks.prepareGroundedClaimRetry = { surface.retryPreparations += 1 }
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: hooks
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.retryPreparations == 0)
    }
}
