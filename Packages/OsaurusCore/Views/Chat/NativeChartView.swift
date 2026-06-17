//
//  NativeChartView.swift
//  osaurus
//
//  AppKit view wrapping AAChartView in a styled card. Rendered by
//  NativeMessageCellView for .chart(spec:) content blocks.
//

import AppKit
import AAInfographics
import UniformTypeIdentifiers
import WebKit

final class NativeChartView: NSView {

    private let card = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let typePicker = NSPopUpButton()
    private let downloadButton = NSButton()
    private let noteLabel = NSTextField(labelWithString: "")
    private let chartView = AAChartView()

    /// Animation runs only on first draw; subsequent spec changes skip animation.
    private var hasDrawn = false
    /// Skip redundant redraws (window focus, resize) when spec hasn't changed.
    private var lastSpec: ChartSpec?
    /// Chart type chosen by the user via the picker; overrides spec.chartType until a new spec arrives.
    private var chartTypeOverride: String?
    /// Cached theme so the picker action can trigger a redraw with the same theme.
    private var lastTheme: (any ThemeProtocol)?

    /// Active when the note is visible — pins card.bottom to noteLabel.bottom + p.
    private var cardBottomToNoteConstraint: NSLayoutConstraint?
    /// Active when the note is hidden — pins card.bottom to chartView.bottom + p so the
    /// hidden-but-still-laid-out noteLabel doesn't add phantom height.
    private var cardBottomToChartConstraint: NSLayoutConstraint?

    // Chart height gives Highcharts enough vertical room for the plot + legend.
    static let chartHeight: CGFloat = 320
    static let cardPadding: CGFloat = 12

    private static let chartTypes: [String] = [
        "line", "spline", "column", "bar", "area", "areaspline",
        "pie", "scatter", "bubble", "waterfall",
    ]

    private static func symbol(for chartType: String) -> String {
        switch chartType {
        case "line": return "chart.xyaxis.line"
        case "spline": return "chart.line.uptrend.xyaxis"
        case "column": return "chart.bar.fill"
        case "bar": return "chart.bar.xaxis.ascending"
        case "area": return "chart.line.flattrend.xyaxis.circle.fill"
        case "areaspline": return "chart.line.uptrend.xyaxis.circle.fill"
        case "pie": return "chart.pie.fill"
        case "scatter": return "chart.dots.scatter"
        case "bubble": return "circle.grid.3x3.fill"
        case "waterfall": return "chart.bar.doc.horizontal.fill"
        default: return "chart.bar.fill"
        }
    }

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
        card.layer?.borderWidth = 1
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(titleLabel)

        // Chart type picker
        typePicker.removeAllItems()
        for type in Self.chartTypes {
            let item = NSMenuItem()
            item.title = type.capitalized
            item.image = SymbolImageCache.image(Self.symbol(for: type), accessibilityDescription: nil)
            typePicker.menu?.addItem(item)
        }
        typePicker.font = .systemFont(ofSize: 11)
        typePicker.controlSize = .small
        typePicker.bezelStyle = .roundRect
        typePicker.translatesAutoresizingMaskIntoConstraints = false
        typePicker.target = self
        typePicker.action = #selector(chartTypeChanged)
        card.addSubview(typePicker)

        // Download button — snapshots the rendered chart to a PNG file
        downloadButton.image = NSImage(
            systemSymbolName: "square.and.arrow.down",
            accessibilityDescription: "Save chart as image"
        )
        downloadButton.imagePosition = .imageOnly
        downloadButton.bezelStyle = .roundRect
        downloadButton.controlSize = .small
        downloadButton.isBordered = true
        downloadButton.toolTip = "Save chart as image"
        downloadButton.translatesAutoresizingMaskIntoConstraints = false
        downloadButton.target = self
        downloadButton.action = #selector(downloadChart)
        card.addSubview(downloadButton)

        // Suppress WKWebView's white background before JS renders
        chartView.setValue(false, forKey: "drawsBackground")
        chartView.underPageBackgroundColor = .clear
        chartView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(chartView)

        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.isHidden = true
        noteLabel.lineBreakMode = .byWordWrapping
        noteLabel.maximumNumberOfLines = 2
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(noteLabel)

        let p = Self.cardPadding
        // Toggle one of these two based on noteLabel visibility (in `configure`).
        // Without an explicit content-anchored bottom, the card's bottom was
        // driven only by `card.bottom == NativeChartView.bottom`, which is
        // pinned to the cell with a low-priority constraint (priority 250 in
        // `NativeMessageCellView.configureAsChart`). When the row's measured
        // height under-estimates content (e.g. picker not accounted for),
        // NativeChartView gets squeezed and the WKWebView-backed chart layer
        // renders past the cell bounds and bleeds into adjacent rows.
        let bottomToNote = card.bottomAnchor.constraint(
            greaterThanOrEqualTo: noteLabel.bottomAnchor,
            constant: p
        )
        let bottomToChart = card.bottomAnchor.constraint(
            greaterThanOrEqualTo: chartView.bottomAnchor,
            constant: p
        )
        cardBottomToNoteConstraint = bottomToNote
        cardBottomToChartConstraint = bottomToChart

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: p),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: p),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: typePicker.leadingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: typePicker.centerYAnchor),

            typePicker.topAnchor.constraint(equalTo: card.topAnchor, constant: p - 2),
            typePicker.trailingAnchor.constraint(equalTo: downloadButton.leadingAnchor, constant: -6),

            downloadButton.centerYAnchor.constraint(equalTo: typePicker.centerYAnchor),
            downloadButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -p),

            chartView.topAnchor.constraint(equalTo: typePicker.bottomAnchor, constant: 4),
            chartView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            chartView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            chartView.heightAnchor.constraint(equalToConstant: Self.chartHeight),

            noteLabel.topAnchor.constraint(equalTo: chartView.bottomAnchor, constant: 6),
            noteLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: p),
            noteLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -p),

            bottomToChart,  // initially active; toggled in `configure`
        ])
    }

    // MARK: - Configure

    /// `animateInitialDraw` controls only the first paint on this NSView
    /// instance. Cells get recycled across scroll, so the coordinator tracks
    /// which block ids have already animated once and passes `false` on
    /// re-attach to suppress the entry animation. Picker-driven redraws
    /// always animate (see `chartTypeChanged`).
    func configure(spec: ChartSpec, theme: any ThemeProtocol, animateInitialDraw: Bool = true) {
        let bgColor = NSColor(theme.cardBackground)
        let bgHex = bgColor.hexString
        let textColor = NSColor(theme.primaryText)

        card.layer?.backgroundColor = bgColor.cgColor
        card.layer?.borderColor = NSColor(theme.primaryBorder).withAlphaComponent(0.25).cgColor
        titleLabel.textColor = textColor
        noteLabel.textColor = NSColor(theme.secondaryText)

        titleLabel.stringValue = spec.title ?? ""
        titleLabel.isHidden = (spec.title ?? "").isEmpty

        if let note = spec.note, !note.isEmpty {
            noteLabel.stringValue = "ⓘ \(note)"
            noteLabel.isHidden = false
        } else {
            noteLabel.isHidden = true
        }

        // Pin card.bottom to whichever piece of content actually trails so the
        // card stops at its content rather than at NativeChartView's bounds.
        // Hidden NSTextField still participates in Auto Layout, so when the
        // note is hidden we explicitly anchor to chartView.bottom to avoid
        // phantom space.
        cardBottomToNoteConstraint?.isActive = !noteLabel.isHidden
        cardBottomToChartConstraint?.isActive = noteLabel.isHidden

        lastTheme = theme

        // Skip chart redraw when spec hasn't changed (handles window focus / resize)
        guard spec != lastSpec else { return }
        lastSpec = spec
        chartTypeOverride = nil  // new spec from model — reset any user override

        // Sync picker to the spec's chart type
        if let idx = Self.chartTypes.firstIndex(of: spec.chartType) {
            typePicker.selectItem(at: idx)
        }

        redraw(spec: spec, bgHex: bgHex, textHex: textColor.hexString, theme: theme, animate: animateInitialDraw)
    }

    func measuredCardHeight() -> CGFloat {
        let p = Self.cardPadding
        let headerH: CGFloat = 24  // picker height + 4pt gap
        var h = p + headerH
        h += Self.chartHeight
        if noteLabel.isHidden {
            h += p
        } else {
            h += 6 + 16 + p
        }
        return h
    }

    // MARK: - Picker action

    @objc private func chartTypeChanged() {
        guard let spec = lastSpec, let theme = lastTheme else { return }
        chartTypeOverride = Self.chartTypes[typePicker.indexOfSelectedItem]

        var updated = spec
        updated.chartType = chartTypeOverride!

        let bgHex = NSColor(theme.cardBackground).hexString
        let textHex = NSColor(theme.primaryText).hexString
        redraw(spec: updated, bgHex: bgHex, textHex: textHex, theme: theme, forceFullRedraw: true)
    }

    // MARK: - Download action

    /// Snapshots the rendered chart (AAChartView is a WKWebView) into a PNG and
    /// prompts the user for a save location.
    @objc private func downloadChart() {
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        chartView.takeSnapshot(with: config) { [weak self] image, error in
            guard let self, let image, error == nil else { return }
            self.presentSavePanel(for: image)
        }
    }

    private func presentSavePanel(for image: NSImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let baseName = (lastSpec?.title?.isEmpty == false ? lastSpec?.title : nil) ?? "chart"
        panel.nameFieldStringValue = "\(baseName).png"

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            // Pull the (cheap) bitmap off the image on the main actor, then hand
            // the Sendable TIFF Data to a detached task for the expensive PNG
            // encode + disk write so the main thread never blocks.
            Task { @MainActor in
                guard let tiff = image.tiffRepresentation else {
                    NSSound.beep()
                    return
                }
                let saved = await Self.encodeAndWritePNG(tiff: tiff, to: url)
                guard saved else {
                    NSSound.beep()
                    return
                }
                ToastManager.shared.action(
                    L("Chart saved"),
                    message: url.lastPathComponent,
                    action: .revealInFinder(url),
                    buttonTitle: L("Reveal in Finder")
                )
            }
        }
        // beginSheetModal is async (non-blocking); runModal is a blocking
        // fallback only when the view isn't yet in a window.
        if let window = self.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    /// PNG-encodes `tiff` and writes it to `url` off the main thread.
    private nonisolated static func encodeAndWritePNG(tiff: Data, to url: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            guard
                let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:]),
                (try? png.write(to: url)) != nil
            else { return false }
            return true
        }.value
    }

    // MARK: - Draw / Refresh

    private func redraw(
        spec: ChartSpec,
        bgHex: String,
        textHex: String,
        theme: any ThemeProtocol,
        forceFullRedraw: Bool = false,
        animate: Bool = true
    ) {
        let (options, seriesElements) = buildChartModel(
            from: spec,
            bgHex: bgHex,
            textHex: textHex,
            theme: theme,
            animate: animate
        )

        if !hasDrawn || forceFullRedraw {
            hasDrawn = true
            chartView.aa_drawChartWithChartOptions(options)
        } else {
            chartView.aa_onlyRefreshTheChartDataWithChartModelSeries(seriesElements, animation: false)
        }
    }

    // MARK: - AAChartModel Builder

    private func buildChartModel(
        from spec: ChartSpec,
        bgHex: String,
        textHex: String,
        theme: any ThemeProtocol,
        animate: Bool = true
    ) -> (AAOptions, [AASeriesElement]) {
        let gridHex = NSColor(theme.primaryBorder).withAlphaComponent(0.2).hexString

        // Pie charts read each slice's label from a `name` field on the data
        // point itself — they ignore the model's `categories` array. Bar/line/etc.
        // use `categories` for x-axis labels so plain numeric data is fine there
        let isPie = spec.chartType == "pie"
        let seriesElements: [AASeriesElement] = spec.series.map { s in
            let element = AASeriesElement().name(s.name)
            if isPie, let cats = spec.categories {
                let paired: [Any] = s.data.enumerated().map { idx, v -> Any in
                    let label = idx < cats.count ? cats[idx] : "Slice \(idx + 1)"
                    return ["name": label, "y": v as Any? ?? NSNull()] as [String: Any]
                }
                return element.data(paired as [AnyObject])
            }
            return element.data(s.data.map { v -> Any in v.map { $0 as Any } ?? NSNull() } as [AnyObject])
        }

        let model = AAChartModel()
            .chartType(AAChartType(rawValue: spec.chartType) ?? .column)
            .backgroundColor(bgHex)
            .animationType(.easeInOutQuart)
            .animationDuration(animate ? 600 : 0)
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
        let r = Int((color.redComponent * 255).rounded())
        let g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
