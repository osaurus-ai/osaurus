//
//  RemoteAgentRoutingTests.swift
//  osaurusTests
//
//  Pins the Mode 1 / Mode 2 split for native `.osaurus` peers:
//    • Mode 2 (remote agent run, `runAsRemoteAgent == true`) routes to
//      `/agents/{address}/run`, OMITS the `model` field on the wire so the peer
//      resolves the agent's live effective model, and stamps the local-only
//      routing flag.
//    • Mode 1 (remote inference, `runAsRemoteAgent == false`) routes to the
//      OpenAI-compatible `/chat/completions` endpoint and preserves the
//      caller's model + tools so the local agent loop drives the turn.
//    • The routing flag is local-only and never crosses the wire.
//    • Mode 2 routing is resolved by the selected agent's provider id, never by
//      the (possibly stale) model string, and a non-`.osaurus` provider can
//      never accept an agent run.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Remote agent routing (Mode 1 vs Mode 2)")
struct RemoteAgentRoutingTests {

    // MARK: - Fixtures

    private static func makeProvider(
        basePath: String,
        port: Int? = 1234,
        remoteAgentId: UUID? = UUID(),
        remoteAgentAddress: String? = "agent-address"
    ) -> RemoteProvider {
        RemoteProvider(
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
    }

    private static func makeService(
        basePath: String,
        port: Int? = 1234,
        remoteAgentId: UUID? = UUID(),
        remoteAgentAddress: String? = "agent-address"
    ) -> RemoteProviderService {
        RemoteProviderService(
            provider: makeProvider(
                basePath: basePath,
                port: port,
                remoteAgentId: remoteAgentId,
                remoteAgentAddress: remoteAgentAddress
            ),
            models: ["coco/model-a"],
            resolvedHeaders: [:]
        )
    }

    /// A non-`.osaurus` provider — the local third-party shape (e.g. a llama.cpp
    /// / "fugu" server) that a remote-agent run must never be routed to.
    private static func makeNonOsaurusProvider(models: [String] = ["fugu/fugu"]) -> RemoteProvider {
        RemoteProvider(
            name: "fugu-local",
            host: "127.0.0.1",
            providerProtocol: .http,
            port: 1234,
            basePath: "/v1",
            authType: .none,
            providerType: .openaiLegacy
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

    @Test func mode2_buildChatRequest_omitsModelOnWireAndStampsFlag() async throws {
        let service = Self.makeService(basePath: "/v1")
        let req = await service.buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: Self.makeParams(runAsRemoteAgent: true),
            model: "gemma-3-12b",
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        // The local routing flag is stamped so `buildURLRequest` targets
        // `/agents/{address}/run`...
        #expect(req.runAsRemoteAgent == true)
        // ...and the `model` field is OMITTED on the wire — the peer resolves
        // the agent's live effective model server-side. Sending any caller-side
        // value (a stale prefix, or the old "default" sentinel) was exactly what
        // surfaced as the opaque upstream 404.
        let data = try JSONEncoder().encode(req)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["model"] == nil)
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

    @Test func mode2_buildChatRequest_stripsSamplingAndReasoning() async throws {
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
        // sampling/reasoning controls may ride along, and the `model` field is
        // omitted from the wire entirely.
        let data = try JSONEncoder().encode(req)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["model"] == nil)
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
        // The `model` field is OMITTED on the wire for an agent run — the peer
        // resolves the agent's live effective model server-side.
        #expect(obj["model"] == nil)
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

    // MARK: - Agent metadata decode (avatar over the wire)

    @Test func parseAgentMetadata_decodesAvatarAndEffectiveModel() throws {
        let json = #"""
            {
                "name": "Coco",
                "description": "A friendly helper",
                "effective_model": "coco/gemma-3-12b",
                "default_model": "default",
                "avatar": "green"
            }
            """#
        let meta = try #require(
            RemoteProviderService.parseAgentMetadata(from: Data(json.utf8))
        )
        #expect(meta.name == "Coco")
        #expect(meta.description == "A friendly helper")
        // Prefers effective_model over default_model.
        #expect(meta.effectiveModel == "coco/gemma-3-12b")
        // The mascot id is the whole point of this workstream.
        #expect(meta.avatar == "green")
    }

    @Test func parseAgentMetadata_collapsesDefaultSentinelModelToNil() throws {
        // A peer that only exposes the "default" sentinel has no concrete model
        // to pin — the chip must not imply a specific device model.
        let json = #"{"name":"Coco","default_model":"default"}"#
        let meta = try #require(
            RemoteProviderService.parseAgentMetadata(from: Data(json.utf8))
        )
        #expect(meta.effectiveModel == nil)
        // Absent avatar → nil (monogram fallback), absent description → nil.
        #expect(meta.avatar == nil)
        #expect(meta.description == nil)
        #expect(meta.name == "Coco")
    }

    @Test func parseAgentMetadata_trimsAndNilsBlankFields() throws {
        let json = #"""
            {"name":"  ","description":"   ","avatar":"  ","effective_model":""}
            """#
        let meta = try #require(
            RemoteProviderService.parseAgentMetadata(from: Data(json.utf8))
        )
        #expect(meta.name == nil)
        #expect(meta.description == nil)
        #expect(meta.avatar == nil)
        #expect(meta.effectiveModel == nil)
    }

    @Test func parseAgentMetadata_returnsNilForNonJSON() {
        #expect(RemoteProviderService.parseAgentMetadata(from: Data("not json".utf8)) == nil)
    }

    // MARK: - Agent metadata decode (Action Bar / quick actions over the wire)

    @Test func parseAgentMetadata_decodesActionBarQuickActions() throws {
        let json = #"""
            {
                "name": "Coco",
                "avatar": "green",
                "chat_quick_actions": [
                    {"id":"11111111-1111-1111-1111-111111111111","icon":"book","text":"Explain","prompt":"Explain "},
                    {"id":"22222222-2222-2222-2222-222222222222","icon":"doc","text":"Summarize","prompt":"Summarize "}
                ]
            }
            """#
        let meta = try #require(
            RemoteProviderService.parseAgentMetadata(from: Data(json.utf8))
        )
        let actions = try #require(meta.quickActions)
        #expect(actions.count == 2)
        #expect(actions.first?.text == "Explain")
        #expect(actions.first?.prompt == "Explain ")
        #expect(actions.last?.icon == "doc")
    }

    @Test func parseAgentMetadata_dropsBlankQuickActionsAndNilsWhenEmpty() throws {
        // Entries missing text or prompt are dropped; an all-blank list collapses
        // to nil so the client falls back to its neutral chat defaults.
        let json = #"""
            {
                "name": "Coco",
                "chat_quick_actions": [
                    {"id":"11111111-1111-1111-1111-111111111111","icon":"book","text":"  ","prompt":"x"},
                    {"id":"22222222-2222-2222-2222-222222222222","icon":"doc","text":"y","prompt":"   "}
                ]
            }
            """#
        let meta = try #require(
            RemoteProviderService.parseAgentMetadata(from: Data(json.utf8))
        )
        #expect(meta.name == "Coco")
        #expect(meta.quickActions == nil)
    }

    @Test func parseAgentMetadata_malformedActionBarDoesNotFailWholeDecode() throws {
        // A malformed action list must not lose the agent's name/avatar/model —
        // quick actions decode from a separate envelope and degrade to nil.
        let json = #"""
            {
                "name": "Coco",
                "avatar": "green",
                "effective_model": "coco/gemma-3-12b",
                "chat_quick_actions": "not-an-array"
            }
            """#
        let meta = try #require(
            RemoteProviderService.parseAgentMetadata(from: Data(json.utf8))
        )
        #expect(meta.name == "Coco")
        #expect(meta.avatar == "green")
        #expect(meta.effectiveModel == "coco/gemma-3-12b")
        #expect(meta.quickActions == nil)
    }

    @Test func parseAgentMetadata_absentActionBarIsNil() throws {
        let json = #"{"name":"Coco","avatar":"green"}"#
        let meta = try #require(
            RemoteProviderService.parseAgentMetadata(from: Data(json.utf8))
        )
        #expect(meta.quickActions == nil)
    }

    // MARK: - Connection metadata fidelity (Insights honesty)

    @Test func remoteConnectionInfo_mode2_isSecureChannelAgentRun() throws {
        // Hold the provider locally (a Sendable struct) so the providerId
        // assertion reads it directly instead of through the actor-isolated
        // `service.provider`, which the `#expect` @Sendable autoclosure rejects.
        let provider = Self.makeProvider(basePath: "/v1", remoteAgentAddress: "addr-1")
        let service = RemoteProviderService(
            provider: provider,
            models: ["coco/model-a"],
            resolvedHeaders: [:]
        )
        let conn = try #require(
            ChatEngine.remoteConnectionInfo(for: service, runAsRemoteAgent: true)
        )
        #expect(conn.info.mode == .remoteAgentRun)
        #expect(conn.info.transport == .secureChannel)
        #expect(conn.info.providerId == provider.id)
        #expect(conn.path == "/v1/agents/addr-1/run")
        #expect(conn.info.remoteEndpoint?.contains("/agents/addr-1/run") == true)
    }

    @Test func remoteConnectionInfo_mode1_isSecureChannelInference() throws {
        let service = Self.makeService(basePath: "/v1", remoteAgentAddress: "addr-1")
        let conn = try #require(
            ChatEngine.remoteConnectionInfo(for: service, runAsRemoteAgent: false)
        )
        #expect(conn.info.mode == .remoteInference)
        #expect(conn.info.transport == .secureChannel)
        #expect(conn.path == "/v1/chat/completions")
    }

    // MARK: - Root-cause fix: route Mode 2 by provider id, never by model string

    @Test func mode2_routesByProviderId_ignoringStaleModel() {
        // The `fugu` 404 reproduction: a remote-agent run is selected while a
        // stale `selectedModel` ("fugu/...") still names a *different* local
        // provider. Routing must resolve the paired agent by its provider id,
        // not by the model string, so the decoy never wins.
        let cocoProvider = Self.makeProvider(basePath: "/v1", remoteAgentAddress: "coco-addr")
        let coco = RemoteProviderService(
            provider: cocoProvider,
            models: ["coco/model-a"],
            resolvedHeaders: [:]
        )
        let decoy = RemoteProviderService(
            provider: Self.makeNonOsaurusProvider(),
            models: ["fugu/fugu"],
            resolvedHeaders: [:]
        )

        let picked = ChatEngine.remoteAgentService(
            providerId: cocoProvider.id,
            in: [decoy, coco]
        )
        // Reference identity (no actor-isolated `provider` read) proves the
        // paired service won over the model-string decoy.
        #expect((picked as? RemoteProviderService) === coco)
    }

    @Test func mode2_unknownProviderId_resolvesToNil() {
        // Provider disconnected mid-flight: the lookup returns nil so dispatch
        // can fail closed (EngineError.remoteAgentUnavailable) instead of
        // silently retargeting a different provider by model string.
        let coco = Self.makeService(basePath: "/v1", remoteAgentAddress: "coco-addr")
        let picked = ChatEngine.remoteAgentService(providerId: UUID(), in: [coco])
        #expect(picked == nil)
    }

    // MARK: - Defense-in-depth: a non-.osaurus provider can't accept an agent run

    @Test func mode2_nonOsaurusProvider_buildURLRequestThrows() async {
        // Even if routing ever regressed and landed a `runAsRemoteAgent` request
        // on a third-party provider, the URL builder must throw rather than POST
        // `/chat/completions` (the path that produced "Model default not found").
        let service = RemoteProviderService(
            provider: Self.makeNonOsaurusProvider(),
            models: ["fugu/fugu"],
            resolvedHeaders: [:]
        )
        let req = await service.buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: Self.makeParams(runAsRemoteAgent: true),
            model: "fugu/fugu",
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        #expect(req.runAsRemoteAgent == true)
        await #expect(throws: RemoteProviderServiceError.self) {
            _ = try await service.buildURLRequest(for: req)
        }
    }

    @Test func mode1_nonOsaurusProvider_buildURLRequestSucceeds() async throws {
        // Sanity: plain remote inference (Mode 1) against the same third-party
        // provider must still build a `/chat/completions` URL — the guard only
        // fires for agent runs.
        let service = RemoteProviderService(
            provider: Self.makeNonOsaurusProvider(),
            models: ["fugu/fugu"],
            resolvedHeaders: [:]
        )
        let req = await service.buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: Self.makeParams(runAsRemoteAgent: false),
            model: "fugu/fugu",
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        let urlRequest = try await service.buildURLRequest(for: req)
        #expect(urlRequest.url?.path == "/v1/chat/completions")
    }

    // MARK: - Server decode tolerance: /agents/{id}/run accepts an omitted model

    @Test func agentRunDecode_injectsEmptyModelWhenOmitted() throws {
        // A Mode 2 caller omits `model` entirely. The shared decoder requires it,
        // so the run handler pre-injects an empty value; the resolver then maps
        // empty → the agent's effective model (or fails fast if none).
        let json = #"{"messages":[{"role":"user","content":"hi"}]}"#
        let patched = HTTPHandler.injectingEmptyModelIfMissing(Data(json.utf8))
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: patched)
        #expect(req.model == "")
        #expect(req.messages.count == 1)
    }

    @Test func agentRunDecode_treatsNullModelAsOmitted() throws {
        let json = #"{"model":null,"messages":[]}"#
        let patched = HTTPHandler.injectingEmptyModelIfMissing(Data(json.utf8))
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: patched)
        #expect(req.model == "")
    }

    @Test func agentRunDecode_preservesProvidedModel() throws {
        // A concrete model (or the legacy "default" sentinel) must pass through
        // untouched — only a missing/null model is patched.
        let json = #"{"model":"coco/gemma-3-12b","messages":[]}"#
        let patched = HTTPHandler.injectingEmptyModelIfMissing(Data(json.utf8))
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: patched)
        #expect(req.model == "coco/gemma-3-12b")
    }

    @Test func agentRunDecode_passesThroughNonJSONUnchanged() {
        // Not a JSON object → returned as-is (the decode will fail downstream
        // with the normal invalid-body path, not here).
        let raw = Data("not json".utf8)
        #expect(HTTPHandler.injectingEmptyModelIfMissing(raw) == raw)
    }

    // MARK: - ChatCompletionRequest threading: remoteAgentProviderId is local-only

    @Test func chatCompletionRequest_copyHelpersPreserveRemoteAgentProviderId() {
        let providerId = UUID()
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
        req.remoteAgentProviderId = providerId
        #expect(req.withModel("other").remoteAgentProviderId == providerId)
        #expect(
            req.withContext(messages: [], tools: nil, toolChoice: nil).remoteAgentProviderId
                == providerId
        )
    }

    @Test func chatCompletionRequest_remoteAgentProviderIdNotDecodedFromJSON() throws {
        // Local-only routing field — inbound OpenAI JSON must never set it.
        let json = #"{"model":"m","messages":[],"remoteAgentProviderId":"\#(UUID().uuidString)"}"#
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(req.remoteAgentProviderId == nil)
    }
}
