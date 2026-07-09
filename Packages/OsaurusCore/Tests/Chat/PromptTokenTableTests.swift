//
//  PromptTokenTableTests.swift
//
//  Phase-0 measurement baseline for the system-prompt efficiency work: a
//  per-section token table (full vs compact variant) over every template
//  the composer can render, plus a live compose that prints the real
//  `PromptManifest` breakdown and always-loaded tool-schema cost.
//
//  The printed tables are the deliverable — they anchor before/after
//  comparisons for prompt trims. The assertions are deliberately loose
//  (compact never exceeds full; totals are non-zero) so the suite
//  documents cost without pinning every number twice (the hard ceilings
//  live in TotalPromptBudgetTests / SandboxSectionTokenAuditTests).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct PromptTokenTableTests {

    /// One row of the audit table: a section label plus its full and
    /// compact renderings (compact == full when no variant exists).
    private struct Row {
        let label: String
        let full: String
        let compact: String

        init(_ label: String, full: String, compact: String? = nil) {
            self.label = label
            self.full = full
            self.compact = compact ?? full
        }

        var fullTokens: Int { TokenEstimator.estimate(full) }
        var compactTokens: Int { TokenEstimator.estimate(compact) }
    }

    private func sectionRows() -> [Row] {
        [
            Row("platformIdentity", full: SystemPromptTemplates.platformIdentity),
            Row("defaultPersona", full: SystemPromptTemplates.defaultPersona),
            Row(
                "agentLoopGuidance",
                full: SystemPromptTemplates.agentLoopGuidance,
                compact: SystemPromptTemplates.agentLoopGuidanceCompact
            ),
            Row(
                "grounding(discovery)",
                full: SystemPromptTemplates.groundingDirectiveFull,
                compact: SystemPromptTemplates.groundingDirectiveFullCompact
            ),
            Row("grounding(base)", full: SystemPromptTemplates.groundingDirectiveBase),
            Row(
                "discoveryNudge(sandbox,+plugins)",
                full: SystemPromptTemplates.capabilityDiscoveryNudgeSandbox(canCreatePlugins: true),
                compact: SystemPromptTemplates.capabilityDiscoveryNudgeSandbox(
                    canCreatePlugins: true,
                    compact: true
                )
            ),
            Row(
                "discoveryNudge(sandbox,-plugins)",
                full: SystemPromptTemplates.capabilityDiscoveryNudgeSandbox(canCreatePlugins: false),
                compact: SystemPromptTemplates.capabilityDiscoveryNudgeSandbox(
                    canCreatePlugins: false,
                    compact: true
                )
            ),
            Row("discoveryNudge(non-sandbox)", full: SystemPromptTemplates.capabilityDiscoveryNudge),
            Row(
                "secretHandling",
                full: SystemPromptTemplates.secretHandlingGuidance,
                compact: SystemPromptTemplates.secretHandlingGuidanceCompact
            ),
            Row(
                "selfImprovement(+plugins)",
                full: SystemPromptTemplates.selfImprovementGuidance(canCreatePlugins: true),
                compact: SystemPromptTemplates.selfImprovementGuidance(
                    canCreatePlugins: true,
                    compact: true
                )
            ),
            Row(
                "codeStyle",
                full: SystemPromptTemplates.codeStyleGuidance,
                compact: SystemPromptTemplates.codeStyleGuidanceCompact
            ),
            Row(
                "riskAware",
                full: SystemPromptTemplates.riskAwareGuidance,
                compact: SystemPromptTemplates.riskAwareGuidanceCompact
            ),
            Row("computerUse", full: SystemPromptTemplates.computerUseGuidance),
            Row(
                "imageGeneration",
                full: SystemPromptTemplates.imageGenerationGuidance,
                compact: SystemPromptTemplates.imageGenerationGuidanceCompact
            ),
            Row(
                "appleScript",
                full: SystemPromptTemplates.appleScriptGuidance,
                compact: SystemPromptTemplates.appleScriptGuidanceCompact
            ),
            Row(
                "sandbox(section)",
                full: SystemPromptTemplates.sandbox(
                    home: "/home/agent-abcdef123456",
                    hostReadCombined: false,
                    backgroundEnabled: true
                ),
                compact: SystemPromptTemplates.sandbox(
                    home: "/home/agent-abcdef123456",
                    hostReadCombined: false,
                    backgroundEnabled: true,
                    compact: true
                )
            ),
            Row("skillsGovernToolGroups", full: SystemPromptTemplates.skillsGovernToolGroups),
            Row(
                "pluginCreator",
                full: PluginCreatorGate.section(
                    instructions: SystemPromptTemplates.pluginCreatorInstructions
                )
            ),
            Row(
                "family(gptCodex)",
                full: ModelFamilyGuidance.gptCodexGuidance,
                compact: ModelFamilyGuidance.gptCodexGuidanceCompact
            ),
            Row(
                "family(gemma)",
                full: ModelFamilyGuidance.googleGemmaGuidance,
                compact: ModelFamilyGuidance.googleGemmaGuidanceCompact
            ),
            Row("family(gemini)", full: ModelFamilyGuidance.googleGeminiGuidance),
            Row("family(glm/qwen)", full: ModelFamilyGuidance.glmQwenGuidance),
            Row("family(deepseek)", full: ModelFamilyGuidance.deepSeekGuidance),
            Row("family(lfm2)", full: ModelFamilyGuidance.lfm2Guidance),
            Row("family(default)", full: ModelFamilyGuidance.defaultGuidance),
        ]
    }

    private func tableLine(_ label: String, _ full: Int, _ compact: Int) -> String {
        let name = label.padding(toLength: 34, withPad: " ", startingAt: 0)
        let f = String(format: "%8d", full)
        let c = String(format: "%8d", compact)
        let saved = String(format: "%8d", full - compact)
        return "  \(name)\(f)\(c)\(saved)"
    }

    @Test("per-section token table (full vs compact)")
    func printSectionTokenTable() {
        let rows = sectionRows()
        var lines: [String] = []
        lines.append("[PromptTokenTable] per-section tokens (TokenEstimator)")
        lines.append(
            "  " + "section".padding(toLength: 34, withPad: " ", startingAt: 0)
                + "    full compact   saved"
        )
        var fullTotal = 0
        var compactTotal = 0
        for row in rows {
            fullTotal += row.fullTokens
            compactTotal += row.compactTokens
            lines.append(tableLine(row.label, row.fullTokens, row.compactTokens))
        }
        lines.append(tableLine("TOTAL (all rows)", fullTotal, compactTotal))
        print(lines.joined(separator: "\n"))

        for row in rows {
            #expect(row.fullTokens > 0, "\(row.label) rendered empty")
            #expect(
                row.compactTokens <= row.fullTokens,
                "\(row.label): compact (\(row.compactTokens)) exceeds full (\(row.fullTokens))"
            )
        }
    }

    /// Live sandbox compose: print the real `PromptManifest` section table
    /// and the always-loaded tool-schema cost. Mirrors the harness in
    /// `TotalPromptBudgetTests` (Storage → Sandbox → catalog lock order,
    /// baseline-filtered schema) so the numbers are deterministic.
    @Test("live sandbox compose manifest + tool schema table")
    func printLiveComposeTable() async {
        await SandboxTestLock.runWithStoragePaths {
            await DynamicCatalogTestLock.shared.run {
                let config = AutonomousExecConfig(enabled: true, pluginCreate: true)
                let agent = Agent(
                    name: "TokenTableAgent",
                    systemPrompt: "Test identity",
                    agentAddress: "test-token-table-\(UUID().uuidString)",
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
                let toolTokens = ToolRegistry.shared.totalEstimatedTokens(for: baseline)

                print("[PromptTokenTable] live sandbox compose (model: qwen3-8b)")
                print(ctx.manifest.debugDescription)
                print(
                    "  Tool schema:         \(String(format: "%5d", toolTokens)) "
                        + "(\(baseline.count) baseline tools of \(ctx.tools.count) resolved)"
                )
                print(
                    "  Prompt + tools:      \(String(format: "%5d", ctx.manifest.totalEstimatedTokens + toolTokens))"
                )

                ToolRegistry.shared.unregisterAllSandboxTools()
                _ = await AgentManager.shared.delete(id: agent.id)

                #expect(ctx.manifest.totalEstimatedTokens > 0)
                #expect(toolTokens > 0)
            }
        }
    }
}
