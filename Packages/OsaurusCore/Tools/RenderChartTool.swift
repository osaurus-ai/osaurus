//
//  RenderChartTool.swift
//  osaurus
//
//  Builds a ChartSpec from attachment content passed directly by the model.
//  The model passes the raw file content + column references — the tool does
//  all parsing, type coercion, and downsampling so the model never has to
//  format individual data points.
//

import Foundation

struct RenderChartTool: OsaurusTool {
    let name = "render_chart"
    let description =
        "Render a chart from attachment data. Use when the user has attached a data file (CSV, TSV, JSON). Pass the raw file content and column names — the tool handles all parsing and downsampling."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "required": .array([.string("data"), .string("chartType"), .string("series")]),
        "properties": .object([
            "data": .object([
                "type": .string("string"),
                "description": .string("The raw content of the attached file (CSV, TSV, or JSON array of objects)"),
            ]),
            "format": .object([
                "type": .string("string"),
                "description": .string("File format: csv, tsv, or json. Defaults to csv."),
            ]),
            "chartType": .object([
                "type": .string("string"),
                "description": .string(
                    "Chart type: column, bar, line, spline, area, areaspline, pie, scatter, bubble, gauge, waterfall, boxplot"
                ),
            ]),
            "xColumn": .object([
                "type": .string("string"),
                "description": .string("Column name to use as x-axis labels / categories"),
            ]),
            "series": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Column names to plot as data series"),
            ]),
            "title": .object([
                "type": .string("string"),
                "description": .string("Chart title"),
            ]),
            "tooltipSuffix": .object([
                "type": .string("string"),
                "description": .string("Unit suffix shown in tooltips (e.g. USD, %, ms)"),
            ]),
        ]),
    ])

    private static let maxRows = 500

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON) else {
            return errorResult("Invalid arguments JSON")
        }

        guard let raw = args["data"] as? String else {
            return errorResult("data is required — pass the full raw file content")
        }

        // chartType may be top-level or nested inside a "properties" object (model schema confusion)
        let chartType: String
        if let ct = args["chartType"] as? String {
            chartType = ct
        } else if let props = args["properties"] as? [String: Any],
                  let ct = props["chartType"] as? String {
            chartType = ct
        } else if let propsStr = args["properties"] as? String,
                  let data = propsStr.data(using: .utf8),
                  let props = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ct = props["chartType"] as? String {
            chartType = ct
        } else {
            return errorResult("chartType is required (e.g. \"line\", \"column\", \"pie\")")
        }

        // series may be a proper array or a JSON-encoded string array
        guard let seriesCols = coerceStringArray(args["series"]) ?? parseStringArrayFromJSON(args["series"]) else {
            return errorResult("series is required — pass an array of column names to plot")
        }

        let format    = (args["format"] as? String)?.lowercased() ?? "csv"
        let xColumn   = args["xColumn"]       as? String
        let title     = args["title"]         as? String
        let tipSuffix = args["tooltipSuffix"] as? String

        let headers: [String]
        let rows: [[String]]
        do {
            switch format {
            case "json":
                (headers, rows) = try parseJSON(raw)
            case "tsv":
                (headers, rows) = parseDelimited(raw, separator: "\t")
            default:
                (headers, rows) = parseDelimited(raw, separator: ",")
            }
        } catch {
            return errorResult(error.localizedDescription)
        }

        guard !headers.isEmpty else {
            return errorResult("Could not parse any columns from the provided data")
        }

        // Validate columns
        var missingColumns: [String] = []
        for col in seriesCols where !headers.contains(col) {
            missingColumns.append(col)
        }
        if let x = xColumn, !headers.contains(x) {
            missingColumns.append(x)
        }
        if !missingColumns.isEmpty {
            return errorResult(
                "Column(s) not found: \(missingColumns.joined(separator: ", ")). Available columns: \(headers.joined(separator: ", "))"
            )
        }

        // Downsample if needed
        var note: String? = nil
        var dataRows = rows
        if rows.count > Self.maxRows {
            dataRows = downsample(rows, to: Self.maxRows)
            note = "Downsampled from \(rows.count) to \(Self.maxRows) rows for rendering"
        }

        // Build categories from xColumn
        var categories: [String]? = nil
        if let xCol = xColumn, let xIdx = headers.firstIndex(of: xCol) {
            categories = dataRows.map { row in xIdx < row.count ? row[xIdx] : "" }
        }

        // Build series, skipping non-numeric columns
        var chartSeries: [ChartSeries] = []
        var skippedColumns: [String] = []

        for col in seriesCols {
            guard let idx = headers.firstIndex(of: col) else { continue }
            let data: [Double?] = dataRows.map { row in
                idx < row.count ? Double(row[idx].trimmingCharacters(in: .whitespaces)) : nil
            }
            if data.allSatisfy({ $0 == nil }) {
                skippedColumns.append(col)
                continue
            }
            chartSeries.append(ChartSeries(name: col, data: data))
        }

        if !skippedColumns.isEmpty {
            let skipNote = "Column(s) '\(skippedColumns.joined(separator: ", "))' had no numeric data and were skipped"
            note = note.map { $0 + "; " + skipNote } ?? skipNote
        }

        if chartSeries.isEmpty {
            return errorResult("No numeric series could be extracted from the specified columns")
        }

        let spec = ChartSpec(
            chartType: chartType,
            title: title,
            categories: categories,
            series: chartSeries,
            tooltipSuffix: tipSuffix,
            note: note
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let jsonData = try encoder.encode(spec)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        return "---CHART_START---\n\(jsonString)\n---CHART_END---"
    }

    // MARK: - Parsing

    private func parseDelimited(_ raw: String, separator: Character) -> ([String], [[String]]) {
        var lines = raw.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return ([], []) }
        let headers = lines.removeFirst()
            .components(separatedBy: String(separator))
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let rows = lines.map {
            $0.components(separatedBy: String(separator))
              .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return (headers, rows)
    }

    private func parseJSON(_ raw: String) throws -> ([String], [[String]]) {
        guard let data = raw.data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = array.first
        else {
            throw NSError(
                domain: "RenderChartTool", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "JSON must be an array of objects"]
            )
        }
        let headers = Array(first.keys).sorted()
        let rows: [[String]] = array.map { obj in headers.map { key in "\(obj[key] ?? "")" } }
        return (headers, rows)
    }

    private func downsample(_ rows: [[String]], to maxCount: Int) -> [[String]] {
        guard rows.count > maxCount else { return rows }
        let step = Double(rows.count) / Double(maxCount)
        return (0..<maxCount).map { i in rows[Int(Double(i) * step)] }
    }

    /// Fallback for when the model serializes an array as a JSON string e.g. "[\"Apple\",\"Google\"]"
    private func parseStringArrayFromJSON(_ value: Any?) -> [String]? {
        guard let str = value as? String,
              let data = str.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return nil }
        return arr.isEmpty ? nil : arr
    }

    private func errorResult(_ message: String) -> String {
        let escaped = message.replacingOccurrences(of: "\"", with: "'")
        return "{\"error\": \"\(escaped)\"}"
    }
}
