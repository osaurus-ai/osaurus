//
//  WebSearchToolTests.swift
//  OsaurusCoreTests
//
//  Tool-surface contracts for native search: `web_search` is an always-loaded
//  built-in (and part of the Default-agent baseline) whose schema is immutable
//  by design — `category` is an open string with no provider-derived enum, so
//  the advertised schema never depends on which providers are configured.
//  `search_and_extract` is a dynamic native tool, the per-agent
//  `webSearchEnabled` gate strips both tools in `resolveTools` (while loaded
//  tools survive), and the weak-caller argument sanitizers never fail a call
//  over a malformed value.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct WebSearchToolTests {

    // MARK: - Registration

    @Test func webSearchIsAnAlwaysLoadedBuiltIn() {
        let registry = ToolRegistry.shared
        #expect(registry.registeredToolNames().contains("web_search"))
        #expect(registry.builtInToolNames.contains("web_search"))
        #expect(ToolRegistry.defaultAgentAllowedToolNames.contains("web_search"))
    }

    @Test func searchAndExtractIsADynamicNativeTool() {
        let registry = ToolRegistry.shared
        #expect(registry.registeredToolNames().contains("search_and_extract"))
        // Dynamic: registered but NOT part of the always-loaded baseline.
        #expect(!registry.builtInToolNames.contains("search_and_extract"))
        #expect(!ToolRegistry.defaultAgentAllowedToolNames.contains("search_and_extract"))
    }

    @Test func webSearchContractExplainsDiscoveryToRetrievalTransition() {
        let description = WebSearchTool().description
        #expect(description.contains("does not fetch page bodies"))
        #expect(description.contains("search_and_extract"))
        #expect(description.contains("tool/search_and_extract"))
    }

    @Test func searchAndExtractContractProvidesPageContent() {
        let tool = SearchAndExtractTool()
        let description = tool.description
        #expect(description.contains("actual page text or data"))
        #expect(description.contains("pass the selected result's URL"))
        guard case .object(let root)? = tool.parameters,
            case .object(let properties)? = root["properties"]
        else {
            Issue.record("missing search_and_extract object schema")
            return
        }
        #expect(properties["url"] != nil)
        #expect(properties["urls"] != nil)
    }

    @Test func allFailedExtractionsAreAnHonestToolFailure() throws {
        let envelope = SearchAndExtractTool.extractionEnvelope(
            payload: [
                "mode": "direct_url",
                "provider": "direct_url",
                "results": [
                    [
                        "url": "https://huggingface.co/OsaurusAI/models",
                        "extracted": false,
                        "extract_status": "challenge",
                        "extract_error": "challenge_page",
                    ],
                    [
                        "url": "https://huggingface.co/dealignai/models",
                        "extracted": false,
                        "extract_status": "challenge",
                        "extract_error": "challenge_page",
                    ],
                    [
                        "url": "https://huggingface.co/JANGQ-AI/models",
                        "extracted": false,
                        "extract_status": "challenge",
                        "extract_error": "challenge_page",
                    ],
                ],
            ]
        )

        #expect(ToolEnvelope.isError(envelope))
        #expect(envelope.contains("No page content was retrieved"))
        #expect(envelope.contains("do not claim these pages were read"))

        let data = try #require(envelope.data(using: .utf8))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["retryable"] as? Bool == false)
        #expect(object["extracted_count"] as? Int == 0)
        #expect(object["extraction_failed_count"] as? Int == 3)
        #expect((object["results"] as? [[String: Any]])?.count == 3)
    }

    @Test func partialExtractionSuccessPreservesCountsAndResults() throws {
        let envelope = SearchAndExtractTool.extractionEnvelope(
            payload: [
                "mode": "search_and_extract",
                "provider": "test",
                "results": [
                    [
                        "url": "https://example.com/one",
                        "extracted": true,
                        "extract_status": "ok",
                        "markdown": "retrieved body",
                    ],
                    [
                        "url": "https://example.com/two",
                        "extracted": false,
                        "extract_status": "timeout",
                    ],
                    [
                        "url": "https://example.com/not-attempted",
                        "extracted": false,
                    ],
                ],
            ]
        )

        #expect(ToolEnvelope.isSuccess(envelope))
        let payload = try #require(ToolEnvelope.successPayload(envelope) as? [String: Any])
        #expect(payload["extraction_attempted_count"] as? Int == 2)
        #expect(payload["extracted_count"] as? Int == 1)
        #expect(payload["extraction_failed_count"] as? Int == 1)
        #expect((payload["results"] as? [[String: Any]])?.count == 3)
    }

    @Test func allTimeoutExtractionsRemainRetryableAndPreserveMetadata() throws {
        let envelope = SearchAndExtractTool.extractionEnvelope(
            payload: [
                "mode": "search_and_extract",
                "provider": "local",
                "query": "models for coding",
                "category": "web",
                "search_source": "local",
                "premium_fallback": true,
                "next_offset": 5,
                "results": [
                    [
                        "url": "https://example.com/slow",
                        "extracted": false,
                        "extract_status": "timeout",
                    ],
                ],
            ],
            warnings: ["test warning"]
        )

        let data = try #require(envelope.data(using: .utf8))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["ok"] as? Bool == false)
        #expect(object["kind"] as? String == ToolEnvelope.Kind.timeout.rawValue)
        #expect(object["retryable"] as? Bool == true)
        #expect(object["query"] as? String == "models for coding")
        #expect(object["category"] as? String == "web")
        #expect(object["search_source"] as? String == "local")
        #expect(object["premium_fallback"] as? Bool == true)
        #expect(object["next_offset"] as? Int == 5)
        #expect(object["warnings"] as? [String] == ["test warning"])
    }

    @Test func fetchFailureIsRetryableButNotMislabeledAsTimeout() throws {
        let envelope = SearchAndExtractTool.extractionEnvelope(
            payload: [
                "mode": "direct_url",
                "provider": "direct_url",
                "results": [
                    [
                        "url": "https://example.com/offline",
                        "extracted": false,
                        "extract_status": "fetch_failed",
                    ],
                ],
            ]
        )

        let data = try #require(envelope.data(using: .utf8))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["kind"] as? String == ToolEnvelope.Kind.executionError.rawValue)
        #expect(object["retryable"] as? Bool == true)
    }

    @Test func cancellationIsNotPresentedAsARequestToRetry() throws {
        let envelope = SearchAndExtractTool.extractionEnvelope(
            payload: [
                "mode": "direct_url",
                "provider": "direct_url",
                "results": [
                    [
                        "url": "https://example.com/cancelled",
                        "extracted": false,
                        "extract_status": "cancelled",
                    ],
                ],
            ]
        )

        let data = try #require(envelope.data(using: .utf8))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["retryable"] as? Bool == false)
    }

    // MARK: - Immutable schema contract

    private func categoryProperty(of tool: WebSearchTool) -> [String: JSONValue]? {
        guard case .object(let root)? = tool.parameters,
            case .object(let properties)? = root["properties"],
            case .object(let category)? = properties["category"]
        else { return nil }
        return category
    }

    /// `web_search` is an always-loaded baseline tool: its schema sits in the
    /// static prompt prefix of every compose. `category` must always be
    /// advertised, as an open string with NO provider-derived enum — an enum
    /// that tracked configured providers would flip the schema bytes when the
    /// background Keychain probe lands (or on any settings edit) and
    /// invalidate the KV-cache prefix for the whole conversation.
    @Test func categoryIsAlwaysAdvertisedAsAnOpenString() throws {
        let category = try #require(categoryProperty(of: WebSearchTool()))
        #expect(category["enum"] == nil)
        guard case .string(let type)? = category["type"] else {
            Issue.record("category must be typed as a string")
            return
        }
        #expect(type == "string")
        // Custom provider categories stay expressible: the description names
        // the built-ins and the open-ended contract, not a closed list.
        guard case .string(let description)? = category["description"] else {
            Issue.record("category must carry a description")
            return
        }
        #expect(description.contains("web"))
        #expect(description.contains("news"))
        #expect(description.contains("images"))
        #expect(description.contains("fall back to web"))
    }

    /// The full schema must be byte-stable regardless of provider
    /// availability: identical canonical payloads across fresh instances,
    /// repeated reads, and the registry-registered spec.
    @Test func schemaBytesDoNotDependOnProviderAvailability() throws {
        func canonicalBytes(_ parameters: JSONValue?) throws -> Data {
            let tool = Tool(
                type: "function",
                function: ToolFunction(
                    name: "web_search",
                    description: "probe",
                    parameters: parameters
                )
            )
            return try JSONSerialization.data(
                withJSONObject: tool.toTokenizerToolSpec(),
                options: [.sortedKeys]
            )
        }
        // Two fresh instances and two reads of the same instance agree —
        // there is no hidden state feeding the schema anymore.
        let tool = WebSearchTool()
        #expect(tool.parameters == tool.parameters)
        #expect(try canonicalBytes(WebSearchTool().parameters) == canonicalBytes(tool.parameters))
        // The registry-registered spec carries the same immutable payload.
        let registered = try #require(
            ToolRegistry.shared.specs(forTools: ["web_search"]).first
        )
        #expect(registered.function.parameters == tool.parameters)
    }

    // MARK: - Agent gating in resolveTools

    private static func makeSnapshot(
        webSearchEnabled: Bool,
        renderChartEnabled: Bool = false
    ) -> AgentConfigSnapshot {
        AgentConfigSnapshot(
            agentId: UUID(),
            toolsDisabled: false,
            memoryDisabled: false,
            autonomousConfig: nil,
            toolMode: .auto,
            model: nil,
            manualToolNames: nil,
            systemPrompt: "",
            dbEnabled: false,
            renderChartEnabled: renderChartEnabled,
            webSearchEnabled: webSearchEnabled
        )
    }

    @Test func webSearchPresentForCustomAgentByDefault() {
        let tools = SystemPromptComposer.resolveTools(
            snapshot: Self.makeSnapshot(webSearchEnabled: true),
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        #expect(names.contains("web_search"))
        #expect(!names.contains("search_and_extract"))
    }

    @Test func chartAndWebExposeRetrievalOnTheFirstTurn() {
        let tools = SystemPromptComposer.resolveTools(
            snapshot: Self.makeSnapshot(
                webSearchEnabled: true,
                renderChartEnabled: true
            ),
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        #expect(names.contains("web_search"))
        #expect(names.contains("search_and_extract"))
        #expect(names.contains("render_chart"))
    }

    @Test func disablingWebSearchStripsBothTools() {
        let tools = SystemPromptComposer.resolveTools(
            snapshot: Self.makeSnapshot(webSearchEnabled: false),
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        #expect(!names.contains("web_search"))
        #expect(!names.contains("search_and_extract"))
    }

    @Test func loadedToolsSurviveTheDisableGate() {
        // A tool the session already loaded mid-conversation must not vanish
        // from the schema when the toggle is off (mirrors search_memory).
        let tools = SystemPromptComposer.resolveTools(
            snapshot: Self.makeSnapshot(webSearchEnabled: false),
            executionMode: .none,
            additionalToolNames: ["web_search"]
        )
        let names = Set(tools.map { $0.function.name })
        #expect(names.contains("web_search"))
        #expect(!names.contains("search_and_extract"))
    }

    // MARK: - Weak-caller argument sanitization

    @Test func timeRangeVariantsNormalize() {
        var warnings: [String] = []
        #expect(WebSearchArgs.sanitizeTimeRange("week", warnings: &warnings) == "w")
        #expect(WebSearchArgs.sanitizeTimeRange("D", warnings: &warnings) == "d")
        #expect(WebSearchArgs.sanitizeTimeRange(" month ", warnings: &warnings) == "m")
        #expect(WebSearchArgs.sanitizeTimeRange("year", warnings: &warnings) == "y")
        #expect(warnings.isEmpty)
        #expect(WebSearchArgs.sanitizeTimeRange("fortnight", warnings: &warnings) == nil)
        #expect(warnings.count == 1)
        // Absent / non-string values are silently nil, not warned.
        warnings = []
        #expect(WebSearchArgs.sanitizeTimeRange(nil, warnings: &warnings) == nil)
        #expect(WebSearchArgs.sanitizeTimeRange(7, warnings: &warnings) == nil)
        #expect(warnings.isEmpty)
    }

    @Test func unknownCategoryFallsBackToWebWithWarning() {
        var warnings: [String] = []
        let available = ["web", "news"]
        #expect(
            WebSearchArgs.sanitizeCategory("news", available: available, warnings: &warnings)
                == "news"
        )
        #expect(warnings.isEmpty)
        // Synonyms local models produce map onto available categories.
        #expect(
            WebSearchArgs.sanitizeCategory("articles", available: available, warnings: &warnings)
                == "news"
        )
        #expect(warnings.isEmpty)
        // Unknown category: fall back to web + warning, never an error.
        #expect(
            WebSearchArgs.sanitizeCategory("videos", available: available, warnings: &warnings)
                == "web"
        )
        #expect(warnings.count == 1)
        // Synonym for an UNAVAILABLE category also falls back.
        warnings = []
        #expect(
            WebSearchArgs.sanitizeCategory("photos", available: available, warnings: &warnings)
                == "web"
        )
        #expect(warnings.count == 1)
    }

    @Test func regionValidatesXxYyFormat() {
        var warnings: [String] = []
        #expect(WebSearchArgs.sanitizeRegion("US-EN", warnings: &warnings) == "us-en")
        #expect(warnings.isEmpty)
        #expect(WebSearchArgs.sanitizeRegion("america", warnings: &warnings) == nil)
        #expect(warnings.count == 1)
    }

    @Test func snippetsAreTruncatedInThePayload() {
        let longSnippet = String(repeating: "a", count: 1000)
        let outcome = SearchEngineOutcome(
            hits: [
                SearchHit(title: "T", url: "https://x.example", snippet: longSnippet, engine: "e")
            ],
            provider: "e",
            attempts: []
        )
        let payload = WebSearchResultFormatter.resultsPayload(
            request: SearchRequest(query: "q"),
            outcome: outcome
        )
        let results = payload["results"] as? [[String: Any]]
        let snippet = results?.first?["snippet"] as? String
        #expect((snippet?.count ?? 0) <= WebSearchResultFormatter.maxSnippetLength + 1)
        let nextAction = payload["next_action"] as? [String: Any]
        #expect((nextAction?["tool"] as? String) == "search_and_extract")
        #expect((nextAction?["instruction"] as? String)?.contains("Do not rephrase") == true)
        #expect((nextAction?["candidate_urls"] as? [String]) == ["https://x.example"])
    }

    @Test func noResultsHintDependsOnProviderConfiguration() {
        let withProvider = WebSearchResultFormatter.noResultsHint(hasConfiguredAPIProvider: true)
        let without = WebSearchResultFormatter.noResultsHint(hasConfiguredAPIProvider: false)
        #expect(withProvider.contains("API keys"))
        #expect(without.contains("add a search provider"))
    }
}
