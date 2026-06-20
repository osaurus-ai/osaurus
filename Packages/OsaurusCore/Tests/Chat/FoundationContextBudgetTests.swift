//
//  FoundationContextBudgetTests.swift
//
//  W6 token-budget proof for Apple Foundation's real 4096-token window
//  (read live from `SystemLanguageModel.contextSize` — see
//  `ContextSizeResolver`). The W6 plan gates the "should we build a
//  Foundation-only tiny-tool mode?" decision on a token-budget proof, so
//  this suite measures, with the SAME `TokenEstimator` heuristic the budget
//  pipeline uses:
//
//    1. The FULL agentic tool surface (compact system prompt + the
//       always-loaded sandbox / agent-loop / capability-discovery schema)
//       a `.small` session ships — to confirm it does NOT leave room for a
//       real conversation inside 4096. This is the "why tools are auto-off
//       at the tiny ceiling" number, and the reason the probe must keep
//       Foundation `.tiny` until a device reports a larger window.
//
//    2. A deliberately MINIMAL "tiny-tool mode" surface (stripped prompt +
//       3 ultra-minimal tools) — to record whether such a mode is
//       budget-feasible at 4096. The go/no-go writeup lives in
//       `Packages/OsaurusEvals/Config/foundation-context-probe.md`; this
//       test is the durable evidence behind it and guards the numbers from
//       silent drift.
//
//  Note: the authoritative native-tool cost (`LanguageModelSession`
//  `tokenCount(for: tools)`) is macOS 26.4+; this proof uses the chars/4
//  estimate of the equivalent JSON schema, which is what the runtime budget
//  pipeline itself believes.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct FoundationContextBudgetTests {

    /// Foundation's real window on the macOS 26.x baseline (and the value
    /// `ContextSizeResolver` probes on this device). Hard-coded here as the
    /// budget ceiling under test rather than read from the live probe so the
    /// proof is deterministic on CI without a Foundation-capable model.
    private static let foundationWindow = 4096

    // MARK: - Full agentic surface (the reason tools are auto-off at 4K)

    /// Live-compose the baseline sandbox tool surface + compact prompt, then
    /// price it. Lock order mirrors `TotalPromptBudgetTests`
    /// (Storage → Sandbox, catalog lock innermost) so a concurrent suite
    /// registering dynamic/MCP tools can't inflate the schema mid-measure.
    private func measuredFullStaticSurfaceTokens() async -> (prompt: Int, tools: Int) {
        await SandboxTestLock.runWithStoragePaths {
            await DynamicCatalogTestLock.shared.run {
                let config = AutonomousExecConfig(enabled: true, pluginCreate: false)
                let agent = Agent(
                    name: "FoundationBudgetAgent",
                    systemPrompt: "Test identity",
                    agentAddress: "test-foundation-budget-\(UUID().uuidString)",
                    autonomousExec: config
                )
                AgentManager.shared.add(agent)
                BuiltinSandboxTools.register(
                    agentId: agent.id.uuidString,
                    agentName: agent.name,
                    config: config
                )

                // Compose the compact prompt a small local model receives —
                // the closest analogue to what Foundation would get if tools
                // were forced on at its window.
                let ctx = await SystemPromptComposer.composeChatContext(
                    agentId: agent.id,
                    executionMode: .sandbox(hostRead: nil),
                    model: "qwen3-8b"
                )

                let expectedNames = ToolRegistry.shared.builtInSandboxToolNamesSnapshot
                    .union(SystemPromptComposer.agentLoopToolNames)
                    .union(["capabilities_discover", "capabilities_load"])
                let baseline = ctx.tools.filter { expectedNames.contains($0.function.name) }
                let toolTokens = ToolRegistry.shared.totalEstimatedTokens(for: baseline)
                let promptTokens = TokenEstimator.estimate(ctx.prompt)

                ToolRegistry.shared.unregisterAllSandboxTools()
                _ = await AgentManager.shared.delete(id: agent.id)
                return (promptTokens, toolTokens)
            }
        }
    }

    @Test("full agentic surface does not fit Foundation's 4K window")
    func fullSurfaceOverflowsTinyWindow() async {
        let (promptTokens, toolTokens) = await measuredFullStaticSurfaceTokens()
        let total = promptTokens + toolTokens
        let window = Self.foundationWindow
        let headroom = window - total

        print(
            "[W6] FULL surface @4K: prompt=\(promptTokens) + tools=\(toolTokens) "
                + "= \(total) tokens; window=\(window); conversation headroom=\(headroom) "
                + "(\(headroom * 100 / window)%)"
        )

        // The full static surface must consume MORE than three-quarters of a
        // 4096 window — i.e. it leaves under 25% for the user message,
        // multi-step transcript growth, and the response reservation. That is
        // the structural reason `ContextSizeResolver` keeps Foundation `.tiny`
        // (tools off) until the device reports a larger window.
        #expect(
            total > (window * 3) / 4,
            "Full agentic surface is only \(total) tokens — if it now fits a 4K window with room to spare, Foundation could host the full tool surface and the .tiny auto-off policy should be revisited."
        )
    }

    // MARK: - Minimal tiny-tool surface (budget feasibility)

    /// The stripped system prompt a tiny-tool mode would ship: identity +
    /// persona + a single one-line directive. No gated sections, no manifest,
    /// no family guidance.
    private func strippedTinyPrompt() -> String {
        [
            SystemPromptTemplates.platformIdentity,
            SystemPromptTemplates.defaultPersona,
            "Use a tool when it helps; otherwise answer directly. "
                + "Call `finish` with your final answer when done.",
        ].joined(separator: "\n\n")
    }

    /// Three ultra-minimal tools — the most a 4K window could plausibly host
    /// while leaving conversation budget. Hand-built so the schema is as lean
    /// as a Foundation-native tool would be.
    private func minimalToolSpecs() -> [Tool] {
        func tool(_ name: String, _ desc: String, _ arg: String, _ argDesc: String) -> Tool {
            Tool(
                type: "function",
                function: ToolFunction(
                    name: name,
                    description: desc,
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            arg: .object([
                                "type": .string("string"),
                                "description": .string(argDesc),
                            ])
                        ]),
                        "required": .array([.string(arg)]),
                    ])
                )
            )
        }
        return [
            tool("read_file", "Read a file's contents.", "path", "File path."),
            tool("run_command", "Run a shell command.", "command", "Command to run."),
            tool("finish", "Return the final answer.", "answer", "Final answer text."),
        ]
    }

    @Test("minimal tiny-tool surface fits 4K with conversation headroom")
    func minimalSurfaceFitsTinyWindow() {
        let promptTokens = TokenEstimator.estimate(strippedTinyPrompt())
        let toolTokens = ToolRegistry.shared.totalEstimatedTokens(for: minimalToolSpecs())
        let total = promptTokens + toolTokens
        let window = Self.foundationWindow
        let headroom = window - total

        print(
            "[W6] MINIMAL surface @4K: prompt=\(promptTokens) + tools=\(toolTokens) "
                + "= \(total) tokens; window=\(window); conversation headroom=\(headroom) "
                + "(\(headroom * 100 / window)%)"
        )

        // A stripped 3-tool surface should leave well over half the 4K window
        // for the conversation — i.e. a tiny-tool mode is budget-FEASIBLE.
        // The go/no-go in foundation-context-probe.md therefore rests on
        // engineering cost (a parallel Foundation-only tool dialect) and the
        // 27.0 upgrade path, NOT on a hard budget block.
        #expect(
            total < window / 2,
            "Minimal tiny-tool surface is \(total) tokens — if it no longer leaves half the 4K window, the tiny-tool-mode feasibility claim in foundation-context-probe.md must be re-derived."
        )
    }

    // MARK: - Consolidated Default-agent configure surface (WS4)

    /// Live-compose the Default (configuration) agent's surface — the
    /// simplified `DefaultAgentSystemPromptBuilder` prompt plus the
    /// consolidated `osaurus_*` configure tool schemas the composer resolves
    /// for `Agent.defaultId` — and price it with the same `TokenEstimator`
    /// the budget pipeline uses. The consolidated write set is computed from
    /// the live domain registry, so the built-in domains are registered first
    /// (idempotent).
    private func measuredDefaultAgentSurfaceTokens() async -> (
        prompt: Int, tools: Int, toolCount: Int
    ) {
        await SandboxTestLock.runWithStoragePaths {
            await DynamicCatalogTestLock.shared.run {
                ConfigurationDomainBootstrap.registerBuiltIns()
                let ctx = await SystemPromptComposer.composeChatContext(
                    agentId: Agent.defaultId,
                    executionMode: .none,
                    model: "qwen3-8b"
                )
                let toolTokens = ToolRegistry.shared.totalEstimatedTokens(for: ctx.tools)
                let promptTokens = TokenEstimator.estimate(ctx.prompt)
                return (promptTokens, toolTokens, ctx.tools.count)
            }
        }
    }

    @Test("consolidated Default-agent configure surface budget (4K go/no-go + fits 8K)")
    func defaultAgentConfigureSurfaceBudget() async {
        let (promptTokens, toolTokens, toolCount) = await measuredDefaultAgentSurfaceTokens()
        let total = promptTokens + toolTokens
        let tiny = ContextSizeResolver.tinyCeiling  // 4096 (macOS 26.x)
        let small = ContextSizeResolver.smallCeiling  // 8192 (macOS 27+)
        let tinyHeadroom = tiny - total
        let smallHeadroom = small - total
        // 4096 go/no-go: does the surface leave >25% of a 4K window for the
        // user message + multi-turn growth + response reservation?
        let fitsTinyWithHeadroom = total < (tiny * 3) / 4

        print(
            "[W4] Default-agent configure surface: prompt=\(promptTokens) + tools=\(toolTokens) "
                + "(\(toolCount) tools) = \(total) tokens\n"
                + "      4K (macOS 26.x .tiny): headroom=\(tinyHeadroom) "
                + "(\(tinyHeadroom * 100 / tiny)%) → go/no-go fitsWithHeadroom=\(fitsTinyWithHeadroom)\n"
                + "      8K (macOS 27+ .small): headroom=\(smallHeadroom) "
                + "(\(smallHeadroom * 100 / small)%)"
        )

        // The consolidated surface is the carve-out target: it MUST fit the
        // 8192 window (macOS 27+, where `.small` auto-enables tools) with real
        // conversation headroom (>25% free). If this regresses, the Default
        // agent can't host its own tools even where the window allows it.
        #expect(
            total < (small * 3) / 4,
            "Consolidated Default-agent surface is \(total) tokens — it no longer leaves 25% of an 8K window for the conversation; re-derive the consolidation or the 8192 go decision."
        )

        // The .tiny (4096) tools-off policy is unchanged regardless of this
        // measurement; the number above is the documented 4096 go/no-go input,
        // not a gate that forces tools on.
        #expect(ContextSizeClass.tiny.disablesTools)
    }
}
