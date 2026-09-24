//
//  OrchestratorSchemaBudgetTests.swift
//
//  Pins the token weight of the Orchestrator's turn-1 tool schema — the
//  consolidated configure surface (`osaurus_config` / `osaurus_inspect` /
//  `osaurus_help`), the agent-loop tools, the quick-lookup web pair and
//  `spawn_agent` constrained to one configured worker — with the SAME
//  `ToolSpecTokenEstimator` heuristic the budget pipeline uses.
//
//  Why a hard bound: `ContextSizeResolver` auto-disables tools below the
//  `.tiny` ceiling (4096) and auto-enables them from `.small` (8192). The
//  Orchestrator only works when its schema + addendum leave conversation
//  room in an 8K window, so a description that grows past this bound is a
//  regression for every small local model, not a cosmetic change.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct OrchestratorSchemaBudgetTests {

    /// Upper bound for the whole turn-1 Orchestrator schema (composed
    /// tools + `spawn_agent`). Measured ≈ 1.5K after the 2026 description
    /// trims (≈1.7K with `spawn_agent`); the bound leaves slack for legitimate schema additions while
    /// still failing loudly on a runaway description.
    static let orchestratorSchemaTokenBound = 1_900

    /// Per-tool bounds for the tools the Orchestrator carries every turn. A
    /// single tool past its bound is the usual culprit when the total drifts.
    static let perToolTokenBounds: [String: Int] = [
        "osaurus_config": 260,
        "osaurus_inspect": 220,
        "osaurus_help": 160,
        "spawn_agent": 360,
        "clarify": 220,
        "complete": 160,
        "todo": 120,
        "web_search": 160,
        "search_and_extract": 380,
        "get_current_time": 80,
    ]

    private struct Measurement {
        let total: Int
        let perTool: [(name: String, tokens: Int)]
        var names: Set<String> { Set(perTool.map(\.name)) }
        var table: String { perTool.map { "  \($0.name): \($0.tokens)" }.joined(separator: "\n") }
    }

    private func tokens(_ tool: Tool) -> Int {
        ToolSpecTokenEstimator.estimate(
            name: tool.function.name,
            description: tool.function.description,
            parameters: tool.function.parameters
        )
    }

    /// The tools the composer resolves for the Default agent plus the
    /// `spawn_agent` spec constrained to one worker (UUID + display name in
    /// the enum, exactly as `resolveTools` publishes it). The worker is added
    /// explicitly because the SwiftPM harness has no runnable model, so the
    /// composer's availability filter would otherwise hide the tool.
    private func measure(model: String) async -> Measurement {
        ConfigurationDomainBootstrap.registerBuiltIns()
        return await DynamicCatalogTestLock.shared.run {
            let ctx = await SystemPromptComposer.composeChatContext(
                agentId: Agent.defaultId,
                executionMode: .none,
                model: model
            )
            var tools = ctx.tools.filter {
                $0.function.name != SubagentCapabilityRegistry.spawnAgentToolName
            }
            let workerID = UUID(uuidString: "7A7A0000-0000-4000-8000-000000000001")!
            if let base = ToolRegistry.shared.specs(
                forTools: [SubagentCapabilityRegistry.spawnAgentToolName]
            ).first {
                tools.append(
                    SpawnAgentTool.constrainedSpec(
                        base,
                        allowedAgentIDs: [workerID],
                        allowedAgentNames: ["Coder"],
                        agents: [.init(id: workerID, name: "Coder",
                            description: "Implements and reviews focused code changes in the assigned project.",
                            modelId: nil, isLocal: nil, providerName: nil)]
                    )
                )
            }
            let perTool = tools.map { (name: $0.function.name, tokens: tokens($0)) }
                .sorted { $0.tokens > $1.tokens }
            return Measurement(
                total: ToolRegistry.shared.totalEstimatedTokens(for: tools),
                perTool: perTool
            )
        }
    }

    /// Both prompt variants: the schema a ≤9B local model receives and the
    /// one a large / cloud model receives. The bound applies to both.
    @Test(
        "Orchestrator turn-1 tool schema stays under the small-model bound",
        arguments: ["qwen3-8b", "anthropic/claude-x"]
    )
    func orchestratorSchemaFitsBound(model: String) async {
        let measured = await measure(model: model)
        print(
            "[Orchestrator schema] model=\(model) total≈\(measured.total) tokens across "
                + "\(measured.perTool.count) tools\n\(measured.table)"
        )

        #expect(measured.names.contains("spawn_agent"))
        #expect(measured.names.contains("osaurus_config"))
        #expect(measured.names.contains("osaurus_inspect"))
        #expect(measured.names.contains("osaurus_help"))
        // The Orchestrator never carries the removed delegation spellings or
        // media tools — their schemas must not be paid for.
        for gone in ["spawn_model", "spawn_batch", "image", "applescript", "mac_query"] {
            #expect(!measured.names.contains(gone), "`\(gone)` is back in the Orchestrator schema")
        }
        #expect(
            measured.total <= Self.orchestratorSchemaTokenBound,
            "Orchestrator schema is \(measured.total) tokens (bound \(Self.orchestratorSchemaTokenBound)) — trim a description instead of raising the bound:\n\(measured.table)"
        )
        for (name, bound) in Self.perToolTokenBounds {
            guard let row = measured.perTool.first(where: { $0.name == name }) else { continue }
            #expect(
                row.tokens <= bound,
                "`\(name)` schema is \(row.tokens) tokens (bound \(bound))"
            )
        }
    }

    /// The `spawn_agent` enum grows with the pool. Ten workers (a large but
    /// realistic pool) must still keep the tool under a few hundred tokens —
    /// the names, not the UUIDs, are what a small model reads.
    @Test("spawn_agent schema stays bounded with a ten-agent pool")
    func spawnAgentSchemaBoundedWithLargePool() {
        guard
            let base = ToolRegistry.shared.specs(
                forTools: [SubagentCapabilityRegistry.spawnAgentToolName]
            ).first
        else {
            Issue.record("spawn_agent is not registered")
            return
        }
        let ids = (1...10).map { _ in UUID() }
        let names = (1...10).map { "Worker \($0)" }
        let spec = SpawnAgentTool.constrainedSpec(base, allowedAgentIDs: ids, allowedAgentNames: names)
        let cost = tokens(spec)
        print("[Orchestrator schema] spawn_agent with 10 workers ≈ \(cost) tokens")
        #expect(cost <= 600, "spawn_agent with ten workers costs \(cost) tokens")
    }
}
