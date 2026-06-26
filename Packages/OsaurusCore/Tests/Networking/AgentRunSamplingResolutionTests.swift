//
//  AgentRunSamplingResolutionTests.swift
//  OsaurusCoreTests
//
//  Pins the sampling-resolution contract for the `/agents/{id}/run` endpoint:
//  an agent's configured temperature / max tokens are honored when the request
//  omits them, while an explicit request value still wins. Guards against the
//  HTTP agent-run path reverting to sampling only from the raw request body
//  (the bug where an agent's `effectiveTemperature` was ignored over HTTP).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct AgentRunSamplingResolutionTests {

    /// Decode a minimal chat-completion request, optionally carrying explicit
    /// sampling values. Omitted keys decode to `nil` (the real wire behavior).
    private func makeRequest(temperature: Float?, maxTokens: Int?) -> ChatCompletionRequest {
        var fields = ["\"model\":\"m\"", "\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]"]
        if let temperature { fields.append("\"temperature\":\(temperature)") }
        if let maxTokens { fields.append("\"max_tokens\":\(maxTokens)") }
        let json = "{\(fields.joined(separator: ","))}"
        return try! JSONDecoder().decode(
            ChatCompletionRequest.self,
            from: Data(json.utf8)
        )
    }

    @Test
    func omittedSamplingFallsBackToAgentConfig() async {
        await SandboxTestLock.runWithStoragePaths {
            let manager = AgentManager.shared
            let agent = Agent(
                name: "Sampling Probe \(UUID().uuidString)",
                temperature: 0.1,
                maxTokens: 512
            )
            manager.add(agent)

            let resolved = HTTPHandler.resolveAgentSampling(
                request: self.makeRequest(temperature: nil, maxTokens: nil),
                agentId: agent.id
            )
            #expect(resolved.temperature == 0.1)
            #expect(resolved.maxTokens == 512)

            _ = await manager.delete(id: agent.id)
        }
    }

    @Test
    func explicitRequestSamplingWinsOverAgentConfig() async {
        await SandboxTestLock.runWithStoragePaths {
            let manager = AgentManager.shared
            let agent = Agent(
                name: "Sampling Probe \(UUID().uuidString)",
                temperature: 0.1,
                maxTokens: 512
            )
            manager.add(agent)

            let resolved = HTTPHandler.resolveAgentSampling(
                request: self.makeRequest(temperature: 0.9, maxTokens: 256),
                agentId: agent.id
            )
            #expect(resolved.temperature == 0.9)
            #expect(resolved.maxTokens == 256)

            _ = await manager.delete(id: agent.id)
        }
    }
}
