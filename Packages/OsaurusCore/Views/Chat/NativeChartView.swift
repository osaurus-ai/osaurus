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

    private static let chartHeight: CGFloat = 260
    private static let cardPadding: CGFloat = 12

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
        card.layer?.borderWidth  = 0.5
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

        chartView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(chartView)

        noteLabel.font      = .systemFont(ofSize: 11)
        noteLabel.isHidden  = true
        noteLabel.lineBreakMode = .byWordWrapping
        noteLabel.maximumNumberOfLines = 2
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(noteLabel)

        let p = Self.cardPadding
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: p),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: p),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -p),

            chartView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            chartView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            chartView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            chartView.heightAnchor.constraint(equalToConstant: Self.chartHeight),

            noteLabel.topAnchor.constraint(equalTo: chartView.bottomAnchor, constant: 6),
            noteLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: p),
            noteLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -p),
            noteLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -p),
        ])
    }

    // MARK: - Configure

    func configure(spec: ChartSpec, theme: any ThemeProtocol) {
        card.layer?.backgroundColor = NSColor(theme.cardBackground).cgColor
        card.layer?.borderColor     = NSColor(theme.cardBorder).cgColor
        titleLabel.textColor        = NSColor(theme.primaryText)
        noteLabel.textColor         = NSColor(theme.secondaryText)

        titleLabel.stringValue = spec.title ?? ""
        titleLabel.isHidden    = (spec.title ?? "").isEmpty

        if let note = spec.note, !note.isEmpty {
            noteLabel.stringValue = "ⓘ \(note)"
            noteLabel.isHidden    = false
        } else {
            noteLabel.isHidden = true
        }

        let model = buildChartModel(from: spec, theme: theme)
        // Refresh if already rendered to get a smooth animated update; draw on first render
        if chartView.bounds.width > 0 {
            chartView.aa_refreshChartWholeContentWithChartModel(model)
        } else {
            chartView.aa_drawChartWithChartModel(model)
        }
    }

    func measuredCardHeight() -> CGFloat {
        let p = Self.cardPadding
        var h = p                                        // top padding
        h += titleLabel.isHidden ? 0 : (20 + 8)         // title + gap below
        h += Self.chartHeight                            // chart
        h += noteLabel.isHidden ? 0 : (6 + 16)          // gap + note
        h += p                                           // bottom padding
        return h
    }

    // MARK: - AAChartModel Builder

    private func buildChartModel(from spec: ChartSpec, theme: any ThemeProtocol) -> AAChartModel {
        let seriesElements: [Any] = spec.series.map { s in
            AASeriesElement()
                .name(s.name)
                .data(s.data.map { v -> Any in v.map { $0 as Any } ?? NSNull() } as [Any])
        }

        let model = AAChartModel()
            .chartType(AAChartType(rawValue: spec.chartType) ?? .column)
            .animationType(.easeInOutQuart)
            .animationDuration(400)
            .dataLabelsEnabled(spec.dataLabelsEnabled ?? false)
            .tooltipValueSuffix(spec.tooltipSuffix ?? "")
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

        return model
    }
}
