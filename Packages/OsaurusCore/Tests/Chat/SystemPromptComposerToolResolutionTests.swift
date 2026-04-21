//
//  SystemPromptComposerToolResolutionTests.swift
//  osaurusTests
//
//  Verifies the contract of `SystemPromptComposer.resolveTools` across the
//  matrix of (toolMode: auto|manual) x (executionMode: none|sandbox) x
//  (manualNames empty|set). These tests pin down the user-facing spec:
//   - Auto mode = always-loaded built-ins + preflight additions.
//   - Manual mode (pragmatic) = always-loaded built-ins + sandbox/folder
//     runtime when active + user-picked names. Same shape as auto, minus
//     the LLM-driven preflight specs (manual mode is opt-in).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SystemPromptComposerToolResolutionTests {

    // MARK: - Helpers

    private func withSandboxAgent(
        autonomous: Bool,
        manualToolNames: [String]? = nil,
        body: (UUID) async -> Void
    ) async {
        let manager = AgentManager.shared
        let agent: Agent
        if let names = manualToolNames {
            agent = Agent(
                name: "ToolResolutionTestAgent-\(UUID().uuidString.prefix(6))",
                autonomousExec: autonomous ? AutonomousExecConfig(enabled: true) : nil,
                toolSelectionMode: .manual,
                manualToolNames: names
            )
        } else {
            agent = Agent(
                name: "ToolResolutionTestAgent-\(UUID().uuidString.prefix(6))",
                autonomousExec: autonomous ? AutonomousExecConfig(enabled: true) : nil
            )
        }
        manager.add(agent)
        defer { Task { _ = await manager.delete(id: agent.id) } }
        await body(agent.id)
    }

    private func registerSandboxBuiltins(_ body: () -> Void) {
        BuiltinSandboxTools.register(
            agentId: "tool-resolution-test",
            agentName: "tool-resolution-test",
            config: AutonomousExecConfig(enabled: true)
        )
        defer { ToolRegistry.shared.unregisterAllSandboxTools() }
        body()
    }

    // MARK: - Auto mode

    @Test
    func autoMode_includesAlwaysLoadedAndPreflightAdditions() async {
        await withSandboxAgent(autonomous: false) { agentId in
            let preflight = PreflightResult(toolSpecs: [], items: [])
            let tools = SystemPromptComposer.resolveTools(
                agentId: agentId,
                executionMode: .none,
                preflight: preflight
            )
            // Built-ins like capabilities_search must be present in auto mode.
            #expect(tools.contains { $0.function.name == "capabilities_search" })
        }
    }

    // MARK: - Manual mode (pragmatic)

    @Test
    func manualMode_includesAlwaysLoadedBuiltinsAndUserPicks() async {
        await withSandboxAgent(autonomous: false, manualToolNames: ["render_chart"]) { agentId in
            let tools = SystemPromptComposer.resolveTools(
                agentId: agentId,
                executionMode: .none
            )
            let names = Set(tools.map { $0.function.name })
            // User pick is present.
            #expect(names.contains("render_chart"))
            // Pragmatic manual mode keeps the always-loaded built-ins so
            // the agent loop, share_artifact, and capability discovery
            // remain usable without the user having to re-pick them.
            #expect(names.contains("todo"))
            #expect(names.contains("complete"))
            #expect(names.contains("clarify"))
            #expect(names.contains("share_artifact"))
            #expect(names.contains("capabilities_search"))
            #expect(names.contains("capabilities_load"))
            #expect(names.contains("search_memory"))
        }
    }

    @Test
    func manualMode_includesSandboxBuiltinsWhenSandboxActive() async {
        await withSandboxAgent(autonomous: true, manualToolNames: ["render_chart"]) { agentId in
            registerSandboxBuiltins {
                let tools = SystemPromptComposer.resolveTools(
                    agentId: agentId,
                    executionMode: .sandbox
                )
                let names = Set(tools.map { $0.function.name })
                #expect(names.contains("render_chart"))
                // Sandbox built-ins are additive when sandbox is active.
                #expect(names.contains("sandbox_exec"))
                // Always-loaded built-ins remain present too.
                #expect(names.contains("todo"))
                #expect(names.contains("share_artifact"))
            }
        }
    }

    @Test
    func manualMode_emptyManualNames_stillIncludesAlwaysLoaded() async {
        await withSandboxAgent(autonomous: true, manualToolNames: []) { agentId in
            registerSandboxBuiltins {
                let tools = SystemPromptComposer.resolveTools(
                    agentId: agentId,
                    executionMode: .sandbox
                )
                let names = Set(tools.map { $0.function.name })
                // No manual selection — but always-loaded built-ins and
                // sandbox runtime tools are still present (pragmatic mode).
                #expect(names.contains("todo"))
                #expect(names.contains("share_artifact"))
                #expect(names.contains("sandbox_exec"))
                #expect(names.contains("capabilities_search"))
            }
        }
    }

    // MARK: - Loop tools + share_artifact visibility

    @Test
    func loopToolsAreVisibleAcrossEveryMode() async {
        let modes: [ExecutionMode] = [.none]
        for mode in modes {
            await withSandboxAgent(autonomous: false) { agentId in
                let names = Set(
                    SystemPromptComposer.resolveTools(agentId: agentId, executionMode: mode)
                        .map { $0.function.name }
                )
                #expect(names.contains("todo"))
                #expect(names.contains("complete"))
                #expect(names.contains("clarify"))
                #expect(names.contains("share_artifact"))
            }
        }

        await withSandboxAgent(autonomous: true) { agentId in
            registerSandboxBuiltins {
                let names = Set(
                    SystemPromptComposer.resolveTools(agentId: agentId, executionMode: .sandbox)
                        .map { $0.function.name }
                )
                #expect(names.contains("todo"))
                #expect(names.contains("complete"))
                #expect(names.contains("clarify"))
                #expect(names.contains("share_artifact"))
            }
        }
    }

    @Test
    func canonicalToolOrder_pinsLoopToolsToTheTop() async {
        await withSandboxAgent(autonomous: true) { agentId in
            registerSandboxBuiltins {
                let names = SystemPromptComposer.resolveTools(
                    agentId: agentId,
                    executionMode: .sandbox
                ).map { $0.function.name }
                // The first four entries must be the loop tools in fixed
                // order. This is what makes the rendered <tools> prefix
                // stable across sends regardless of what late-arriving
                // plugins or MCP providers register.
                #expect(names.prefix(4) == ["todo", "complete", "clarify", "share_artifact"])
            }
        }
    }

    // MARK: - Tools disabled

    @Test
    func toolsDisabled_returnsEmpty() async {
        await withSandboxAgent(autonomous: true) { agentId in
            registerSandboxBuiltins {
                let tools = SystemPromptComposer.resolveTools(
                    agentId: agentId,
                    executionMode: .sandbox,
                    toolsDisabled: true
                )
                #expect(tools.isEmpty)
            }
        }
    }

    // MARK: - Auto-mode preflight query fallback

    @Test
    func resolvePreflightQuery_prefersExplicitQuery() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "old question")
        ]
        let resolved = SystemPromptComposer.resolvePreflightQuery(
            query: "fresh question",
            messages: messages
        )
        #expect(resolved == "fresh question")
    }

    @Test
    func resolvePreflightQuery_fallsBackToLastUserMessageWhenQueryEmpty() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "first"),
            ChatMessage(role: "assistant", content: "ok"),
            ChatMessage(role: "user", content: "second"),
        ]
        let resolved = SystemPromptComposer.resolvePreflightQuery(
            query: "",
            messages: messages
        )
        #expect(resolved == "second")
    }

    @Test
    func resolvePreflightQuery_returnsEmptyWhenNothingAvailable() {
        let resolved = SystemPromptComposer.resolvePreflightQuery(
            query: "",
            messages: []
        )
        #expect(resolved.isEmpty)
    }

    // MARK: - additionalToolNames

    @Test
    func resolveTools_autoMode_mergesAdditionalToolNames() async {
        await withSandboxAgent(autonomous: false) { agentId in
            // share_artifact is a built-in always-loaded tool; ask the
            // resolver to also include `search_memory` via additionalToolNames
            // and verify the union has no duplicates (search_memory is already
            // a built-in but additional should still be a no-op merge).
            let tools = SystemPromptComposer.resolveTools(
                agentId: agentId,
                executionMode: .none,
                additionalToolNames: ["search_memory"]
            )
            let names = tools.map { $0.function.name }
            #expect(names.contains("search_memory"))
            #expect(Set(names).count == names.count)
        }
    }

    // MARK: - canonicalToolOrder

    @Test
    func canonicalToolOrder_isStableAcrossInvocations() async {
        await withSandboxAgent(autonomous: true) { agentId in
            registerSandboxBuiltins {
                // Two compositions with identical inputs must return the
                // exact same tool ordering — that's what makes the rendered
                // <tools> block byte-stable across sends.
                let a = SystemPromptComposer.resolveTools(agentId: agentId, executionMode: .sandbox)
                let b = SystemPromptComposer.resolveTools(agentId: agentId, executionMode: .sandbox)
                let aNames = a.map { $0.function.name }
                let bNames = b.map { $0.function.name }
                #expect(aNames == bNames)

                // Sandbox built-ins must come first, capability tools next.
                if let firstSandbox = aNames.firstIndex(where: { $0.hasPrefix("sandbox_") }),
                    let firstCapability = aNames.firstIndex(of: "capabilities_search")
                {
                    #expect(firstSandbox < firstCapability)
                }
            }
        }
    }
}
