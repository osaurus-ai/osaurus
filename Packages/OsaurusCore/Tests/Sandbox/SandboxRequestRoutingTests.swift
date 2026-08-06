import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SandboxRequestRoutingTests {
    @Test
    func secretCheckUsesRequestAgentInsteadOfCapturedAgent() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let config = AutonomousExecConfig(enabled: true)
            let requestAgent = Agent(name: "Secret Request", autonomousExec: config)
            let capturedAgent = Agent(name: "Secret Captured", autonomousExec: config)
            AgentManager.shared.add(requestAgent)
            AgentManager.shared.add(capturedAgent)
            let secret = "ROUTING_SECRET_\(UUID().uuidString.prefix(8))"

            try await AgentSecretsKeychain._withInMemoryStoreForTesting {
                #expect(
                    AgentSecretsKeychain.saveSecret(
                        "request-only",
                        id: secret,
                        agentId: requestAgent.id
                    )
                )
                let tool = SandboxSecretCheckTool(agentId: capturedAgent.id.uuidString)

                let requestResult = try await ChatExecutionContext.$currentAgentId.withValue(
                    requestAgent.id
                ) {
                    try await tool.execute(
                        argumentsJSON: #"{"key":"\#(secret)"}"#
                    )
                }
                let capturedResult = try await ChatExecutionContext.$currentAgentId.withValue(
                    capturedAgent.id
                ) {
                    try await tool.execute(
                        argumentsJSON: #"{"key":"\#(secret)"}"#
                    )
                }

                let requestPayload = try #require(
                    ToolEnvelope.successPayload(requestResult) as? [String: Any]
                )
                let capturedPayload = try #require(
                    ToolEnvelope.successPayload(capturedResult) as? [String: Any]
                )
                #expect(requestPayload["exists"] as? Bool == true)
                #expect(capturedPayload["exists"] as? Bool == false)
            }
        }
    }

    @Test
    func stalePluginRegisterScopeFailsClosedForDisabledRequestAgent() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let enabled = Agent(
                name: "Plugin Enabled",
                autonomousExec: AutonomousExecConfig(enabled: true, pluginCreate: true)
            )
            let disabled = Agent(
                name: "Plugin Disabled",
                autonomousExec: AutonomousExecConfig(enabled: true, pluginCreate: false)
            )
            AgentManager.shared.add(enabled)
            AgentManager.shared.add(disabled)
            let tool = SandboxPluginRegisterTool(
                agentId: enabled.id.uuidString,
                agentName: SandboxAgentProvisioner.linuxName(for: enabled.id.uuidString)
            )

            let result = try await ChatExecutionContext.$currentAgentId.withValue(disabled.id) {
                try await tool.execute(argumentsJSON: "{}")
            }
            #expect(ToolEnvelope.isError(result))
            let data = try #require(result.data(using: .utf8))
            let payload = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            #expect(payload["kind"] as? String == "rejected")
            #expect((payload["message"] as? String ?? "").contains("Plugin creation is disabled"))
        }
    }
}
