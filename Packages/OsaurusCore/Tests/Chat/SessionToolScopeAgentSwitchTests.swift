//
//  SessionToolScopeAgentSwitchTests.swift
//  OsaurusCoreTests
//
//  Regression coverage for the agent-switch tool-scope starvation seen live
//  (Raptor on 0.24.6, Orchestrator chip): a chat started under a custom
//  agent froze that agent's always-loaded snapshot on turn 1 — a snapshot
//  WITHOUT the configure trio, which `resolveTools` strips from every
//  non-default agent. Switching the chip to the Orchestrator did not
//  invalidate the session tool state (the fingerprint was mode + toolMode
//  only), so the Orchestrator's schema was filtered by the custom agent's
//  frozen names and never carried `osaurus_help`, while its addendum told
//  the model to ALWAYS call `osaurus_help`. The scope (== the schema)
//  refused every call with `tool_not_found`.
//
//  Fix under test: the agent id is part of the session fingerprint, so an
//  agent switch re-freezes the snapshot for the new agent; the addendum's
//  required tool names are pinned against the exposed scope.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Shared assertion helper

/// The Orchestrator addendum instructs the model to call
/// `osaurus_help` / `osaurus_inspect` / `osaurus_config` unconditionally.
/// Assert that `scope` (what the request may EXECUTE) permits every one of
/// them — the exact disagreement that produced the live loop.
func expectOrchestratorAddendumAgrees(
    with scope: ToolExecutionScope,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let missing = DefaultAgentSystemPromptBuilder.missingRequiredToolNames(
        exposed: scope.authorizedNames
    )
    #expect(
        missing.isEmpty,
        "the Orchestrator addendum advertises tools the scope refuses: \(missing.sorted())",
        sourceLocation: sourceLocation
    )
    for name in DefaultAgentSystemPromptBuilder.orchestratorRequiredToolNames {
        #expect(scope.permits(name), "scope refuses `\(name)`", sourceLocation: sourceLocation)
    }
}

// MARK: - Fingerprint identity

@Suite(.serialized)
struct SessionToolStateAgentFingerprintTests {

    @Test func fingerprintForksPerAgent() {
        let custom = UUID()
        let a = SessionToolState.fingerprint(executionMode: .none, toolMode: .auto, agentId: custom)
        let b = SessionToolState.fingerprint(
            executionMode: .none,
            toolMode: .auto,
            agentId: Agent.defaultId
        )
        let aAgain = SessionToolState.fingerprint(
            executionMode: .none,
            toolMode: .auto,
            agentId: custom
        )
        #expect(a != b, "a different agent must fork the fingerprint")
        #expect(a == aAgain, "the identity must be stable for the same agent")
        // Mode + toolMode components are unchanged by the agent component.
        #expect(a.hasPrefix("none/auto/"))
        #expect(b.hasPrefix("none/auto/"))
    }

    @Test func agentComponentRoundTrips() {
        let custom = UUID()
        let fp = SessionToolState.fingerprint(
            executionMode: .sandbox(hostRead: nil, hostWrite: false),
            toolMode: .manual,
            agentId: custom
        )
        #expect(
            SessionToolState.agentComponent(of: fp)
                == SessionToolState.agentComponentPrefix + custom.uuidString
        )
        // Legacy shape (no agent) carries no component.
        #expect(SessionToolState.agentComponent(of: "sandbox/auto") == nil)
        #expect(
            SessionToolState.fingerprint(executionMode: .none, toolMode: .auto) == "none/auto",
            "omitting the agent keeps the legacy shape"
        )
    }
}

// MARK: - Store invalidation

@Suite(.serialized)
struct SessionToolStateStoreAgentSwitchTests {

    @Test func agentSwitch_dropsFrozenSnapshotAndDoesNotCarryLoads() async {
        let store = SessionToolStateStore()
        let sessionId = "agent-switch-\(UUID().uuidString)"
        let custom = UUID()
        let customFp = SessionToolState.fingerprint(
            executionMode: .none,
            toolMode: .auto,
            agentId: custom
        )
        let defaultFp = SessionToolState.fingerprint(
            executionMode: .none,
            toolMode: .auto,
            agentId: Agent.defaultId
        )
        await store.appendLoadedTools(
            sessionId,
            names: ["some_mcp_tool"],
            fallbackAlwaysLoadedNames: nil
        )
        await store.setInitial(
            sessionId,
            alwaysLoadedNames: ["web_search", "todo"],
            toolSpecs: nil,
            fingerprint: customFp,
            manifest: "custom manifest"
        )

        let invalidated = await store.invalidateIfFingerprintChanged(
            sessionId,
            liveFingerprint: defaultFp,
            preservingLoadedToolNames: ["some_mcp_tool"]
        )
        #expect(invalidated, "switching the agent chip must invalidate the frozen snapshot")
        let state = await store.get(sessionId)
        #expect(
            state == nil,
            "an agent switch drops the entry wholesale — the new agent's grant is a different baseline"
        )
    }

    @Test func sameAgentModeFlip_stillCarriesModeIndependentLoads() async {
        let store = SessionToolStateStore()
        let sessionId = "mode-flip-same-agent-\(UUID().uuidString)"
        let custom = UUID()
        await store.appendLoadedTools(
            sessionId,
            names: ["some_mcp_tool", "sandbox_only_tool"],
            fallbackAlwaysLoadedNames: nil
        )
        await store.setInitial(
            sessionId,
            alwaysLoadedNames: ["web_search"],
            toolSpecs: nil,
            fingerprint: SessionToolState.fingerprint(
                executionMode: .none,
                toolMode: .auto,
                agentId: custom
            ),
            manifest: nil
        )
        let live = SessionToolState.fingerprint(
            executionMode: .sandbox(hostRead: nil, hostWrite: false),
            toolMode: .auto,
            agentId: custom
        )
        let invalidated = await store.invalidateIfFingerprintChanged(
            sessionId,
            liveFingerprint: live,
            preservingLoadedToolNames: ["some_mcp_tool"]
        )
        #expect(invalidated)
        let state = await store.get(sessionId)
        #expect(state?.loadedToolNames == ["some_mcp_tool"], "mode flip semantics are unchanged")
        #expect(state?.initialAlwaysLoadedNames == nil)
        #expect(state?.sessionFingerprint == live)
    }

    @Test func sameAgentSameMode_isNotInvalidated() async {
        let store = SessionToolStateStore()
        let sessionId = "stable-\(UUID().uuidString)"
        let fp = SessionToolState.fingerprint(
            executionMode: .none,
            toolMode: .auto,
            agentId: Agent.defaultId
        )
        await store.setInitial(
            sessionId,
            alwaysLoadedNames: ["osaurus_help"],
            toolSpecs: nil,
            fingerprint: fp
        )
        let invalidated = await store.invalidateIfFingerprintChanged(sessionId, liveFingerprint: fp)
        #expect(!invalidated)
        let state = await store.get(sessionId)
        #expect(state?.initialAlwaysLoadedNames == ["osaurus_help"])
    }
}

// MARK: - Schema: custom agent → Orchestrator

@Suite(.serialized)
@MainActor
struct SessionToolScopeAgentSwitchSchemaTests {

    private static func makeSnapshot(agentId: UUID) -> AgentConfigSnapshot {
        AgentConfigSnapshot(
            agentId: agentId,
            toolsDisabled: false,
            memoryDisabled: false,
            autonomousConfig: nil,
            toolMode: .auto,
            model: nil,
            manualToolNames: nil,
            systemPrompt: "",
            dbEnabled: false
        )
    }

    /// Turn-1 always-loaded snapshot for `agentId`, computed the way
    /// `SystemPromptComposer.resolveAlwaysLoadedNames` does on a first
    /// compose: live always-loaded names ∩ the resolved schema.
    private static func firstTurnFrozenNames(agentId: UUID) -> LoadedTools {
        let resolved = Set(
            SystemPromptComposer.resolveTools(
                snapshot: makeSnapshot(agentId: agentId),
                executionMode: .none
            ).map { $0.function.name }
        )
        let live = Set(
            ToolRegistry.shared.alwaysLoadedSpecs(mode: .none).map { $0.function.name }
        )
        return live.intersection(resolved)
            .subtracting([BuiltinSandboxTools.initPendingToolName])
    }

    /// The live defect, as a control: the custom agent's frozen snapshot has
    /// no configure tools, and the Orchestrator composed against it lacks
    /// `osaurus_help`. Proves the fix below is doing the work.
    @Test func control_orchestratorFilteredByCustomAgentSnapshot_lacksOsaurusHelp() {
        ConfigurationDomainBootstrap.registerBuiltIns()
        let customFrozen = Self.firstTurnFrozenNames(agentId: UUID())
        #expect(!customFrozen.isEmpty, "INVALID: the custom agent froze an empty snapshot")
        for name in DefaultAgentSystemPromptBuilder.orchestratorRequiredToolNames {
            #expect(!customFrozen.contains(name), "custom agents never freeze `\(name)`")
        }

        let starved = SystemPromptComposer.resolveTools(
            snapshot: Self.makeSnapshot(agentId: Agent.defaultId),
            executionMode: .none,
            frozenAlwaysLoadedNames: customFrozen
        )
        let scope = ToolExecutionScope(exposed: starved)
        #expect(
            !scope.permits("osaurus_help"),
            "control failed: the frozen filter no longer starves the Orchestrator — re-check the mechanism"
        )
        #expect(
            !DefaultAgentSystemPromptBuilder.missingRequiredToolNames(exposed: scope.authorizedNames)
                .isEmpty
        )
    }

    /// The fix end to end at the store + composer boundary: a session
    /// frozen under a custom agent, switched to the Default agent, is
    /// invalidated by the agent-aware fingerprint, so the Orchestrator
    /// composes with NO frozen names and its schema contains `osaurus_help`;
    /// the addendum's required names and the exposed scope agree.
    @Test func agentSwitchToDefault_reFreezesAndExposesOsaurusHelp() async {
        ConfigurationDomainBootstrap.registerBuiltIns()
        let store = SessionToolStateStore()
        let sessionId = "switch-to-orchestrator-\(UUID().uuidString)"
        let custom = UUID()

        // Turn 1 under the custom agent.
        let customFrozen = Self.firstTurnFrozenNames(agentId: custom)
        await store.setInitial(
            sessionId,
            alwaysLoadedNames: customFrozen,
            toolSpecs: nil,
            fingerprint: SessionToolState.fingerprint(
                executionMode: .none,
                toolMode: .auto,
                agentId: custom
            )
        )

        // Turn 2: the chip is now the Orchestrator. Same invalidation call
        // the send path makes.
        let liveFp = SessionToolState.fingerprint(
            executionMode: .none,
            toolMode: .auto,
            agentId: Agent.defaultId
        )
        await store.invalidateIfFingerprintChanged(
            sessionId,
            liveFingerprint: liveFp,
            preservingLoadedToolNames: Set(ToolRegistry.shared.listDynamicTools().map(\.name))
        )
        let cached = await store.get(sessionId)
        #expect(cached?.initialAlwaysLoadedNames == nil, "the custom agent's snapshot must be gone")

        let tools = SystemPromptComposer.resolveTools(
            snapshot: Self.makeSnapshot(agentId: Agent.defaultId),
            executionMode: .none,
            additionalToolNames: cached?.loadedToolNames ?? [],
            frozenAlwaysLoadedNames: cached?.initialAlwaysLoadedNames
        )
        let scope = ToolExecutionScope(exposed: tools)
        #expect(scope.permits("osaurus_help"))
        expectOrchestratorAddendumAgrees(with: scope)

        // Re-freeze for the new agent: the snapshot now carries the trio, so
        // turn 3 stays byte-stable AND keeps them.
        let defaultFrozen = Self.firstTurnFrozenNames(agentId: Agent.defaultId)
        await store.setInitial(
            sessionId,
            alwaysLoadedNames: defaultFrozen,
            toolSpecs: nil,
            fingerprint: liveFp
        )
        let turn3 = SystemPromptComposer.resolveTools(
            snapshot: Self.makeSnapshot(agentId: Agent.defaultId),
            executionMode: .none,
            frozenAlwaysLoadedNames: await store.get(sessionId)?.initialAlwaysLoadedNames
        )
        expectOrchestratorAddendumAgrees(with: ToolExecutionScope(exposed: turn3))
    }

    /// The reverse switch is safe too: Orchestrator → custom agent must not
    /// leak the configure trio into the custom agent's schema (the strip is
    /// unconditional for non-default agents, and the invalidation gives it a
    /// clean baseline).
    @Test func agentSwitchToCustom_doesNotLeakConfigureTools() async {
        ConfigurationDomainBootstrap.registerBuiltIns()
        let store = SessionToolStateStore()
        let sessionId = "switch-to-custom-\(UUID().uuidString)"
        let custom = UUID()
        await store.setInitial(
            sessionId,
            alwaysLoadedNames: Self.firstTurnFrozenNames(agentId: Agent.defaultId),
            toolSpecs: nil,
            fingerprint: SessionToolState.fingerprint(
                executionMode: .none,
                toolMode: .auto,
                agentId: Agent.defaultId
            )
        )
        await store.invalidateIfFingerprintChanged(
            sessionId,
            liveFingerprint: SessionToolState.fingerprint(
                executionMode: .none,
                toolMode: .auto,
                agentId: custom
            )
        )
        let cached = await store.get(sessionId)
        let tools = SystemPromptComposer.resolveTools(
            snapshot: Self.makeSnapshot(agentId: custom),
            executionMode: .none,
            additionalToolNames: cached?.loadedToolNames ?? [],
            frozenAlwaysLoadedNames: cached?.initialAlwaysLoadedNames
        )
        let names = Set(tools.map { $0.function.name })
        for name in ToolRegistry.configureToolNames {
            #expect(!names.contains(name), "`\(name)` leaked into a custom agent's schema")
        }
    }
}

// MARK: - Prompt ↔ contract agreement

@Suite(.serialized)
@MainActor
struct OrchestratorAddendumRequiredToolsTests {

    private static func probe(id: String, writeToolNames: [String]) -> ConfigurationDomain {
        ConfigurationDomain(
            id: id,
            displayName: id.capitalized,
            summary: "Summary for \(id).",
            menuHint: "do / things",
            searchKeywords: [],
            exampleQueries: [],
            tools: [],
            writeToolNames: Set(writeToolNames)
        )
    }

    /// The static required-name list and the rendered prose cannot drift:
    /// every required name is advertised (in backticks) by BOTH addendum
    /// variants, and every required name is a real configure tool the
    /// Default agent's allowlist carries.
    @Test func requiredNames_areAdvertisedByBothVariantsAndAllowed() {
        let domains = [Self.probe(id: "config", writeToolNames: ["osaurus_config"])]
        for compact in [false, true] {
            let rendered = DefaultAgentSystemPromptBuilder._renderForTests(
                domains: domains,
                compact: compact
            )
            for name in DefaultAgentSystemPromptBuilder.orchestratorRequiredToolNames {
                #expect(
                    rendered.contains("`\(name)`"),
                    "compact=\(compact): addendum no longer advertises `\(name)` — update the contract"
                )
            }
        }
        #expect(
            ToolRegistry.configureToolNames.isSuperset(
                of: DefaultAgentSystemPromptBuilder.orchestratorRequiredToolNames
            )
        )
        #expect(
            ToolRegistry.orchestratorAllowedToolNames.isSuperset(
                of: DefaultAgentSystemPromptBuilder.orchestratorRequiredToolNames
            )
        )
    }

    @Test func missingRequiredToolNames_reportsExactlyTheGap() {
        let full = DefaultAgentSystemPromptBuilder.orchestratorRequiredToolNames
        #expect(DefaultAgentSystemPromptBuilder.missingRequiredToolNames(exposed: full).isEmpty)
        #expect(
            DefaultAgentSystemPromptBuilder.missingRequiredToolNames(
                exposed: full.subtracting(["osaurus_help"])
            ) == ["osaurus_help"]
        )
        #expect(DefaultAgentSystemPromptBuilder.missingRequiredToolNames(exposed: []) == full)
    }
}
