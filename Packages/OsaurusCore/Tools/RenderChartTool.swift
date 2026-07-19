//
//  RenderChartTool.swift
//  osaurus
//
//  Builds a ChartSpec from raw tabular content passed directly by the model
//  or by reference from `search_and_extract`. The tool handles parsing, type
//  coercion, and downsampling so the model never has to format or re-prefill
//  individual data points.
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
        "Render a chart card inline in the chat from CSV, TSV, or JSON data already "
            + "obtained or generated in this turn. Supported chart types: \(Self.chartTypeList). "
            + "Pass either the full raw `data` or a `dataRef` returned by search_and_extract. "
            + "Data may come from web extraction, an attachment, sandbox/file read, download, or computation. "
            + "For delimited data, preserve its header row and pass column names; when `series` is omitted, "
            + "numeric columns are inferred. For nested JSON references, "
            + "copy the returned xPath/seriesPaths next action. This tool does not fetch URLs, so retrieve data first. "
            + "A successful result is already displayed as an inline chart card; create a separate file only when "
            + "the user explicitly requests a saved or downloadable artifact."
    }

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        // The `properties:` wrapper schema-confusion case is now rescued
        // by `SchemaValidator.coerceArguments` for every tool, so we can
        // safely lock this schema strict. Keeps the model from sneaking
        // in unexpected keys (e.g. `chartType` typoed as `chart_type`)
        // by surfacing them as `invalid_args` instead of silently
        // dropping them.
        "additionalProperties": .bool(false),
        "properties": .object([
            "data": .object([
                "type": .string("string"),
                "description": .string(
                    "Raw CSV, TSV, or JSON array-of-objects content to chart. Omit when using dataRef. It may come from "
                        + "an attachment, web extraction, sandbox/file read, download, or computation. "
                        + "Preserve the CSV/TSV header row when one is available."
                ),
            ]),
            "dataRef": .object([
                "type": .string("string"),
                "description": .string(
                    "Session-scoped structured-data reference returned by search_and_extract. Preferred over copying a large raw payload into data."
                ),
            ]),
            "format": .object([
                "type": .string("string"),
                "description": .string("File format: `csv`, `tsv`, or `json`."),
                "enum": .array([.string("csv"), .string("tsv"), .string("json")]),
                "default": .string("csv"),
            ]),
            "dataFormat": .object([
                "type": .string("string"),
                "description": .string(
                    "Compatibility alias for `format`. Prefer `format`; accepted to recover local-model argument drift."
                ),
                "enum": .array([.string("csv"), .string("tsv"), .string("json")]),
            ]),
            "chartType": .object([
                "type": .string("string"),
                "description": .string("Chart type. Strict enum — invalid values are rejected with `invalid_args`."),
                "enum": Self.chartTypeEnum,
                "default": .string("line"),
            ]),
            "xColumn": .object([
                "type": .string("string"),
                "description": .string("Column name to use as x-axis labels / categories."),
            ]),
            "series": .object([
                "oneOf": .array([
                    .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                    .object(["type": .string("string")]),
                ]),
                "description": .string(
                    "Column names to plot as data series for CSV/TSV or JSON array-of-objects. "
                        + "Use an array; a string-encoded array is accepted for local-model compatibility."
                ),
            ]),
            "yColumn": .object([
                "type": .string("string"),
                "description": .string(
                    "Compatibility alias for one `series` column. Prefer `series`; accepted to recover local-model argument drift."
                ),
            ]),
            "xPath": .object([
                "type": .string("string"),
                "description": .string(
                    "Dot/index path to the x-axis array inside nested JSON held by dataRef, for example chart.result[0].timestamp."
                ),
            ]),
            "seriesPaths": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "required": .array([.string("name"), .string("path")]),
                    "properties": .object([
                        "name": .object(["type": .string("string")]),
                        "path": .object(["type": .string("string")]),
                    ]),
                ]),
                "description": .string(
                    "Named numeric array paths inside nested JSON held by dataRef. Copy these from search_and_extract next_action."
                ),
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
        guard case .value(let parsedArgs) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let args = Self.recoverNestedChartArguments(parsedArgs)

        let chartType: String
        if args["chartType"] == nil {
            // A line chart is the search pipeline's advertised default. Keep
            // the field optional at the schema boundary so XML tool parsing
            // preserves the model's dataRef/xColumn/series arguments when a
            // small local model omits only this otherwise recoverable value.
            chartType = "line"
        } else {
            let chartReq = requireString(
                args,
                "chartType",
                expected: "one of \(Self.chartTypeList)",
                tool: name
            )
            guard case .value(let requestedChartType) = chartReq else {
                return chartReq.failureEnvelope ?? ""
            }
            chartType = requestedChartType
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

        let dataRef = (args["dataRef"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let referencedEntry: SearchStructuredDataEntry?
        if let dataRef, !dataRef.isEmpty {
            referencedEntry = await SearchStructuredDataStore.shared.load(
                reference: dataRef,
                sessionId: ChatExecutionContext.currentSessionId
            )
            guard referencedEntry != nil else {
                return ToolEnvelope.failure(
                    kind: .notFound,
                    message:
                        "Structured data reference was not found in this chat session. Retrieve the source again with search_and_extract.",
                    field: "dataRef",
                    expected: "a data_ref returned in the current chat session",
                    tool: name,
                    retryable: false
                )
            }
        } else {
            referencedEntry = nil
        }

        let inlineRaw = (args["data"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let suppliedRaw = inlineRaw?.isEmpty == false ? inlineRaw : referencedEntry?.raw else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Provide raw `data` or a `dataRef` returned by search_and_extract.",
                expected: "data or dataRef",
                tool: name
            )
        }

        let declaredFormat =
            (args["format"] as? String)?.lowercased()
            ?? (args["dataFormat"] as? String)?.lowercased()
            ?? referencedEntry?.format
            ?? "csv"
        let format = Self.reconciledDelimitedFormat(
            suppliedRaw,
            declaredFormat: declaredFormat
        )
        let raw = Self.unwrapQuotedDelimitedPayload(suppliedRaw, format: format)
        let title = args["title"] as? String
        let tipSuffix = args["tooltipSuffix"] as? String

        var xPath = (args["xPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var pathSeries = parseSeriesPaths(args["seriesPaths"])
        if format == "json", referencedEntry != nil, pathSeries.isEmpty {
            let descriptors = SearchStructuredDataInspector.jsonArrayDescriptors(raw)
            if let suggestion = SearchStructuredDataInspector.suggestedJSONChart(
                descriptors: descriptors
            ) {
                xPath = xPath?.isEmpty == false ? xPath : suggestion.xPath
                pathSeries = [(suggestion.seriesName, suggestion.seriesPath)]
            }
        }
        if !pathSeries.isEmpty {
            guard let xPath, !xPath.isEmpty else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "`xPath` is required when `seriesPaths` is used.",
                    field: "xPath",
                    expected: "path to the x-axis array in the referenced JSON",
                    tool: name
                )
            }
            return renderNestedJSON(
                raw: raw,
                chartType: chartType,
                xPath: xPath,
                seriesPaths: pathSeries,
                title: title,
                tooltipSuffix: tipSuffix
            )
        }

        let xColumn = args["xColumn"] as? String
        let requestedSeries = args["series"] ?? args["yColumn"]

        var headers: [String]
        var rows: [[String]]
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

        // Bonsai can copy only the body rows of a small inline CSV and omit
        // both `series` and the header row. In that case parseDelimited has
        // necessarily mistaken the first data record for headers. Recover the
        // narrow chart-shaped form (one text category followed by numeric
        // values) before inferring series, so the first point is not lost.
        // Explicit series/xColumn requests continue through the stricter
        // requested-column recovery below.
        if requestedSeries == nil,
            xColumn == nil,
            format != "json",
            let recovered = recoverOmittedSeriesHeaderlessDelimited(
                firstRecord: headers,
                remainingRows: rows
            )
        {
            headers = recovered.headers
            rows = recovered.rows
        }

        // The model-facing schema intentionally leaves `series` optional so
        // nested JSON can use `seriesPaths`. For tabular data, recover an
        // omitted series list from columns whose values are predominantly
        // numeric. Never replace an explicit list: misspelled or otherwise
        // invalid user/model-selected columns still fail below.
        let seriesCols: [String]
        if requestedSeries == nil {
            seriesCols = Self.inferredSeriesColumns(
                headers: headers,
                rows: rows,
                excluding: xColumn
            )
        } else if let requested = Self.parseRequestedSeries(requestedSeries), !requested.isEmpty {
            seriesCols = requested
        } else {
            seriesCols = []
        }
        guard !seriesCols.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Argument `series` must name at least one numeric column, or the data must contain an inferable numeric column.",
                field: "series",
                expected: "non-empty array of numeric column names",
                tool: name
            )
        }

        // Small models sometimes copy the body of retrieved CSV/TSV data but
        // accidentally omit its header row. A first record containing a
        // numeric cell strongly indicates data rather than a header, so recover
        // that narrow case from the requested x/series names. Do not apply
        // this to a text-only first row: a genuinely misspelled column must
        // still return invalid_args instead of being silently relabelled.
        if format != "json",
            requestedColumnsMissing(headers: headers, series: seriesCols, xColumn: xColumn),
            let recovered = recoverHeaderlessDelimited(
                firstRecord: headers,
                remainingRows: rows,
                series: seriesCols,
                xColumn: xColumn
            )
        {
            headers = recovered.headers
            rows = recovered.rows
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

        // Build categories from xColumn. if the model omitted xColumn (common with
        // small/quantized models on inline placeholder data), fall back to the first
        // non-series header whose values are non-numeric because that's almost always the
        // label column. without this the categories ends up nil and bar/line/pie all
        // lose their labels.
        var resolvedXColumn: String? = xColumn
        if resolvedXColumn == nil {
            let seriesSet = Set(seriesCols)
            for header in headers where !seriesSet.contains(header) {
                guard let idx = headers.firstIndex(of: header) else { continue }
                let sample = dataRows.prefix(10).compactMap { row in
                    idx < row.count ? row[idx].trimmingCharacters(in: .whitespaces) : nil
                }.filter { !$0.isEmpty }
                guard !sample.isEmpty else { continue }
                let numericCount = sample.filter { Double($0) != nil }.count
                if numericCount * 2 < sample.count {  // mostly non-numeric → labels
                    resolvedXColumn = header
                    break
                }
            }
        }
        var categories: [String]? = nil
        if let xCol = resolvedXColumn, let xIdx = headers.firstIndex(of: xCol) {
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

        return encodedChartResult(spec)
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

    private func parseSeriesPaths(_ value: Any?) -> [(name: String, path: String)] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap { value in
            guard let object = value as? [String: Any],
                let name = (object["name"] as? String)?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                let path = (object["path"] as? String)?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                !name.isEmpty,
                !path.isEmpty
            else { return nil }
            return (name, path)
        }
    }

    private func renderNestedJSON(
        raw: String,
        chartType: String,
        xPath: String,
        seriesPaths: [(name: String, path: String)],
        title: String?,
        tooltipSuffix: String?
    ) -> String {
        guard let data = raw.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data),
            let xValues = resolveJSONPath(xPath, in: root) as? [Any],
            !xValues.isEmpty
        else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Could not resolve xPath `\(xPath)` to a non-empty JSON array.",
                field: "xPath",
                expected: "path to an array in the referenced JSON",
                tool: name
            )
        }

        var resolvedSeries: [(name: String, values: [Any])] = []
        for series in seriesPaths {
            guard let values = resolveJSONPath(series.path, in: root) as? [Any],
                values.count == xValues.count
            else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "Could not resolve series path `\(series.path)` to an array matching xPath count \(xValues.count).",
                    field: "seriesPaths",
                    expected: "numeric array path with the same count as xPath",
                    tool: name
                )
            }
            resolvedSeries.append((series.name, values))
        }

        let rowCount = xValues.count
        let indices: [Int]
        let note: String?
        if rowCount > Self.maxRows {
            let step = Double(rowCount) / Double(Self.maxRows)
            indices = (0 ..< Self.maxRows).map { Int(Double($0) * step) }
            note = "Downsampled from \(rowCount) to \(Self.maxRows) rows for rendering"
        } else {
            indices = Array(0 ..< rowCount)
            note = nil
        }

        let categories = indices.map { categoryLabel(xValues[$0], path: xPath) }
        let chartSeries = resolvedSeries.compactMap { series -> ChartSeries? in
            let values: [Double?] = indices.map { numericValue(series.values[$0]) }
            guard !values.allSatisfy({ $0 == nil }) else { return nil }
            return ChartSeries(name: series.name, data: values)
        }
        guard !chartSeries.isEmpty else {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "No numeric values were found at the requested series paths.",
                tool: name,
                retryable: false
            )
        }

        return encodedChartResult(
            ChartSpec(
                chartType: chartType,
                title: title,
                categories: categories,
                series: chartSeries,
                tooltipSuffix: tooltipSuffix,
                note: note
            )
        )
    }

    private func resolveJSONPath(_ path: String, in root: Any) -> Any? {
        let expression = try? NSRegularExpression(pattern: #"([^.\[\]]+)|\[(\d+)\]"#)
        guard let expression else { return nil }
        let pathString = path as NSString
        let matches = expression.matches(
            in: path,
            range: NSRange(location: 0, length: pathString.length)
        )
        guard !matches.isEmpty else { return nil }

        var current: Any = root
        for match in matches {
            let whole = pathString.substring(with: match.range(at: 0))
            if whole.hasPrefix("[") {
                guard match.range(at: 2).location != NSNotFound,
                    let index = Int(pathString.substring(with: match.range(at: 2))),
                    let array = current as? [Any],
                    array.indices.contains(index)
                else { return nil }
                current = array[index]
            } else {
                guard let object = current as? [String: Any], let child = object[whole] else {
                    return nil
                }
                current = child
            }
        }
        return current
    }

    private func categoryLabel(_ value: Any, path: String) -> String {
        if value is NSNull { return "" }
        if let number = value as? NSNumber {
            let leaf = path.lowercased()
            let seconds = number.doubleValue
            if (leaf.contains("timestamp") || leaf.contains("date") || leaf.contains("time")),
                seconds > 0,
                seconds < 10_000_000_000
            {
                let formatter = DateFormatter()
                formatter.calendar = Calendar(identifier: .iso8601)
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy-MM-dd"
                return formatter.string(from: Date(timeIntervalSince1970: seconds))
            }
            return number.stringValue
        }
        return String(describing: value)
    }

    private func numericValue(_ value: Any) -> Double? {
        if value is NSNull { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func encodedChartResult(_ spec: ChartSpec) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let jsonData = try? encoder.encode(spec),
            let jsonString = String(data: jsonData, encoding: .utf8)
        else {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Could not encode the chart specification.",
                tool: name,
                retryable: false
            )
        }
        // Marker block is parsed by `parseChartSpecFromResult` downstream.
        // Wrapped in the success envelope's `text` so the tool-call card
        // can detect success without parsing markers first.
        let marker = "---CHART_START---\n\(jsonString)\n---CHART_END---"
        return ToolEnvelope.success(tool: name, text: marker)
    }

    /// Keep the full marker payload for the inline chart card, but do not send
    /// hundreds of categories and values back through the model on the next
    /// loop iteration. The model only needs confirmation and a small structural
    /// summary; the persisted assistant tool result retains the full marker for
    /// UI rendering.
    static func compactModelResult(from renderedResult: String) -> String? {
        guard let spec = chartSpec(from: renderedResult) else { return nil }
        let pointCount = max(
            spec.categories?.count ?? 0,
            spec.series.map { $0.data.count }.max() ?? 0
        )
        var result: [String: Any] = [
            "rendered": true,
            "display": "inline_chart_card",
            "chart_type": spec.chartType,
            "series": spec.series.map(\.name),
            "point_count": pointCount,
            "artifact_created": false,
            "message":
                "The chart is already displayed inline. No image or file was created; do not emit a file/image link unless the user explicitly requests one and a file tool succeeds.",
        ]
        if let title = spec.title, !title.isEmpty { result["title"] = title }
        if let note = spec.note, !note.isEmpty { result["note"] = note }
        if let categories = spec.categories, let first = categories.first, let last = categories.last {
            result["x_start"] = first
            result["x_end"] = last
            if let span = calendarDaySpan(from: first, to: last) {
                result["x_span_days"] = span
            }
        }
        let summaries: [[String: Any]] = spec.series.compactMap { series in
            let values = series.data.compactMap { $0 }
            guard let first = values.first, let last = values.last else { return nil }
            return [
                "name": series.name,
                "first": first,
                "last": last,
                "min": values.min() ?? first,
                "max": values.max() ?? last,
            ]
        }
        if !summaries.isEmpty { result["series_summary"] = summaries }
        return ToolEnvelope.success(tool: "render_chart", result: result)
    }

    private static func calendarDaySpan(from start: String, to end: String) -> Int? {
        func components(_ value: String) -> DateComponents? {
            let parts = value.split(separator: "-")
            guard parts.count == 3,
                let year = Int(parts[0]),
                let month = Int(parts[1]),
                let day = Int(parts[2])
            else { return nil }
            return DateComponents(
                calendar: Calendar(identifier: .gregorian),
                timeZone: TimeZone(secondsFromGMT: 0),
                year: year,
                month: month,
                day: day
            )
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let startComponents = components(start),
            let endComponents = components(end),
            let startDate = calendar.date(from: startComponents),
            let endDate = calendar.date(from: endComponents),
            let days = calendar.dateComponents([.day], from: startDate, to: endDate).day,
            days >= 0
        else { return nil }
        return days
    }

    /// Accept the native array, a JSON-encoded array, or the observed local-
    /// model shorthand `[Close]`. This compatibility belongs to this tool:
    /// bracketed text can be a legitimate scalar in other tool schemas.
    private static func parseRequestedSeries(_ value: Any?) -> [String]? {
        if let array = value as? [String] { return array }
        guard let raw = value as? String else { return nil }
        if let data = raw.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String]
        {
            return parsed
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.first == "[", trimmed.last == "]" {
            let inner = trimmed.dropFirst().dropLast()
            let items = inner.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }.filter { !$0.isEmpty }
            return items.isEmpty ? nil : items
        }
        return [trimmed]
    }

    private static func inferredSeriesColumns(
        headers: [String],
        rows: [[String]],
        excluding xColumn: String?
    ) -> [String] {
        headers.enumerated().compactMap { index, header in
            guard header != xColumn else { return nil }
            let values = rows.compactMap { row -> String? in
                guard index < row.count else { return nil }
                let value = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            guard !values.isEmpty else { return nil }
            let numericCount = values.reduce(into: 0) { count, value in
                if Double(value) != nil { count += 1 }
            }
            return numericCount > 0 && numericCount * 2 >= values.count ? header : nil
        }
    }

    /// Some local models serialize a complete render_chart argument object
    /// into the `data` string instead of placing those fields at the tool-call
    /// root. Recover exactly one such layer only when it contains an inner
    /// data payload plus a chart-control key and no unknown fields. Explicit
    /// root fields continue to win, so this cannot override a valid call.
    private static func recoverNestedChartArguments(_ args: [String: Any]) -> [String: Any] {
        guard let wrapped = args["data"] as? String,
            let encoded = wrapped.data(using: .utf8),
            let nested = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
            nested["data"] is String
        else { return args }

        let allowedKeys: Set<String> = [
            "data", "dataRef", "format", "dataFormat", "chartType", "xColumn", "series",
            "yColumn", "xPath", "seriesPaths", "title", "tooltipSuffix",
        ]
        guard Set(nested.keys).isSubset(of: allowedKeys),
            nested.keys.contains(where: { $0 != "data" && $0 != "title" })
        else { return args }

        var recovered = nested
        for (key, value) in args where key != "data" {
            recovered[key] = value
        }
        return recovered
    }

    /// Some local models wrap an entire CSV/TSV payload in one extra pair of
    /// quotes. JSON decoding has already handled escaping by this point, so
    /// remove only that dataset-wide wrapper when the first record still has
    /// multiple delimited columns. Ordinary quoted fields remain untouched.
    private static func unwrapQuotedDelimitedPayload(_ raw: String, format: String) -> String {
        guard format == "csv" || format == "tsv" else { return raw }
        let separator = format == "tsv" ? "\t" : ","

        // A second observed Bonsai drift quotes only the complete header row,
        // turning `month,sales` into one CSV field while the body still has two
        // columns. Remove that wrapper only when every non-empty body row has
        // the same multi-column shape as the unquoted header.
        var lines = raw.components(separatedBy: .newlines)
        if let first = lines.first,
            first.first == "\"",
            first.last == "\"",
            first.count >= 2
        {
            let candidate = String(first.dropFirst().dropLast())
            let columnCount = candidate.components(separatedBy: separator).count
            let body = lines.dropFirst().filter { !$0.isEmpty }
            if columnCount > 1,
                !body.isEmpty,
                body.allSatisfy({ $0.components(separatedBy: separator).count == columnCount })
            {
                lines[0] = candidate
                return lines.joined(separator: "\n")
            }
        }

        guard
            raw.first == "\"",
            raw.last == "\"",
            raw.contains("\n"),
            raw.count >= 2
        else { return raw }
        let candidate = String(raw.dropFirst().dropLast())
        guard candidate.components(separatedBy: .newlines).first?.contains(separator) == true else {
            return raw
        }
        return candidate
    }

    /// Reconcile an explicit CSV/TSV label with the payload's unambiguous
    /// delimiter shape. Local models can preserve every byte of an attached
    /// table while changing commas to tabs without changing `format` from
    /// `csv` (or vice versa). Treat that as transport metadata drift only
    /// when the declared delimiter produces one column and the alternate
    /// delimiter produces a stable multi-column table across every sampled
    /// row. Ambiguous, mixed, JSON, and ordinary one-column data remain on
    /// the declared path and keep the strict column validation below.
    private static func reconciledDelimitedFormat(
        _ raw: String,
        declaredFormat: String
    ) -> String {
        guard declaredFormat == "csv" || declaredFormat == "tsv" else {
            return declaredFormat
        }

        let declaredSeparator = declaredFormat == "csv" ? "," : "\t"
        let alternateSeparator = declaredFormat == "csv" ? "\t" : ","
        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(16)
        guard !lines.isEmpty else { return declaredFormat }

        let declaredCounts = lines.map {
            $0.components(separatedBy: declaredSeparator).count
        }
        guard declaredCounts.allSatisfy({ $0 == 1 }) else { return declaredFormat }

        let alternateCounts = lines.map {
            $0.components(separatedBy: alternateSeparator).count
        }
        guard let columnCount = alternateCounts.first,
            columnCount > 1,
            alternateCounts.allSatisfy({ $0 == columnCount })
        else { return declaredFormat }

        return declaredFormat == "csv" ? "tsv" : "csv"
    }

    private static func chartSpec(from result: String) -> ChartSpec? {
        let source: String
        if let payload = ToolEnvelope.successPayload(result) as? [String: Any],
            let text = payload["text"] as? String
        {
            source = text
        } else {
            source = result
        }
        guard let start = source.range(of: "---CHART_START---\n"),
            let end = source.range(of: "\n---CHART_END---"),
            start.upperBound <= end.lowerBound,
            let data = String(source[start.upperBound ..< end.lowerBound]).data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(ChartSpec.self, from: data)
    }

    private func requestedColumnsMissing(
        headers: [String],
        series: [String],
        xColumn: String?
    ) -> Bool {
        series.contains { !headers.contains($0) }
            || xColumn.map { !headers.contains($0) } == true
    }

    private func recoverHeaderlessDelimited(
        firstRecord: [String],
        remainingRows: [[String]],
        series: [String],
        xColumn: String?
    ) -> (headers: [String], rows: [[String]])? {
        guard !firstRecord.isEmpty,
            firstRecord.contains(where: {
                Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
            }),
            remainingRows.allSatisfy({ $0.count == firstRecord.count })
        else {
            return nil
        }

        let recoveredHeaders: [String]
        if let xColumn, firstRecord.count == series.count + 1 {
            recoveredHeaders = [xColumn] + series
        } else if xColumn == nil, firstRecord.count == series.count + 1 {
            recoveredHeaders = ["category"] + series
        } else if xColumn == nil, firstRecord.count == series.count {
            recoveredHeaders = series
        } else {
            return nil
        }
        return (recoveredHeaders, [firstRecord] + remainingRows)
    }

    private func recoverOmittedSeriesHeaderlessDelimited(
        firstRecord: [String],
        remainingRows: [[String]]
    ) -> (headers: [String], rows: [[String]])? {
        guard firstRecord.count >= 2,
            Double(firstRecord[0].trimmingCharacters(in: .whitespacesAndNewlines)) == nil,
            remainingRows.allSatisfy({ $0.count == firstRecord.count }),
            Self.looksLikeHeaderlessCategorySequence(
                [firstRecord[0]] + remainingRows.map { $0[0] }
            )
        else {
            return nil
        }

        let numericIndices = firstRecord.indices.dropFirst().filter { index in
            let firstValue = firstRecord[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard Double(firstValue) != nil else { return false }
            return remainingRows.allSatisfy { row in
                Double(row[index].trimmingCharacters(in: .whitespacesAndNewlines)) != nil
            }
        }
        guard numericIndices.count == firstRecord.count - 1 else { return nil }

        let valueHeaders = numericIndices.enumerated().map { offset, _ in
            numericIndices.count == 1 ? "value" : "value_\(offset + 1)"
        }
        return (["category"] + valueHeaders, [firstRecord] + remainingRows)
    }

    /// Numeric column names are valid CSV headers (years are common), so a
    /// numeric first record alone is not enough to reinterpret it as data.
    /// Limit headerless recovery to recognizable category sequences observed
    /// in small inline charts: calendar months, ISO dates, or quarters.
    private static func looksLikeHeaderlessCategorySequence(_ values: [String]) -> Bool {
        guard values.count >= 2 else { return false }
        let normalized = values.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let months: Set<String> = [
            "jan", "january", "feb", "february", "mar", "march", "apr", "april",
            "may", "jun", "june", "jul", "july", "aug", "august", "sep", "sept",
            "september", "oct", "october", "nov", "november", "dec", "december",
        ]
        if normalized.allSatisfy(months.contains) { return true }
        if normalized.allSatisfy({ value in
            value.range(of: #"^\d{4}-\d{2}-\d{2}(?:[t ][^,]+)?$"#, options: .regularExpression)
                != nil
        }) {
            return true
        }
        return normalized.allSatisfy { value in
            value.range(of: #"^q[1-4](?:\s+\d{4})?$"#, options: .regularExpression) != nil
        }
    }

    private func downsample(_ rows: [[String]], to maxCount: Int) -> [[String]] {
        guard rows.count > maxCount else { return rows }
        let step = Double(rows.count) / Double(maxCount)
        return (0 ..< maxCount).map { i in rows[Int(Double(i) * step)] }
    }

}
