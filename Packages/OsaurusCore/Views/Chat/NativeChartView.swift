//
//  NativeChartView.swift
//  osaurus
//
//  AppKit view wrapping AAChartView in a styled card. Rendered by
//  NativeMessageCellView for .chart(spec:) content blocks.
//

import AppKit
import AAInfographics

final class NativeChartView: NSView {

    private let card       = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let noteLabel  = NSTextField(labelWithString: "")
    private let chartView  = AAChartView()

    /// Animation runs only on first draw; subsequent spec changes skip animation.
    private var hasDrawn = false
    /// Skip redundant redraws (window focus, resize) when spec hasn't changed.
    private var lastSpec: ChartSpec?
    /// Cached theme background hex — used to re-apply after WebView loads.
    private var lastBgHex: String = "#000000"

    // Chart height gives Highcharts enough vertical room for the plot + legend.
    static let chartHeight: CGFloat = 300
    static let cardPadding: CGFloat = 12

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Layout

    private func setupLayout() {
        wantsLayer = true

        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        // Subtle border for elevation
        card.layer?.borderWidth  = 1
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        titleLabel.font          = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(titleLabel)

        // Transparent WKWebView so AAChartKit's chart.backgroundColor controls the background
        chartView.underPageBackgroundColor = .clear
        chartView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(chartView)

        noteLabel.font                 = .systemFont(ofSize: 11)
        noteLabel.isHidden             = true
        noteLabel.lineBreakMode        = .byWordWrapping
        noteLabel.maximumNumberOfLines = 2
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(noteLabel)

        let p = Self.cardPadding
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: p),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: p),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -p),

            chartView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            chartView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            chartView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            chartView.heightAnchor.constraint(equalToConstant: Self.chartHeight),

            // noteLabel anchors to chartView bottom and defines card bottom
            noteLabel.topAnchor.constraint(equalTo: chartView.bottomAnchor, constant: 6),
            noteLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: p),
            noteLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -p),
            noteLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -p),
        ])
    }

    // MARK: - Configure

    func configure(spec: ChartSpec, theme: any ThemeProtocol) {
        let bgColor   = NSColor(theme.cardBackground)
        let bgHex     = bgColor.hexString
        let textColor = NSColor(theme.primaryText)

        // Card chrome
        card.layer?.backgroundColor = bgColor.cgColor
        // Subtle gray border — slightly lighter than the card background
        card.layer?.borderColor = NSColor(theme.primaryBorder).withAlphaComponent(0.25).cgColor
        titleLabel.textColor    = textColor
        noteLabel.textColor     = NSColor(theme.secondaryText)

        titleLabel.stringValue = spec.title ?? ""
        titleLabel.isHidden    = (spec.title ?? "").isEmpty

        if let note = spec.note, !note.isEmpty {
            noteLabel.stringValue = "ⓘ \(note)"
            noteLabel.isHidden    = false
        } else {
            noteLabel.isHidden = true
        }

        lastBgHex = bgHex

        // Skip chart redraw when spec hasn't changed (handles window focus / resize)
        guard spec != lastSpec else { return }
        lastSpec = spec

        let (options, seriesElements) = buildChartModel(from: spec, bgHex: bgHex, textHex: textColor.hexString, theme: theme)

        if !hasDrawn {
            hasDrawn = true
            chartView.aa_drawChartWithChartOptions(options)
        } else {
            chartView.aa_onlyRefreshTheChartDataWithChartModelSeries(seriesElements, animation: false)
        }
    }

    func measuredCardHeight() -> CGFloat {
        let p = Self.cardPadding
        var h = p
        h += titleLabel.isHidden ? 0 : (20 + 4)   // title + gap
        h += Self.chartHeight
        h += noteLabel.isHidden ? p : (6 + 16 + p) // bottom padding or note + bottom padding
        return h
    }

    // MARK: - AAChartModel Builder

    private func buildChartModel(
        from spec: ChartSpec,
        bgHex: String,
        textHex: String,
        theme: any ThemeProtocol
    ) -> (AAOptions, [AASeriesElement]) {
        let gridHex = NSColor(theme.primaryBorder).withAlphaComponent(0.2).hexString

        let seriesElements: [AASeriesElement] = spec.series.map { s in
            AASeriesElement()
                .name(s.name)
                .data(s.data.map { v -> Any in v.map { $0 as Any } ?? NSNull() } as [AnyObject])
        }

        let model = AAChartModel()
            .chartType(AAChartType(rawValue: spec.chartType) ?? .column)
            .backgroundColor(bgHex)
            .animationType(.easeInOutQuart)
            .animationDuration(600)
            .dataLabelsEnabled(spec.dataLabelsEnabled ?? false)
            .dataLabelsStyle(AAStyle().color(textHex).fontSize(11))
            .tooltipValueSuffix(spec.tooltipSuffix ?? "")
            .legendEnabled(true)
            .series(seriesElements)

        if let categories = spec.categories {
            model.categories(categories)
        }
        if let stacking = spec.stacking,
           let stackingType = AAChartStackingType(rawValue: stacking)
        {
            model.stacking(stackingType)
        }
        if let colors = spec.colorsTheme {
            model.colorsTheme(colors)
        }

        // Apply axis label and legend text colors via AAOptions (AAChartModel has no axesTextColor)
        let options = model.aa_toAAOptions()
        let labelStyle = AAStyle().color(textHex).fontSize(11)
        options.xAxis?.labels(AALabels().style(labelStyle))
            .gridLineColor(gridHex)
            .lineColor(gridHex)
        options.yAxis?.labels(AALabels().style(labelStyle))
            .gridLineColor(gridHex)
            .lineColor(gridHex)
        options.legend?.itemStyle(AAStyle().color(textHex).fontSize(12).fontWeight(.regular))

        return (options, seriesElements)
    }
}

// MARK: - NSColor hex helper

private extension NSColor {
    /// Returns a CSS hex string (#rrggbb) suitable for passing to AAChartKit
    var hexString: String {
        guard let color = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int((color.redComponent   * 255).rounded())
        let g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent  * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
