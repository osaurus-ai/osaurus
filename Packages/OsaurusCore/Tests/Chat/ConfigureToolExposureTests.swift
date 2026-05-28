//
//  ConfigureToolExposureTests.swift
//  OsaurusCoreTests
//
//  Phase C composer contract:
//
//   * For the Default agent (`Agent.defaultId`), `resolveTools` returns
//     exactly the 8-tool baseline (`defaultAgentAllowedToolNames`):
//     3 reads + 2 discovery + 3 agent-loop. Writes are NOT in this
//     set — they enter the schema only via `capabilities_load`'s
//     `additionalToolNames` carve-out.
//   * For every other agent, every `configure_*` tool is stripped
//     from the resolved schema, even when a registration path leaks
//     them into the always-loaded surface.
//
//  Tests build an `AgentConfigSnapshot` directly so we can pin the
//  agent id deterministically without provisioning custom agents
//  through `AgentManager`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ConfigureToolExposureTests {

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

    private static func ensureBootstrapped() {
        ConfigurationDomainBootstrap.registerBuiltIns()
    }

    @Test
    func defaultAgent_seesExactlyEightToolBaseline() async {
        Self.ensureBootstrapped()
        let snapshot = Self.makeSnapshot(agentId: Agent.defaultId)
        let tools = SystemPromptComposer.resolveTools(
            snapshot: snapshot,
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        #expect(names == ToolRegistry.defaultAgentAllowedToolNames)
    }

    @Test
    func defaultAgent_excludesEveryConfigureWrite() async {
        Self.ensureBootstrapped()
        let snapshot = Self.makeSnapshot(agentId: Agent.defaultId)
        let tools = SystemPromptComposer.resolveTools(
            snapshot: snapshot,
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        for write in ToolRegistry.configureWriteToolNames {
            #expect(!names.contains(write), "configure write \(write) leaked into default-agent schema")
        }
    }

    @Test
    func defaultAgent_canLoadWritesViaAdditionalToolNames() async {
        // capabilities_load carries the loaded write through the
        // `additionalToolNames` parameter; the composer must let
        // that carve-out into the schema even though the write isn't
        // in `defaultAgentAllowedToolNames`.
        Self.ensureBootstrapped()
        let snapshot = Self.makeSnapshot(agentId: Agent.defaultId)
        let tools = SystemPromptComposer.resolveTools(
            snapshot: snapshot,
            executionMode: .none,
            additionalToolNames: ["osaurus_provider_add"]
        )
        let names = Set(tools.map { $0.function.name })
        #expect(names.contains("osaurus_provider_add"))
    }

    @Test
    func customAgent_isStrippedOfEveryConfigureTool() async {
        Self.ensureBootstrapped()
        let snapshot = Self.makeSnapshot(agentId: UUID())
        let tools = SystemPromptComposer.resolveTools(
            snapshot: snapshot,
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        for configure in ToolRegistry.configureToolNames {
            #expect(
                !names.contains(configure),
                "configure tool \(configure) leaked into non-default-agent schema"
            )
        }
    }

    @Test
    func customAgent_excludesReadsTooSinceTheyAreDefaultAgentOnly() async {
        Self.ensureBootstrapped()
        let snapshot = Self.makeSnapshot(agentId: UUID())
        let tools = SystemPromptComposer.resolveTools(
            snapshot: snapshot,
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        // osaurus_status / osaurus_list / osaurus_describe live in
        // ToolRegistry as built-ins for indexing, but the composer
        // strips them from custom-agent schemas. Verifying this so
        // future "make them globally available" changes are forced
        // to come through a review.
        #expect(!names.contains("osaurus_status"))
        #expect(!names.contains("osaurus_list"))
        #expect(!names.contains("osaurus_describe"))
    }
}
