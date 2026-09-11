//
//  RemoteModelMetadataDecodingTests.swift
//  osaurusTests
//
//  Fixture-driven coverage for the provider-neutral `RemoteModelMetadata`
//  the model picker renders: every decoder must surface only what the
//  provider actually published (nil = no claim), normalize prices to
//  micro-USD per million tokens, and stay lenient about optional shapes.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct RemoteModelMetadataDecodingTests {

    private func makeProvider(
        host: String = "127.0.0.1",
        providerProtocol: RemoteProviderProtocol = .https,
        port: Int? = nil,
        providerType: RemoteProviderType = .openaiLegacy
    ) -> RemoteProvider {
        RemoteProvider(
            name: "Test Provider",
            host: host,
            providerProtocol: providerProtocol,
            port: port,
            basePath: "/v1",
            authType: .none,
            providerType: providerType
        )
    }

    // MARK: - Price conversions

    @Test func priceConversions_normalizeToMicroUSDPerMTok() {
        // OpenRouter: USD per token as a string. $0.0000003/token = $0.30/MTok.
        #expect(RemoteModelMetadata.microPerMTok(fromUSDPerToken: "0.0000003") == 300_000)
        #expect(RemoteModelMetadata.microPerMTok(fromUSDPerToken: "0") == 0)
        #expect(RemoteModelMetadata.microPerMTok(fromUSDPerToken: "-1") == nil)
        #expect(RemoteModelMetadata.microPerMTok(fromUSDPerToken: "nope") == nil)
        #expect(RemoteModelMetadata.microPerMTok(fromUSDPerToken: nil) == nil)

        // Venice: USD per million tokens. $2.50/MTok.
        #expect(RemoteModelMetadata.microPerMTok(fromUSDPerMTok: 2.5) == 2_500_000)
        #expect(RemoteModelMetadata.microPerMTok(fromUSDPerMTok: nil) == nil)

        // xAI: cents per 100M tokens. 20000 => $200 / 100M = $2.00/MTok.
        #expect(RemoteModelMetadata.microPerMTok(fromCentsPer100MTok: 20000) == 2_000_000)
        #expect(RemoteModelMetadata.microPerMTok(fromCentsPer100MTok: nil) == nil)
    }

    @Test func metadata_isEmptyWhenNothingClaimed_andMergeOverlaysKnownFields() {
        let empty = RemoteModelMetadata()
        #expect(empty.isEmpty)

        let base = RemoteModelMetadata(displayName: "Base", contextLength: 8192)
        let overlay = RemoteModelMetadata(contextLength: 32768, supportsToolCalling: true)
        let merged = base.merging(overlay)
        #expect(merged.displayName == "Base")
        #expect(merged.contextLength == 32768)
        #expect(merged.supportsToolCalling == true)
        #expect(merged.supportsVision == nil)

        // Whitespace-only strings and non-positive ints are not claims.
        let noisy = RemoteModelMetadata(displayName: "   ", description: "", contextLength: 0, maxOutputTokens: -5)
        #expect(noisy.isEmpty)
    }

    // MARK: - OpenAI-compatible (OpenRouter shape)

    @Test func openRouterEntry_decodesPricingModalitiesToolsReasoningAndDeprecation() throws {
        let body = Data(
            """
            {
              "data": [
                {
                  "id": "anthropic/claude-sonnet-4",
                  "name": "Anthropic: Claude Sonnet 4",
                  "description": "Balanced model.",
                  "created": 1747000000,
                  "context_length": 200000,
                  "architecture": {"input_modalities": ["text", "image"], "output_modalities": ["text"]},
                  "pricing": {"prompt": "0.000003", "completion": "0.000015"},
                  "supported_parameters": ["tools", "tool_choice", "reasoning", "temperature"],
                  "top_provider": {"max_completion_tokens": 64000}
                },
                {
                  "id": "openai/gpt-3.5-turbo",
                  "deprecation": "2026-01-01",
                  "deprecation_replacement_model": "openai/gpt-4o-mini"
                },
                {"id": "bare-model"}
              ]
            }
            """.utf8
        )

        let discovery = try RemoteProviderService.decodeOpenAICompatibleModelsDiscovery(
            data: body,
            statusCode: 200,
            provider: makeProvider()
        )

        #expect(discovery.models == ["anthropic/claude-sonnet-4", "openai/gpt-3.5-turbo", "bare-model"])

        let sonnet = try #require(discovery.metadata["anthropic/claude-sonnet-4"])
        #expect(sonnet.displayName == "Anthropic: Claude Sonnet 4")
        #expect(sonnet.description == "Balanced model.")
        #expect(sonnet.contextLength == 200_000)
        #expect(sonnet.maxOutputTokens == 64_000)
        #expect(sonnet.supportsVision == true)
        #expect(sonnet.supportsAudioInput == false)
        #expect(sonnet.supportsToolCalling == true)
        #expect(sonnet.supportsReasoning == true)
        #expect(sonnet.inputPriceMicroPerMTok == 3_000_000)
        #expect(sonnet.outputPriceMicroPerMTok == 15_000_000)
        #expect(sonnet.isDeprecated == false)
        #expect(sonnet.created == 1_747_000_000)

        let turbo = try #require(discovery.metadata["openai/gpt-3.5-turbo"])
        #expect(turbo.isDeprecated)
        #expect(turbo.deprecationReplacement == "openai/gpt-4o-mini")
        #expect(turbo.supportsToolCalling == nil)

        // A bare `{ "id": ... }` makes no claims and gets no record at all.
        #expect(discovery.metadata["bare-model"] == nil)
        #expect(discovery.contextLengths == ["anthropic/claude-sonnet-4": 200_000])
    }

    @Test func openAICompatibleEntry_readsMistralCapabilitiesAndReasoningBlock() throws {
        let body = Data(
            """
            {
              "data": [
                {
                  "id": "mistral-large-latest",
                  "max_context_length": 131072,
                  "capabilities": {"function_calling": true, "vision": false, "completion_chat": true}
                },
                {
                  "id": "magistral-medium",
                  "reasoning": {"supported": true},
                  "supported_parameters": []
                },
                {
                  "id": "pricing-as-numbers",
                  "pricing": {"prompt": 0.000001, "completion": 2e-6}
                }
              ]
            }
            """.utf8
        )

        let discovery = try RemoteProviderService.decodeOpenAICompatibleModelsDiscovery(
            data: body,
            statusCode: 200,
            provider: makeProvider()
        )

        let large = try #require(discovery.metadata["mistral-large-latest"])
        #expect(large.supportsToolCalling == true)
        #expect(large.supportsVision == false)
        #expect(large.contextLength == 131_072)
        #expect(large.supportsReasoning == nil)

        let magistral = try #require(discovery.metadata["magistral-medium"])
        #expect(magistral.supportsReasoning == true)
        // Empty supported_parameters is a claim of "no tools".
        #expect(magistral.supportsToolCalling == false)

        // Numeric pricing is accepted alongside OpenRouter's string form.
        let numeric = try #require(discovery.metadata["pricing-as-numbers"])
        #expect(numeric.inputPriceMicroPerMTok == 1_000_000)
        #expect(numeric.outputPriceMicroPerMTok == 2_000_000)
    }

    @Test func openAICompatibleEntry_toleratesUnexpectedShapes() throws {
        // Fields with the wrong type must not fail the whole list.
        let body = Data(
            """
            {
              "data": [
                {"id": "weird", "context_length": "not-a-number", "pricing": "free", "architecture": []},
                {"id": "ok", "context_length": "65536"}
              ]
            }
            """.utf8
        )

        let discovery = try RemoteProviderService.decodeOpenAICompatibleModelsDiscovery(
            data: body,
            statusCode: 200,
            provider: makeProvider()
        )
        #expect(discovery.models == ["weird", "ok"])
        #expect(discovery.metadata["weird"] == nil)
        #expect(discovery.metadata["ok"]?.contextLength == 65_536)
    }

    // MARK: - Venice

    @Test func veniceTextRecord_decodesSpecCapabilitiesPricingAndTraits() throws {
        let body = Data(
            """
            {
              "data": [
                {
                  "id": "llama-3.3-70b",
                  "type": "text",
                  "created": 1733768349,
                  "context_length": 65536,
                  "model_spec": {
                    "name": "Llama 3.3 70B",
                    "description": "Venice default.",
                    "availableContextTokens": 65536,
                    "maxCompletionTokens": 8192,
                    "capabilities": {
                      "supportsFunctionCalling": true,
                      "supportsVision": false,
                      "supportsReasoning": false,
                      "quantization": "fp8"
                    },
                    "pricing": {"input": {"usd": 0.7, "diem": 0.007}, "output": {"usd": 2.8, "diem": 0.028}},
                    "traits": ["default", "function_calling_default"]
                  }
                },
                {
                  "id": "hosted-model",
                  "type": "text",
                  "model_spec": {"capabilities": {"quantization": "not-available"}}
                },
                {
                  "id": "venice-sd35",
                  "type": "image",
                  "model_spec": {"constraints": {"aspect_ratios": ["1:1"]}}
                }
              ]
            }
            """.utf8
        )

        let discovery = try VeniceModelDiscovery.decode(body, providerID: UUID(), providerName: "Venice")
        #expect(Set(discovery.chatModelIDs) == ["llama-3.3-70b", "hosted-model"])

        let llama = try #require(discovery.chatMetadata["llama-3.3-70b"])
        #expect(llama.displayName == "Llama 3.3 70B")
        #expect(llama.description == "Venice default.")
        #expect(llama.contextLength == 65_536)
        #expect(llama.maxOutputTokens == 8192)
        #expect(llama.supportsToolCalling == true)
        #expect(llama.supportsVision == false)
        #expect(llama.supportsReasoning == false)
        #expect(llama.supportsAudioInput == nil)
        #expect(llama.quantization == "fp8")
        #expect(llama.inputPriceMicroPerMTok == 700_000)
        #expect(llama.outputPriceMicroPerMTok == 2_800_000)
        #expect(llama.recommendedReason == "Venice default")
        #expect(llama.created == 1_733_768_349)

        // "not-available" quantization is not a claim; with nothing else the
        // record is omitted entirely.
        #expect(discovery.chatMetadata["hosted-model"] == nil)
        // Image records feed the media catalog, never chat metadata.
        #expect(discovery.chatMetadata["venice-sd35"] == nil)
    }

    @Test func veniceTraits_mapToASingleRecommendedReason() {
        #expect(VeniceModelRecord.recommendedReason(fromTraits: ["default"]) == "Venice default")
        #expect(VeniceModelRecord.recommendedReason(fromTraits: ["MOST_INTELLIGENT"]) == "Venice: most intelligent")
        #expect(VeniceModelRecord.recommendedReason(fromTraits: ["fastest"]) == "Venice: fastest")
        #expect(VeniceModelRecord.recommendedReason(fromTraits: ["default_code"]) == "Venice default for code")
        // `default` wins over weaker traits.
        #expect(VeniceModelRecord.recommendedReason(fromTraits: ["fastest", "default"]) == "Venice default")
        #expect(VeniceModelRecord.recommendedReason(fromTraits: ["function_calling_default"]) == nil)
        #expect(VeniceModelRecord.recommendedReason(fromTraits: []) == nil)
    }

    // MARK: - Anthropic

    @Test func anthropicModelInfo_exposesOnlyDisplayName() throws {
        let body = Data(
            """
            {
              "data": [
                {"id": "claude-opus-4-1", "display_name": "Claude Opus 4.1", "created_at": "2025-08-05T00:00:00Z", "type": "model"}
              ],
              "has_more": false,
              "first_id": "claude-opus-4-1",
              "last_id": "claude-opus-4-1"
            }
            """.utf8
        )
        let response = try JSONDecoder().decode(AnthropicModelsResponse.self, from: body)
        let info = try #require(response.data.first)
        let metadata = info.pickerMetadata
        #expect(metadata.displayName == "Claude Opus 4.1")
        // Anthropic's list route publishes none of these; they must stay unknown.
        #expect(metadata.contextLength == nil)
        #expect(metadata.supportsVision == nil)
        #expect(metadata.supportsToolCalling == nil)
        #expect(metadata.inputPriceMicroPerMTok == nil)
    }

    // MARK: - Gemini

    @Test func geminiModelInfo_exposesDisplayNameDescriptionAndTokenLimits() throws {
        let body = Data(
            """
            {
              "models": [
                {
                  "name": "models/gemini-2.5-pro",
                  "displayName": "Gemini 2.5 Pro",
                  "description": "Most capable.",
                  "inputTokenLimit": 1048576,
                  "outputTokenLimit": 65536,
                  "supportedGenerationMethods": ["generateContent"]
                },
                {"name": "models/embedding-001", "supportedGenerationMethods": ["embedContent"]}
              ]
            }
            """.utf8
        )
        let response = try JSONDecoder().decode(GeminiModelsResponse.self, from: body)
        let models = try #require(response.models)
        let pro = try #require(models.first)
        #expect(pro.modelId == "gemini-2.5-pro")
        let metadata = pro.pickerMetadata
        #expect(metadata.displayName == "Gemini 2.5 Pro")
        #expect(metadata.description == "Most capable.")
        #expect(metadata.contextLength == 1_048_576)
        #expect(metadata.maxOutputTokens == 65_536)
        #expect(metadata.supportsVision == nil)
        #expect(metadata.supportsToolCalling == nil)

        #expect(models[1].pickerMetadata.isEmpty)
    }

    // MARK: - xAI language-models

    @Test func xaiLanguageModels_decodePricesModalitiesAndAliases() {
        let body = Data(
            """
            {
              "models": [
                {
                  "id": "grok-4",
                  "aliases": ["grok-4-latest"],
                  "input_modalities": ["text", "image"],
                  "output_modalities": ["text"],
                  "prompt_text_token_price": 30000,
                  "completion_text_token_price": 150000,
                  "created": 1752000000
                },
                {"id": "grok-empty"}
              ]
            }
            """.utf8
        )

        let metadata = RemoteProviderService.decodeXAILanguageModelsMetadata(body)
        let grok = metadata["grok-4"]
        #expect(grok?.supportsVision == true)
        #expect(grok?.supportsAudioInput == false)
        // 30000 cents per 100M tokens = $300 / 100M = $3.00/MTok.
        #expect(grok?.inputPriceMicroPerMTok == 3_000_000)
        #expect(grok?.outputPriceMicroPerMTok == 15_000_000)
        #expect(grok?.created == 1_752_000_000)
        // Aliases are selectable ids on /models too, so they share the card.
        #expect(metadata["grok-4-latest"] == grok)
        #expect(metadata["grok-empty"] == nil)
    }

    @Test func xaiLanguageModels_malformedBodyYieldsNothing() {
        #expect(RemoteProviderService.decodeXAILanguageModelsMetadata(Data("not json".utf8)).isEmpty)
        #expect(RemoteProviderService.decodeXAILanguageModelsMetadata(Data("{\"models\": {}}".utf8)).isEmpty)
    }

    // MARK: - Ollama tags

    @Test func ollamaTags_decodeParameterSizeAndQuantization_forTaggedAndBareNames() {
        let body = Data(
            """
            {
              "models": [
                {
                  "name": "llama3.2:3b",
                  "model": "llama3.2:3b",
                  "size": 2019393189,
                  "details": {"family": "llama", "parameter_size": "3.2B", "quantization_level": "Q4_K_M"}
                },
                {"name": "no-details:latest"}
              ]
            }
            """.utf8
        )

        let metadata = RemoteProviderService.decodeOllamaTagsMetadata(body)
        let tagged = metadata["llama3.2:3b"]
        #expect(tagged?.parameterCount == "3.2B")
        #expect(tagged?.quantization == "Q4_K_M")
        // The bare name (without the tag) is also how /v1/models can list it.
        #expect(metadata["llama3.2"] == tagged)
        #expect(metadata["no-details:latest"] == nil)
        #expect(metadata["no-details"] == nil)
    }

    @Test func ollamaTags_malformedBodyYieldsNothing() {
        #expect(RemoteProviderService.decodeOllamaTagsMetadata(Data("[]".utf8)).isEmpty)
        #expect(RemoteProviderService.decodeOllamaTagsMetadata(Data("{}".utf8)).isEmpty)
    }
}
