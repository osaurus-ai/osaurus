//
//  DefaultAgentSystemPromptBuilderTests.swift
//  OsaurusCoreTests
//
//  The Orchestrator's persona: the eight rules, the routing table, and the
//  truthfulness contract (every tool the persona names is in the request
//  schema for that exposure). Everything about Osaurus's own settings now
//  lives in the Configurator's prompt (`ConfiguratorSystemPromptBuilderTests`).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct DefaultAgentSystemPromptBuilderTests {

    private static let exposures: [DefaultAgentSystemPromptBuilder.Exposure] = [
        .init(folderBound: false, runWorkflowAvailable: false),
        .init(folderBound: true, runWorkflowAvailable: false),
        .init(folderBound: false, runWorkflowAvailable: true),
        .full,
    ]

    @Test
    func toolsDisabledDoesNotAdvertiseUnavailableOrchestratorFunctions() {
        for compact in [false, true] {
            let enabled = DefaultAgentSystemPromptBuilder.render(compact: compact)
            let disabled = DefaultAgentSystemPromptBuilder.render(compact: compact, toolsAvailable: false)
            #expect(disabled.contains("Tools are unavailable"))
            for name in ["configurator_handoff", "architect_handoff", "status", "state"] {
                #expect(!disabled.contains("`\(name)`"))
            }
            for name in ["configurator_handoff", "architect_handoff", "status"] {
                #expect(enabled.contains("`\(name)`"))
            }
            #expect(DefaultAgentSystemPromptBuilder.render(compact: compact) == enabled)
        }
    }

    @Test
    func defaultChatDisabledToolGatesAlsoGateItsPersona() {
        let cases: [(Bool, Bool, String?, ExecutionMode)] = [
            (true, false, nil, .none),
            (false, true, nil, .none),
            (false, true, nil, .sandbox),
            (false, false, "foundation", .none),
        ]
        for (agentDisabled, globalDisabled, model, mode) in cases {
            let snapshot = AgentConfigSnapshot(
                agentId: Agent.defaultId,
                toolsDisabled: agentDisabled,
                globalToolsDisabled: globalDisabled,
                memoryDisabled: true,
                autonomousConfig: nil,
                toolMode: .auto,
                model: model,
                manualToolNames: nil,
                systemPrompt: "User persona survives.",
                dbEnabled: false
            )
            let rendered = SystemPromptComposer.forChat(
                snapshot: snapshot, agentId: Agent.defaultId, executionMode: mode
            ).render()
            #expect(rendered.contains("Tools are unavailable"))
            #expect(rendered.contains("User persona survives."))
            #expect(!rendered.contains("configurator_handoff"))
        }
    }

    /// The seven rules, each present and in order, in both variants.
    @Test
    func render_carriesTheSevenRulesInOrder() {
        for compact in [false, true] {
            for exposure in Self.exposures {
                let rendered = DefaultAgentSystemPromptBuilder._renderForTests(compact: compact, exposure: exposure)
                #expect(!rendered.contains("\n8. "))
                var cursor = rendered.startIndex
                for rule in 1...7 {
                    let marker = "\n\(rule). "
                    guard let range = rendered.range(of: marker, range: cursor..<rendered.endIndex) else {
                        Issue.record("rule \(rule) missing (compact=\(compact) exposure=\(exposure))")
                        break
                    }
                    cursor = range.upperBound
                }
            }
        }
    }

    @Test
    func render_ruleTextMatchesTheContract() {
        for compact in [false, true] {
            let rendered = DefaultAgentSystemPromptBuilder._renderForTests(
                compact: compact,
                exposure: .init(folderBound: false))
            #expect(rendered.contains("1. No tool needed: answer. Any tool needed: route."))
            #expect(rendered.contains("verbatim"))
            #expect(rendered.contains("3. Never spawn a subagent."))
            #expect(rendered.contains("4. Never apply a settings change yourself"))
            #expect(rendered.contains("6. Present results as returned."))
            #expect(rendered.contains("7. At most one clarifying question per turn"))
            // The `state` rule is the injected block's last line instead.
            #expect(!rendered.contains("`state`"))
        }
    }

    /// The Orchestrator never carries the configuration knowledge or tools
    /// it handed to the Configurator.
    @Test
    func render_neverTeachesConfigurationItself() {
        for compact in [false, true] {
            for exposure in Self.exposures {
                let rendered = DefaultAgentSystemPromptBuilder._renderForTests(compact: compact, exposure: exposure)
                for name in ["osaurus_config", "osaurus_inspect", "osaurus_help", "file_read", "file_search"] {
                    #expect(!rendered.contains(name), "compact=\(compact) names \(name)")
                }
                #expect(!rendered.contains("Document sections"))
                #expect(!rendered.contains("yaml"))
                #expect(rendered.contains("`configurator_handoff`"))
            }
        }
    }

    @Test
    func render_routesFollowTheExposure() {
        for compact in [false, true] {
            let bare = DefaultAgentSystemPromptBuilder._renderForTests(
                compact: compact,
                exposure: .init(folderBound: false, runWorkflowAvailable: false))
            #expect(!bare.contains("`run_workflow`"))
            #expect(bare.contains("`architect_handoff`, which builds it and runs it now"))
            #expect(bare.contains("Folder chip"))

            let full = DefaultAgentSystemPromptBuilder._renderForTests(compact: compact, exposure: .full)
            #expect(full.contains("`run_workflow`"))
            #expect(full.contains("that worker or agent's name"))
            #expect(full.contains("A working folder is attached"))
            for rendered in [bare, full] {
                #expect(!rendered.contains("`spawn_agent`"))
                #expect(!rendered.contains("`web_search`"))
                #expect(rendered.contains("3. Never spawn a subagent."))
            }
        }
    }

    @Test
    func render_isMemoizedPerExposure() {
        DefaultAgentSystemPromptBuilder._resetForTests()
        defer { DefaultAgentSystemPromptBuilder._resetForTests() }
        let a = DefaultAgentSystemPromptBuilder.render(compact: true, exposure: .full)
        let b = DefaultAgentSystemPromptBuilder.render(compact: true, exposure: .full)
        let c = DefaultAgentSystemPromptBuilder.render(
            compact: true, exposure: .init(folderBound: false))
        #expect(a == b)
        #expect(a != c)
        #expect(DefaultAgentSystemPromptBuilder.render(compact: false, exposure: .full) != a)
    }

    @Test
    func requiredToolNamesAreTheRoutingCore() {
        #expect(
            DefaultAgentSystemPromptBuilder.orchestratorRequiredToolNames
                == ["status", "state", "configurator_handoff", "architect_handoff"])
        #expect(
            DefaultAgentSystemPromptBuilder.orchestratorRequiredToolNames
                .isSubset(of: ToolRegistry.orchestratorRoutingToolNames))
    }

    /// Truthfulness contract: for every (compact, exposure) variant, each
    /// registered tool the persona names in backticks is in the schema for
    /// that exposure.
    @Test
    func render_everyAdvertisedToolIsInTheMatchingSchema() async {
        let lease = await acquireSubagentStoreSandbox("orchestrator-persona-truth")
        defer { lease.release() }
        let known = Set(ToolRegistry.shared.registeredToolNames())
            .union(ToolRegistry.orchestratorRoutingToolNames)
            .union(ToolRegistry.orchestratorLegacyToolNames)
            .union(["spawn_agent", "file_read", "file_search", "osaurus_config"])
        for compact in [false, true] {
            for exposure in Self.exposures {
                var schema = ToolRegistry.orchestratorRoutingToolNames
                if !exposure.runWorkflowAvailable { schema.remove(RunWorkflowTool.toolName) }
                let rendered = DefaultAgentSystemPromptBuilder.render(compact: compact, exposure: exposure)
                let advertised = DefaultAgentSystemPromptBuilder.advertisedToolNames(in: rendered, known: known)
                #expect(
                    advertised.isSubset(of: schema),
                    "compact=\(compact) exposure=\(exposure): \(advertised.subtracting(schema).sorted())")
                let withStateLine = DefaultAgentSystemPromptBuilder.advertisedToolNames(
                    in: rendered + "\n" + OrchestratorTurnBlock.stateRuleLine, known: known)
                #expect(withStateLine.isSuperset(of: DefaultAgentSystemPromptBuilder.orchestratorRequiredToolNames))
            }
        }
    }

    /// End to end: the resolver's Default-agent schema agrees with the
    /// persona the composer ships for it.
    @Test
    func forChat_defaultAgentPersonaMatchesResolvedSchema() async {
        let lease = await acquireSubagentStoreSandbox("orchestrator-persona-forChat")
        defer { lease.release() }
        let snapshot = AgentConfigSnapshot(
            agentId: Agent.defaultId, toolsDisabled: false, memoryDisabled: true,
            autonomousConfig: nil, toolMode: .auto, model: nil, manualToolNames: nil,
            systemPrompt: "", dbEnabled: false)
        let resolved = Set(
            SystemPromptComposer.resolveTools(snapshot: snapshot, executionMode: .none)
                .map(\.function.name))
        #expect(DefaultAgentSystemPromptBuilder.missingRequiredToolNames(exposed: resolved).isEmpty)
        for name in ["osaurus_config", "osaurus_inspect", "osaurus_help", "file_read", "file_search"] {
            #expect(!resolved.contains(name), "Orchestrator schema carries \(name)")
        }
        let exposure = DefaultAgentSystemPromptBuilder.Exposure.from(toolNames: resolved, folderBound: false)
        let rendered = DefaultAgentSystemPromptBuilder.render(compact: true, exposure: exposure)
        let known = Set(ToolRegistry.shared.registeredToolNames()).union(["spawn_agent"])
        let advertised = DefaultAgentSystemPromptBuilder.advertisedToolNames(in: rendered, known: known)
        #expect(advertised.isSubset(of: resolved), "\(advertised.subtracting(resolved).sorted())")
    }
}
