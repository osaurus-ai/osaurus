//
//  DefaultAgentConfigurationEvaluator.swift
//  osaurus
//
//  Public facade that drives a real, multi-turn agent loop pinned to the
//  built-in Default (configuration) agent for the OsaurusEvals
//  `default_agent` domain. It exists so the eval runner can prove the
//  Default agent's stability end to end: with the agent pinned, the
//  composer resolves exactly the consolidated configure surface
//  (the `osaurus_inspect` read + the
//  per-domain `osaurus_*` write tools) plus the agent-loop tools — and
//  NOTHING else — so a case can assert which tools the model calls, the
//  arguments it passes, and that out-of-scope asks route to creating or
//  switching an agent.
//
//  This is a thin pin over `CapabilityClaimsEvaluator`: same compose-once,
//  frozen-schema, multi-turn loop and the same hardened LLM-judge, just
//  bound to `Agent.defaultId` (and `executionMode: .none`, which the
//  underlying loop already uses). Reusing that machinery keeps a single
//  battle-tested transcript + judge path instead of forking it.
//

import Foundation

/// Public entry point for the Default-agent configuration evals. Lives on
/// the main actor because the prompt composer, tool registry, and agent
/// lookups it drives are all main-actor-isolated.
@MainActor
public enum DefaultAgentConfigurationEvaluator {

    /// Run the multi-turn agent loop for `query` against the **Default
    /// (configuration) agent**, regardless of which agent is currently
    /// active. The loop composes the real system prompt + frozen tool
    /// schema once (the Default agent's consolidated configure surface),
    /// dispatches every tool call through `ToolRegistry.execute`, and
    /// continues until the model answers without calling a tool (or
    /// `maxIterations` is hit). Returns the same decode-friendly transcript
    /// the capability-claims lane uses.
    ///
    /// `model` defaults to whatever `ChatConfigurationStore` currently
    /// routes to (set by the eval runner's `ModelOverride`).
    /// Wall-clock budget for any single configure-tool execution before the
    /// harness abandons it and feeds the model a typed timeout error. An
    /// `osaurus_config` apply mostly mutates local state (fast) or opens a
    /// credential sheet that the eval bypass resolves instantly, but some
    /// sections reach live services — a `models:` entry probes Hugging Face,
    /// a `plugins:` entry hits the registry, an `mcp_servers:` entry connects
    /// the server. With no/slow network those awaits would otherwise stall the
    /// whole suite. 25s is far longer than any healthy local op yet bounds a
    /// hung network call. The tool CALL is recorded before execution, so
    /// `argsMustContain` / `mustCallTools` still score the model's selection.
    public static let toolExecutionTimeout: TimeInterval = 25

    public static func run(
        query: String,
        maxIterations: Int = 6,
        model: String? = nil
    ) async -> CapabilityClaimsTranscript {
        // The configure tools (`osaurus_config` + the reads) are registered
        // into `ToolRegistry` lazily by the domain bootstrap, not as static
        // built-ins. The host app calls this from
        // `applicationDidFinishLaunching`, but the out-of-process eval CLI
        // does not run AppDelegate — so without this idempotent call a
        // `default_agent` run would compose a Default agent that can only see
        // the loop tools, and every `mustCallTools` case would fail for
        // "tool not in schema" reasons that have nothing to do with the
        // model. Idempotent (latched + registry-deduped).
        ConfigurationDomainBootstrap.registerBuiltIns()

        // The configure write (`osaurus_config`) carries an `.ask`
        // permission policy. Production gates each write behind a one-tap
        // approval; the headless eval has no UI, so without this bypass the
        // first write tool call suspends forever on `ToolPermissionPromptService`
        // and wedges the whole suite. Auto-approving here mirrors the bypass
        // `AgentLoopEvaluator` already uses and the security contract pinned by
        // `ToolRegistryAutoApproveTests` (production surfaces keep the `false`
        // default). The case assertions score the model's tool SELECTION, not
        // the human approval step, so this does not weaken what we measure.
        return await CapabilityClaimsEvaluator.run(
            query: query,
            agentId: Agent.defaultId,
            maxIterations: maxIterations,
            model: model,
            toolExecutionTimeout: toolExecutionTimeout,
            autoApproveToolPrompts: true
        )
    }

    /// Grade `finalText` against each rubric `condition` with a single
    /// LLM-judge call. Delegates to the hardened capability-claims judge
    /// (tolerant verdict parsing, index-aligned, never silently passes on
    /// a broken judge). Returns one verdict per condition, in order.
    public static func judge(
        finalText: String,
        conditions: [String],
        model: String? = nil
    ) async -> [CapabilityClaimsJudgement] {
        await CapabilityClaimsEvaluator.judge(
            finalText: finalText,
            conditions: conditions,
            model: model
        )
    }

    /// `judge` plus the audit trail (raw judge reply, resolved judge model,
    /// attempts) — same delegation, for callers that persist judge evidence.
    public static func judgeDetailed(
        finalText: String,
        conditions: [String],
        model: String? = nil
    ) async -> CapabilityClaimsJudgeAudit {
        await CapabilityClaimsEvaluator.judgeDetailed(
            finalText: finalText,
            conditions: conditions,
            model: model
        )
    }
}
