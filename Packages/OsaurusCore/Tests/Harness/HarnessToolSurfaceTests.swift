//
//  HarnessToolSurfaceTests.swift
//  osaurusTests
//
//  The Osaurus tools an agent's harness process is offered over the bridge.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct HarnessToolSurfaceTests {

    @Test func neverListsWhatOnlyOsaurusLoopCanRunOrShow() {
        let kept: Set<String> = ["status", "run_workflow", "osaurus_inspect", "web_search"]
        let dropped: Set<String> = HarnessGrantStore.deniedToolNames
            .union(HarnessGrantStore.builtInLoopToolNames)
            .union(ToolRegistry.externallyDeniedToolNames)
            .union(ToolRegistry.capabilityToolNames)
            .union(["configurator_handoff", "architect_handoff", "share_artifact", "image", "video", "render_chart"])
        #expect(HarnessToolSurface.filtered(kept.union(dropped)) == kept)
        #expect(ToolRegistry.externallyDeniedToolNames.contains("file_write"))
    }

    @Test func defaultAgentGetsItsRoutingSurfaceAndInspectTools() {
        let names = HarnessToolSurface.names(agentId: Agent.defaultId, allowsConfigWrites: false)
        #expect(names.contains(StatusTool.toolName))
        #expect(names.contains("osaurus_inspect"))
        #expect(names.contains("osaurus_help"))
        #expect(!names.contains("osaurus_config"))
        for denied in ["clarify", "configurator_handoff", "architect_handoff", "spawn_agent", "share_artifact"] {
            #expect(!names.contains(denied), "\(denied) must not reach a harness")
        }
        #expect(names.isDisjoint(with: ToolRegistry.externallyDeniedToolNames))
    }

    @Test func configWritesFollowTheOptIn() {
        #expect(HarnessToolSurface.names(agentId: Agent.defaultId, allowsConfigWrites: true).contains("osaurus_config"))
    }

    @Test func aCustomAgentWithToolsOffGetsNothing() async {
        await SandboxTestLock.runWithStoragePaths {
            let manager = AgentManager.shared
            let agent = Agent(
                name: "HarnessSurfaceToolsOff-\(UUID().uuidString.prefix(6))",
                agentAddress: "test-harness-surface-\(UUID().uuidString)",
                toolsEnabled: false
            )
            manager.add(agent)
            #expect(HarnessToolSurface.names(agentId: agent.id, allowsConfigWrites: false).isEmpty)
            _ = await manager.delete(id: agent.id)
        }
    }

    @Test func aCustomAgentGetsItsBuiltInsWithoutLoopTools() async {
        await SandboxTestLock.runWithStoragePaths {
            let manager = AgentManager.shared
            let agent = Agent(
                name: "HarnessSurface-\(UUID().uuidString.prefix(6))",
                agentAddress: "test-harness-surface-\(UUID().uuidString)"
            )
            manager.add(agent)
            let names = HarnessToolSurface.names(agentId: agent.id, allowsConfigWrites: false)
            let builtIn = Set(
                SystemPromptComposer.resolveTools(agentId: agent.id, executionMode: .none).map(\.function.name))
            #expect(HarnessToolSurface.filtered(builtIn).isSubset(of: names))
            #expect(names.contains("osaurus_inspect"))
            for denied in ["todo", "complete", "clarify", "capabilities", "share_artifact", "run_workflow", "status"] {
                #expect(!names.contains(denied), "\(denied) must not reach a custom agent's harness")
            }
            _ = await manager.delete(id: agent.id)
        }
    }
}
