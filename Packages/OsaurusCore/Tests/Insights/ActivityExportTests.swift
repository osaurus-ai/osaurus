//
//  ActivityExportTests.swift
//  osaurusTests
//
//  Export shapes (JSONL / CSV / Markdown), include-content toggle, and the
//  offline hash-chain recipe published in the JSONL manifest.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("ActivityExport")
struct ActivityExportTests {

    private func seeded() throws -> (ActivityLogStore, [RequestLog]) {
        let store = ActivityLogStore()
        try store.openInMemory()
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        var rows: [RequestLog] = []
        rows.append(
            try store.append(
                RequestLog(
                    timestamp: base,
                    source: .chatUI, method: "POST", path: "/chat/completions", statusCode: 200, durationMs: 1500,
                    requestBody: #"{"messages":[{"role":"user","content":"secret, prompt"}]}"#,
                    responseBody: "answer \"quoted\"",
                    model: "local/model", inputTokens: 3, outputTokens: 9,
                    toolCalls: [ToolCallLog(name: "read_file", arguments: #"{"path":"a.md"}"#)],
                    finishReason: .stop
                )
            )
        )
        rows.append(
            try store.append(
                RequestLog(
                    timestamp: base.addingTimeInterval(30),
                    source: .chatUI, method: "POST", path: "/chat/completions", statusCode: 200, durationMs: 900,
                    requestBody: "{}", responseBody: "cloud answer", model: "gpt-4.1", inputTokens: 5, outputTokens: 7,
                    connection: RequestConnectionInfo(remoteEndpoint: "https://api.openai.com/v1/chat/completions", transport: .direct, mode: .remoteInference),
                    egress: EgressInfo(destinationLabel: "OpenAI", destinationHost: "api.openai.com", bytesSent: 2048, dataClasses: ["prompt"], privacyFilterApplied: true, redactedSpanCount: 1),
                    agentId: UUID(), agentName: "Researcher"
                )
            )
        )
        rows.append(
            try store.append(
                RequestLog(
                    timestamp: base.addingTimeInterval(60),
                    source: .tool, method: "POST", path: "/tools/web_search", statusCode: 502, durationMs: 400,
                    errorMessage: "upstream | failed",
                    category: .webSearch, locality: .remote,
                    egress: EgressInfo(destinationLabel: "Tavily", destinationHost: "api.tavily.com", bytesSent: 128, dataClasses: ["search_query"], details: ["query": "osaurus audit"])
                )
            )
        )
        return (store, rows)
    }

    private func lines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: - JSONL

    @Test func jsonlHasManifestThenOneRecordPerLineInSeqOrder() throws {
        let (store, rows) = try seeded()
        let data = try ActivityExportService.render(
            logs: rows.reversed(),  // newest-first like the UI
            options: ActivityExportOptions(format: .jsonl, includeContent: true, filteredOnly: false),
            filterDescription: "all records",
            verification: try store.verify(),
            appVersion: "test",
            now: Date(timeIntervalSince1970: 1_790_000_100)
        )
        let ls = lines(data).filter { !$0.isEmpty }
        #expect(ls.count == 4)

        struct ManifestLine: Decodable { let manifest: ActivityExportManifest }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let manifest = try dec.decode(ManifestLine.self, from: Data(ls[0].utf8)).manifest
        #expect(manifest.kind == "osaurus.activity-log")
        #expect(manifest.recordCount == 3)
        #expect(manifest.firstSeq == 1)
        #expect(manifest.lastSeq == 3)
        #expect(manifest.lastHash == rows.last?.hash)
        #expect(manifest.chainIntact == true)
        #expect(manifest.localCount == 1)
        #expect(manifest.remoteCount == 2)
        #expect(manifest.bytesSent == 2048 + 128)
        #expect(manifest.includesContent)
        #expect(manifest.hashRecipe.contains("SHA-256"))

        let decoded = try ls.dropFirst().map { try ActivityLogStore.decoder.decode(RequestLog.self, from: Data($0.utf8)) }
        #expect(decoded.map { $0.seq } == [1, 2, 3])
        #expect(decoded[0].requestBody?.contains("secret, prompt") == true)
        #expect(decoded[1].agentName == "Researcher")
    }

    @Test func jsonlChainIsRecomputableOfflineUsingPublishedRecipe() throws {
        let (store, rows) = try seeded()
        let data = try ActivityExportService.render(
            logs: rows, options: ActivityExportOptions(format: .jsonl, includeContent: true, filteredOnly: false),
            filterDescription: "all records", verification: try store.verify()
        )
        let recordLines = lines(data).filter { !$0.isEmpty }.dropFirst()
        var prev = ActivityLogStore.genesisHash
        for line in recordLines {
            var record = try ActivityLogStore.decoder.decode(RequestLog.self, from: Data(line.utf8))
            let claimed = try #require(record.hash)
            #expect(record.prevHash == prev)
            record.hash = nil
            let payload = try ActivityLogStore.canonicalEncoder.encode(record)
            let recomputed = ActivityLogStore.hash(prevHash: prev, payload: payload)
            #expect(recomputed == claimed, "seq \(record.seq ?? -1)")
            prev = claimed
        }
    }

    @Test func withholdingContentMasksBodiesButKeepsChainFieldsAndMetadata() throws {
        let (store, rows) = try seeded()
        let data = try ActivityExportService.render(
            logs: rows, options: ActivityExportOptions(format: .jsonl, includeContent: false, filteredOnly: false),
            filterDescription: "all records", verification: try store.verify()
        )
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("secret, prompt"))
        #expect(!text.contains("cloud answer"))
        #expect(!text.contains("osaurus audit"))
        #expect(text.contains(RequestLog.contentWithheldMarker))
        #expect(text.contains("\"includesContent\":false"))
        // Chain fields survive so the reviewer still knows which rows these were.
        for row in rows {
            #expect(text.contains(try #require(row.hash)))
        }
        #expect(text.contains("api.openai.com"))
        #expect(text.contains("read_file"))
    }

    // MARK: - CSV

    @Test func csvHasHeaderAndEscapesFields() throws {
        let (store, rows) = try seeded()
        let data = try ActivityExportService.render(
            logs: rows, options: ActivityExportOptions(format: .csv, includeContent: true, filteredOnly: true),
            filterDescription: "x", verification: try store.verify()
        )
        let ls = lines(data).filter { !$0.isEmpty }
        #expect(ls.count == 4)
        #expect(ls[0] == ActivityExportService.csvColumns.joined(separator: ","))
        // No message bodies in CSV regardless of includeContent.
        #expect(!ls.joined().contains("secret, prompt"))
        // Row 1: local inference
        #expect(ls[1].hasPrefix("1,"))
        #expect(ls[1].contains(",inference,local,,,"))
        #expect(ls[1].contains(",read_file,stop,"))
        // Row 2: remote with destination, privacy filter
        #expect(ls[2].contains(",inference,remote,OpenAI,api.openai.com,"))
        #expect(ls[2].contains(",Researcher,5,7,2048,,true,1,prompt,"))
        // Row 3: error with pipe + spaces in message — not a CSV special char, so unquoted.
        #expect(ls[3].contains(",web_search,remote,Tavily,api.tavily.com,"))
        #expect(ls[3].contains(",502,true,400,"))
        // Every data row has exactly the header's column count.
        for l in ls.dropFirst() {
            #expect(parseCSVRow(l).count == ActivityExportService.csvColumns.count, Comment(rawValue: l))
        }
    }

    @Test func csvEscapeQuotesCommasQuotesAndNewlines() {
        #expect(ActivityExportService.csvEscape("plain") == "plain")
        #expect(ActivityExportService.csvEscape("a,b") == "\"a,b\"")
        #expect(ActivityExportService.csvEscape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(ActivityExportService.csvEscape("l1\nl2") == "\"l1\nl2\"")
    }

    private func parseCSVRow(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuotes = false
        var it = line.makeIterator()
        while let c = it.next() {
            if inQuotes {
                if c == "\"" { inQuotes = false } else { cur.append(c) }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                out.append(cur)
                cur = ""
            } else {
                cur.append(c)
            }
        }
        out.append(cur)
        return out
    }

    // MARK: - Markdown

    @Test func markdownReportHasSummaryDestinationsAndEntries() throws {
        let (store, rows) = try seeded()
        let data = try ActivityExportService.render(
            logs: rows, options: ActivityExportOptions(format: .markdown, includeContent: true, filteredOnly: false),
            filterDescription: "cloud only", verification: try store.verify(), appVersion: "9.9"
        )
        let md = String(decoding: data, as: UTF8.self)
        #expect(md.hasPrefix("# Osaurus Activity Log"))
        #expect(md.contains("- App version: 9.9"))
        #expect(md.contains("- Records: 3 (1 local, 2 cloud)"))
        #expect(md.contains("- Filter: cloud only"))
        #expect(md.contains("- Integrity: chain verified"))
        #expect(md.contains("## Cloud destinations"))
        #expect(md.contains("| OpenAI | api.openai.com | 1 |"))
        #expect(md.contains("| Tavily | api.tavily.com | 1 |"))
        #expect(md.contains("## Activity"))
        #expect(md.contains("Cloud → OpenAI"))
        #expect(md.contains("Local"))
        #expect(md.contains("privacy filter: 1 span(s) redacted"))
        // Pipe in the error message is escaped so it doesn't break tables.
        #expect(md.contains("error: upstream \\| failed"))
        #expect(md.contains("<details><summary>Request</summary>"))
        #expect(md.contains("secret, prompt"))
    }

    @Test func markdownWithoutContentOmitsBodies() throws {
        let (store, rows) = try seeded()
        let data = try ActivityExportService.render(
            logs: rows, options: ActivityExportOptions(format: .markdown, includeContent: false, filteredOnly: false),
            filterDescription: "all records", verification: try store.verify()
        )
        let md = String(decoding: data, as: UTF8.self)
        #expect(md.contains("- Message content: withheld"))
        #expect(!md.contains("<details>"))
        #expect(!md.contains("secret, prompt"))
    }

    @Test func markdownFlagsBrokenChain() throws {
        let (store, rows) = try seeded()
        try store.executeForTesting("UPDATE activity SET payload = X'7b7d' WHERE seq = 2")
        let data = try ActivityExportService.render(
            logs: rows, options: ActivityExportOptions(format: .markdown, includeContent: false, filteredOnly: false),
            filterDescription: "all records", verification: try store.verify()
        )
        let md = String(decoding: data, as: UTF8.self)
        #expect(md.contains("- Integrity: PROBLEMS FOUND"))
        #expect(md.contains("#2"))
    }

    // MARK: - Filter description & filename

    @Test func systemRowsExportWithPlainLanguageTitle() throws {
        let (store, _) = try seeded()
        try store.recordVerification(try store.verify())
        try store.appendSystemEvent(
            "exported", details: ["format": "jsonl", "records": "3", "include_content": "false", "file_name": "x.jsonl"])
        var rows: [RequestLog] = []
        try store.forEach { rows.append($0) }
        let data = try ActivityExportService.render(
            logs: rows, options: ActivityExportOptions(format: .csv), filterDescription: "all records",
            verification: try store.verify())
        let csv = String(decoding: data, as: UTF8.self)
        #expect(csv.contains("system,local"))
        #expect(csv.contains("/activity/verified"))
        #expect(csv.contains("/activity/exported"))
        let verified = try #require(rows.first { $0.path == "/activity/verified" })
        #expect(verified.title.lowercased().contains("verif"))
        #expect(verified.systemEventSummary?.contains("3 records") == true)
        let exported = try #require(rows.first { $0.path == "/activity/exported" })
        #expect(exported.systemEventSummary?.contains("metadata only") == true)
        // The custody rows are chained like everything else.
        #expect(try store.verify().isIntact)

        let jsonl = try ActivityExportService.render(
            logs: rows, options: ActivityExportOptions(format: .jsonl), filterDescription: "all records",
            verification: try store.verify())
        let last = try #require(lines(jsonl).filter { !$0.isEmpty }.last)
        #expect(last.contains(#""category":"system""#))
        #expect(last.contains(#""event":"exported""#))
    }

    @Test func describeFilterIsReadable() {
        #expect(ActivityExportService.describe(.empty) == "all records")
        var f = ActivityFilter()
        f.locality = .remote
        f.dateRange = .last7Days
        f.categories = [.webSearch, .inference]
        f.destinationHost = "api.openai.com"
        f.status = .error
        f.text = "foo"
        let d = ActivityExportService.describe(f)
        #expect(d.contains("text \"foo\""))
        #expect(d.contains("cloud only"))
        #expect(d.contains("categories: inference, web_search"))
        #expect(d.contains("destination api.openai.com"))
        #expect(d.contains(ActivityDateRange.last7Days.displayName))
    }

    @Test func suggestedFilenameUsesFormatExtension() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let name = ActivityExportService.suggestedFilename(format: .csv, now: now)
        #expect(name.hasPrefix("osaurus-activity-"))
        #expect(name.hasSuffix(".csv"))
        #expect(ActivityExportService.suggestedFilename(format: .jsonl, now: now).hasSuffix(".jsonl"))
        #expect(ActivityExportService.suggestedFilename(format: .markdown, now: now).hasSuffix(".md"))
    }
}
