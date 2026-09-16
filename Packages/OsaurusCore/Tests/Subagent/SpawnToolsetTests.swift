//
//  SpawnToolsetTests.swift
//  OsaurusCoreTests
//
//  Unit coverage for the spawn child toolset: the allowlist refusal, the
//  child exclusions, and the child scope/identity seams — using the
//  injection seams so no live ToolRegistry or model is needed.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SpawnToolsetTests {
    private func spec(_ name: String) -> Tool {
        Tool(
            type: "function",
            function: ToolFunction(name: name, description: nil, parameters: nil)
        )
    }

    private func invocation(_ name: String) -> ServiceToolInvocation {
        ServiceToolInvocation(toolName: name, jsonArguments: "{}")
    }

    @Test("no specs yields no toolset (text-only run)")
    func emptySpecsYieldNil() async {
        let toolset = await TextSubagentKind.makeToolset(
            feed: nil,
            specs: [],
            dispatch: { _ in "unreachable" }
        )
        #expect(toolset == nil)
    }

    @Test("allowed tool dispatches; non-allowlisted tool is refused")
    func allowlistEnforced() async throws {
        let toolset = await TextSubagentKind.makeToolset(
            feed: nil,
            specs: [spec("file_read"), spec("file_search")],
            dispatch: { inv in "ran:\(inv.toolName)" }
        )
        let set = try #require(toolset)
        #expect(set.specs.count == 2)

        let ok = await set.execute(invocation("file_read"))
        #expect(ok == "ran:file_read")

        let refused = await set.execute(invocation("delete_everything"))
        #expect(ToolEnvelope.isError(refused))
        #expect(ToolEnvelope.failureMessage(refused).contains("not available inside this subagent"))
    }

    @Test("there is no per-run tool-call cap: repeated calls keep dispatching")
    func noToolCallCap() async throws {
        let toolset = await TextSubagentKind.makeToolset(
            feed: nil,
            specs: [spec("file_read")],
            dispatch: { _ in "ok" }
        )
        let set = try #require(toolset)
        var successes = 0
        for _ in 0 ..< 40 {
            if await set.execute(invocation("file_read")) == "ok" { successes += 1 }
        }
        #expect(successes == 40)
    }

    @Test("tool-carrying children get at least 2 turns; text-only budgets stay untouched")
    func effectiveMaxTurnsFloorsToolCarryingChildren() {
        // One tool call consumes a turn, so a tool-carrying child with a
        // 1-turn budget always dies at the iteration cap without a digest —
        // the floor keeps a granted toolset from being a guaranteed wasted
        // run, while text-only spawns honor the configured budget exactly.
        #expect(TextSubagentKind.effectiveMaxTurns(configured: 1, hasToolset: true) == 2)
        #expect(TextSubagentKind.effectiveMaxTurns(configured: 2, hasToolset: true) == 2)
        #expect(TextSubagentKind.effectiveMaxTurns(configured: 6, hasToolset: true) == 6)
        #expect(TextSubagentKind.effectiveMaxTurns(configured: 1, hasToolset: false) == 1)
        #expect(TextSubagentKind.effectiveMaxTurns(configured: 6, hasToolset: false) == 6)
    }

    // MARK: - Agent-mode child tools (spawn_agent carries the persona's tool policy)

    @Test("agent specs alone yield a toolset")
    func agentSpecsAlone() async throws {
        let toolset = await TextSubagentKind.makeToolset(
            feed: nil,
            agentSpecs: [spec("create_event"), spec("search_events")],
            dispatch: { inv in "ran:\(inv.toolName)" }
        )
        let set = try #require(toolset)
        #expect(set.specs.map(\.function.name).sorted() == ["create_event", "search_events"])

        let ok = await set.execute(invocation("create_event"))
        #expect(ok == "ran:create_event")
        let refused = await set.execute(invocation("file_read"))
        #expect(ToolEnvelope.isError(refused))
    }

    @Test("agent specs union with extra specs; agent spec wins a name collision")
    func agentSpecsUnionExtras() async throws {
        let toolset = await TextSubagentKind.makeToolset(
            feed: nil,
            agentSpecs: [spec("create_event"), spec("file_read")],
            specs: [spec("file_read"), spec("file_search")],
            dispatch: { inv in "ran:\(inv.toolName)" }
        )
        let set = try #require(toolset)
        #expect(
            set.specs.map(\.function.name).sorted() == ["create_event", "file_read", "file_search"])
        let ok = await set.execute(invocation("create_event"))
        #expect(ok == "ran:create_event")
    }

    @Test("agent tool dispatch publishes the child scope instead of inheriting the parent scope")
    func agentToolDispatchUsesChildExecutionScope() async throws {
        let parentScope = ToolExecutionScope(exposed: [spec("spawn_agent")])
        let toolset = await TextSubagentKind.makeToolset(
            feed: nil,
            agentSpecs: [spec("get_events")],
            dispatch: { invocation in
                ChatExecutionContext.toolExecutionScope?.permits(invocation.toolName) == true
                    ? "child-scope"
                    : "wrong-scope"
            }
        )
        let set = try #require(toolset)

        let result = await ChatExecutionContext.$toolExecutionScope.withValue(parentScope) {
            await set.execute(invocation("get_events"))
        }

        #expect(result == "child-scope")
        #expect(!parentScope.permits("get_events"))
    }

    @Test("configured-agent tool dispatch uses target UUID at the registry boundary")
    @MainActor
    func configuredAgentDispatchUsesTargetIdentity() async throws {
        let launcher = UUID()
        let target = UUID()
        let tool = SpawnAgentIdentityProbeTool()
        ToolRegistry.shared.register(tool)
        defer { ToolRegistry.shared.unregister(names: [tool.name]) }

        let executionAgentId = TextSubagentKind.childToolExecutionAgentId(
            targetAgentId: target,
            launcherAgentId: launcher
        )
        let toolset = await TextSubagentKind.makeToolset(
            feed: nil,
            agentSpecs: [spec(tool.name)],
            executionAgentId: executionAgentId
        )
        let set = try #require(toolset)

        let (result, restoredLauncher) =
            await ChatExecutionContext.$currentAgentId.withValue(launcher) {
                let output = await set.execute(invocation(tool.name))
                return (output, ChatExecutionContext.currentAgentId == launcher)
            }
        #expect(restoredLauncher)
        let payload = try #require(ToolEnvelope.successPayload(result) as? [String: Any])

        #expect(payload["text"] as? String == target.uuidString)
        #expect(ChatExecutionContext.currentAgentId == nil)
    }

    @Test("tool dispatch without a target persona preserves the launcher UUID")
    @MainActor
    func noTargetDispatchUsesLauncherIdentity() async throws {
        let launcher = UUID()
        let tool = SpawnAgentIdentityProbeTool()
        ToolRegistry.shared.register(tool)
        defer { ToolRegistry.shared.unregister(names: [tool.name]) }

        let executionAgentId = TextSubagentKind.childToolExecutionAgentId(
            targetAgentId: nil,
            launcherAgentId: launcher
        )
        let toolset = await TextSubagentKind.makeToolset(
            feed: nil,
            specs: [spec(tool.name)],
            executionAgentId: executionAgentId
        )
        let set = try #require(toolset)

        let (result, restoredLauncher) =
            await ChatExecutionContext.$currentAgentId.withValue(launcher) {
                let output = await set.execute(invocation(tool.name))
                return (output, ChatExecutionContext.currentAgentId == launcher)
            }
        #expect(restoredLauncher)
        let payload = try #require(ToolEnvelope.successPayload(result) as? [String: Any])

        #expect(payload["text"] as? String == launcher.uuidString)
        #expect(ChatExecutionContext.currentAgentId == nil)
    }

    @Test("only the spawn family and clarify are excluded from a child schema")
    func childExclusions() {
        #expect(TextSubagentKind.isExcludedChildTool("spawn_agent"))
        #expect(TextSubagentKind.isExcludedChildTool("clarify"))
        #expect(!TextSubagentKind.isExcludedChildTool("create_event"))
        #expect(!TextSubagentKind.isExcludedChildTool("web_search"))
        // Fully capable workers: knowledge/skill mutation is no longer
        // stripped structurally — their own approval cards gate them.
        #expect(!TextSubagentKind.isExcludedChildTool("write_knowledge"))
        #expect(!TextSubagentKind.isExcludedChildTool("delete_knowledge"))
        #expect(!TextSubagentKind.isExcludedChildTool("update_skill"))
        #expect(!TextSubagentKind.isExcludedChildTool("file_write"))
        #expect(!TextSubagentKind.isExcludedChildTool("shell_run"))
    }

    @Test("cancel-reason mapping: user stop / parent cancel / deadline get distinct honest copy")
    func cancelReasonMapping() {
        // User stop → user_denied with "stopped by the user" (NOT a timeout).
        let userStop = TextSubagentKind.cancelError(
            cause: .userInterrupt,
            label: "worker",
            maxElapsedSeconds: 120
        )
        guard case .userDenied(let userMessage) = userStop else {
            Issue.record("user interrupt mapped to \(userStop), expected .userDenied")
            return
        }
        #expect(userMessage.contains("stopped by the user"))
        #expect(!userMessage.contains("time budget"))

        // Parent task cancel → execution failure tied to the parent run.
        let parent = TextSubagentKind.cancelError(
            cause: .parentTask,
            label: "worker",
            maxElapsedSeconds: 120
        )
        guard case .executionFailed(let parentMessage, let retryable) = parent else {
            Issue.record("parent cancel mapped to \(parent), expected .executionFailed")
            return
        }
        #expect(parentMessage.contains("cancelled with the parent run"))
        #expect(retryable == false)

        // Deadline (and the unknown-cause fallback) → the time-budget copy.
        for cause in [SubagentCancelCause.deadline, nil] {
            let deadline = TextSubagentKind.cancelError(
                cause: cause,
                label: "worker",
                maxElapsedSeconds: 120
            )
            guard case .timedOut(let deadlineMessage) = deadline else {
                Issue.record("\(String(describing: cause)) mapped to \(deadline), expected .timedOut")
                return
            }
            #expect(deadlineMessage.contains("120s time budget"))
        }
    }

    // MARK: - Child tool surface mirrors the target agent's enablement (A1)

    private func capabilities(
        webSearch: Bool = false,
        db: Bool = false,
        knowledge: Bool = false,
        curator: Bool = false
    ) -> AgentCapabilities {
        AgentCapabilities(
            toolsEnabled: true,
            memoryEnabled: false,
            dbEnabled: db,
            renderChartEnabled: false,
            speakEnabled: false,
            searchMemoryEnabled: false,
            webSearchEnabled: webSearch,
            selfSchedulingEnabled: false,
            knowledgeEnabled: knowledge,
            knowledgeCuratorEnabled: curator
        )
    }

    @Test("auto surface: everything off leaves only the worker baseline")
    func autoSurfaceBaseline() {
        // Time + `share_artifact`: the declarative spawned-worker baseline
        // (`ToolRegistry.spawnedWorkerBaselineToolNames`).
        #expect(
            TextSubagentKind.autoChildToolNames(capabilities: capabilities())
                == ["get_current_time", "share_artifact"]
        )
    }

    @Test("auto surface: capability gates map to the direct-chat tool names")
    func autoSurfaceFollowsCapabilityGates() {
        #expect(
            TextSubagentKind.autoChildToolNames(
                capabilities: capabilities(webSearch: true)
            ) == ["get_current_time", "search_and_extract", "share_artifact", "web_search"]
        )

        let db = Set(TextSubagentKind.autoChildToolNames(capabilities: capabilities(db: true)))
        #expect(db.isSuperset(of: SystemPromptComposer.agentDBToolNames))

        let knowledge = Set(
            TextSubagentKind.autoChildToolNames(
                capabilities: capabilities(knowledge: true)
            )
        )
        // A child carries the agent's full knowledge surface (the
        // spawn-safety audit, not `isExcludedChildTool`, is the final gate).
        let childKnowledgeNames = SystemPromptComposer.knowledgeToolNames
            .filter { !TextSubagentKind.isExcludedChildTool($0) }
        #expect(knowledge.isSuperset(of: childKnowledgeNames))
        #expect(knowledge.isDisjoint(with: SystemPromptComposer.knowledgeCuratorToolNames))

        let curator = Set(
            TextSubagentKind.autoChildToolNames(
                capabilities: capabilities(knowledge: true, curator: true)
            )
        )
        #expect(curator.isSuperset(of: SystemPromptComposer.knowledgeCuratorToolNames))
    }

    @Test("auto surface: curator toggle without knowledge grants nothing")
    func autoSurfaceCuratorRequiresKnowledge() {
        let names = Set(
            TextSubagentKind.autoChildToolNames(
                capabilities: capabilities(curator: true)
            )
        )
        #expect(names.isDisjoint(with: SystemPromptComposer.knowledgeToolNames))
        #expect(names.isDisjoint(with: SystemPromptComposer.knowledgeCuratorToolNames))
    }

    @Test("spawn-safety gate keeps audited tools and drops the interactive curator proposal")
    @MainActor
    func spawnSafetyGateIntersectsAuditedTools() {
        let names = ToolRegistry.shared.specsForSpawnedOperations(
            forTools: [
                "web_search", "get_current_time", "search_knowledge",
                "write_knowledge",
            ]
        ).map(\.function.name)
        #expect(names.contains("web_search"))
        #expect(names.contains("get_current_time"))
        #expect(names.contains("search_knowledge"))
        // Interactive approval flow — must never run inside a child.
        #expect(!names.contains("write_knowledge"))
    }

    // MARK: - Child seed composition (A4)

    @Test("child system prompt: persona plus optional knowledge section")
    func childSystemPromptComposition() {
        #expect(
            TextSubagentKind.childSystemPrompt(persona: "You are P.", knowledgeSection: nil)
                == "You are P."
        )
        #expect(
            TextSubagentKind.childSystemPrompt(persona: "  ", knowledgeSection: "K")
                == "K"
        )
        #expect(
            TextSubagentKind.childSystemPrompt(persona: "P\n", knowledgeSection: "K")
                == "P\n\nK"
        )
    }

    @Test("seed user content: memory recall rides as the direct-chat-shaped prefix")
    func seedUserContentMemoryPrefix() {
        #expect(TextSubagentKind.seedUserContent(input: "task", memorySection: nil) == "task")
        #expect(TextSubagentKind.seedUserContent(input: "task", memorySection: "  \n") == "task")
        #expect(
            TextSubagentKind.seedUserContent(input: "task", memorySection: "recall")
                == "[Memory]\nrecall\n[/Memory]\n\ntask"
        )
    }
}

private struct SpawnAgentIdentityProbeTool: OsaurusTool {
    let name = "test_spawn_agent_identity_\(UUID().uuidString.prefix(12))"
    let description = "Returns the agent UUID visible at registry dispatch."
    let parameters: JSONValue? = .object(["type": .string("object")])

    var canExposeToSpawnedOperation: Bool { true }

    func spawnedOperationCancellationSupport(
        argumentsJSON _: String
    ) -> SpawnedOperationCancellationSupport {
        .cooperative
    }

    func execute(argumentsJSON _: String) async throws -> String {
        ChatExecutionContext.currentAgentId?.uuidString ?? "none"
    }
}
