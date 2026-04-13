//
//  ChartSpec.swift
//  osaurus
//
//  Data model for chart rendering. Used by both the fenced block path (Path A)
//  and the render_chart tool path (Path B).
//

import Foundation

public struct ChartSeries: Codable, Equatable, Sendable {
    public var name: String
    public var data: [Double?]  // nil emits gaps in AAChartKit
}

public struct ChartSpec: Codable, Equatable, Sendable {
    public var chartType: String
    public var title: String?
    public var subtitle: String?
    public var categories: [String]?
    public var series: [ChartSeries]
    public var colorsTheme: [String]?
    public var tooltipSuffix: String?
    public var stacking: String?        // "normal", "percent", or nil
    public var dataLabelsEnabled: Bool?
    public var note: String?            // set by RenderChartTool when downsampling occurs

    public static let validChartTypes: Set<String> = [
        "column", "bar", "line", "spline", "area", "areaspline",
        "pie", "scatter", "bubble", "gauge", "waterfall", "boxplot",
    ]

    /// Returns a copy with chartType coerced to a known value
    public var normalized: ChartSpec {
        guard !Self.validChartTypes.contains(chartType) else { return self }
        var copy = self
        copy.chartType = "column"
        return copy
    }

    // MARK: - Forgiving decode

    enum CodingKeys: String, CodingKey {
        case chartType, title, subtitle, categories, series
        case colorsTheme, tooltipSuffix, stacking, dataLabelsEnabled, note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chartType         = (try? c.decode(String.self, forKey: .chartType)) ?? "column"
        title             = try? c.decode(String.self, forKey: .title)
        subtitle          = try? c.decode(String.self, forKey: .subtitle)
        categories        = try? c.decode([String].self, forKey: .categories)
        tooltipSuffix     = try? c.decode(String.self, forKey: .tooltipSuffix)
        stacking          = try? c.decode(String.self, forKey: .stacking)
        dataLabelsEnabled = try? c.decode(Bool.self, forKey: .dataLabelsEnabled)
        note              = try? c.decode(String.self, forKey: .note)
        colorsTheme       = try? c.decode([String].self, forKey: .colorsTheme)

        // Coerce series data: some quantized models emit numbers as strings or omit nulls
        if let rawSeries = try? c.decode([RawSeries].self, forKey: .series) {
            series = rawSeries.map { raw in
                ChartSeries(
                    name: raw.name,
                    data: raw.data.map { v in
                        switch v {
                        case .double(let d): return d
                        case .string(let s): return Double(s)
                        case .null:          return nil
                        }
                    }
                )
            }
        } else {
            series = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(chartType, forKey: .chartType)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(subtitle, forKey: .subtitle)
        try c.encodeIfPresent(categories, forKey: .categories)
        try c.encodeIfPresent(tooltipSuffix, forKey: .tooltipSuffix)
        try c.encodeIfPresent(stacking, forKey: .stacking)
        try c.encodeIfPresent(dataLabelsEnabled, forKey: .dataLabelsEnabled)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(colorsTheme, forKey: .colorsTheme)
        try c.encode(series, forKey: .series)
    }

    public init(
        chartType: String,
        title: String? = nil,
        subtitle: String? = nil,
        categories: [String]? = nil,
        series: [ChartSeries],
        colorsTheme: [String]? = nil,
        tooltipSuffix: String? = nil,
        stacking: String? = nil,
        dataLabelsEnabled: Bool? = nil,
        note: String? = nil
    ) {
        self.chartType         = chartType
        self.title             = title
        self.subtitle          = subtitle
        self.categories        = categories
        self.series            = series
        self.colorsTheme       = colorsTheme
        self.tooltipSuffix     = tooltipSuffix
        self.stacking          = stacking
        self.dataLabelsEnabled = dataLabelsEnabled
        self.note              = note
    }

    // MARK: - Internal lenient series parser

    private struct RawSeries: Decodable {
        let name: String
        let data: [FlexDouble]
    }

    private enum FlexDouble: Decodable {
        case double(Double), string(String), null

        init(from decoder: Decoder) throws {
            let s = try decoder.singleValueContainer()
            if s.decodeNil()                             { self = .null }
            else if let d = try? s.decode(Double.self)  { self = .double(d) }
            else if let str = try? s.decode(String.self) { self = .string(str) }
            else                                         { self = .null }
        }
    }
}
