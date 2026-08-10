import Foundation
import Testing

@testable import OsaurusCore
@testable import OsaurusEvalsKit

@Suite("Capability claims fixtures", .serialized)
@MainActor
struct CapabilityClaimsFixtureTests {
    @Test("Browser fixture toggles the production per-agent gate")
    func browserUsesAuthoritativeAgentFlag() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-capability-claims-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousRoot = OsaurusPaths.overrideRoot
        OsaurusPaths.overrideRoot = root
        AgentManager.shared.refresh()
        defer {
            OsaurusPaths.overrideRoot = previousRoot
            AgentManager.shared.refresh()
            try? FileManager.default.removeItem(at: root)
        }

        let agentId = EvalRunner.installCapabilityClaimsAgent(excluding: [])
        defer { EvalRunner.removeEvalAgent(agentId) }
        #expect(AgentManager.shared.agent(for: agentId)?.settings.browserUseEnabled == false)

        let restore = await EvalRunner.applyEnableTools(
            [SubagentCapabilityRegistry.browserUse.primaryToolName],
            agentId: agentId
        )

        #expect(AgentManager.shared.agent(for: agentId)?.settings.browserUseEnabled == true)
        #expect(
            !(AgentManager.shared.effectiveEnabledToolNames(for: agentId) ?? [])
                .contains(SubagentCapabilityRegistry.browserUse.primaryToolName)
        )

        await EvalRunner.restoreToolGrant(restore, agentId: agentId)
        #expect(AgentManager.shared.agent(for: agentId)?.settings.browserUseEnabled == false)
    }

    @Test("Deferred-load probe is dynamic and cleaned up")
    func deferredLoadProbeLifecycle() {
        EvalHostBootstrap.unregisterDynamicLoadProbe()
        #expect(
            !EvalHostBootstrap.dynamicToolNames()
                .contains(EvalHostBootstrap.dynamicLoadProbeToolName)
        )

        EvalHostBootstrap.registerDynamicLoadProbe()
        #expect(
            EvalHostBootstrap.dynamicToolNames()
                .contains(EvalHostBootstrap.dynamicLoadProbeToolName)
        )

        EvalHostBootstrap.unregisterDynamicLoadProbe()
        #expect(
            !EvalHostBootstrap.dynamicToolNames()
                .contains(EvalHostBootstrap.dynamicLoadProbeToolName)
        )
    }

    @Test("Agent-loop deferred-load probe appears by exact id in the unified manifest")
    func deferredLoadProbeUsesGatewayManifestContract() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-capability-probe-manifest-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousRoot = OsaurusPaths.overrideRoot
        OsaurusPaths.overrideRoot = root
        AgentManager.shared.refresh()
        defer {
            EvalHostBootstrap.unregisterDynamicLoadProbe()
            OsaurusPaths.overrideRoot = previousRoot
            AgentManager.shared.refresh()
            try? FileManager.default.removeItem(at: root)
        }

        EvalHostBootstrap.registerDynamicLoadProbe()
        let agentId = EvalRunner.installEvalAgent(nil)
        defer { EvalRunner.removeEvalAgent(agentId) }
        #expect(AgentManager.shared.effectiveEnabledToolNames(for: agentId) == nil)
        EvalRunner.prepareAgentLoopEnabledToolFixtures(
            [EvalHostBootstrap.dynamicLoadProbeToolName],
            agentId: agentId
        )
        let restore = await EvalRunner.applyEnableTools(
            [EvalHostBootstrap.dynamicLoadProbeToolName],
            agentId: agentId
        )

        let context = await SystemPromptComposer.composeChatContext(
            agentId: agentId,
            executionMode: .none,
            model: "google/gemma-4-4b-it"
        )
        let manifest = context.enabledManifest ?? ""
        let schemaNames = Set(context.tools.map(\.function.name))

        #expect(manifest.contains("tool/\(EvalHostBootstrap.dynamicLoadProbeToolName)"))
        #expect(context.prompt.contains("`capabilities`"))
        #expect(!context.prompt.contains("capabilities_load"))
        #expect(!context.prompt.contains("capabilities_discover"))
        #expect(schemaNames.contains("capabilities"))
        #expect(!schemaNames.contains("capabilities_load"))
        #expect(!schemaNames.contains("capabilities_discover"))

        await EvalRunner.restoreToolGrant(restore, agentId: agentId)
    }
}
