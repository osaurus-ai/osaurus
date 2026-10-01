//
//  ActivityLogStoreTests.swift
//  osaurusTests
//
//  Persisted activity log: append/fetch/filter/paging, Codable round trip,
//  hash-chain verification, prune-with-anchor, clear tombstone, summaries.
//  Each test opens its own plaintext in-memory store.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("ActivityLogStore")
struct ActivityLogStoreTests {

    private func makeStore() throws -> ActivityLogStore {
        let store = ActivityLogStore()
        try store.openInMemory()
        return store
    }

    private func inference(
        at date: Date = Date(),
        model: String = "mlx-community/test",
        remote: Bool = false,
        turnId: UUID? = nil,
        error: String? = nil
    ) -> RequestLog {
        RequestLog(
            timestamp: date,
            source: .chatUI,
            turnId: turnId,
            method: "POST",
            path: "/chat/completions",
            statusCode: error == nil ? 200 : 500,
            durationMs: 1200,
            requestBody: #"{"messages":[{"role":"user","content":"hello"}],"tools":[{"a":1}]}"#,
            responseBody: "hi there",
            model: model,
            inputTokens: 10,
            outputTokens: 20,
            toolCalls: [ToolCallLog(name: "web_search", arguments: #"{"query":"x"}"#)],
            finishReason: error == nil ? .stop : .error,
            errorMessage: error,
            connection: remote
                ? RequestConnectionInfo(
                    providerId: UUID(), remoteEndpoint: "https://api.openai.com/v1/chat/completions",
                    transport: .direct, mode: .remoteInference)
                : nil,
            egress: remote
                ? EgressInfo(destinationLabel: "OpenAI", destinationHost: "api.openai.com", bytesSent: 512, dataClasses: ["prompt", "tools"], privacyFilterApplied: true, redactedSpanCount: 2)
                : nil
        )
    }

    private func search(at date: Date = Date(), query: String = "swift concurrency") -> RequestLog {
        RequestLog(
            timestamp: date,
            source: .tool,
            method: "POST",
            path: "/tools/web_search",
            statusCode: 200,
            durationMs: 800,
            category: .webSearch,
            locality: .remote,
            egress: EgressInfo(
                destinationLabel: "Tavily", destinationHost: "api.tavily.com", bytesSent: 100, bytesReceived: 4000,
                dataClasses: ["search_query"], details: ["query": query, "provider_used": "tavily", "hit_count": "5"]
            )
        )
    }

    // MARK: - Append / chain

    @Test func appendAssignsContiguousChain() throws {
        let store = try makeStore()
        let a = try store.append(inference())
        let b = try store.append(search())
        #expect(a.seq == 1)
        #expect(b.seq == 2)
        #expect(a.prevHash == ActivityLogStore.genesisHash)
        #expect(b.prevHash == a.hash)
        #expect(a.hash?.count == 64)
        let v = try store.verify()
        #expect(v.isIntact)
        #expect(v.recordCount == 2)
        #expect(v.lastSeq == 2)
        #expect(v.lastHash == b.hash)
    }

    @Test func roundTripPreservesEveryField() throws {
        let store = try makeStore()
        let turnId = UUID()
        let original = inference(remote: true, turnId: turnId)
        let chained = try store.append(original)
        let loaded = try #require(try store.find(turnId: turnId))

        #expect(loaded.id == original.id)
        #expect(loaded.seq == chained.seq)
        #expect(loaded.hash == chained.hash)
        #expect(loaded.prevHash == chained.prevHash)
        #expect(loaded.model == original.model)
        #expect(loaded.requestBody == original.requestBody)
        #expect(loaded.responseBody == original.responseBody)
        #expect(loaded.toolCalls?.first?.name == "web_search")
        #expect(loaded.toolCalls?.first?.arguments == #"{"query":"x"}"#)
        #expect(loaded.connection == original.connection)
        #expect(loaded.egress == original.egress)
        #expect(loaded.category == .inference)
        #expect(loaded.locality == .remote)
        #expect(loaded.inputTokens == 10)
        #expect(loaded.tokensPerSecond == original.tokensPerSecond)
        #expect(abs(loaded.timestamp.timeIntervalSince(original.timestamp)) < 0.002)
    }

    @Test func categoryAndLocalityAreInferredForLegacyCallers() {
        let local = RequestLog(source: .chatUI, method: "POST", path: "/chat/completions", statusCode: 200, durationMs: 1)
        #expect(local.category == .inference)
        #expect(local.locality == .local)

        let plugin = RequestLog(source: .plugin, method: "LOG", path: "console", statusCode: 200, durationMs: 0, pluginId: "p")
        #expect(plugin.category == .pluginLog)

        let api = RequestLog(source: .httpAPI, method: "GET", path: "/v1/models", statusCode: 200, durationMs: 1)
        #expect(api.category == .inboundAPI)
        #expect(api.locality == .local)

        let remote = RequestLog(
            source: .chatUI, method: "POST", path: "/chat/completions", statusCode: 200, durationMs: 1,
            connection: RequestConnectionInfo(remoteEndpoint: "https://x.example/v1", transport: .direct, mode: .remoteInference)
        )
        #expect(remote.locality == .remote)

        let p2pInbound = RequestLog(
            source: .p2p, method: "POST", path: "/agents/0xabc/run", statusCode: 200, durationMs: 1,
            connection: RequestConnectionInfo(transport: .secureChannel, accessKeyId: "k")
        )
        #expect(p2pInbound.locality == .remote)
        #expect(p2pInbound.category == .inference)
    }

    // MARK: - Tamper evidence

    @Test func editedPayloadIsDetected() throws {
        let store = try makeStore()
        try store.append(inference())
        try store.append(inference())
        try store.executeForTesting("UPDATE activity SET payload = X'7b7d' WHERE seq = 1")
        let v = try store.verify()
        #expect(!v.isIntact)
        #expect(v.problems.contains(.hashMismatch(seq: 1)))
    }

    @Test func deletedMiddleRowIsDetected() throws {
        let store = try makeStore()
        for _ in 0..<3 { try store.append(inference()) }
        try store.executeForTesting("DELETE FROM activity WHERE seq = 2")
        let v = try store.verify()
        #expect(!v.isIntact)
        #expect(v.problems.contains(.sequenceGap(seq: 3, expected: 2)))
        #expect(v.problems.contains(.brokenLink(seq: 3)))
    }

    @Test func truncatedTailIsDetectedViaHead() throws {
        let store = try makeStore()
        for _ in 0..<3 { try store.append(inference()) }
        try store.executeForTesting("DELETE FROM activity WHERE seq = 3")
        let v = try store.verify()
        #expect(!v.isIntact)
        #expect(v.problems.contains { if case .headMismatch = $0 { return true } else { return false } })
    }

    // MARK: - Retention

    @Test func pruneRemovesPrefixAndAdvancesAnchor() throws {
        let store = try makeStore()
        let old = Date().addingTimeInterval(-10 * 86_400)
        try store.append(inference(at: old))
        try store.append(inference(at: old.addingTimeInterval(60)))
        let kept = try store.append(inference(at: Date()))

        let cutoff = Date().addingTimeInterval(-86_400)
        let removed = try store.prune(olderThan: cutoff)
        #expect(removed == 2)
        // The kept row plus the `pruned` custody row.
        #expect(try store.count() == 2)
        let v = try store.verify()
        #expect(v.isIntact, "\(v.problems)")
        #expect(v.firstSeq == kept.seq)

        // The prune is itself on the chain, right after the kept row.
        let rows = try store.fetch()
        let custody = try #require(rows.first)
        #expect(custody.category == .system)
        #expect(custody.source == .system)
        #expect(custody.egress?.details["event"] == "pruned")
        #expect(custody.egress?.details["removed_rows"] == "2")
        #expect(custody.egress?.details["anchor_seq"] == "2")
        #expect(custody.egress?.details["cutoff"] == ActivityLogStore.iso8601String(cutoff))
        #expect(custody.seq == 4)
        #expect(custody.prevHash == kept.hash)

        // Appending after a prune continues the chain.
        let next = try store.append(inference())
        #expect(next.seq == 5)
        #expect(next.prevHash == custody.hash)
        #expect(try store.verify().isIntact)
    }

    @Test func pruneWithNothingNewerRemovesEverythingAndKeepsChainVerifiable() throws {
        let store = try makeStore()
        let old = Date().addingTimeInterval(-10 * 86_400)
        let last = try store.append(inference(at: old))
        #expect(try store.prune(olderThan: Date()) == 1)
        // Only the `pruned` custody row remains, anchored on the removed tail.
        let rows = try store.fetch()
        #expect(rows.count == 1)
        let custody = try #require(rows.first)
        #expect(custody.egress?.details["event"] == "pruned")
        #expect(custody.egress?.details["removed_rows"] == "1")
        #expect(custody.seq == 2)
        #expect(custody.prevHash == last.hash)
        #expect(try store.verify().isIntact)
        let next = try store.append(inference())
        #expect(next.seq == 3)
        #expect(next.prevHash == custody.hash)
        #expect(try store.verify().isIntact)
    }

    @Test func pruneIsNoOpWhenNothingIsOldAndWritesNoCustodyRow() throws {
        let store = try makeStore()
        try store.append(inference())
        #expect(try store.prune(olderThan: Date().addingTimeInterval(-86_400)) == 0)
        #expect(try store.count() == 1)
        #expect(try store.fetch().allSatisfy { $0.category != .system })
    }

    @Test func clearLeavesAuditableTombstone() throws {
        let store = try makeStore()
        try store.append(inference())
        try store.append(search())
        try store.clear()
        let rows = try store.fetch()
        #expect(rows.count == 1)
        let tombstone = try #require(rows.first)
        #expect(tombstone.category == .system)
        #expect(tombstone.source == .system)
        #expect(tombstone.egress?.details["removed_rows"] == "2")
        #expect(tombstone.egress?.details["event"] == "cleared")
        #expect(tombstone.egress?.details["reason"] == "cleared_by_user")
        #expect(tombstone.path == "/activity/cleared")
        #expect(tombstone.seq == 3)
        #expect(try store.verify().isIntact)
    }

    // MARK: - Chain-of-custody rows

    @Test func verificationCanBeRecordedOnTheChain() throws {
        let store = try makeStore()
        try store.append(inference())
        try store.append(search())
        let result = try store.verify()
        let row = try store.recordVerification(result)
        #expect(row.category == .system)
        #expect(row.path == "/activity/verified")
        #expect(row.egress?.details["event"] == "verified")
        #expect(row.egress?.details["records"] == "2")
        #expect(row.egress?.details["problems"] == "0")
        #expect(row.egress?.details["ok"] == "true")
        #expect(row.egress?.details["head_hash"] == result.lastHash)
        #expect(row.egress?.details["head_seq"] == "2")
        #expect(row.seq == 3)
        // Recording the check did not break the chain it checked.
        #expect(try store.verify().isIntact)
    }

    @Test func failedVerificationRecordsProblemSummary() throws {
        let store = try makeStore()
        try store.append(inference())
        try store.append(inference())
        try store.executeForTesting("UPDATE activity SET payload = X'00' WHERE seq = 1")
        let result = try store.verify()
        #expect(!result.isIntact)
        let row = try store.recordVerification(result)
        #expect(row.egress?.details["ok"] == "false")
        #expect(row.egress?.details["problems"] == String(result.problems.count))
        #expect(row.egress?.details["problem_summary"]?.isEmpty == false)
    }

    @Test func systemEventRowCarriesEventAndDetails() throws {
        let store = try makeStore()
        let row = try store.appendSystemEvent(
            "exported",
            details: ["format": "jsonl", "records": "12", "include_content": "false", "file_name": "a.jsonl"]
        )
        #expect(row.source == .system)
        #expect(row.category == .system)
        #expect(row.method == "SYSTEM")
        #expect(row.path == "/activity/exported")
        #expect(row.locality == .local)
        #expect(row.egress?.details["event"] == "exported")
        #expect(row.egress?.details["file_name"] == "a.jsonl")
        #expect(row.systemEventSummary?.contains("12") == true)
        #expect(try store.verify().isIntact)
    }

    @Test func headMismatchIsDetectedWhenDatabaseOutrunsHead() throws {
        let store = try makeStore()
        try store.append(inference())
        try store.append(inference())
        // Fresh store, head agrees with the database.
        #expect(try store.pendingHeadMismatchForTesting() == nil)
        // Simulate a crash between insert and head write / a restored backup:
        // the database has a row the head never saw.
        try store.executeForTesting("DELETE FROM activity WHERE seq = 2")
        let mismatch = try #require(try store.pendingHeadMismatchForTesting())
        #expect(mismatch.expectedSeq == 2)
        #expect(mismatch.foundSeq == 1)
        #expect(mismatch.expectedHash != mismatch.foundHash)
        // Recording it (what `open()` does) puts the facts on the chain and
        // realigns the head so the log continues from the database.
        let row = try store.appendSystemEvent(
            "recovered",
            details: ["expected_seq": String(mismatch.expectedSeq), "found_seq": String(mismatch.foundSeq)]
        )
        #expect(row.seq == 2)
        #expect(row.systemEventSummary?.contains("seq 2") == true)
        #expect(try store.pendingHeadMismatchForTesting() == nil)
        #expect(try store.verify().isIntact)
    }

    // MARK: - Queries

    @Test func fetchFiltersByLocalityCategoryAndText() throws {
        let store = try makeStore()
        try store.append(inference(model: "local-model"))
        try store.append(inference(model: "gpt-4.1", remote: true))
        try store.append(search(query: "swift concurrency"))
        try store.append(search(query: "metal shaders"))

        var f = ActivityFilter()
        f.locality = .remote
        #expect(try store.count(filter: f) == 3)

        f = ActivityFilter()
        f.categories = [.webSearch]
        #expect(try store.count(filter: f) == 2)

        f = ActivityFilter()
        f.text = "metal"
        let hits = try store.fetch(filter: f)
        #expect(hits.count == 1)
        #expect(hits.first?.egress?.details["query"] == "metal shaders")

        f = ActivityFilter()
        f.destinationHost = "api.openai.com"
        #expect(try store.count(filter: f) == 1)

        f = ActivityFilter()
        f.privacyFilterApplied = true
        #expect(try store.count(filter: f) == 1)

        f = ActivityFilter()
        f.status = .error
        #expect(try store.count(filter: f) == 0)
        try store.append(inference(error: "boom"))
        #expect(try store.count(filter: f) == 1)
    }

    @Test func fetchIsNewestFirstAndPaged() throws {
        let store = try makeStore()
        let base = Date().addingTimeInterval(-1000)
        for i in 0..<7 { try store.append(inference(at: base.addingTimeInterval(Double(i)))) }
        let page1 = try store.fetch(limit: 3)
        let page2 = try store.fetch(limit: 3, offset: 3)
        #expect(page1.map { $0.seq } == [7, 6, 5])
        #expect(page2.map { $0.seq } == [4, 3, 2])
    }

    @Test func dateRangeFilterUsesBounds() throws {
        let store = try makeStore()
        try store.append(inference(at: Date().addingTimeInterval(-40 * 86_400)))
        try store.append(inference(at: Date()))
        var f = ActivityFilter()
        f.dateRange = .last30Days
        #expect(try store.count(filter: f) == 1)
        f.dateRange = .all
        #expect(try store.count(filter: f) == 2)
    }

    @Test func summaryAggregatesEgress() throws {
        let store = try makeStore()
        try store.append(inference(model: "local"))
        try store.append(inference(model: "gpt", remote: true))
        try store.append(search())
        try store.append(search())
        let s = try store.summary()
        #expect(s.totalCount == 4)
        #expect(s.localCount == 1)
        #expect(s.remoteCount == 3)
        #expect(s.searchCount == 2)
        #expect(s.inferenceCount == 2)
        #expect(s.bytesSent == 512 + 200)
        #expect(s.privacyFilteredCount == 1)
        #expect(s.redactedSpanTotal == 2)
        #expect(s.destinations.count == 2)
        let tavily = try #require(s.destinations.first { $0.host == "api.tavily.com" })
        #expect(tavily.count == 2)
        #expect(tavily.label == "Tavily")
        #expect(s.totalInputTokens == 20)
    }

    @Test func connectionActivityByProviderAndAccessKey() throws {
        let store = try makeStore()
        let providerId = UUID()
        try store.append(
            RequestLog(
                source: .chatUI, method: "POST", path: "/chat/completions", statusCode: 200, durationMs: 1000,
                model: "m", inputTokens: 5, outputTokens: 50,
                connection: RequestConnectionInfo(providerId: providerId, remoteEndpoint: "https://peer/x", transport: .secureChannel, mode: .remoteAgentRun)
            )
        )
        try store.append(
            RequestLog(
                source: .p2p, method: "POST", path: "/agents/0xabc/run", statusCode: 200, durationMs: 500,
                model: "m", outputTokens: 7,
                connection: RequestConnectionInfo(transport: .secureChannel, accessKeyId: "key-1", audience: "0xabc")
            )
        )
        let out = try store.connectionActivity(column: "provider_id", value: providerId.uuidString)
        #expect(out.requestCount == 1)
        #expect(out.totalOutputTokens == 50)
        #expect(out.averageSpeed == 50)
        let inbound = try store.connectionActivity(column: "access_key_id", value: "key-1")
        #expect(inbound.requestCount == 1)
        #expect(inbound.totalOutputTokens == 7)
        #expect(try store.find(accessKeyId: "key-1") != nil)
        #expect(try store.find(providerId: providerId) != nil)
    }

    @Test func distinctValuesForFilterMenus() throws {
        let store = try makeStore()
        try store.append(inference(model: "a", remote: true))
        try store.append(search())
        try store.append(search())
        let hosts = try store.distinctValues(column: .destinationHost)
        #expect(hosts.first == "api.tavily.com")
        #expect(hosts.contains("api.openai.com"))
        #expect(try store.distinctValues(column: .model) == ["a"])
    }

    @Test func detailsAreBounded() throws {
        let store = try makeStore()
        var row = search()
        var details = row.egress!.details
        details["huge"] = String(repeating: "x", count: 10_000)
        for i in 0..<40 { details["k\(i)"] = "v" }
        row = RequestLog(
            source: .tool, method: "POST", path: "/tools/web_search", statusCode: 200, durationMs: 1,
            category: .webSearch, locality: .remote,
            egress: EgressInfo(destinationHost: "h", details: details)
        )
        let stored = try store.append(row)
        #expect(stored.egress!.details.count <= 32)
        #expect((stored.egress!.details["huge"]?.count ?? 0) <= ActivityLogStore.maxDetailValueLength)
    }

    // MARK: - Content policy

    @Test func withoutContentKeepsMetadataAndMasksBodies() {
        let row = inference(remote: true).withoutContent()
        #expect(row.requestBody == RequestLog.contentWithheldMarker)
        #expect(row.responseBody == RequestLog.contentWithheldMarker)
        #expect(row.toolCalls?.first?.name == "web_search")
        #expect(row.toolCalls?.first?.arguments == RequestLog.contentWithheldMarker)
        #expect(row.model == "mlx-community/test")
        #expect(row.egress?.destinationHost == "api.openai.com")
        #expect(row.egress?.bytesSent == 512)
        #expect(!row.hasStoredContent)

        let s = search().withoutContent()
        #expect(s.egress?.details["query"] == RequestLog.contentWithheldMarker)
        #expect(s.egress?.details["provider_used"] == "tavily")
    }

    /// Rows written with an earlier marker spelling must still read as
    /// withheld, never as real content.
    @Test func legacyWithheldMarkerStillCountsAsWithheld() {
        for legacy in RequestLog.legacyContentWithheldMarkers {
            let row = RequestLog(
                source: .chatUI, method: "POST", path: "/chat/completions", statusCode: 200, durationMs: 1,
                requestBody: legacy, responseBody: legacy, model: "mlx-community/test",
                category: .inference, locality: .local
            )
            #expect(RequestLog.isWithheldContent(legacy))
            #expect(!row.hasStoredContent, "legacy marker \(legacy) must not read as stored content")
        }
        #expect(RequestLog.isWithheldContent(RequestLog.contentWithheldMarker))
        #expect(!RequestLog.isWithheldContent("{\"messages\":[]}"))
        #expect(!RequestLog.isWithheldContent(nil))
    }

    @Test func titlesAreHumanReadable() {
        #expect(inference().title == "test")
        #expect(search(query: "q").title.contains("“q”"))
        let mcp = RequestLog(
            source: .tool, method: "POST", path: "/mcp/x", statusCode: 200, durationMs: 1, category: .mcpToolCall,
            egress: EgressInfo(destinationHost: "mcp.example", details: ["tool": "list_files", "server": "fs"])
        )
        #expect(mcp.title == "list_files @ fs")
        #expect(mcp.destinationDisplay == "mcp.example")
        #expect(inference().destinationDisplay == L("This Mac"))
    }
}
