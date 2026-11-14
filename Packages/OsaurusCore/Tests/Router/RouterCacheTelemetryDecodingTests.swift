//
//  RouterCacheTelemetryDecodingTests.swift
//  osaurusTests
//
//  Cache-aware billing contract between the app and the Osaurus Router
//  (`docs/OSAURUS_ROUTER.md` → "Prompt Cache Contract"), plus the direct BYOK
//  cached-token parsers that feed the same "N cached" footer chip.
//
//  Every decode must work both with and without the cache fields: routers
//  deployed before `0046_cache_pricing` omit them, and ledger rows written by
//  older app builds have no columns for them.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Router cache telemetry decoding")
struct RouterCacheTelemetryDecodingTests {

    // MARK: - Summary frame

    @Test func summaryFrame_decodesCacheSplitWhenPresent() throws {
        let json = """
            {"osaurus":{"request_id":"req-1","cost_micro":"1234","status":"completed","token_source":"provider",
             "input_tokens":10000,"output_tokens":300,"cached_input_tokens":8000,"cache_write_tokens":1500,
             "billed_to":"workspace:ws-1"}}
            """
        let event = try JSONDecoder().decode(OsaurusRouterSummaryEvent.self, from: Data(json.utf8))
        #expect(event.osaurus.inputTokens == 10000)
        #expect(event.osaurus.cachedInputTokens == 8000)
        #expect(event.osaurus.cacheWriteTokens == 1500)

        let summary = RouterBillingSummary(event.osaurus)
        #expect(summary.cachedInputTokens == 8000)
        #expect(summary.cacheWriteTokens == 1500)
        #expect(summary.billedTo == "workspace:ws-1")
    }

    @Test func summaryFrame_withoutCacheFieldsDecodesAsZero() throws {
        // Pre-cache router: identical frame minus the split.
        let json = """
            {"osaurus":{"cost_micro":"1234","status":"completed","token_source":"provider","input_tokens":11,"output_tokens":3}}
            """
        let event = try JSONDecoder().decode(OsaurusRouterSummaryEvent.self, from: Data(json.utf8))
        #expect(event.osaurus.cachedInputTokens == 0)
        #expect(event.osaurus.cacheWriteTokens == 0)
        #expect(RouterBillingSummary(event.osaurus).cachedInputTokens == 0)
    }

    @Test func summaryFrame_clampsNegativeCacheCountsToZero() throws {
        let json = """
            {"osaurus":{"cost_micro":"1","status":"completed","token_source":"provider","input_tokens":5,"output_tokens":1,
             "cached_input_tokens":-3,"cache_write_tokens":-1}}
            """
        let event = try JSONDecoder().decode(OsaurusRouterSummaryEvent.self, from: Data(json.utf8))
        #expect(event.osaurus.cachedInputTokens == 0)
        #expect(event.osaurus.cacheWriteTokens == 0)
    }

    @Test func summaryFrame_billingHintCarriesCacheSplitToChat() async throws {
        // The streaming path decodes the frame and re-encodes it as a
        // `StreamingBillingHint`; the chat layer must see the split intact.
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let shouldFinish = RemoteProviderService.processEventPayload(
            #"{"osaurus":{"request_id":"r-9","cost_micro":"777","status":"completed","token_source":"provider","input_tokens":4000,"output_tokens":20,"cached_input_tokens":3500,"cache_write_tokens":0}}"#,
            state: &state,
            providerType: .osaurusRouter,
            tools: [],
            continuation: continuation
        )
        continuation.finish()
        #expect(shouldFinish == false)

        var decoded: RouterBillingSummary?
        for try await delta in stream {
            decoded = StreamingBillingHint.decode(delta) ?? decoded
        }
        let billing = try #require(decoded)
        #expect(billing.inputTokens == 4000)
        #expect(billing.cachedInputTokens == 3500)
        #expect(billing.cacheWriteTokens == 0)
        #expect(billing.costMicro == "777")
    }

    // MARK: - RouterBillingSummary persistence (chat turn / hint payload)

    @Test func billingSummary_roundTripsCacheFieldsAndToleratesLegacyPayloads() throws {
        let summary = RouterBillingSummary(
            requestId: "r",
            costMicro: "10",
            status: "completed",
            tokenSource: "provider",
            inputTokens: 100,
            outputTokens: 5,
            cachedInputTokens: 60,
            cacheWriteTokens: 40
        )
        let data = try JSONEncoder().encode(summary)
        let back = try JSONDecoder().decode(RouterBillingSummary.self, from: data)
        #expect(back == summary)

        // Persisted by an older app build (no cache keys at all).
        let legacy = """
            {"costMicro":"10","status":"completed","tokenSource":"provider","inputTokens":100,"outputTokens":5}
            """
        let old = try JSONDecoder().decode(RouterBillingSummary.self, from: Data(legacy.utf8))
        #expect(old.cachedInputTokens == 0)
        #expect(old.cacheWriteTokens == 0)
        #expect(old.inputTokens == 100)
    }

    // MARK: - GET /credits/usage rows

    @Test func usageItem_decodesWithAndWithoutCacheFields() throws {
        let withCache = """
            {"id":"u1","model":"m","provider":"anthropic","input_tokens":1000,"output_tokens":20,
             "cached_input_tokens":900,"cache_write_tokens":50,"cost_micro":"123","status":"completed",
             "token_source":"provider","created_at":"2026-06-13T18:00:00Z"}
            """
        let item = try JSONDecoder().decode(OsaurusRouterUsageItem.self, from: Data(withCache.utf8))
        #expect(item.cachedInputTokens == 900)
        #expect(item.cacheWriteTokens == 50)

        let without = """
            {"id":"u1","model":"m","provider":"venice","input_tokens":1,"output_tokens":2,"cost_micro":"123",
             "status":"completed","token_source":"provider","created_at":"2026-06-13T18:00:00Z"}
            """
        let legacy = try JSONDecoder().decode(OsaurusRouterUsageItem.self, from: Data(without.utf8))
        #expect(legacy.cachedInputTokens == 0)
        #expect(legacy.cacheWriteTokens == 0)
        #expect(legacy.inputTokens == 1)
    }

    @Test func usageResponse_listDecodesMixedRows() throws {
        let json = """
            {"data":[
              {"id":"a","model":"m","provider":"openai","input_tokens":10,"output_tokens":1,"cached_input_tokens":8,"cache_write_tokens":0,"cost_micro":"1","status":"completed","token_source":"provider","created_at":"2026-06-13T18:00:00Z"},
              {"id":"b","model":"m","provider":"venice","input_tokens":10,"output_tokens":1,"cost_micro":"1","status":"completed","token_source":"provider","created_at":"2026-06-13T18:00:00Z"}
            ],"next_cursor":null}
            """
        let response = try JSONDecoder().decode(OsaurusRouterUsageResponse.self, from: Data(json.utf8))
        #expect(response.data.map(\.cachedInputTokens) == [8, 0])
    }

    // MARK: - Credits center aggregates

    @Test func creditsSummary_sumsCachedInputAcrossRows() {
        let rows = [
            OsaurusRouterUsageItem(
                id: "a", requestId: nil, model: "m", provider: "openai",
                inputTokens: 100, outputTokens: 1, cachedInputTokens: 80, cacheWriteTokens: 0,
                costMicro: "1", status: "completed", tokenSource: "provider", createdAt: "2026-06-13T18:00:00Z"
            ),
            OsaurusRouterUsageItem(
                id: "b", requestId: nil, model: "m", provider: "venice",
                inputTokens: 50, outputTokens: 1,
                costMicro: "1", status: "completed", tokenSource: "provider", createdAt: "2026-06-13T18:00:00Z"
            ),
        ]
        let summary = RouterAccountUsageCenter.creditsSummary(rows)
        #expect(summary.inputTokens == 150)
        #expect(summary.cachedInputTokens == 80)
    }

    @Test func activityRow_tokensLineAppendsCachedOnlyWhenNonZero() {
        let cached = OsaurusRouterUsageItem(
            id: "a", requestId: nil, model: "m", provider: "openai",
            inputTokens: 1200, outputTokens: 340, cachedInputTokens: 900, cacheWriteTokens: 0,
            costMicro: "1", status: "completed", tokenSource: "provider", createdAt: "2026-06-13T18:00:00Z"
        )
        let cachedRow = CreditsActivityRow(usage: cached, match: nil, insightsReference: nil)
        #expect(cachedRow.tokensLine == "1,200 in / 340 out (900 cached)")

        let plain = OsaurusRouterUsageItem(
            id: "b", requestId: nil, model: "m", provider: "venice",
            inputTokens: 1200, outputTokens: 340,
            costMicro: "1", status: "completed", tokenSource: "provider", createdAt: "2026-06-13T18:00:00Z"
        )
        let plainRow = CreditsActivityRow(usage: plain, match: nil, insightsReference: nil)
        #expect(plainRow.tokensLine == "1,200 in / 340 out")
    }

    // MARK: - "N cached" label

    @Test func cachedInputLabel_formatsCountAndRatio() {
        #expect(OsaurusRouter.formatCachedInputLabel(cachedTokens: 0) == nil)
        #expect(OsaurusRouter.formatCachedInputLabel(cachedTokens: -5) == nil)
        #expect(OsaurusRouter.formatCachedInputLabel(cachedTokens: 900) == "900 cached")
        #expect(OsaurusRouter.formatCachedInputLabel(cachedTokens: 3200, inputTokens: 4000) == "3,200 cached · 80%")
        #expect(OsaurusRouter.formatCachedInputLabel(cachedTokens: 1, inputTokens: 3) == "1 cached · 33%")
        // Ratio omitted when the total is unknown, zero, or inconsistent.
        #expect(OsaurusRouter.formatCachedInputLabel(cachedTokens: 10, inputTokens: 0) == "10 cached")
        #expect(OsaurusRouter.formatCachedInputLabel(cachedTokens: 10, inputTokens: 5) == "10 cached")
        #expect(OsaurusRouter.formatCachedInputLabel(cachedTokens: 1_234_567, inputTokens: 1_234_567) == "1,234,567 cached · 100%")
    }

    @Test @MainActor func statsFooter_showsCachedChipOnlyWhenPositive() {
        let plain = NativeStatsView.statsText(ttft: nil, tokensPerSecond: 40, tokenCount: 12)
        #expect(!plain.contains("cached"))
        let zero = NativeStatsView.statsText(ttft: nil, tokensPerSecond: 40, tokenCount: 12, cachedInputTokens: 0)
        #expect(zero == plain)
        let cached = NativeStatsView.statsText(ttft: nil, tokensPerSecond: 40, tokenCount: 12, cachedInputTokens: 2048)
        #expect(cached.hasSuffix("2,048 cached"))
        #expect(cached.hasPrefix(plain))
    }

    @Test @MainActor func chatTurn_effectiveCachedInputPrefersProviderStatsThenRouterBilling() {
        let turn = ChatTurn(role: .assistant, content: "hi")
        #expect(turn.effectiveCachedInputTokens == nil)

        turn.routerBilling = RouterBillingSummary(
            costMicro: "1", status: "completed", tokenSource: "provider",
            inputTokens: 100, outputTokens: 1, cachedInputTokens: 70
        )
        #expect(turn.effectiveCachedInputTokens == 70)

        turn.cachedInputTokenCount = 80
        #expect(turn.effectiveCachedInputTokens == 80)

        turn.cachedInputTokenCount = 0
        #expect(turn.effectiveCachedInputTokens == 70)

        turn.routerBilling = nil
        #expect(turn.effectiveCachedInputTokens == nil)
    }

    // MARK: - Ledger (SQLite v3)

    private static let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())

    private func makeEntry(
        requestId: String = "req-1",
        cachedInputTokens: Int = 0,
        cacheWriteTokens: Int = 0
    ) -> RouterBillingEntry {
        RouterBillingEntry(
            id: UUID().uuidString,
            requestId: requestId,
            createdAt: Self.now,
            sessionId: UUID().uuidString,
            turnId: UUID().uuidString,
            model: "anthropic/claude",
            tokenSource: "provider",
            inputTokens: 5000,
            outputTokens: 30,
            cachedInputTokens: cachedInputTokens,
            cacheWriteTokens: cacheWriteTokens,
            costMicro: "1500",
            status: "completed",
            outcome: .pending,
            appVersion: "1.2.3"
        )
    }

    @Test func ledger_roundTripsCacheColumns() throws {
        let db = RouterBillingDatabase()
        try db.openInMemory()
        let entry = makeEntry(cachedInputTokens: 4500, cacheWriteTokens: 200)
        try db.insert(entry)
        let back = try #require(try db.findByRequestId("req-1"))
        #expect(back == entry)
        #expect(back.cachedInputTokens == 4500)
        #expect(back.cacheWriteTokens == 200)
        #expect(try db.recent(limit: 10).first?.cachedInputTokens == 4500)
    }

    @Test func ledger_upsertByRequestIdReplacesCacheSplit() throws {
        let db = RouterBillingDatabase()
        try db.openInMemory()
        _ = try db.upsertByRequestId(makeEntry(cachedInputTokens: 0))
        let updated = try db.upsertByRequestId(makeEntry(cachedInputTokens: 4000, cacheWriteTokens: 10))
        #expect(updated.cachedInputTokens == 4000)
        #expect(updated.cacheWriteTokens == 10)
        #expect(try db.findByRequestId("req-1")?.cachedInputTokens == 4000)
        #expect(try db.count() == 1)
    }

    @Test func ledger_v2RowsMigrateToV3WithZeroCacheCounts() throws {
        let db = RouterBillingDatabase()
        try db.openInMemory(upToSchemaVersion: 2)
        #expect(try db.schemaVersionForTesting() == 2)
        // Seed a row exactly as a v2 build would have written it.
        try db.executeForTesting(
            """
            INSERT INTO router_billing (entry_id, request_id, created_at, session_id, turn_id, model,
                token_source, input_tokens, output_tokens, cost_micro, status, outcome, app_version)
            VALUES ('legacy-1', 'req-legacy', \(Self.now.timeIntervalSince1970), NULL, NULL, 'm',
                'provider', 77, 8, '900', 'completed', 'rendered', '1.0.0')
            """
        )

        try db.migrateToLatestForTesting()
        #expect(try db.schemaVersionForTesting() == 3)

        let legacy = try #require(try db.findByRequestId("req-legacy"))
        #expect(legacy.inputTokens == 77)
        #expect(legacy.outputTokens == 8)
        #expect(legacy.cachedInputTokens == 0)
        #expect(legacy.cacheWriteTokens == 0)
        #expect(legacy.outcome == .rendered)

        // New rows written after the migration carry the split alongside the
        // legacy row.
        try db.insert(makeEntry(requestId: "req-new", cachedInputTokens: 60, cacheWriteTokens: 5))
        let rows = try db.recent(limit: 10)
        #expect(rows.count == 2)
        #expect(rows.first { $0.requestId == "req-new" }?.cachedInputTokens == 60)
        #expect(rows.first { $0.requestId == "req-legacy" }?.cachedInputTokens == 0)
    }

    @Test func ledger_entryClampsNegativeCacheCounts() {
        let entry = makeEntry(cachedInputTokens: -1, cacheWriteTokens: -9)
        #expect(entry.cachedInputTokens == 0)
        #expect(entry.cacheWriteTokens == 0)
    }

    @Test func ledgerFacade_recordsCacheSplitFromSummary() throws {
        let db = RouterBillingDatabase()
        try db.openInMemory()
        let ledger = RouterBillingLedger(database: db)
        let summary = RouterBillingSummary(
            requestId: "req-facade",
            costMicro: "42",
            status: "completed",
            tokenSource: "provider",
            inputTokens: 900,
            outputTokens: 10,
            cachedInputTokens: 800,
            cacheWriteTokens: 100
        )
        let entryId = ledger.record(summary: summary, sessionId: UUID(), turnId: UUID(), model: "m")
        #expect(entryId != nil)
        let stored = try #require(try db.findByRequestId("req-facade"))
        #expect(stored.cachedInputTokens == 800)
        #expect(stored.cacheWriteTokens == 100)
    }
}

// MARK: - Direct BYOK cached-token parsers

@Suite("Provider cached-token usage parsing")
struct ProviderCachedUsageParsingTests {

    // OpenAI Chat Completions (also Azure / OpenRouter / xAI shape).

    @Test func usage_decodesPromptTokensDetailsCachedTokens() throws {
        let json = """
            {"prompt_tokens":2000,"completion_tokens":10,"total_tokens":2010,
             "prompt_tokens_details":{"cached_tokens":1792,"audio_tokens":0}}
            """
        let usage = try JSONDecoder().decode(Usage.self, from: Data(json.utf8))
        #expect(usage.prompt_tokens_details?.cached_tokens == 1792)
        #expect(usage.cachedPromptTokens == 1792)

        let bare = try JSONDecoder().decode(
            Usage.self,
            from: Data(#"{"prompt_tokens":5,"completion_tokens":1,"total_tokens":6}"#.utf8)
        )
        #expect(bare.prompt_tokens_details == nil)
        #expect(bare.cachedPromptTokens == nil)

        // Details object without the key → nil (not zero), and over-reports clamp.
        let empty = try JSONDecoder().decode(
            Usage.self,
            from: Data(#"{"prompt_tokens":5,"completion_tokens":1,"total_tokens":6,"prompt_tokens_details":{}}"#.utf8)
        )
        #expect(empty.cachedPromptTokens == nil)
        let over = try JSONDecoder().decode(
            Usage.self,
            from: Data(#"{"prompt_tokens":5,"completion_tokens":1,"total_tokens":6,"prompt_tokens_details":{"cached_tokens":9}}"#.utf8)
        )
        #expect(over.cachedPromptTokens == 5)
        let negative = try JSONDecoder().decode(
            Usage.self,
            from: Data(#"{"prompt_tokens":5,"completion_tokens":1,"total_tokens":6,"prompt_tokens_details":{"cached_tokens":-2}}"#.utf8)
        )
        #expect(negative.cachedPromptTokens == 0)
    }

    @Test func usage_encodingOmitsDetailsWhenNil() throws {
        // Server-side writers construct `Usage` without details; the wire must
        // not grow a `prompt_tokens_details: null` key.
        let data = try JSONEncoder().encode(Usage(prompt_tokens: 1, completion_tokens: 2, total_tokens: 3))
        #expect(!String(decoding: data, as: UTF8.self).contains("prompt_tokens_details"))
    }

    @Test func chatCompletions_usageChunkCarriesCachedTokensIntoStatsHint() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let payload = """
            {"id":"c","object":"chat.completion.chunk","created":1,"model":"gpt-5.2","choices":[],
             "usage":{"prompt_tokens":3000,"completion_tokens":12,"total_tokens":3012,
                      "prompt_tokens_details":{"cached_tokens":2816}}}
            """
        _ = RemoteProviderService.handleStreamEvent(
            jsonData: Data(payload.utf8),
            providerType: .openaiLegacy,
            state: &state,
            yield: { _ in }
        )
        #expect(state.providerUsage?.prompt_tokens == 3000)
        #expect(state.providerCachedInputTokens == 2816)
    }

    @Test func chatCompletions_usageWithoutDetailsLeavesCachedNil() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let payload = """
            {"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[],
             "usage":{"prompt_tokens":30,"completion_tokens":2,"total_tokens":32}}
            """
        _ = RemoteProviderService.handleStreamEvent(
            jsonData: Data(payload.utf8),
            providerType: .openaiLegacy,
            state: &state,
            yield: { _ in }
        )
        #expect(state.providerUsage?.prompt_tokens == 30)
        #expect(state.providerCachedInputTokens == nil)
    }

    // Anthropic Messages: three disjoint prompt buckets.

    @Test func anthropicInputAccounting_sumsThreeBuckets() throws {
        let usage = try JSONDecoder().decode(
            AnthropicUsage.self,
            from: Data(#"{"input_tokens":12,"output_tokens":1,"cache_creation_input_tokens":2048,"cache_read_input_tokens":4096}"#.utf8)
        )
        let accounting = RemoteProviderService.anthropicInputAccounting(usage)
        #expect(accounting.totalInputTokens == 12 + 2048 + 4096)
        #expect(accounting.cacheReadTokens == 4096)
        #expect(accounting.cacheWriteTokens == 2048)

        let bare = try JSONDecoder().decode(
            AnthropicUsage.self,
            from: Data(#"{"input_tokens":12,"output_tokens":1}"#.utf8)
        )
        let plain = RemoteProviderService.anthropicInputAccounting(bare)
        #expect(plain.totalInputTokens == 12)
        #expect(plain.cacheReadTokens == 0)
        #expect(plain.cacheWriteTokens == 0)

        let negative = try JSONDecoder().decode(
            AnthropicUsage.self,
            from: Data(#"{"input_tokens":-1,"output_tokens":1,"cache_read_input_tokens":-7}"#.utf8)
        )
        #expect(RemoteProviderService.anthropicInputAccounting(negative).totalInputTokens == 0)
    }

    @Test func anthropicStream_messageStartRecordsTotalPromptAndCacheRead() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let start = """
            {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude","content":[],
             "stop_reason":null,"stop_sequence":null,
             "usage":{"input_tokens":12,"output_tokens":1,"cache_creation_input_tokens":500,"cache_read_input_tokens":9000}}}
            """
        _ = RemoteProviderService.handleStreamEvent(
            jsonData: Data(start.utf8),
            providerType: .anthropic,
            state: &state,
            yield: { _ in }
        )
        #expect(state.providerUsage?.prompt_tokens == 9512)
        #expect(state.providerCachedInputTokens == 9000)

        // `message_delta` completes the pair without disturbing the prompt side.
        let delta = """
            {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":40}}
            """
        _ = RemoteProviderService.handleStreamEvent(
            jsonData: Data(delta.utf8),
            providerType: .anthropic,
            state: &state,
            yield: { _ in }
        )
        #expect(state.providerUsage?.prompt_tokens == 9512)
        #expect(state.providerUsage?.completion_tokens == 40)
        #expect(state.providerCachedInputTokens == 9000)
    }

    @Test func anthropicStream_withoutCacheFieldsReportsZeroCached() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let start = """
            {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude","content":[],
             "stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":42,"output_tokens":1}}}
            """
        _ = RemoteProviderService.handleStreamEvent(
            jsonData: Data(start.utf8),
            providerType: .anthropic,
            state: &state,
            yield: { _ in }
        )
        #expect(state.providerUsage?.prompt_tokens == 42)
        #expect(state.providerCachedInputTokens == 0)
    }

    // Gemini generateContent stream.

    @Test func geminiUsageMetadata_decodesCachedContentTokenCount() throws {
        let json = """
            {"promptTokenCount":5000,"candidatesTokenCount":30,"totalTokenCount":5030,"cachedContentTokenCount":4200,"thoughtsTokenCount":12}
            """
        let usage = try JSONDecoder().decode(GeminiUsageMetadata.self, from: Data(json.utf8))
        #expect(usage.cachedContentTokenCount == 4200)
        #expect(usage.thoughtsTokenCount == 12)
        let bare = try JSONDecoder().decode(
            GeminiUsageMetadata.self,
            from: Data(#"{"promptTokenCount":5,"candidatesTokenCount":1,"totalTokenCount":6}"#.utf8)
        )
        #expect(bare.cachedContentTokenCount == nil)
    }

    @Test func geminiStream_capturesUsageAndCachedCount() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let chunk = """
            {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"},"index":0}],
             "usageMetadata":{"promptTokenCount":5000,"candidatesTokenCount":3,"totalTokenCount":5003,"cachedContentTokenCount":4200}}
            """
        var yielded: [String] = []
        _ = RemoteProviderService.handleStreamEvent(
            jsonData: Data(chunk.utf8),
            providerType: .gemini,
            state: &state,
            yield: { yielded.append($0) }
        )
        #expect(yielded.contains("Hello"))
        #expect(state.providerUsage?.prompt_tokens == 5000)
        #expect(state.providerUsage?.completion_tokens == 3)
        #expect(state.providerCachedInputTokens == 4200)

        // A later chunk with final counts (no cached field) keeps the cached
        // value and updates the completion side.
        let final = """
            {"candidates":[{"content":{"parts":[{"text":"!"}],"role":"model"},"finishReason":"STOP","index":0}],
             "usageMetadata":{"promptTokenCount":5000,"candidatesTokenCount":9,"totalTokenCount":5009}}
            """
        _ = RemoteProviderService.handleStreamEvent(
            jsonData: Data(final.utf8),
            providerType: .gemini,
            state: &state,
            yield: { _ in }
        )
        #expect(state.providerUsage?.completion_tokens == 9)
        #expect(state.providerCachedInputTokens == 4200)
    }

    @Test func geminiStream_withoutUsageMetadataLeavesUsageNil() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let chunk = """
            {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"},"index":0}]}
            """
        _ = RemoteProviderService.handleStreamEvent(
            jsonData: Data(chunk.utf8),
            providerType: .gemini,
            state: &state,
            yield: { _ in }
        )
        #expect(state.providerUsage == nil)
        #expect(state.providerCachedInputTokens == nil)
    }

    @Test func geminiUsage_clampsCachedToPrompt() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        RemoteProviderService.captureGeminiUsage(
            GeminiUsageMetadata(promptTokenCount: 10, candidatesTokenCount: 1, totalTokenCount: 11, cachedContentTokenCount: 99),
            state: &state
        )
        #expect(state.providerCachedInputTokens == 10)
        RemoteProviderService.captureGeminiUsage(nil, state: &state)
        #expect(state.providerUsage?.prompt_tokens == 10)
    }

    // End-to-end: captured cache counts reach the chat layer via the stats hint.

    private struct StatsHint {
        let tokenCount: Int
        let stopReason: String?
        let inputTokenCount: Int?
        let cachedInputTokenCount: Int?
    }

    private static func drainDispatchFinal(
        state: RemoteProviderService.StreamingState
    ) async -> [StatsHint] {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        RemoteProviderService.dispatchFinal(
            state: state,
            tools: [],
            finishMarker: "[DONE]",
            continuation: continuation
        )
        var hints: [StatsHint] = []
        do {
            for try await delta in stream {
                if let hint = StreamingStatsHint.decode(delta) {
                    hints.append(
                        StatsHint(
                            tokenCount: hint.tokenCount,
                            stopReason: hint.stopReason,
                            inputTokenCount: hint.inputTokenCount,
                            cachedInputTokenCount: hint.cachedInputTokenCount
                        )
                    )
                }
            }
        } catch {}
        return hints
    }

    @Test func dispatchFinal_statsHintCarriesCachedInputPerProvider() async {
        // Chat Completions.
        var openai = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        _ = RemoteProviderService.handleStreamEvent(
            jsonData: Data(
                """
                {"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[],
                 "usage":{"prompt_tokens":3000,"completion_tokens":12,"total_tokens":3012,"prompt_tokens_details":{"cached_tokens":2816}}}
                """.utf8),
            providerType: .openaiLegacy,
            state: &openai,
            yield: { _ in }
        )
        openai.lastFinishReason = "stop"
        let openaiHints = await Self.drainDispatchFinal(state: openai)
        #expect(openaiHints.count == 1)
        #expect(openaiHints.first?.inputTokenCount == 3000)
        #expect(openaiHints.first?.cachedInputTokenCount == 2816)
        #expect(openaiHints.first?.tokenCount == 12)

        // Anthropic.
        var anthropic = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        for payload in [
            #"{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","model":"claude","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":6000}}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":25}}"#,
        ] {
            _ = RemoteProviderService.handleStreamEvent(
                jsonData: Data(payload.utf8),
                providerType: .anthropic,
                state: &anthropic,
                yield: { _ in }
            )
        }
        let anthropicHints = await Self.drainDispatchFinal(state: anthropic)
        #expect(anthropicHints.first?.inputTokenCount == 6010)
        #expect(anthropicHints.first?.cachedInputTokenCount == 6000)
        #expect(anthropicHints.first?.tokenCount == 25)

        // Gemini.
        var gemini = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        _ = RemoteProviderService.handleStreamEvent(
            jsonData: Data(
                """
                {"candidates":[{"content":{"parts":[{"text":"ok"}],"role":"model"},"finishReason":"STOP","index":0}],
                 "usageMetadata":{"promptTokenCount":700,"candidatesTokenCount":4,"totalTokenCount":704,"cachedContentTokenCount":512}}
                """.utf8),
            providerType: .gemini,
            state: &gemini,
            yield: { _ in }
        )
        let geminiHints = await Self.drainDispatchFinal(state: gemini)
        #expect(geminiHints.first?.inputTokenCount == 700)
        #expect(geminiHints.first?.cachedInputTokenCount == 512)
        #expect(geminiHints.first?.tokenCount == 4)
        #expect(geminiHints.first?.stopReason == "stop")

        // No cache fields anywhere → hint still emitted, cached count absent.
        var plain = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        plain.captureProviderUsage(Usage(prompt_tokens: 10, completion_tokens: 2, total_tokens: 12))
        let plainHints = await Self.drainDispatchFinal(state: plain)
        #expect(plainHints.first?.inputTokenCount == 10)
        #expect(plainHints.first?.cachedInputTokenCount == nil)
    }

    // OpenAI Responses (unchanged contract, regression guard).

    @Test func openResponses_completedCarriesCachedTokens() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let payload = """
            {"type":"response.completed","response":{"id":"resp_1","object":"response","status":"completed","output":[],
             "usage":{"input_tokens":1500,"output_tokens":20,"total_tokens":1520,"input_tokens_details":{"cached_tokens":1280}}}}
            """
        _ = RemoteProviderService.handleStreamEvent(
            jsonData: Data(payload.utf8),
            providerType: .openResponses,
            state: &state,
            yield: { _ in }
        )
        #expect(state.providerUsage?.prompt_tokens == 1500)
        #expect(state.providerCachedInputTokens == 1280)
    }
}

// MARK: - Anthropic cache_control TTL selection

@Suite("Anthropic cache_control TTL")
struct AnthropicCacheControlTTLTests {

    private func request(messages: [ChatMessage]) -> RemoteChatRequest {
        RemoteChatRequest(
            model: "claude-opus-4-8",
            messages: messages,
            temperature: nil,
            max_completion_tokens: 512,
            stream: true,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            tools: nil,
            tool_choice: nil,
            reasoning_effort: nil,
            reasoning: nil,
            thinking: nil,
            modelOptions: [:],
            veniceParameters: nil
        )
    }

    @Test func forConversation_picksOneHourAfterUserTurnAndFiveMinutesAfterToolResult() {
        #expect(AnthropicCacheControl.forConversation(lastMessageRole: "user") == AnthropicCacheControl(ttl: "1h"))
        #expect(AnthropicCacheControl.forConversation(lastMessageRole: "tool") == AnthropicCacheControl())
        #expect(AnthropicCacheControl.forConversation(lastMessageRole: "tool").ttl == nil)
        // Anything else (assistant prefill, nil) is treated like a human gap.
        #expect(AnthropicCacheControl.forConversation(lastMessageRole: "assistant").ttl == "1h")
        #expect(AnthropicCacheControl.forConversation(lastMessageRole: nil).ttl == "1h")
    }

    @Test func toAnthropicRequest_userTailGetsOneHourTTLOnTheWire() throws {
        let anthropic = request(messages: [ChatMessage(role: "user", content: "Hello")]).toAnthropicRequest()
        #expect(anthropic.cache_control?.type == "ephemeral")
        #expect(anthropic.cache_control?.ttl == "1h")

        let encoded = try JSONEncoder.osaurusCanonical().encode(anthropic)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let cacheControl = try #require(json["cache_control"] as? [String: Any])
        #expect(cacheControl["type"] as? String == "ephemeral")
        #expect(cacheControl["ttl"] as? String == "1h")
        #expect(cacheControl.count == 2)
    }

    @Test func toAnthropicRequest_toolResultTailGetsDefaultTTL() throws {
        let messages = [
            ChatMessage(role: "user", content: "Read the file"),
            ChatMessage(
                role: "assistant",
                content: nil,
                tool_calls: [
                    ToolCall(id: "toolu_1", type: "function", function: ToolCallFunction(name: "read", arguments: "{}"))
                ],
                tool_call_id: nil
            ),
            ChatMessage(role: "tool", content: "contents", tool_calls: nil, tool_call_id: "toolu_1"),
        ]
        let anthropic = request(messages: messages).toAnthropicRequest()
        #expect(anthropic.cache_control?.type == "ephemeral")
        #expect(anthropic.cache_control?.ttl == nil)

        // Wire: `ttl` omitted entirely (5m default), key order canonical.
        let encoded = try JSONEncoder.osaurusCanonical().encode(anthropic)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let cacheControl = try #require(json["cache_control"] as? [String: Any])
        #expect(cacheControl["ttl"] == nil)
        #expect(cacheControl.count == 1)
    }

    @Test func toAnthropicRequest_ttlSelectionIsDeterministicAcrossEncodes() throws {
        // Byte-stable bodies are a precondition for cache hits: the same
        // request must encode identically every time.
        let anthropic = request(messages: [ChatMessage(role: "user", content: "Hello")]).toAnthropicRequest()
        let a = try JSONEncoder.osaurusCanonical().encode(anthropic)
        let b = try JSONEncoder.osaurusCanonical().encode(anthropic)
        #expect(a == b)
    }

    @Test func cacheControl_decodesWithAndWithoutTTL() throws {
        let withTTL = try JSONDecoder().decode(
            AnthropicCacheControl.self,
            from: Data(#"{"type":"ephemeral","ttl":"1h"}"#.utf8)
        )
        #expect(withTTL.ttl == "1h")
        let without = try JSONDecoder().decode(
            AnthropicCacheControl.self,
            from: Data(#"{"type":"ephemeral"}"#.utf8)
        )
        #expect(without.ttl == nil)
    }
}
