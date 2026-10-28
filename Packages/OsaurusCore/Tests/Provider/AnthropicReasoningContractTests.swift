//
//  AnthropicReasoningContractTests.swift
//  osaurusTests
//
//  The native Anthropic route turns the Models API `capabilities` object into
//  picker effort levels and the Messages API `thinking` / `output_config`
//  fields.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Anthropic reasoning contract")
struct AnthropicReasoningContractTests {

    // MARK: - Models API decoding

    @Test func modelsResponse_decodesCapabilitiesContextAndLifecycle() throws {
        let json = """
            {
              "data": [
                {
                  "id": "claude-sonnet-5-5",
                  "display_name": "Claude Sonnet 5.5",
                  "created_at": "2026-09-01T00:00:00Z",
                  "type": "model",
                  "max_input_tokens": 1000000,
                  "max_tokens": 128000,
                  "lifecycle": "active",
                  "line": "sonnet",
                  "capabilities": {
                    "batch": {"supported": true},
                    "thinking": {
                      "supported": true,
                      "types": {
                        "adaptive": {"supported": true},
                        "enabled": {"supported": false},
                        "disabled": {"supported": false},
                        "between_tools": {"supported": true}
                      }
                    },
                    "effort": {
                      "supported": true,
                      "low": {"supported": true},
                      "medium": {"supported": true},
                      "high": {"supported": true},
                      "xhigh": {"supported": true},
                      "max": {"supported": true}
                    }
                  }
                },
                {
                  "id": "claude-opus-4-6",
                  "display_name": "Claude Opus 4.6",
                  "created_at": "2026-02-01T00:00:00Z",
                  "type": "model",
                  "lifecycle": "deprecated",
                  "capabilities": "unexpected-shape"
                }
              ],
              "has_more": false,
              "first_id": "claude-sonnet-5-5",
              "last_id": "claude-opus-4-6"
            }
            """
        let response = try JSONDecoder().decode(AnthropicModelsResponse.self, from: Data(json.utf8))
        #expect(response.data.count == 2)

        let sonnet = response.data[0]
        #expect(sonnet.max_input_tokens == 1_000_000)
        #expect(sonnet.max_tokens == 128_000)
        #expect(!sonnet.isDeprecated)
        let capabilities = try #require(sonnet.capabilities)
        #expect(capabilities.effort?.supportedLevels == ["low", "medium", "high", "xhigh", "max"])
        #expect(AnthropicReasoningContract.offMode(capabilities) == .betweenTools)

        let legacy = response.data[1]
        #expect(legacy.isDeprecated)
        #expect(legacy.capabilities == nil, "a malformed capability object must not fail the list")
        #expect(AnthropicModelCatalog.contextLengths(of: response.data) == ["claude-sonnet-5-5": 1_000_000])
    }

    @Test func modelsResponse_withoutCapabilitiesStillDecodes() throws {
        let json = """
            {"data": [{"id": "claude-proxy", "display_name": "Proxy", "created_at": "2026-01-01T00:00:00Z",
                       "type": "model"}], "has_more": false, "first_id": null, "last_id": null}
            """
        let response = try JSONDecoder().decode(AnthropicModelsResponse.self, from: Data(json.utf8))
        #expect(response.data.first?.capabilities == nil)
        #expect(response.data.first?.max_input_tokens == nil)
    }

    // MARK: - Picker levels

    @Test func pickerLevels_followTheAdvertisedContract() {
        #expect(
            AnthropicReasoningContract.capabilities(from: Self.adaptiveWithDisabled)?.levels.map(\.id)
                == ["none", "low", "medium", "high", "xhigh", "max"]
        )
        #expect(AnthropicReasoningContract.capabilities(from: Self.adaptiveWithDisabled)?.defaultLevelId == nil)
        #expect(
            AnthropicReasoningContract.capabilities(from: Self.sonnet55)?.levels.map(\.id)
                == ["none", "low", "medium", "high", "xhigh", "max"]
        )
        #expect(
            AnthropicReasoningContract.capabilities(from: Self.alwaysOn)?.levels.map(\.id)
                == ["low", "medium", "high", "xhigh", "max"],
            "models that cannot turn thinking off offer no Off level"
        )
        let manual = AnthropicReasoningContract.capabilities(from: Self.manualOnly)
        #expect(manual?.levels.map(\.id) == ["none", "low", "medium", "high"])
        #expect(manual?.defaultLevelId == "none")
        #expect(AnthropicReasoningContract.capabilities(from: Self.noThinking) == nil)
        #expect(AnthropicReasoningContract.capabilities(from: nil) == nil)
    }

    // MARK: - Wire controls

    @Test func adaptiveModels_defaultToSummarizedAdaptiveThinkingWithoutEffort() {
        for capabilities in [Self.adaptiveWithDisabled, Self.sonnet55, Self.alwaysOn] {
            let controls = AnthropicReasoningContract.wireControls(
                capabilities: capabilities, effort: nil, maxTokens: 4096)
            #expect(controls?.thinking == AnthropicThinkingConfig(type: "adaptive", display: "summarized"))
            #expect(controls?.effort == nil)
            #expect(controls?.isManualThinking == false)
        }
    }

    @Test func adaptiveModels_sendOnlyAdvertisedEfforts() {
        let picked = AnthropicReasoningContract.wireControls(
            capabilities: Self.adaptiveWithDisabled, effort: "XHigh", maxTokens: 4096)
        #expect(picked?.effort == "xhigh")
        #expect(picked?.thinking?.display == "summarized")

        let unadvertised = AnthropicReasoningContract.wireControls(
            capabilities: Self.lowHighOnly, effort: "medium", maxTokens: 4096)
        #expect(unadvertised?.effort == nil)
        #expect(unadvertised?.thinking?.type == "adaptive")
    }

    @Test func offLevel_usesTheModelsOwnOffMode() {
        let disabled = AnthropicReasoningContract.wireControls(
            capabilities: Self.adaptiveWithDisabled, effort: "none", maxTokens: 4096)
        #expect(disabled?.thinking == AnthropicThinkingConfig(type: "disabled"))
        #expect(disabled?.effort == nil)

        let betweenTools = AnthropicReasoningContract.wireControls(
            capabilities: Self.sonnet55, effort: "none", maxTokens: 4096)
        #expect(betweenTools?.thinking == AnthropicThinkingConfig(type: "between_tools"))
        #expect(betweenTools?.thinking?.display == nil, "display is invalid with between_tools")

        let alwaysOn = AnthropicReasoningContract.wireControls(
            capabilities: Self.alwaysOn, effort: "none", maxTokens: 4096)
        #expect(alwaysOn?.thinking?.type == "adaptive", "a model that cannot turn off keeps thinking on")
    }

    @Test func manualOnlyModels_sendBudgetedThinkingOnlyWhenPicked() {
        #expect(
            AnthropicReasoningContract.wireControls(capabilities: Self.manualOnly, effort: nil, maxTokens: 4096)
                == nil
        )
        #expect(
            AnthropicReasoningContract.wireControls(capabilities: Self.manualOnly, effort: "none", maxTokens: 4096)
                == nil
        )
        let medium = AnthropicReasoningContract.wireControls(
            capabilities: Self.manualOnly, effort: "medium", maxTokens: 64_000)
        #expect(medium?.thinking == AnthropicThinkingConfig(type: "enabled", budget_tokens: 8192))
        #expect(medium?.isManualThinking == true)

        let clamped = AnthropicReasoningContract.wireControls(
            capabilities: Self.manualOnly, effort: "high", maxTokens: 4096)
        #expect(clamped?.thinking?.budget_tokens == 2048, "budget stays below max_tokens")

        let tooSmall = AnthropicReasoningContract.wireControls(
            capabilities: Self.manualOnly, effort: "high", maxTokens: 1024)
        #expect(tooSmall == nil, "budget_tokens must be >= 1024 and < max_tokens")
    }

    @Test func unknownCapabilitiesSendNothing() {
        #expect(AnthropicReasoningContract.wireControls(capabilities: nil, effort: "high", maxTokens: 4096) == nil)
        #expect(
            AnthropicReasoningContract.wireControls(capabilities: Self.noThinking, effort: "high", maxTokens: 4096)
                == nil
        )
    }

    // MARK: - Request integration

    @Test func buildChatRequest_wiresThinkingAndEffortFromTheCatalog() async throws {
        let service = Self.makeService()
        let providerId = await service.provider.id
        AnthropicModelCatalog.replace(
            providerId: providerId,
            models: [Self.model("claude-opus-5-5", capabilities: Self.alwaysOn)]
        )
        defer { AnthropicModelCatalog.remove(providerId: providerId) }

        let request = await service.buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: GenerationParameters(
                temperature: 0.7, maxTokens: 8192, modelOptions: ["reasoningEffort": .string("max")]),
            model: "claude-opus-5-5",
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        let anthropic = request.toAnthropicRequest()
        #expect(anthropic.thinking == AnthropicThinkingConfig(type: "adaptive", display: "summarized"))
        #expect(anthropic.output_config == AnthropicOutputConfig(effort: "max"))
        #expect(anthropic.temperature == nil, "thinking rejects temperature changes")

        let payload = try Self.decodeAsDictionary(try JSONEncoder().encode(anthropic))
        let thinking = try #require(payload["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "adaptive")
        #expect(thinking["display"] as? String == "summarized")
        #expect(thinking["budget_tokens"] == nil)
        #expect((payload["output_config"] as? [String: Any])?["effort"] as? String == "max")
    }

    @Test func buildChatRequest_disableThinkingMapsToOff() async {
        let service = Self.makeService()
        let providerId = await service.provider.id
        AnthropicModelCatalog.replace(
            providerId: providerId,
            models: [Self.model("claude-opus-4-8", capabilities: Self.adaptiveWithDisabled)]
        )
        defer { AnthropicModelCatalog.remove(providerId: providerId) }

        let request = await service.buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: GenerationParameters(
                temperature: 0.7, maxTokens: 1024, modelOptions: ["disableThinking": .bool(true)]),
            model: "claude-opus-4-8",
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        let anthropic = request.toAnthropicRequest()
        #expect(anthropic.thinking == AnthropicThinkingConfig(type: "disabled"))
        #expect(anthropic.output_config == nil)
    }

    @Test func buildChatRequest_manualThinkingDowngradesForcedToolChoice() async {
        let service = Self.makeService()
        let providerId = await service.provider.id
        AnthropicModelCatalog.replace(
            providerId: providerId,
            models: [Self.model("claude-sonnet-4-5", capabilities: Self.manualOnly)]
        )
        defer { AnthropicModelCatalog.remove(providerId: providerId) }

        let thinkingRequest = await service.buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: GenerationParameters(
                temperature: 0.7, maxTokens: 16_000, modelOptions: ["reasoningEffort": .string("low")]),
            model: "claude-sonnet-4-5",
            stream: true,
            tools: [Self.weatherTool],
            toolChoice: .required
        )
        #expect(thinkingRequest.tool_choice == .auto)
        #expect(thinkingRequest.toAnthropicRequest().thinking?.budget_tokens == 1024)

        let offRequest = await service.buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: GenerationParameters(temperature: 0.7, maxTokens: 16_000),
            model: "claude-sonnet-4-5",
            stream: true,
            tools: [Self.weatherTool],
            toolChoice: .required
        )
        #expect(offRequest.tool_choice == .required)
        #expect(offRequest.toAnthropicRequest().thinking == nil)
        #expect(offRequest.toAnthropicRequest().temperature == Double(Float(0.7)))
    }

    @Test func samplerKnobs_followTheManualThinkingGeneration() {
        #expect(AnthropicReasoningContract.acceptsSamplerKnobs(Self.adaptiveWithDisabled) == false)
        #expect(AnthropicReasoningContract.acceptsSamplerKnobs(Self.sonnet55) == false)
        #expect(AnthropicReasoningContract.acceptsSamplerKnobs(Self.adaptiveAndManual) == true)
        #expect(AnthropicReasoningContract.acceptsSamplerKnobs(Self.manualOnly) == true)
        #expect(AnthropicReasoningContract.acceptsSamplerKnobs(nil) == nil)
    }

    @Test func buildChatRequest_thinkingOffKeepsSamplersOnlyWhereAccepted() async {
        let service = Self.makeService()
        let providerId = await service.provider.id
        AnthropicModelCatalog.replace(
            providerId: providerId,
            models: [
                Self.model("claude-haiku-5-5", capabilities: Self.adaptiveWithDisabled),
                Self.model("claude-sonnet-4-6", capabilities: Self.adaptiveAndManual),
            ]
        )
        defer { AnthropicModelCatalog.remove(providerId: providerId) }

        func offRequest(_ model: String) async -> AnthropicMessagesRequest {
            await service.buildChatRequest(
                messages: [ChatMessage(role: "user", content: "hi")],
                parameters: GenerationParameters(
                    temperature: 0.7, maxTokens: 1024, modelOptions: ["reasoningEffort": .string("none")]),
                model: model,
                stream: true,
                tools: nil,
                toolChoice: nil
            ).toAnthropicRequest()
        }

        let haiku = await offRequest("claude-haiku-5-5")
        #expect(haiku.thinking == AnthropicThinkingConfig(type: "disabled"))
        #expect(haiku.temperature == nil, "rejected with HTTP 400 even when thinking is off")

        let sonnet46 = await offRequest("claude-sonnet-4-6")
        #expect(sonnet46.thinking == AnthropicThinkingConfig(type: "disabled"))
        #expect(sonnet46.temperature == Double(Float(0.7)))

        let uncatalogued = await offRequest("claude-haiku-5-6")
        #expect(uncatalogued.thinking == nil)
        #expect(uncatalogued.temperature == nil, "uncatalogued models fall back to the family prefix")
    }

    @Test func buildChatRequest_uncataloguedModelSendsNoThinking() async {
        let service = Self.makeService()
        let request = await service.buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: GenerationParameters(
                temperature: 0.7, maxTokens: 1024, modelOptions: ["reasoningEffort": .string("high")]),
            model: "claude-proxy-model",
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        let anthropic = request.toAnthropicRequest()
        #expect(anthropic.thinking == nil)
        #expect(anthropic.output_config == nil)
    }

    // MARK: - Picker enrichment

    @MainActor @Test func remoteModelItems_attachAnthropicContractContextAndLifecycle() throws {
        let providerId = UUID()
        let provider = RemoteProviderManager.CachedProviderModels(
            providerId: providerId,
            providerName: "Anthropic",
            providerType: .anthropic,
            host: "api.anthropic.com",
            models: ["anthropic/claude-sonnet-5-5", "anthropic/claude-opus-4-6", "anthropic/claude-unknown"]
        )
        let infos: [String: AnthropicModelInfo] = [
            "claude-sonnet-5-5": Self.model(
                "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5", capabilities: Self.sonnet55,
                maxInputTokens: 1_000_000),
            "claude-opus-4-6": Self.model(
                "claude-opus-4-6", capabilities: Self.adaptiveWithDisabled, lifecycle: "deprecated"),
        ]

        let result = ModelPickerItemCache.remoteModelItems(
            providers: [provider],
            codexMetadata: [:],
            osaurusRouterProviderId: RemoteProviderManager.osaurusRouterProviderId,
            routerMetadata: { _ in nil },
            anthropicModelInfo: { id, modelId in
                #expect(id == providerId)
                return infos[modelId]
            }
        )
        let byId = Dictionary(uniqueKeysWithValues: result.items.map { ($0.id, $0) })

        let sonnet = try #require(byId["anthropic/claude-sonnet-5-5"])
        #expect(sonnet.displayName == "Claude Sonnet 5.5")
        #expect(sonnet.contextLength == 1_000_000)
        #expect(sonnet.description == nil)
        #expect(
            result.reasoningCapabilities["anthropic/claude-sonnet-5-5"]?.levels.map(\.id)
                == ["none", "low", "medium", "high", "xhigh", "max"]
        )

        #expect(byId["anthropic/claude-opus-4-6"]?.description == "Deprecated")
        #expect(byId["anthropic/claude-unknown"]?.reasoningCapabilities == nil)
        #expect(result.reasoningCapabilities["anthropic/claude-unknown"] == nil)
    }

    // MARK: - Fixtures

    private static func support(_ value: Bool) -> AnthropicCapabilitySupport {
        AnthropicCapabilitySupport(supported: value)
    }

    private static func capabilities(
        adaptive: Bool, enabled: Bool, disabled: Bool, betweenTools: Bool = false,
        efforts: [String] = ["low", "medium", "high", "xhigh", "max"]
    ) -> AnthropicModelCapabilities {
        AnthropicModelCapabilities(
            thinking: .init(
                supported: true,
                types: .init(
                    adaptive: support(adaptive), enabled: support(enabled), disabled: support(disabled),
                    between_tools: support(betweenTools))
            ),
            effort: .init(
                supported: !efforts.isEmpty,
                low: support(efforts.contains("low")),
                medium: support(efforts.contains("medium")),
                high: support(efforts.contains("high")),
                xhigh: support(efforts.contains("xhigh")),
                max: support(efforts.contains("max"))
            )
        )
    }

    /// Opus 4.8-style: adaptive, can be disabled.
    static let adaptiveWithDisabled = capabilities(adaptive: true, enabled: false, disabled: true)
    /// Sonnet 5.5: rejects `disabled`, lowest setting is `between_tools`.
    static let sonnet55 = capabilities(adaptive: true, enabled: false, disabled: false, betweenTools: true)
    /// Opus 5.5 / Fable 5.1: thinking cannot be turned off.
    static let alwaysOn = capabilities(adaptive: true, enabled: false, disabled: false)
    /// 4.6 generation: adaptive plus manual budgets.
    static let adaptiveAndManual = capabilities(
        adaptive: true, enabled: true, disabled: true, efforts: ["low", "medium", "high", "max"])
    static let lowHighOnly = capabilities(
        adaptive: true, enabled: false, disabled: true, efforts: ["low", "high"])
    /// 4.5 generation: manual `enabled` + `budget_tokens` only.
    static let manualOnly = capabilities(
        adaptive: false, enabled: true, disabled: true, efforts: [])
    static let noThinking = AnthropicModelCapabilities(thinking: .init(supported: false), effort: nil)

    private static func model(
        _ id: String,
        displayName: String = "",
        capabilities: AnthropicModelCapabilities?,
        maxInputTokens: Int? = nil,
        lifecycle: String? = "active"
    ) -> AnthropicModelInfo {
        AnthropicModelInfo(
            id: id, display_name: displayName, created_at: "2026-01-01T00:00:00Z",
            capabilities: capabilities, max_input_tokens: maxInputTokens, lifecycle: lifecycle)
    }

    private static func makeService() -> RemoteProviderService {
        RemoteProviderService(
            provider: RemoteProvider(
                name: "Anthropic",
                host: "api.anthropic.com",
                providerProtocol: .https,
                port: nil,
                basePath: "/v1",
                authType: .none,
                providerType: .anthropic
            ),
            models: [],
            resolvedHeaders: [:]
        )
    }

    private static let weatherTool = Tool(
        type: "function",
        function: ToolFunction(
            name: "get_weather",
            description: "Weather",
            parameters: .object(["type": .string("object"), "properties": .object([:])])
        )
    )

    private static func decodeAsDictionary(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
