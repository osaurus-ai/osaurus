//
//  ActivityEmitterTests.swift
//  osaurusTests
//
//  Pure builders behind the activity-log emitters: web search, URL extract,
//  MCP tool calls, channel deliveries, Router control-plane calls, and the
//  inference egress / privacy-outcome merge.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Activity emitters")
struct ActivityEmitterTests {

    // MARK: - Web search

    @Test func searchEgressNamesProviderQueryAndFailures() {
        let request = SearchRequest(query: "osaurus audit log", site: "github.com", timeRange: "w")
        let outcome = SearchEngineOutcome(
            hits: [
                SearchHit(title: "a", url: "https://a.example/1", snippet: "", engine: "tavily"),
                SearchHit(title: "b", url: "https://b.example/2", snippet: "", engine: "tavily"),
            ],
            provider: "tavily",
            attempts: [
                SearchAttempt(provider: "osaurus_router", ok: false, kind: .network, error: "offline"),
                SearchAttempt(provider: "tavily", ok: true, count: 2),
            ],
            elapsed: 0.8
        )
        let egress = SearchActivityLogger.searchEgress(
            request: request, outcome: outcome, hostedSource: .custom, hostedFallbackReason: "unavailable",
            pinned: false, hostFor: { $0 == "tavily" ? "api.tavily.com" : nil })
        #expect(egress.destinationHost == "api.tavily.com")
        #expect(egress.destinationLabel == "Tavily")
        #expect(egress.dataClasses == ["search_query"])
        #expect(egress.details["query"] == "osaurus audit log")
        #expect(egress.details["provider_used"] == "tavily")
        #expect(egress.details["providers_tried"] == "osaurus_router, tavily")
        #expect(egress.details["hit_count"] == "2")
        #expect(egress.details["site"] == "github.com")
        #expect(egress.details["time_range"] == "w")
        #expect(egress.details["source"] == "custom")
        #expect(egress.details["hosted_fallback"] == "unavailable")
        #expect(egress.details["failures"] == "osaurus_router: offline")
        #expect(egress.details["result_preview"] == "https://a.example/1\nhttps://b.example/2")
        #expect(egress.details["pinned_test"] == nil)
        #expect(egress.bytesSent == "osaurus audit log".utf8.count + "github.com".utf8.count + 1)
    }

    @Test func searchEgressWithNoHitsStillNamesFirstDestination() {
        let outcome = SearchEngineOutcome(
            hits: [], provider: nil,
            attempts: [SearchAttempt(provider: "ddg", ok: false, kind: .challenge, error: "captcha")])
        let egress = SearchActivityLogger.searchEgress(
            request: SearchRequest(query: "x"), outcome: outcome, hostedSource: nil, hostedFallbackReason: nil,
            pinned: true, hostFor: { _ in "html.duckduckgo.com" })
        #expect(egress.destinationHost == "html.duckduckgo.com")
        #expect(egress.destinationLabel == "DuckDuckGo")
        #expect(egress.details["pinned_test"] == "true")
        #expect(egress.details["provider_used"] == nil)
        #expect(egress.details["result_preview"] == nil)
    }

    @Test func nativeAndDeclarativeHosts() {
        let ddg = SearchProviderDefinition(id: "ddg", name: "DuckDuckGo", runtime: .native)
        #expect(SearchActivityLogger.host(for: ddg, category: "web") == "html.duckduckgo.com")
        var decl = SearchProviderDefinition(id: "exa", name: "Exa", runtime: .declarative)
        decl.endpoints = [
            "web": SearchEndpoint(
                url: "https://api.exa.ai/search", method: "POST",
                response: SearchResponseMapping(resultsPath: "results", item: SearchHitFieldPaths()))
        ]
        #expect(SearchActivityLogger.host(for: decl, category: "web") == "api.exa.ai")
        #expect(SearchActivityLogger.host(for: decl, category: "news") == "api.exa.ai")
    }

    // MARK: - URL extract

    @Test func hostedExtractEgressListsURLsAndFailures() {
        let outcome = HostedContentsOutcome(
            pages: [
                .init(url: "https://a.example", title: "A", text: "hello world", succeeded: true, error: nil),
                .init(url: "https://b.example", title: nil, text: nil, succeeded: false, error: "403"),
            ],
            billing: nil, replayed: false)
        let egress = SearchActivityLogger.hostedExtractEgress(
            urls: ["https://a.example", "https://b.example"], outcome: outcome, failureReason: nil)
        #expect(egress.destinationHost == SearchActivityLogger.hostedHost)
        #expect(egress.dataClasses == ["urls"])
        #expect(egress.details["mode"] == "hosted")
        #expect(egress.details["url_count"] == "2")
        #expect(egress.details["succeeded"] == "1")
        #expect(egress.details["failures"] == "https://b.example: 403")
        #expect(egress.bytesReceived == "hello world".utf8.count)
    }

    @Test func directExtractEgressUsesPageHost() {
        let extraction = SearchReadability.Extraction(
            markdown: "x", wordCount: 120, title: "Doc", byline: nil, lang: nil,
            canonicalURL: "https://docs.example/page/", status: .ok, truncated: false, message: nil,
            totalWordCount: nil, structuredData: nil, structuredFormat: nil)
        let egress = SearchActivityLogger.directExtractEgress(
            url: "https://docs.example/page", extraction: extraction, bytesReceived: 4096)
        #expect(egress.destinationHost == "docs.example")
        #expect(egress.destinationLabel == "docs.example")
        #expect(egress.details["mode"] == "direct")
        #expect(egress.details["title"] == "Doc")
        #expect(egress.details["canonical_url"] == "https://docs.example/page/")
        #expect(egress.details["word_count"] == "120")
        #expect(egress.bytesReceived == 4096)
    }

    // MARK: - MCP

    @Test func mcpHTTPCallIsRemoteWithServerHost() {
        var provider = MCPProvider(name: "Linear", url: "https://mcp.linear.app/sse")
        provider.transport = .http
        #expect(MCPActivityLogger.locality(for: provider) == .remote)
        let egress = MCPActivityLogger.egress(
            provider: provider, toolName: "list_issues", exposedToolName: "linear_list_issues",
            recordedArguments: #"{"team":"ENG"}"#, resultPreview: "[...]", bytesReceived: 5)
        #expect(egress.destinationHost == "mcp.linear.app")
        #expect(egress.destinationLabel == "Linear")
        #expect(egress.dataClasses == ["tool_arguments"])
        #expect(egress.details["server"] == "Linear")
        #expect(egress.details["tool"] == "list_issues")
        #expect(egress.details["exposed_as"] == "linear_list_issues")
        #expect(egress.details["arguments"] == #"{"team":"ENG"}"#)
        #expect(egress.details["transport"] == "http")
        #expect(egress.bytesSent == #"{"team":"ENG"}"#.utf8.count)
    }

    @Test func mcpStdioCallIsLocalWithoutHost() {
        var provider = MCPProvider(name: "fs", url: "")
        provider.transport = .stdio
        provider.command = "npx"
        #expect(MCPActivityLogger.locality(for: provider) == .local)
        let egress = MCPActivityLogger.egress(
            provider: provider, toolName: "read", exposedToolName: nil,
            recordedArguments: "{}", resultPreview: nil, bytesReceived: nil)
        #expect(egress.destinationHost == nil)
        #expect(egress.details["command"] == "npx")
        #expect(egress.details["execution_host"] == provider.executionHost.rawValue)
        #expect(egress.details["exposed_as"] == nil)
    }

    // MARK: - Channels

    @Test func channelDeliveryIsMetadataOnly() {
        let connection = AgentChannelConnection(id: "slack", name: "Team Slack", kind: .slack)
        let binding = AgentChannelBinding(
            id: "ops", agentId: UUID(), connectionId: "slack", roomId: "C123", threadId: "171.1", label: "Ops")
        let egress = AgentChannelPublishService.channelDeliveryEgress(
            connection: connection, binding: binding, contentLength: 42, intentId: "intent-1",
            runSource: "schedule", outcome: "sent", providerMessageId: "msg-9", error: nil)
        #expect(egress.destinationHost == "slack.com")
        #expect(egress.destinationLabel == "Slack")
        #expect(egress.bytesSent == 42)
        #expect(egress.dataClasses == ["channel_message"])
        #expect(egress.details["room"] == "C123")
        #expect(egress.details["thread"] == "171.1")
        #expect(egress.details["outcome"] == "sent")
        #expect(egress.details["provider_message_id"] == "msg-9")
        #expect(egress.details["run_source"] == "schedule")
        #expect(egress.details["content_length"] == "42")
        // Message text never reaches the activity row.
        #expect(!egress.details.values.contains { $0.contains("hello") })
    }

    @Test func channelDeliveryUnknownConnectionFallsBackToBindingId() {
        let binding = AgentChannelBinding(
            id: "b", agentId: UUID(), connectionId: "gone", roomId: "r", label: "L")
        let egress = AgentChannelPublishService.channelDeliveryEgress(
            connection: nil, binding: binding, contentLength: 1, intentId: "i",
            runSource: nil, outcome: "failed", providerMessageId: nil, error: "boom")
        #expect(egress.destinationHost == nil)
        #expect(egress.destinationLabel == "gone")
        #expect(egress.details["channel"] == "unknown")
        #expect(egress.details["error"] == "boom")
    }

    // MARK: - Router control plane

    @Test func routerSkipsHostedSearchPaths() {
        #expect(!OsaurusRouterAPIClient.shouldLogControlPlaneCall(path: "/v1/search"))
        #expect(!OsaurusRouterAPIClient.shouldLogControlPlaneCall(path: "/v1/contents"))
        #expect(OsaurusRouterAPIClient.shouldLogControlPlaneCall(path: "/v1/credits/balance"))
        #expect(OsaurusRouterAPIClient.shouldLogControlPlaneCall(path: nil))
    }

    @Test func routerPurposeIsPlainLanguage() {
        #expect(OsaurusRouterAPIClient.controlPlanePurpose(path: "/v1/workspaces/abc/invites") == "Workspaces")
        #expect(OsaurusRouterAPIClient.controlPlanePurpose(path: "/v1/credits/balance") == "Credits")
        #expect(OsaurusRouterAPIClient.controlPlanePurpose(path: "/v1/media/jobs/1") == "Media generation")
        #expect(OsaurusRouterAPIClient.controlPlanePurpose(path: "/v1/pair-invite") == "Secure channel pairing")
        #expect(OsaurusRouterAPIClient.controlPlanePurpose(path: "/v1/something") == "Router control plane")
    }

    // MARK: - Inference egress

    @Test func inferenceEgressOnlyForRemoteConnections() {
        #expect(InsightsService.inferenceEgress(connection: nil, requestBody: "{}") == nil)
        let local = RequestConnectionInfo(transport: .local, mode: .local)
        #expect(InsightsService.inferenceEgress(connection: local, requestBody: "{}") == nil)
        let remote = RequestConnectionInfo(
            remoteEndpoint: "https://api.anthropic.com/v1/messages", transport: .direct, mode: .remoteInference)
        let egress = InsightsService.inferenceEgress(
            connection: remote, requestBody: #"{"messages":[],"tools":[{"x":1}],"image_url":"..."}"#)
        #expect(egress?.destinationHost == "api.anthropic.com")
        #expect(egress?.destinationLabel == "Anthropic")
        #expect(egress?.dataClasses == ["prompt", "tools", "attachments"])
    }

    @Test func privacyOutcomeFlowsThroughLogInference() async throws {
        let model = "privacy-probe-\(UUID().uuidString)"
        let remote = RequestConnectionInfo(
            remoteEndpoint: "https://api.openai.com/v1/chat/completions", transport: .direct, mode: .remoteInference)
        InsightsService.logInference(
            source: .agent, model: model, inputTokens: 1, outputTokens: 1, durationMs: 1,
            temperature: nil, maxTokens: 1, requestBody: "{}",
            wireRequestBody: Data(repeating: 0x41, count: 321),
            connection: remote,
            privacy: WireTransportProbe.PrivacyOutcome(applied: true, redactedCount: 3),
            agentName: "Probe Agent"
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        let row = try #require(await MainActor.run { InsightsService.shared.logs.first { $0.model == model } })
        #expect(row.locality == .remote)
        #expect(row.category == .inference)
        #expect(row.source == .agent)
        #expect(row.agentName == "Probe Agent")
        #expect(row.egress?.privacyFilterApplied == true)
        #expect(row.egress?.redactedSpanCount == 3)
        #expect(row.egress?.bytesSent == 321)
        #expect(row.egress?.destinationLabel == "OpenAI")
    }

    @Test func wireProbeRecordsPrivacyOutcome() {
        let probe = WireTransportProbe()
        #expect(probe.privacyOutcome == nil)
        probe.recordPrivacyFilter(applied: true, redactedCount: 2)
        #expect(probe.privacyOutcome == .init(applied: true, redactedCount: 2))
        probe.recordPrivacyFilter(applied: false, redactedCount: 0)
        #expect(probe.privacyOutcome?.applied == false)
    }

    @Test func attributionReadsTaskLocals() async {
        let agentId = UUID()
        let sessionId = UUID()
        let outside = InsightsService.ActivityAttribution.current()
        #expect(outside.agentId == nil)
        let inside = await ChatExecutionContext.$currentAgentId.withValue(agentId) {
            await ChatExecutionContext.$currentSessionId.withValue(sessionId.uuidString) {
                InsightsService.ActivityAttribution.current()
            }
        }
        #expect(inside.agentId == agentId)
        #expect(inside.sessionId == sessionId)
    }

    // MARK: - CoreModelService one-shots

    /// Titles, follow-ups, memory distillation and transcript cleanup run
    /// through `CoreModelService` at `/internal/<purpose>`. They must land as
    /// inference rows (not inbound API) with a readable purpose, so a remote
    /// core model's cloud sends are visible in the audit log.
    @Test func coreModelOneShotRowsAreInferenceWithPurpose() async throws {
        let model = "probe/core-\(UUID().uuidString.prefix(6))"
        InsightsService.logInference(
            source: .system,
            model: model,
            inputTokens: 40,
            outputTokens: 6,
            durationMs: 120,
            temperature: 0.3,
            maxTokens: 64,
            requestBody: #"{"purpose":"chat_title"}"#,
            responseBody: "Capital of France",
            path: "/internal/chat_title"
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        let row = try #require(await MainActor.run { InsightsService.shared.logs.first { $0.model == model } })
        #expect(row.category == .inference)
        #expect(row.isInference)
        #expect(row.locality == .local)
        #expect(row.source == .system)
        #expect(row.internalPurposeLabel == "Chat title")
        #expect(row.title.hasPrefix("Chat title"))
        #expect(RequestLog.inferCategory(method: "POST", path: "/internal/memory_distillation", pluginId: nil) == .inference)
        #expect(RequestLog.inferCategory(method: "GET", path: "/health", pluginId: nil) == .inboundAPI)
    }

    // MARK: - Media / embedding / audio categories

    @Test func mediaEndpointsMapToTheirCategories() {
        #expect(RequestLog.mediaCategory(forPath: "/v1/embeddings") == .embedding)
        #expect(RequestLog.mediaCategory(forPath: "/embed") == .embedding)
        #expect(RequestLog.mediaCategory(forPath: "/internal/embeddings") == .embedding)
        #expect(RequestLog.mediaCategory(forPath: "/audio/transcriptions") == .audioTranscription)
        #expect(RequestLog.mediaCategory(forPath: "/v1/audio/translations") == .audioTranscription)
        #expect(RequestLog.mediaCategory(forPath: "/internal/audio_transcription") == .audioTranscription)
        #expect(RequestLog.mediaCategory(forPath: "/v1/audio/speech") == .speechSynthesis)
        #expect(RequestLog.mediaCategory(forPath: "/images/generations") == .mediaGeneration)
        #expect(RequestLog.mediaCategory(forPath: "/videos/quote") == .mediaGeneration)
        #expect(RequestLog.mediaCategory(forPath: "/internal/image_generate") == .mediaGeneration)
        #expect(RequestLog.mediaCategory(forPath: "/chat/completions") == nil)
        #expect(RequestLog.mediaCategory(forPath: "/health") == nil)
        // The HTTP handler's double-write guard keys on the same table.
        #expect(HTTPHandler.handlerWritesOwnActivityRow(path: "/embeddings"))
        #expect(HTTPHandler.handlerWritesOwnActivityRow(path: "/audio/transcriptions"))
        #expect(HTTPHandler.handlerWritesOwnActivityRow(path: "/images/edits"))
        #expect(!HTTPHandler.handlerWritesOwnActivityRow(path: "/chat/completions"))
        // inferCategory prefers media over inbound API / plugin.
        #expect(RequestLog.inferCategory(method: "POST", path: "/v1/embeddings", pluginId: "p") == .embedding)
        #expect(RequestLog.inferCategory(method: "POST", path: "/images/generations", pluginId: nil) == .mediaGeneration)
    }

    @Test func newCategoriesAreModelWorkWithDisplayNames() {
        for c in [ActivityCategory.embedding, .audioTranscription, .speechSynthesis, .mediaGeneration] {
            #expect(c.isModelWork)
            #expect(!c.displayName.isEmpty)
            #expect(!c.icon.isEmpty)
        }
        #expect(!ActivityCategory.system.isModelWork)
        #expect(!ActivityCategory.webSearch.isModelWork)
    }

    @Test func httpMediaDetailsMirrorInProcessKeys() {
        let image = HTTPHandler.mediaActivityDetails(
            kind: "image", operation: "generate", backend: .local,
            count: 2, width: 1024, height: 768, aspect: nil, resolution: nil)
        #expect(image["media_kind"] == "image")
        #expect(image["operation"] == "generate")
        #expect(image["backend"] == "local")
        #expect(image["count"] == "2")
        #expect(image["size"] == "1024x768")

        let video = HTTPHandler.mediaActivityDetails(
            kind: "video", operation: "quote", backend: .remoteProvider(UUID()),
            count: nil, width: nil, height: nil, aspect: "16:9", resolution: "1080p",
            extra: ["duration": "5", "quote_usd": "0.1200"])
        #expect(video["size"] == "1080p 16:9")
        #expect(video["count"] == nil)
        #expect(video["duration"] == "5")
        #expect(video["quote_usd"] == "0.1200")

        let emb = HTTPHandler.embeddingActivityDetails(texts: ["ab", "cde"], dimensions: 128)
        #expect(emb == ["texts": "2", "chars": "5", "dims": "128"])
        #expect(HTTPHandler.embeddingActivityDetails(texts: [], dimensions: nil) == ["texts": "0", "chars": "0"])
    }

    @Test func speechJobLogsRemoteSynthesisWithTextAndVoice() async throws {
        let model = "tts-probe-\(UUID().uuidString)"
        let job = MediaActivityLogger.beginSpeech(
            text: "Hello there, this is spoken.", model: model, voice: "alloy",
            provider: "api.openai.com", endpoint: "https://api.openai.com/v1/audio/speech", trigger: .readAloud)
        job.finish(audioSeconds: 2.5, error: nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        let row = try #require(await MainActor.run { InsightsService.shared.logs.first { $0.model == model } })
        #expect(row.category == .speechSynthesis)
        #expect(row.locality == .remote)
        #expect(row.source == .chatUI)
        #expect(row.path == "/v1/audio/speech")
        #expect(row.requestBody == "Hello there, this is spoken.")
        #expect(row.egress?.destinationHost == "api.openai.com")
        #expect(row.egress?.dataClasses == ["speech_text"])
        #expect(row.egress?.details["voice"] == "alloy")
        #expect(row.egress?.details["chars"] == "28")
        #expect(row.egress?.details["audio_seconds"] == "2.5")
        #expect(row.egress?.details["trigger"] == "read_aloud")
        #expect(row.title.contains("28") || row.title.contains("2.5"))
    }

    @Test func speechJobLocalSpeakToolIsLocalToolRow() async throws {
        let model = "pocket-probe-\(UUID().uuidString)"
        let job = MediaActivityLogger.beginSpeech(
            text: "local", model: model, voice: "alba", provider: "PocketTTS", endpoint: nil, trigger: .speakTool)
        job.finish(audioSeconds: nil, error: nil, cancelled: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        let row = try #require(await MainActor.run { InsightsService.shared.logs.first { $0.model == model } })
        #expect(row.locality == .local)
        #expect(row.source == .tool)
        #expect(row.path == "/internal/speech_synthesis")
        #expect(row.egress?.destinationHost == nil)
        #expect(row.egress?.details["cancelled"] == "true")
    }

    @Test func transcriptionJobIsSkippedUnderHTTPGuardAndLoggedOtherwise() async throws {
        let guarded = ChatExecutionContext.$currentRequestSource.withValue(.httpAPI) {
            MediaActivityLogger.beginTranscription(model: "m", audioSeconds: 1, audioBytes: 1, audioFormat: "wav", mode: "file")
        }
        #expect(guarded == nil)

        let model = "stt-probe-\(UUID().uuidString)"
        let job = try #require(
            MediaActivityLogger.beginTranscription(model: model, audioSeconds: nil, audioBytes: 32_000, audioFormat: "microphone", mode: "live"))
        job.finish(transcript: "hello world", language: "en", error: nil, audioSeconds: 4.2)
        try await Task.sleep(nanoseconds: 50_000_000)
        let row = try #require(await MainActor.run { InsightsService.shared.logs.first { $0.model == model } })
        #expect(row.category == .audioTranscription)
        #expect(row.locality == .local)
        #expect(row.path == "/internal/audio_transcription")
        #expect(row.responseBody == "hello world")
        #expect(row.egress?.details["mode"] == "live")
        #expect(row.egress?.details["audio_seconds"] == "4.2")
        #expect(row.egress?.details["audio_bytes"] == "32000")
        #expect(row.egress?.details["language"] == "en")
        #expect(row.egress?.details["transcript_chars"] == "11")
    }

    @Test func embeddingRowIsMetadataOnlyWithPurposeAndHTTPGuard() async throws {
        let marker = UUID().uuidString
        // Under the HTTP guard nothing is written.
        ChatExecutionContext.$currentRequestSource.withValue(.httpAPI) {
            MediaActivityLogger.$embeddingPurpose.withValue("guarded-\(marker)") {
                MediaActivityLogger.logEmbedding(
                    model: "potion", textCount: 1, totalChars: 5, dimensions: 128, purpose: MediaActivityLogger.embeddingPurpose,
                    durationMs: 1, error: nil)
            }
        }
        MediaActivityLogger.$embeddingPurpose.withValue("memory_search") {
            MediaActivityLogger.logEmbedding(
                model: "probe-\(marker)", textCount: 3, totalChars: 42, dimensions: 128,
                purpose: MediaActivityLogger.embeddingPurpose, durationMs: 7, error: nil)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let rows = await MainActor.run { InsightsService.shared.logs.filter { $0.category == .embedding } }
        #expect(!rows.contains { $0.egress?.details["purpose"] == "guarded-\(marker)" })
        let row = try #require(rows.first { $0.model == "probe-\(marker)" })
        #expect(row.locality == .local)
        #expect(row.source == .system)  // no session → system work
        #expect(row.path == "/internal/embeddings")
        #expect(row.requestBody == nil)
        #expect(row.egress?.details == ["texts": "3", "chars": "42", "dims": "128", "purpose": "memory_search"])
        #expect(row.title.contains("3"))
    }

    @Test func mediaJobLocalAndRemotePaths() async throws {
        let model = "media-probe-\(UUID().uuidString)"
        let local = try #require(
            MediaActivityLogger.beginMedia(
                kind: .image, operation: .generate, model: "pending", prompt: "a red fox", provider: "Local (MLX)",
                endpoint: nil, requestedCount: 2, size: "1024x1024", steps: 20, trigger: .chatTool))
        local.withModel(model).finish(producedCount: 2, jobId: "img_1", error: nil)

        let remoteModel = "venice-probe-\(UUID().uuidString)"
        let remote = try #require(
            MediaActivityLogger.beginMedia(
                kind: .video, operation: .quote, model: remoteModel, prompt: "waves", provider: "Venice",
                endpoint: "https://api.venice.ai/api/v1", requestedCount: 1, size: "1080p", durationSeconds: 5,
                trigger: .imagePanel))
        remote.finish(producedCount: nil, jobId: nil, error: "quota")

        #expect(
            ChatExecutionContext.$currentRequestSource.withValue(.httpAPI) {
                MediaActivityLogger.beginMedia(
                    kind: .image, operation: .generate, model: "m", prompt: nil, provider: "p", endpoint: nil,
                    requestedCount: 1, trigger: .httpAPI)
            } == nil)

        try await Task.sleep(nanoseconds: 50_000_000)
        let localRow = try #require(await MainActor.run { InsightsService.shared.logs.first { $0.model == model } })
        #expect(localRow.category == .mediaGeneration)
        #expect(localRow.locality == .local)
        #expect(localRow.source == .tool)
        #expect(localRow.path == "/internal/image_generate")
        #expect(localRow.requestBody == "a red fox")
        #expect(localRow.egress?.details["count"] == "2")
        #expect(localRow.egress?.details["size"] == "1024x1024")
        #expect(localRow.egress?.details["steps"] == "20")
        #expect(localRow.egress?.details["job_id"] == "img_1")

        let remoteRow = try #require(await MainActor.run { InsightsService.shared.logs.first { $0.model == remoteModel } })
        #expect(remoteRow.locality == .remote)
        #expect(remoteRow.source == .chatUI)
        #expect(remoteRow.path == "/v1/videos/quote")
        #expect(remoteRow.isError)
        #expect(remoteRow.egress?.destinationHost == "api.venice.ai")
        #expect(remoteRow.egress?.dataClasses == ["media_prompt"])
        #expect(remoteRow.egress?.details["duration_seconds"] == "5")
        #expect(remoteRow.egress?.details["count"] == "1")  // requested, nothing produced
    }

    // MARK: - Channel auto-reply

    @Test func channelAutoReplyIsReplyMethodWithAttachmentsClass() async throws {
        let connection = AgentChannelConnection(id: "tg", name: "Family Telegram", kind: .telegram)
        let egress = ChannelActivityLogger.egress(
            connection: connection, connectionId: "tg", roomId: "-100", threadId: nil, contentLength: 12,
            outcome: "replied", trigger: .autoReply, extraDetails: ["artifacts_sent": "2"])
        #expect(egress.dataClasses == ["channel_message", "attachments"])
        #expect(egress.details["trigger"] == "auto_reply")
        #expect(egress.details["channel"] == "telegram")
        #expect(egress.details["artifacts_sent"] == "2")

        let room = "room-\(UUID().uuidString.prefix(8))"
        ChannelActivityLogger.logDelivery(
            connection: connection, connectionId: "tg", roomId: room, threadId: nil, contentLength: 12,
            outcome: "replied", trigger: .autoReply, error: nil, durationMs: 3,
            attribution: InsightsService.ActivityAttribution(agentId: nil, sessionId: nil), source: .channel)
        try await Task.sleep(nanoseconds: 50_000_000)
        let row = try #require(await MainActor.run { InsightsService.shared.logs.first { $0.path == "/channels/tg/\(room)" } })
        #expect(row.category == .channelDelivery)
        #expect(row.method == "REPLY")
        #expect(row.source == .channel)
        #expect(row.statusCode == 200)
        #expect(row.requestBody == nil)  // message text never stored
        #expect(row.egress?.destinationHost == "api.telegram.org")
    }
}
