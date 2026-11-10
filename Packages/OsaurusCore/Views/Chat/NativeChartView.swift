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
import SwiftUI

#if OSAURUS_DESIGN_SYSTEM
/// AX activation must present the same assigned menu as pointer activation.
private final class InspectorChartTypePopup: NSPopUpButton {
    weak var assignedTrigger: AssignedNativePicker<EmptyView>.AssignedPickerMenuTrigger?
    override func accessibilityPerformPress() -> Bool {
        assignedTrigger?.accessibilityPerformPress() ?? super.accessibilityPerformPress()
    }
}
#endif

final class NativeChartView: NSView {

    private let card = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    #if OSAURUS_DESIGN_SYSTEM
    private let typePicker = InspectorChartTypePopup()
    #else
    private let typePicker = NSPopUpButton()
    #endif
    private let downloadButton = NSButton()
    private let noteLabel = NSTextField(labelWithString: "")
    private let chartView = AAChartView()

    /// Animation runs only on first draw; subsequent spec changes skip animation.
    private var hasDrawn = false
    /// Skip redundant redraws (window focus, resize) when spec hasn't changed.
    private var lastSpec: ChartSpec?
    private var lastStyleFingerprint: Int?
    private var pickerHeightConstraint: NSLayoutConstraint?
    #if OSAURUS_DESIGN_SYSTEM
    private let inspectorPicker = AssignedNativePicker<EmptyView>.AssignedPickerMenuTrigger()
    #endif
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
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        titleLabel.font = ThemeManager.shared.chatTheme.nsFont(.label, weight: .semibold)
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
        typePicker.font = ThemeManager.shared.chatTheme.nsFont(.footnote)
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

        noteLabel.font = ThemeManager.shared.chatTheme.nsFont(.footnote)
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
        let theme = theme.catalogFamily(39, authoritative: true)
        let styleChanged = lastStyleFingerprint != theme.renderFingerprint
        let bgColor = NSColor(theme.surface.raised)
        let bgHex = bgColor.hexString
        let textColor = NSColor(theme.text.primary)

        card.layer?.backgroundColor = bgColor.cgColor
        #if OSAURUS_DESIGN_SYSTEM
        card.catalogAssignmentTarget(["background", "border"].map { "component.library.39." + $0 }, name: "Chart container", theme: theme)
        #endif
        card.layer?.borderColor = NSColor(theme.border.subtle).cgColor
        card.layer?.borderWidth = theme.stroke.default
        card.layer?.cornerRadius = theme.radius.large
        titleLabel.textColor = textColor
        noteLabel.textColor = NSColor(theme.text.secondary)

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
        applyInspectionStyle(theme)

        // Style-only edits need a full options refresh, preserving the user's chart type.
        let specChanged = spec != lastSpec
        guard specChanged || styleChanged else { return }
        lastStyleFingerprint = theme.renderFingerprint
        lastSpec = spec
        if specChanged { chartTypeOverride = nil }

        // Sync picker to the spec's chart type
        if let idx = Self.chartTypes.firstIndex(of: chartTypeOverride ?? spec.chartType) {
            typePicker.selectItem(at: idx)
        }

        var displayed = spec
        if let chartTypeOverride { displayed.chartType = chartTypeOverride }
        redraw(spec: displayed, bgHex: bgHex, textHex: textColor.hexString, theme: theme, forceFullRedraw: styleChanged, animate: hasDrawn ? false : animateInitialDraw)
    }

    func measuredCardHeight() -> CGFloat {
        let theme = lastTheme ?? CustomizableTheme.light()
        let p = NativeComponentInspectionStyle.metric(39, "padding", Self.cardPadding, theme)
        let headerH = max(24, pickerHeightConstraint?.constant ?? 20) + NativeComponentInspectionStyle.metric(39, "gap", 4, theme)
        var h = p + headerH
        h += Self.chartHeight
        if noteLabel.isHidden {
            h += p
        } else {
            h += NativeComponentInspectionStyle.metric(39, "gap", 6, theme) + max(16, noteLabel.intrinsicContentSize.height) + p
        }
        return h
    }

    private func applyInspectionStyle(_ theme: any ThemeProtocol) {
        #if OSAURUS_DESIGN_SYSTEM
        let p = NativeComponentInspectionStyle.metric(39, "padding", Self.cardPadding, theme)
        let gap = NativeComponentInspectionStyle.metric(39, "gap", 6, theme)
        NativeComponentInspectionStyle.label(titleLabel, family: 39, property: "heading", theme: theme)
        NativeComponentInspectionStyle.label(noteLabel, family: 39, property: "text", theme: theme)
        NativeComponentInspectionStyle.button(typePicker, family: 39, property: "caption", theme: theme)
        typePicker.contentTintColor = NSColor(theme.text.secondary)
        typePicker.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        typePicker.isBordered = false
        downloadButton.appearance = typePicker.appearance
        downloadButton.contentTintColor = NSColor(theme.text.secondary)
        downloadButton.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save chart as image")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [NSColor(theme.text.secondary)]))
        // NSPopUpButton draws its selected menu item's title, rather than the
        // NSButton attributedTitle used by the other native control adapter.
        for item in typePicker.itemArray {
            let label = NSTextField(labelWithString: item.title)
            label.textColor = NSColor(theme.text.secondary)
            NativeComponentInspectionStyle.label(label, family: 39, property: "caption", theme: theme)
            item.attributedTitle = label.attributedStringValue
        }
        let minH = max(NativeComponentInspectionStyle.metric(39, "height", 20, theme), theme.assignedLineHeight(NativeComponentInspectionStyle.key(39, "caption"), fallback: 16), titleLabel.isHidden ? 0 : max(titleLabel.intrinsicContentSize.height, theme.assignedLineHeight(NativeComponentInspectionStyle.key(39, "heading"), fallback: 20)))
        if pickerHeightConstraint == nil { pickerHeightConstraint = typePicker.heightAnchor.constraint(greaterThanOrEqualToConstant: minH); pickerHeightConstraint?.isActive = true }
        pickerHeightConstraint?.constant = minH
        cardBottomToNoteConstraint?.constant = p; cardBottomToChartConstraint?.constant = p
        for c in card.constraints {
            let view = c.firstItem as? NSView
            if view === titleLabel || view === noteLabel {
                if c.firstAttribute == .leading || c.firstAttribute == .top { c.constant = view === noteLabel && c.firstAttribute == .top ? gap : p }
                if c.firstAttribute == .trailing { c.constant = -p }
            }
            if view === typePicker, c.firstAttribute == .top { c.constant = p }
            if view === downloadButton, c.firstAttribute == .trailing { c.constant = -p }
            if view === chartView, c.firstAttribute == .top { c.constant = gap }
        }
        for (index, item) in typePicker.itemArray.enumerated() { item.target = self; item.action = #selector(inspectorChartTypeSelected(_:)); item.tag = index }
        inspectorPicker.popup = typePicker
        typePicker.assignedTrigger = inspectorPicker
        inspectorPicker.recipe = AssignedNativePicker<EmptyView>.TextRecipe(theme: theme, enabled: typePicker.isEnabled, family: 5, disabledMenuIndices: [])
        inspectorPicker.frame = typePicker.bounds
        inspectorPicker.autoresizingMask = [.width, .height]
        inspectorPicker.setAccessibilityLabel(L("Chart type")); inspectorPicker.setAccessibilityValue(typePicker.title)
        typePicker.refusesFirstResponder = true; typePicker.setAccessibilityElement(false)
        if inspectorPicker.superview !== typePicker { typePicker.addSubview(inspectorPicker) }
        #endif
    }
    #if OSAURUS_DESIGN_SYSTEM
    @objc private func inspectorChartTypeSelected(_ item: NSMenuItem) {
        typePicker.selectItem(at: item.tag)
        inspectorPicker.setAccessibilityValue(typePicker.title)
        chartTypeChanged()
    }
    #endif

    // MARK: - Picker action

    @objc private func chartTypeChanged() {
        guard let spec = lastSpec, let theme = lastTheme else { return }
        chartTypeOverride = Self.chartTypes[typePicker.indexOfSelectedItem]

        var updated = spec
        updated.chartType = chartTypeOverride!

        let bgHex = NSColor(theme.surface.raised).hexString
        let textHex = NSColor(theme.text.primary).hexString
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
        let gridHex = NSColor(theme.border.subtle).withAlphaComponent(0.2).hexString

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

        #if OSAURUS_DESIGN_SYSTEM
        let font = theme.assignedNativeFont(NativeComponentInspectionStyle.key(39, "caption"), fallback: theme.nsFont(.caption))
        let recipe = theme.scaledTextStyle(.caption)
        let family = font.fontName.hasPrefix(".") ? "-apple-system, BlinkMacSystemFont, sans-serif" : (font.familyName ?? "sans-serif")
        let style: [String: Any] = ["color": NSColor(theme.text.secondary).hexString, "fontFamily": family, "fontSize": "\(font.pointSize)px", "fontWeight": String(recipe.weight), "letterSpacing": "\(theme.assignedTracking(NativeComponentInspectionStyle.key(39, "caption")) ?? 0)px", "lineHeight": "\(theme.assignedLineHeight(NativeComponentInspectionStyle.key(39, "caption"), fallback: 16))px"]
        if let data = try? JSONSerialization.data(withJSONObject: style, options: [.sortedKeys]), let json = String(data: data, encoding: .utf8) {
            options.afterDrawChartJavaScript = """
            (function(){ const style = \(json); if(typeof Highcharts === 'undefined')return; Highcharts.charts.filter(Boolean).forEach(function(chart){chart.update({xAxis:{labels:{style:style}},yAxis:{labels:{style:style}},legend:{itemStyle:style},tooltip:{style:style},plotOptions:{series:{dataLabels:{style:style}}}},false);chart.redraw(false);}); })();
            """
        }
        if spec.colorsTheme == nil, var palette = model.colorsTheme, !palette.isEmpty {
            palette[0] = NSColor(theme.border.focus).hexString
            options.colors = palette
        }
        #endif
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
