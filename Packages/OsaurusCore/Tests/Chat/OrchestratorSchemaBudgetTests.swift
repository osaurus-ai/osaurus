//
//  OrchestratorSchemaBudgetTests.swift
//
//  Pins the token weight of the Orchestrator's turn-1 tool schema — the
//  routing surface (`status`, `state`, the Configurator and Architect
//  handoffs, `run_workflow`, `clarify`) — with the SAME
//  `ToolSpecTokenEstimator` heuristic the budget pipeline uses, and the
//  `spawn_agent` spec custom agents receive.
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

    /// Upper bound for the whole turn-1 Orchestrator schema. Measured ≈ 670
    /// with `run_workflow` (a runnable workflow); the bound leaves slack for
    /// legitimate schema additions while still failing loudly on a runaway
    /// description.
    static let orchestratorSchemaTokenBound = 800

    /// Per-tool bounds for the tools the Orchestrator carries every turn. A
    /// single tool past its bound is the usual culprit when the total drifts.
    static let perToolTokenBounds: [String: Int] = [
        "status": 80,
        "state": 220,
        "configurator_handoff": 120,
        "clarify": 220,
        "architect_handoff": 110,
        "run_workflow": 90,
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

    /// The tools the composer resolves for the Default agent. `run_workflow`
    /// is counted in its compact baseline shape whether or not
    /// a runnable workflow happens to be installed: anyone with one pays it.
    private func measure(model: String) async -> Measurement {
        ConfigurationDomainBootstrap.registerBuiltIns()
        return await DynamicCatalogTestLock.shared.run {
            let ctx = await SystemPromptComposer.composeChatContext(
                agentId: Agent.defaultId,
                executionMode: .none,
                model: model
            )
            var tools = ctx.tools.filter { $0.function.name != RunWorkflowTool.toolName }
            tools += ToolRegistry.shared.specs(forTools: [RunWorkflowTool.toolName])
                .map(SystemPromptComposer.compactBootstrapSpec)
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

        #expect(!measured.names.contains("spawn_agent"))
        for name in DefaultAgentSystemPromptBuilder.orchestratorRequiredToolNames {
            #expect(measured.names.contains(name), "`\(name)` missing from the Orchestrator schema")
        }
        for name in ["osaurus_config", "osaurus_inspect", "osaurus_help"] {
            #expect(!measured.names.contains(name), "`\(name)` belongs to the Configurator")
        }
        #expect(measured.names.contains(RunWorkflowTool.toolName))
        #expect(measured.names.contains(ArchitectHandoffTool.toolName))
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

    /// `architect_handoff` carries the verbatim message and `keep_draft`;
    /// the routing surface still fits the bound.
    @Test("The inline architect_handoff schema stays bounded")
    func inlineArchitectHandoffSchemaBounded() async {
        guard let inline = ToolRegistry.shared.specs(forTools: [ArchitectHandoffTool.toolName]).first else {
            Issue.record("architect_handoff is not registered")
            return
        }
        let properties = inline.function.parameters?.objectValue?["properties"]?.objectValue
        #expect(properties?["keep_draft"] != nil)
        #expect(tokens(inline) <= 150, "inline `architect_handoff` schema is \(tokens(inline)) tokens (bound 150)")
    }

    /// Keep the historical identity-only bound; routing descriptions have
    /// their own measured payload below and must never disappear to fit it.
    @Test("spawn_agent identity schema stays bounded with a ten-agent pool")
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

    @Test("ten-agent routing metadata survives repeated composition without duplication")
    func largePoolRetainsEveryDescription() throws {
        let agents = (1...10).map { index in
            SpawnAgentDescriptor(
                id: UUID(), name: "Worker \(index)",
                description: "Reviews task \(index): " + String(repeating: "x", count: 143),
                modelId: nil, isLocal: nil, providerName: nil
            )
        }
        let base = SpawnAgentTool().asOpenAITool()
        let first = SpawnAgentTool.constrainedSpec(
            base, allowedAgentIDs: agents.map(\.id), allowedAgentNames: agents.map(\.name), agents: agents
        )
        let repeated = SpawnAgentTool.constrainedSpec(
            first, allowedAgentIDs: agents.map(\.id), allowedAgentNames: agents.map(\.name), agents: agents
        )
        #expect(tokens(first) == tokens(repeated))
        let text = try #require(repeated.function.description)
        let sections = text.components(separatedBy: SpawnAgentTool.routingMetadataMarker)
        #expect(sections.count == 2)
        let payload = try #require(sections.last)
        let rows = try payload.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String])
        }
        #expect(rows.count == agents.count)
        for agent in agents {
            #expect(!(try #require(agent.description)).isEmpty)
            #expect(rows.contains { $0["id"] == agent.id.uuidString && $0["description"] == agent.description })
        }
        print("[Orchestrator schema] ten described workers ≈ \(tokens(first)) tokens; routing payload \(payload.utf8.count) bytes")
    }
}
