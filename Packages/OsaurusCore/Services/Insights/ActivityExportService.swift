//
//  ActivityExportService.swift
//  osaurus
//
//  Serialises activity-log rows for outside review. Three shapes:
//
//    - JSONL: full fidelity, one record per line with `seq` / `prevHash` /
//      `hash`, preceded by a manifest line so a reviewer can verify the
//      chain offline.
//    - CSV: one summary row per record (no bodies) for spreadsheets.
//    - Markdown: a human-readable report — totals, local/cloud split,
//      per-destination table, chronological entries.
//
//  Pure functions over `[RequestLog]`; the save-panel glue lives in
//  `ActivityExportCoordinator`.
//

import Foundation

enum ActivityExportFormat: String, CaseIterable, Identifiable {
    case jsonl
    case csv
    case markdown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .jsonl: return "JSONL"
        case .csv: return "CSV"
        case .markdown: return "Markdown"
        }
    }

    var fileExtension: String {
        switch self {
        case .jsonl: return "jsonl"
        case .csv: return "csv"
        case .markdown: return "md"
        }
    }

    var summary: String {
        switch self {
        case .jsonl: return L("Full detail, one record per line, with hash-chain fields. Best for machine review.")
        case .csv: return L("One summary row per record (no message bodies). Best for spreadsheets.")
        case .markdown: return L("Readable report with totals, destinations, and a chronological list.")
        }
    }
}

struct ActivityExportOptions: Equatable {
    var format: ActivityExportFormat = .jsonl
    /// When false, bodies / tool arguments are replaced with the withheld
    /// marker so the file can be handed to a reviewer who shouldn't see
    /// message content.
    var includeContent: Bool = true
    /// Export the filtered view (true) or the whole log (false).
    var filteredOnly: Bool = true
}

/// First line of a JSONL export; also rendered at the top of Markdown.
struct ActivityExportManifest: Codable, Equatable {
    let kind: String
    let version: Int
    let exportedAt: Date
    let appVersion: String
    let recordCount: Int
    let includesContent: Bool
    let filterDescription: String
    let firstSeq: Int?
    let lastSeq: Int?
    let lastHash: String?
    let chainIntact: Bool?
    let chainProblems: [String]
    let localCount: Int
    let remoteCount: Int
    let bytesSent: Int
    /// How to recompute each record's `hash` offline.
    let hashRecipe: String

    static let currentVersion = 1
    static let hashRecipe =
        "hash = hex(SHA-256(UTF-8(prevHash + \"\\n\" + canonicalJSON(record without its hash key)))); "
        + "canonicalJSON = compact JSON, keys sorted, slashes unescaped, timestamps as milliseconds since 1970, "
        + "null fields omitted; genesis prevHash = 64 zeros"
}

enum ActivityExportService {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Chained row encoder: must match `ActivityLogStore.canonicalEncoder`
    /// so a reviewer can recompute hashes from the export.
    static let recordEncoder: JSONEncoder = ActivityLogStore.canonicalEncoder

    // MARK: - Entry point

    static func render(
        logs: [RequestLog],
        options: ActivityExportOptions,
        filterDescription: String,
        verification: ActivityLogVerification?,
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
        now: Date = Date()
    ) throws -> Data {
        let rows = options.includeContent ? logs : logs.map { $0.withoutContent() }
        let ordered = rows.sorted { ($0.seq ?? 0, $0.timestamp) < ($1.seq ?? 0, $1.timestamp) }
        let manifest = ActivityExportManifest(
            kind: "osaurus.activity-log",
            version: ActivityExportManifest.currentVersion,
            exportedAt: now,
            appVersion: appVersion,
            recordCount: ordered.count,
            includesContent: options.includeContent,
            filterDescription: filterDescription,
            firstSeq: ordered.first?.seq,
            lastSeq: ordered.last?.seq,
            lastHash: ordered.last?.hash,
            chainIntact: verification?.isIntact,
            chainProblems: verification?.problems.map(\.description) ?? [],
            localCount: ordered.filter { $0.locality == .local }.count,
            remoteCount: ordered.filter { $0.locality == .remote }.count,
            bytesSent: ordered.reduce(0) { $0 + ($1.egress?.bytesSent ?? 0) },
            hashRecipe: ActivityExportManifest.hashRecipe
        )
        switch options.format {
        case .jsonl: return try renderJSONL(ordered, manifest: manifest)
        case .csv: return Data(renderCSV(ordered).utf8)
        case .markdown: return Data(renderMarkdown(ordered, manifest: manifest).utf8)
        }
    }

    // MARK: - JSONL

    static func renderJSONL(_ rows: [RequestLog], manifest: ActivityExportManifest) throws -> Data {
        var out = Data()
        out.append(try encoder.encode(ManifestLine(manifest: manifest)))
        out.append(0x0A)
        for row in rows {
            out.append(try recordEncoder.encode(row))
            out.append(0x0A)
        }
        return out
    }

    private struct ManifestLine: Codable {
        let manifest: ActivityExportManifest
    }

    // MARK: - CSV

    static let csvColumns: [String] = [
        "seq", "timestamp", "category", "locality", "destination", "destination_host", "title",
        "source", "method", "path", "status", "error", "duration_ms", "model", "agent",
        "input_tokens", "output_tokens", "bytes_sent", "bytes_received", "privacy_filter",
        "redacted_spans", "data_classes", "tool_calls", "finish_reason", "request_id", "turn_id", "hash",
    ]

    static func renderCSV(_ rows: [RequestLog]) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines: [String] = [csvColumns.joined(separator: ",")]
        for r in rows {
            let fields: [String] = [
                r.seq.map(String.init) ?? "",
                iso.string(from: r.timestamp),
                r.category.rawValue,
                r.locality.rawValue,
                r.locality == .remote ? r.destinationDisplay : "",
                r.egress?.destinationHost ?? "",
                r.title,
                r.source.rawValue,
                r.method,
                r.path,
                String(r.statusCode),
                r.isError ? "true" : "false",
                String(format: "%.0f", r.durationMs),
                r.model ?? "",
                r.agentName ?? "",
                r.inputTokens.map(String.init) ?? "",
                r.outputTokens.map(String.init) ?? "",
                r.egress?.bytesSent.map(String.init) ?? "",
                r.egress?.bytesReceived.map(String.init) ?? "",
                (r.egress?.privacyFilterApplied ?? false) ? "true" : "false",
                r.egress?.redactedSpanCount.map(String.init) ?? "",
                (r.egress?.dataClasses ?? []).joined(separator: ";"),
                (r.toolCalls ?? []).map(\.name).joined(separator: ";"),
                r.finishReason?.rawValue ?? "",
                r.requestId ?? "",
                r.turnId?.uuidString ?? "",
                r.hash ?? "",
            ]
            lines.append(fields.map(csvEscape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func csvEscape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Markdown

    static func renderMarkdown(_ rows: [RequestLog], manifest: ActivityExportManifest) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium
        var md: [String] = []
        md.append("# Osaurus Activity Log")
        md.append("")
        md.append("- Exported: \(df.string(from: manifest.exportedAt))")
        md.append("- App version: \(manifest.appVersion)")
        md.append("- Records: \(manifest.recordCount) (\(manifest.localCount) local, \(manifest.remoteCount) cloud)")
        md.append("- Filter: \(manifest.filterDescription)")
        md.append("- Message content: \(manifest.includesContent ? "included" : "withheld")")
        md.append("- Bytes sent to cloud: \(ActivitySummary.formattedBytes(manifest.bytesSent))")
        if let intact = manifest.chainIntact {
            md.append("- Integrity: \(intact ? "chain verified" : "PROBLEMS FOUND")")
            for p in manifest.chainProblems { md.append("  - \(p)") }
        }
        if let first = manifest.firstSeq, let last = manifest.lastSeq {
            md.append("- Chain range: #\(first) – #\(last)" + (manifest.lastHash.map { ", last hash `\($0)`" } ?? ""))
        }
        md.append("")

        // Destinations
        let remote = rows.filter { $0.locality == .remote }
        if !remote.isEmpty {
            md.append("## Cloud destinations")
            md.append("")
            md.append("| Destination | Host | Requests | Bytes sent | Errors |")
            md.append("|---|---|---:|---:|---:|")
            var byDest: [String: (label: String, host: String, count: Int, bytes: Int, errors: Int)] = [:]
            for r in remote {
                let host = r.egress?.destinationHost ?? EgressInfo.host(from: r.connection?.remoteEndpoint) ?? ""
                let key = host.isEmpty ? r.destinationDisplay : host
                var e = byDest[key] ?? (r.destinationDisplay, host, 0, 0, 0)
                e.count += 1
                e.bytes += r.egress?.bytesSent ?? 0
                e.errors += r.isError ? 1 : 0
                byDest[key] = e
            }
            for e in byDest.values.sorted(by: { $0.count > $1.count }) {
                md.append("| \(mdEscape(e.label)) | \(mdEscape(e.host)) | \(e.count) | \(ActivitySummary.formattedBytes(e.bytes)) | \(e.errors) |")
            }
            md.append("")
        }

        md.append("## Activity")
        md.append("")
        var currentDay = ""
        let dayFormatter = DateFormatter()
        dayFormatter.dateStyle = .full
        dayFormatter.timeStyle = .none
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .medium
        for r in rows {
            let day = dayFormatter.string(from: r.timestamp)
            if day != currentDay {
                currentDay = day
                md.append("### \(day)")
                md.append("")
            }
            let where_ = r.locality == .remote ? "☁️ Cloud → \(r.destinationDisplay)" : "💻 Local"
            let status = r.isError ? "FAILED" : "ok"
            md.append("- **\(timeFormatter.string(from: r.timestamp))** · \(r.category.displayName) · \(where_) · \(mdEscape(r.title)) · \(status) · \(r.formattedDuration)" + (r.seq.map { " · #\($0)" } ?? ""))
            var facts: [String] = []
            facts.append("source: \(r.source.rawValue)")
            if let model = r.model { facts.append("model: \(model)") }
            if let agent = r.agentName { facts.append("agent: \(agent)") }
            if let i = r.inputTokens, let o = r.outputTokens { facts.append("tokens: \(i) in / \(o) out") }
            if let e = r.egress {
                if let b = e.bytesSent { facts.append("sent: \(ActivitySummary.formattedBytes(b))") }
                if !e.dataClasses.isEmpty { facts.append("data: \(e.dataClasses.joined(separator: ", "))") }
                if e.privacyFilterApplied { facts.append("privacy filter: \(e.redactedSpanCount ?? 0) span(s) redacted") }
                for (k, v) in e.details.sorted(by: { $0.key < $1.key }) where !v.isEmpty {
                    facts.append("\(k): \(mdEscape(String(v.prefix(300))))")
                }
            }
            if let tools = r.toolCalls, !tools.isEmpty {
                facts.append("tools: \(tools.map(\.name).joined(separator: ", "))")
            }
            if let err = r.errorMessage { facts.append("error: \(mdEscape(err))") }
            for f in facts { md.append("  - \(f)") }
            if r.hasStoredContent, let body = r.requestBody, !RequestLog.isWithheldContent(body) {
                md.append("  <details><summary>Request</summary>")
                md.append("")
                md.append("  ```")
                md.append(indent(String(body.prefix(4_000))))
                md.append("  ```")
                md.append("  </details>")
            }
            if r.hasStoredContent, let body = r.responseBody, !RequestLog.isWithheldContent(body), r.category != .pluginLog {
                md.append("  <details><summary>Response</summary>")
                md.append("")
                md.append("  ```")
                md.append(indent(String(body.prefix(4_000))))
                md.append("  ```")
                md.append("  </details>")
            }
        }
        md.append("")
        return md.joined(separator: "\n")
    }

    private static func indent(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n")
    }

    static func mdEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - Filter description

    static func describe(_ f: ActivityFilter) -> String {
        if f.isEmpty { return "all records" }
        var parts: [String] = []
        if !f.text.isEmpty { parts.append("text \"\(f.text)\"") }
        if f.dateRange != .all { parts.append(f.dateRange.displayName) }
        if let l = f.locality { parts.append(l == .local ? "local only" : "cloud only") }
        if !f.categories.isEmpty { parts.append("categories: " + f.categories.map(\.rawValue).sorted().joined(separator: ", ")) }
        if !f.sources.isEmpty { parts.append("sources: " + f.sources.map(\.rawValue).sorted().joined(separator: ", ")) }
        if let h = f.destinationHost { parts.append("destination \(h)") }
        if let m = f.model { parts.append("model \(m)") }
        if let a = f.agentId { parts.append("agent \(a.uuidString)") }
        if f.status != .all { parts.append(f.status.rawValue) }
        if let pf = f.privacyFilterApplied { parts.append(pf ? "privacy-filtered" : "not privacy-filtered") }
        if !f.includePluginLogs { parts.append("plugin logs hidden") }
        return parts.joined(separator: "; ")
    }

    static func suggestedFilename(format: ActivityExportFormat, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmm"
        return "osaurus-activity-\(f.string(from: now)).\(format.fileExtension)"
    }
}
