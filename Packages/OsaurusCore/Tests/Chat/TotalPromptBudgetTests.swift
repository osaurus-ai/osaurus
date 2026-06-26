//
//  TotalPromptBudgetTests.swift
//
//  Whole-prompt budget guardrail for small-context (~8K window) models.
//  The per-section ceilings (SandboxSectionTokenAuditTests) catch local
//  bloat, but nothing previously asserted that the SUM of every section a
//  `.small` sandbox session can fire still leaves room for conversation.
//  These tests stack the static surface for an 8K window — worst case
//  (every gated section on, SOUL at its `.small` cap, the enabled-
//  capabilities manifest at its 70-tool cap, plugin creation enabled) and
//  the typical everyday configuration — plus the real always-loaded
//  tool-schema cost from a live compose, and pin the totals against the
//  window.
//
//  All numbers use `TokenEstimator` (the same heuristic the budget
//  pipeline uses), so the assertions track what the runtime believes,
//  not a model-specific tokenizer.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct TotalPromptBudgetTests {

    // MARK: - Tool-schema harness

    /// Spin up a sandbox-enabled agent, compose a live context, and return
    /// the always-loaded tool-schema cost — then tear everything down.
    ///
    /// Lock order: Storage → Sandbox (via `runWithStoragePaths`) with the
    /// catalog lock INNERMOST — the canonical nesting (see
    /// `CapabilityToolsTests`). The catalog lock matters because the
    /// measurement prices the live schema, so a concurrent suite
    /// registering dynamic/MCP tools mid-measure would inflate the number
    /// and flake the ceiling.
    ///
    /// The cost is also filtered to the canonical baseline (sandbox
    /// built-ins + agent-loop + capability discovery): other suites can
    /// leak registered tools into the shared `ToolRegistry` mid-run, and
    /// filtering keeps the measurement deterministic regardless of suite
    /// ordering. The schema is size-class-independent (compact bootstrap
    /// specs apply everywhere), so a normal-class compose prices the same
    /// schema a `.small` session ships.
    private func measuredBaselineToolTokens(pluginCreate: Bool) async -> Int {
        await SandboxTestLock.runWithStoragePaths {
            await DynamicCatalogTestLock.shared.run {
                let config = AutonomousExecConfig(enabled: true, pluginCreate: pluginCreate)
                let agent = Agent(
                    name: "TotalBudgetAgent",
                    systemPrompt: "Test identity",
                    agentAddress: "test-total-budget-\(UUID().uuidString)",
                    autonomousExec: config
                )
                AgentManager.shared.add(agent)
                BuiltinSandboxTools.register(
                    agentId: agent.id.uuidString,
                    agentName: agent.name,
                    config: config
                )

                let ctx = await SystemPromptComposer.composeChatContext(
                    agentId: agent.id,
                    executionMode: .sandbox(hostRead: nil),
                    model: "qwen3-8b"
                )

                let expectedNames = ToolRegistry.shared.builtInSandboxToolNamesSnapshot
                    .union(SystemPromptComposer.agentLoopToolNames)
                    .union(["capabilities_discover", "capabilities_load"])
                let baseline = ctx.tools.filter { expectedNames.contains($0.function.name) }
                let tokens = ToolRegistry.shared.totalEstimatedTokens(for: baseline)

                ToolRegistry.shared.unregisterAllSandboxTools()
                _ = await AgentManager.shared.delete(id: agent.id)
                return tokens
            }
        }
    }

    // MARK: - Prompt stacks

    /// Build the worst-case `.small` static prompt stack from the same
    /// templates the composer renders, in composer order. Mirrors
    /// `appendGatedSections` for a sandbox session with plugin creation
    /// enabled — the heaviest configuration a `.small` model can hit.
    private func worstCaseSmallPrompt() -> String {
        // SOUL at the `.small` byte cap (2 KB), as `soulCap(forModel:)`
        // would deliver it.
        let soulBody = String(
            repeating: "- prefers concise answers and tabular summaries\n",
            count: 200
        )
        let cappedSoul = SystemPromptComposer.capSoulContent(
            soulBody,
            maxBytes: SystemPromptComposer.soulSmallMaxBytes
        )

        // Voluminous install, compact (`.small`) form. Under tiering each
        // plugin costs ONE manifest line regardless of its tool count, so the
        // compact manifest now scales with plugin COUNT, not tool count —
        // model a heavy install (25 plugins, some skill-governed) to bound
        // that growth.
        let manyPlugins = (0 ..< 25).map { i in
            SystemPromptTemplates.ManifestPluginGroup(
                groupId: "service.plugin_\(i)",
                pluginDisplay: "Service Plugin \(i)",
                skills: i % 4 == 0
                    ? [
                        SystemPromptTemplates.ManifestCapability(
                            name: "Guide \(i)",
                            description: "How to drive the plugin tools"
                        )
                    ]
                    : [],
                tools: (0 ..< 6).map {
                    SystemPromptTemplates.ManifestCapability(
                        name: "tool_\(i)_\($0)",
                        description: "Does a focused thing with the service"
                    )
                }
            )
        }
        let manifest =
            SystemPromptTemplates.enabledCapabilitiesManifest(
                groups: manyPlugins,
                compact: true
            ) ?? ""

        let sections: [String] = [
            SystemPromptTemplates.platformIdentity,
            SystemPromptTemplates.defaultPersona,
            SystemPromptTemplates.soulSection(cappedSoul),
            SystemPromptTemplates.selfImprovementGuidance(canCreatePlugins: true),
            // Heaviest compact family block (`.small` gets compact variants).
            ModelFamilyGuidance.compactGuidance(for: .gptCodex),
            SystemPromptTemplates.groundingDirective(discoveryAvailable: true),
            SystemPromptTemplates.codeStyleGuidance,
            SystemPromptTemplates.riskAwareGuidance,
            SystemPromptTemplates.secretHandlingGuidance,
            // `.small` gets the agent-loop cheat sheet from turn 1.
            SystemPromptTemplates.agentLoopGuidance,
            SystemPromptTemplates.sandbox(
                home: "/home/agent-abcdef123456",
                hostReadCombined: false,
                backgroundEnabled: true
            ),
            SystemPromptTemplates.sandboxState(
                secretNames: ["SERVICE_API_KEY", "DB_CONNECTION_STRING"],
                installedPackages: .init(pip: ["requests", "flask"], npm: ["axios"])
            ),
            SystemPromptTemplates.capabilityDiscoveryNudgeSandbox(canCreatePlugins: true),
            manifest,
            SystemPromptTemplates.skillsGovernToolGroups,
            PluginCreatorGate.section(
                instructions: SystemPromptTemplates.pluginCreatorInstructions
            ),
        ]
        return sections.joined(separator: "\n\n")
    }

    /// The everyday `.small` configuration: modest manifest, no plugin
    /// creation, no SOUL yet, no secrets/packages.
    private func typicalSmallPrompt() -> String {
        // A real plugin tiers to ONE line under the compact manifest
        // regardless of its tool count — so 10 tools cost one line, not ten.
        let manifest = makeManifest(
            groupId: "osaurus.mail",
            pluginDisplay: "Mail",
            skills: [],
            tools: (0 ..< 10).map {
                SystemPromptTemplates.ManifestCapability(
                    name: "mail_tool_\($0)",
                    description: "d"
                )
            }
        )

        let sections: [String] = [
            SystemPromptTemplates.platformIdentity,
            SystemPromptTemplates.defaultPersona,
            SystemPromptTemplates.selfImprovementGuidance(canCreatePlugins: false),
            ModelFamilyGuidance.compactGuidance(for: .glmQwen),
            SystemPromptTemplates.groundingDirective(discoveryAvailable: true),
            SystemPromptTemplates.codeStyleGuidance,
            SystemPromptTemplates.riskAwareGuidance,
            SystemPromptTemplates.secretHandlingGuidance,
            SystemPromptTemplates.agentLoopGuidance,
            SystemPromptTemplates.sandbox(
                home: "/home/agent-abcdef123456",
                hostReadCombined: false,
                backgroundEnabled: false
            ),
            SystemPromptTemplates.capabilityDiscoveryNudgeSandbox(canCreatePlugins: false),
            manifest,
            SystemPromptTemplates.skillsGovernToolGroups,
        ]
        return sections.joined(separator: "\n\n")
    }

    private func makeManifest(
        groupId: String,
        pluginDisplay: String,
        skills: [SystemPromptTemplates.ManifestCapability],
        tools: [SystemPromptTemplates.ManifestCapability]
    ) -> String {
        SystemPromptTemplates.enabledCapabilitiesManifest(
            groups: [
                SystemPromptTemplates.ManifestPluginGroup(
                    groupId: groupId,
                    pluginDisplay: pluginDisplay,
                    skills: skills,
                    tools: tools
                )
            ],
            compact: true
        ) ?? ""
    }

    // MARK: - Budget assertions

    @Test("worst-case .small sandbox prompt + tool schema fits the 8K window")
    func smallWindowWorstCaseFitsBudget() async {
        let toolTokens = await measuredBaselineToolTokens(pluginCreate: true)
        let promptTokens = TokenEstimator.estimate(worstCaseSmallPrompt())
        let total = promptTokens + toolTokens
        let window = ContextSizeResolver.smallCeiling  // 8192

        // The full worst case (many-plugin manifest + plugin creator + SOUL
        // at cap) must at minimum fit the window with room for one real
        // exchange. The live number is printed in the failure message so
        // reviewers re-anchor deliberately, not silently.
        #expect(
            total <= (window * 3) / 4,
            "Worst-case .small static surface is \(total) tokens (prompt \(promptTokens) + tools \(toolTokens)) — more than 75% of the \(window) window. A new or grown section is crowding out the conversation; trim it or gate it off for `.small`."
        )
    }

    /// The everyday (non-worst-case) `.small` configuration must leave at
    /// least half the window for conversation. This is the budget most
    /// `.small` users actually live under.
    @Test("typical .small sandbox prompt + tool schema leaves half the window")
    func smallWindowTypicalLeavesHalfTheWindow() async {
        let toolTokens = await measuredBaselineToolTokens(pluginCreate: false)
        let promptTokens = TokenEstimator.estimate(typicalSmallPrompt())
        let total = promptTokens + toolTokens
        let window = ContextSizeResolver.smallCeiling

        #expect(
            total <= window / 2,
            "Typical .small static surface is \(total) tokens (prompt \(promptTokens) + tools \(toolTokens)) — more than half the \(window) window. Section or schema creep is eating the conversation budget."
        )
    }
}
