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

    /// Canonical sorted list of chart types — single source of truth so
    /// the JSON schema enum, the description, and the failure messages
    /// all agree with `ChartSpec.validChartTypes`.
    private static let sortedChartTypes: [String] = ChartSpec.validChartTypes.sorted()
    private static let chartTypeList: String = sortedChartTypes.joined(separator: ", ")
    private static let chartTypeEnum: JSONValue = .array(sortedChartTypes.map { .string($0) })

    var description: String {
        "Render a chart card inline in the chat from tabular data. Supported chart types: \(Self.chartTypeList). "
            + "Pass the raw file content + column names; the tool handles parsing, type coercion, and downsampling. "
            + "Use when the user has attached a data file (CSV/TSV/JSON) — for arbitrary images or saved chart files, use `share_artifact` instead."
    }

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        // Note: NOT setting `additionalProperties: false` here — render_chart
        // historically tolerated a nested `properties` object as a model
        // schema-confusion fallback (see execute body). Locking the schema
        // strict would break that compat.
        "required": .array([.string("data"), .string("chartType"), .string("series")]),
        "properties": .object([
            "data": .object([
                "type": .string("string"),
                "description": .string("The raw content of the attached file (CSV, TSV, or JSON array of objects)."),
            ]),
            "format": .object([
                "type": .string("string"),
                "description": .string("File format: `csv`, `tsv`, or `json`."),
                "enum": .array([.string("csv"), .string("tsv"), .string("json")]),
                "default": .string("csv"),
            ]),
            "chartType": .object([
                "type": .string("string"),
                "description": .string("Chart type. Strict enum — invalid values are rejected with `invalid_args`."),
                "enum": Self.chartTypeEnum,
            ]),
            "xColumn": .object([
                "type": .string("string"),
                "description": .string("Column name to use as x-axis labels / categories."),
            ]),
            "series": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Column names to plot as data series."),
            ]),
            "title": .object([
                "type": .string("string"),
                "description": .string("Chart title."),
            ]),
            "tooltipSuffix": .object([
                "type": .string("string"),
                "description": .string("Unit suffix shown in tooltips (e.g. `USD`, `%`, `ms`)."),
            ]),
        ]),
    ])

    private static let maxRows = 500

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let dataReq = requireString(
            args,
            "data",
            expected: "raw file content (CSV / TSV / JSON array of objects)",
            tool: name
        )
        guard case .value(let raw) = dataReq else { return dataReq.failureEnvelope ?? "" }

        // chartType may be top-level or nested inside a "properties" object (model schema confusion)
        let chartType: String
        if let ct = args["chartType"] as? String {
            chartType = ct
        } else if let props = args["properties"] as? [String: Any],
            let ct = props["chartType"] as? String
        {
            chartType = ct
        } else if let propsStr = args["properties"] as? String,
            let data = propsStr.data(using: .utf8),
            let props = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let ct = props["chartType"] as? String
        {
            chartType = ct
        } else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Missing required argument `chartType`.",
                field: "chartType",
                expected: "one of \(Self.chartTypeList)",
                tool: name
            )
        }

        // Reject unknown chart types up front. Previously `ChartSpec.normalized`
        // silently coerced anything-not-in-validChartTypes to `column`, hiding
        // the model's mistake.
        guard ChartSpec.validChartTypes.contains(chartType) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Unknown `chartType`: `\(chartType)`. Use one of: \(Self.chartTypeList).",
                field: "chartType",
                expected: "one of \(Self.chartTypeList)",
                tool: name
            )
        }

        // series may be a proper array or a JSON-encoded string array
        guard let seriesCols = coerceStringArray(args["series"]) ?? parseStringArrayFromJSON(args["series"]),
            !seriesCols.isEmpty
        else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Missing required argument `series` (array of column names).",
                field: "series",
                expected: "non-empty array of column-name strings",
                tool: name
            )
        }

        let format = (args["format"] as? String)?.lowercased() ?? "csv"
        let xColumn = args["xColumn"] as? String
        let title = args["title"] as? String
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
            return ToolEnvelope.failure(
                kind: .executionError,
                message: error.localizedDescription,
                tool: name,
                retryable: true
            )
        }

        guard !headers.isEmpty else {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Could not parse any columns from the provided data.",
                tool: name,
                retryable: true
            )
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
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Column(s) not found: \(missingColumns.joined(separator: ", ")). "
                    + "Available columns: \(headers.joined(separator: ", ")).",
                field: missingColumns.contains(where: { seriesCols.contains($0) }) ? "series" : "xColumn",
                expected: "column name(s) present in the parsed headers",
                tool: name
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
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "No numeric series could be extracted from the specified columns.",
                tool: name,
                retryable: true
            )
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
        // Marker block is parsed by `parseChartSpecFromResult` downstream.
        // Wrapped in the success envelope's `text` so `BatchTool` and the
        // tool-call card can detect success without parsing markers first.
        let marker = "---CHART_START---\n\(jsonString)\n---CHART_END---"
        return ToolEnvelope.success(tool: name, text: marker)
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
                domain: "RenderChartTool",
                code: 1,
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
        return (0 ..< maxCount).map { i in rows[Int(Double(i) * step)] }
    }

    /// Fallback for when the model serializes an array as a JSON string e.g. "[\"Apple\",\"Google\"]"
    private func parseStringArrayFromJSON(_ value: Any?) -> [String]? {
        guard let str = value as? String,
            let data = str.data(using: .utf8),
            let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return nil }
        return arr.isEmpty ? nil : arr
    }

}
