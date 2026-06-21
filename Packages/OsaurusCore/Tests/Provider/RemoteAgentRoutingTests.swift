//
//  RemoteAgentRoutingTests.swift
//  osaurusTests
//
//  Pins the Mode 1 / Mode 2 split for native `.osaurus` peers:
//    • Mode 2 (remote agent run, `runAsRemoteAgent == true`) routes to
//      `/agents/{address}/run`, sends `model: "default"` so the peer resolves
//      the agent's live effective model, and stamps the local-only routing flag.
//    • Mode 1 (remote inference, `runAsRemoteAgent == false`) routes to the
//      OpenAI-compatible `/chat/completions` endpoint and preserves the
//      caller's model + tools so the local agent loop drives the turn.
//    • The routing flag is local-only and never crosses the wire.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Remote agent routing (Mode 1 vs Mode 2)")
struct RemoteAgentRoutingTests {

    // MARK: - Fixtures

    private static func makeService(
        basePath: String,
        port: Int? = 1234,
        remoteAgentId: UUID? = UUID(),
        remoteAgentAddress: String? = "agent-address"
    ) -> RemoteProviderService {
        let provider = RemoteProvider(
            name: "Coco",
            host: "127.0.0.1",
            providerProtocol: .http,
            port: port,
            basePath: basePath,
            authType: .none,
            providerType: .osaurus,
            remoteAgentId: remoteAgentId,
            remoteAgentAddress: remoteAgentAddress
        )
        return RemoteProviderService(
            provider: provider,
            models: ["coco/model-a"],
            resolvedHeaders: [:]
        )
    }

    private static func makeParams(runAsRemoteAgent: Bool) -> GenerationParameters {
        GenerationParameters(
            temperature: 0.7,
            maxTokens: 1024,
            runAsRemoteAgent: runAsRemoteAgent
        )
    }

    private static let weatherTool = Tool(
        type: "function",
        function: ToolFunction(
            name: "get_weather",
            description: "Get weather",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "location": .object(["type": .string("string")])
                ]),
            ])
        )
    )

    // MARK: - URL routing

    @Test func mode2_relayBasePath_routesToAgentRun() async {
        let service = Self.makeService(basePath: "/v1", remoteAgentAddress: "addr-1")
        let url = await service.osaurusEndpointURL(runAsRemoteAgent: true)
        #expect(url?.path == "/v1/agents/addr-1/run")
    }

    @Test func mode1_relayBasePath_routesToChatCompletions() async {
        let service = Self.makeService(basePath: "/v1", remoteAgentAddress: "addr-1")
        let url = await service.osaurusEndpointURL(runAsRemoteAgent: false)
        #expect(url?.path == "/v1/chat/completions")
    }

    @Test func mode2_discoveredBasePath_routesToAgentRun() async {
        let service = Self.makeService(basePath: "", remoteAgentAddress: "addr-2")
        let url = await service.osaurusEndpointURL(runAsRemoteAgent: true)
        #expect(url?.path == "/agents/addr-2/run")
    }

    @Test func mode1_discoveredBasePath_routesToChatCompletions() async {
        let service = Self.makeService(basePath: "", remoteAgentAddress: "addr-2")
        let url = await service.osaurusEndpointURL(runAsRemoteAgent: false)
        #expect(url?.path == "/chat/completions")
    }

    @Test func mode2_fallsBackToRemoteAgentIdWhenNoAddress() async {
        let agentId = UUID()
        let service = Self.makeService(
            basePath: "",
            remoteAgentId: agentId,
            remoteAgentAddress: nil
        )
        let url = await service.osaurusEndpointURL(runAsRemoteAgent: true)
        #expect(url?.path == "/agents/\(agentId.uuidString)/run")
    }

    @Test func mode2_returnsNilWhenNoIdentifier() async {
        let service = Self.makeService(basePath: "", remoteAgentId: nil, remoteAgentAddress: nil)
        let url = await service.osaurusEndpointURL(runAsRemoteAgent: true)
        #expect(url == nil)
    }

    @Test func mode1_returnsChatCompletionsEvenWithoutAgentIdentifier() async {
        // Mode 1 never needs the agent identifier — it's plain inference.
        let service = Self.makeService(basePath: "", remoteAgentId: nil, remoteAgentAddress: nil)
        let url = await service.osaurusEndpointURL(runAsRemoteAgent: false)
        #expect(url?.path == "/chat/completions")
    }

    // MARK: - Wire request shape

    @Test func mode2_buildChatRequest_pinsModelDefaultAndStampsFlag() async {
        let service = Self.makeService(basePath: "/v1")
        let req = await service.buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: Self.makeParams(runAsRemoteAgent: true),
            model: "gemma-3-12b",
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        // The agent resolves its own model server-side from the "default" sentinel.
        #expect(req.model == "default")
        #expect(req.runAsRemoteAgent == true)
    }

    @Test func mode1_buildChatRequest_keepsModelAndTools() async {
        let service = Self.makeService(basePath: "/v1")
        let req = await service.buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: Self.makeParams(runAsRemoteAgent: false),
            model: "gemma-3-12b",
            stream: true,
            tools: [Self.weatherTool],
            toolChoice: nil
        )
        #expect(req.model == "gemma-3-12b")
        #expect(req.runAsRemoteAgent == false)
        #expect(req.tools?.count == 1)
        #expect(req.tools?.first?.function.name == "get_weather")
    }

    // MARK: - S1: Mode 2 strips the caller's sampling + reasoning

    /// Params carrying a full set of caller sampling + reasoning controls, so a
    /// Mode 2 build can be proven to drop every one of them (the remote agent
    /// uses its own `generation_config.json`) while Mode 1 forwards them.
    private static func makeRichParams(runAsRemoteAgent: Bool) -> GenerationParameters {
        GenerationParameters(
            temperature: 0.42,
            maxTokens: 777,
            topPOverride: 0.91,
            frequencyPenalty: 0.5,
            presencePenalty: 0.25,
            modelOptions: ["reasoningEffort": .string("high")],
            runAsRemoteAgent: runAsRemoteAgent
        )
    }

    @Test func mode2_buildChatRequest_stripsSamplingAndReasoning() async {
        let service = Self.makeService(basePath: "/v1")
        let req = await service.buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: Self.makeRichParams(runAsRemoteAgent: true),
            // Non-OpenAI-reasoning model so Mode 1 would normally KEEP
            // temperature/top_p — proving the nils below come from Mode 2, not
            // from the reasoning-model carve-out.
            model: "gemma-3-12b",
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        // The remote agent owns its generation config: none of the caller's
        // sampling/reasoning controls may ride along, only `model: "default"`.
        #expect(req.model == "default")
        #expect(req.temperature == nil)
        #expect(req.top_p == nil)
        #expect(req.frequency_penalty == nil)
        #expect(req.presence_penalty == nil)
        #expect(req.max_completion_tokens == nil)
        #expect(req.stop == nil)
        #expect(req.reasoning_effort == nil)
        #expect(req.reasoning == nil)
        #expect(req.thinking == nil)
    }

    @Test func mode1_buildChatRequest_forwardsSamplingAndReasoning() async {
        let service = Self.makeService(basePath: "/v1")
        let req = await service.buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: Self.makeRichParams(runAsRemoteAgent: false),
            model: "gemma-3-12b",
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        // Mode 1 is plain remote inference driven by the LOCAL agent, so the
        // caller's sampling controls are preserved on the wire.
        #expect(req.model == "gemma-3-12b")
        #expect(req.temperature == 0.42)
        #expect(req.top_p == 0.91)
        #expect(req.frequency_penalty == 0.5)
        #expect(req.presence_penalty == 0.25)
        #expect(req.max_completion_tokens == 777)
        #expect(req.reasoning_effort == "high")
    }

    // MARK: - Wire safety: the routing flag never serializes

    @Test func runAsRemoteAgent_isNotSerializedToWire() async throws {
        let service = Self.makeService(basePath: "/v1")
        let req = await service.buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: Self.makeParams(runAsRemoteAgent: true),
            model: "gemma-3-12b",
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        let data = try JSONEncoder().encode(req)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["runAsRemoteAgent"] == nil)
        #expect(obj["run_as_remote_agent"] == nil)
        // The sentinel model IS on the wire — that's how the peer resolves the
        // agent's live effective model.
        #expect(obj["model"] as? String == "default")
    }

    // MARK: - ChatCompletionRequest threading

    @Test func chatCompletionRequest_defaultsRunAsRemoteAgentFalse() {
        let req = ChatCompletionRequest(
            model: "m",
            messages: [],
            temperature: nil,
            max_tokens: nil,
            stream: true,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil,
            session_id: nil
        )
        #expect(req.runAsRemoteAgent == false)
    }

    @Test func chatCompletionRequest_copyHelpersPreserveRunAsRemoteAgent() {
        var req = ChatCompletionRequest(
            model: "m",
            messages: [],
            temperature: nil,
            max_tokens: nil,
            stream: true,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil,
            session_id: nil
        )
        req.runAsRemoteAgent = true
        #expect(req.withModel("other").runAsRemoteAgent == true)
        #expect(
            req.withContext(messages: [], tools: nil, toolChoice: nil).runAsRemoteAgent == true
        )
    }

    @Test func chatCompletionRequest_runAsRemoteAgentNotDecodedFromJSON() throws {
        // Inbound OpenAI JSON must never be able to set the local-only routing
        // flag — it's excluded from CodingKeys, so decoding leaves it false.
        let json = #"{"model":"m","messages":[],"runAsRemoteAgent":true}"#
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(req.runAsRemoteAgent == false)
    }
}
