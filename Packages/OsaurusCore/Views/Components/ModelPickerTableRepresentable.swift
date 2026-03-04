//
//  ModelPickerTableRepresentable.swift
//  osaurus
//
//  NSViewRepresentable wrapping an NSTableView for the model picker
//  list. Provides true cell reuse and efficient diffing for large
//  model lists (e.g. OpenRouter with thousands of models).
//
//  Key design decisions:
//  - NSDiffableDataSource with row IDs for efficient structural updates.
//  - Manual row heights via `tableView(_:heightOfRow:)`.
//  - Pure AppKit cells (no NSHostingView) for 60fps scroll performance.
//  - Selection/highlight state separated from row data for O(visible) updates.
//  - Single NSTrackingArea for hover instead of per-row trackers.
//  - Keyboard highlight scroll via `scrollRowToVisible`.
//

import AppKit
import SwiftUI

// MARK: - Supporting Types

enum ModelPickerSection: Hashable {
    case main
}

/// Flattened row model. Contains only structural data — visual state
/// (selection, highlight, hover) lives in the coordinator.
enum ModelPickerRow: Equatable, Identifiable {
    case groupHeader(
        sourceKey: String,
        displayName: String,
        sourceType: ModelOption.Source,
        count: Int,
        isExpanded: Bool
    )
    case model(
        id: String,
        sourceKey: String,
        displayName: String,
        description: String?,
        parameterCount: String?,
        quantization: String?,
        isVLM: Bool
    )

    var id: String {
        switch self {
        case .groupHeader(let sourceKey, _, _, _, _): return "gh-\(sourceKey)"
        case .model(let id, let sourceKey, _, _, _, _, _): return "model-\(sourceKey)-\(id)"
        }
    }

    var modelId: String? {
        switch self {
        case .groupHeader: return nil
        case .model(let id, _, _, _, _, _, _): return id
        }
    }
}

/// Pre-converted NSColors from the SwiftUI theme, built once per theme change
/// to avoid expensive `NSColor(SwiftUI.Color)` bridging on every cell configure.
struct ThemeColorCache {
    let primaryText: NSColor
    let secondaryText: NSColor
    let tertiaryText: NSColor
    let accentColor: NSColor
    let secondaryBackground: NSColor
    let primaryBorder: NSColor

    let accentAlpha09: NSColor
    let accentAlpha012: NSColor
    let accentAlpha015: NSColor
    let secondaryTextAlpha09: NSColor
    let secondaryTextAlpha012: NSColor
    let hoverBg: NSColor
    let borderAlpha01: NSColor

    init(theme: ThemeProtocol) {
        primaryText = NSColor(theme.primaryText)
        secondaryText = NSColor(theme.secondaryText)
        tertiaryText = NSColor(theme.tertiaryText)
        accentColor = NSColor(theme.accentColor)
        secondaryBackground = NSColor(theme.secondaryBackground)
        primaryBorder = NSColor(theme.primaryBorder)

        accentAlpha09 = accentColor.withAlphaComponent(0.9)
        accentAlpha012 = accentColor.withAlphaComponent(0.12)
        accentAlpha015 = accentColor.withAlphaComponent(0.15)
        secondaryTextAlpha09 = secondaryText.withAlphaComponent(0.9)
        secondaryTextAlpha012 = secondaryText.withAlphaComponent(0.12)
        hoverBg = secondaryBackground.withAlphaComponent(0.7)
        borderAlpha01 = primaryBorder.withAlphaComponent(0.1)
    }
}

// MARK: - ModelPickerTableRepresentable

struct ModelPickerTableRepresentable: NSViewRepresentable {

    let rows: [ModelPickerRow]
    let theme: ThemeProtocol
    var selectedModelId: String?
    var onToggleGroup: ((String) -> Void)?
    var onSelectModel: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let tableView = Self.makeTableView()
        let scrollView = Self.makeScrollView(documentView: tableView)

        coordinator.tableView = tableView
        coordinator.setupDataSource(for: tableView)
        coordinator.setupHoverTracking(on: tableView)
        coordinator.setupScrollObservation(for: scrollView)
        coordinator.installKeyMonitor()

        coordinator.onToggleGroup = onToggleGroup
        coordinator.onSelectModel = onSelectModel
        coordinator.onDismiss = onDismiss
        coordinator.updateColorsIfNeeded(from: theme)
        coordinator.updateSelectedModelId(selectedModelId)
        coordinator.applyRows(rows)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onToggleGroup = onToggleGroup
        coordinator.onSelectModel = onSelectModel
        coordinator.onDismiss = onDismiss
        coordinator.updateColorsIfNeeded(from: theme)
        coordinator.updateSelectedModelId(selectedModelId)
        coordinator.applyRows(rows)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.removeKeyMonitor()
    }

    private static func makeTableView() -> HoverTrackingTableView {
        let tv = HoverTrackingTableView()
        tv.style = .plain
        tv.headerView = nil
        tv.rowSizeStyle = .custom
        tv.selectionHighlightStyle = .none
        tv.backgroundColor = .clear
        tv.intercellSpacing = .zero
        tv.usesAlternatingRowBackgroundColors = false
        tv.refusesFirstResponder = true
        tv.allowsMultipleSelection = false
        tv.allowsEmptySelection = true
        tv.gridStyleMask = []
        tv.usesAutomaticRowHeights = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ModelPickerColumn"))
        column.resizingMask = .autoresizingMask
        tv.addTableColumn(column)
        return tv
    }

    private static func makeScrollView(documentView: NSView) -> NSScrollView {
        let sv = NSScrollView()
        sv.documentView = documentView
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.contentView.drawsBackground = false
        sv.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        return sv
    }
}

// MARK: - AppKit Helpers

@MainActor
private func makeLabel(
    lineBreakMode: NSLineBreakMode = .byTruncatingTail,
    maximumLines: Int = 1
) -> NSTextField {
    let tf = NSTextField(labelWithString: "")
    tf.isEditable = false
    tf.isSelectable = false
    tf.isBordered = false
    tf.drawsBackground = false
    tf.lineBreakMode = lineBreakMode
    tf.maximumNumberOfLines = maximumLines
    if maximumLines > 1 {
        tf.cell?.truncatesLastVisibleLine = true
    }
    return tf
}

// MARK: - Pure AppKit Cells

/// Lightweight badge: rounded background + optional SF Symbol icon + label.
@MainActor
private final class PickerBadgeView: NSView {
    private let iconView = NSImageView()
    private let label = makeLabel(lineBreakMode: .byClipping)

    private var hPad: CGFloat = 5
    private var vPad: CGFloat = 2
    private var isCapsule = false
    private var bgNSColor: NSColor = .clear
    private var borderNSColor: NSColor = .clear

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.isHidden = true
        addSubview(iconView)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(
        text: String,
        iconImage: NSImage? = nil,
        font: NSFont = .systemFont(ofSize: 9, weight: .medium),
        textColor: NSColor,
        bgColor: NSColor,
        borderColor: NSColor = .clear,
        isCapsule: Bool = false
    ) {
        label.stringValue = text
        label.font = font
        label.textColor = textColor

        if let iconImage {
            iconView.image = iconImage
            iconView.contentTintColor = textColor
            iconView.isHidden = false
        } else {
            iconView.isHidden = true
        }

        bgNSColor = bgColor
        borderNSColor = borderColor
        self.isCapsule = isCapsule
        hPad = isCapsule ? 8 : 5
        vPad = isCapsule ? 3 : 2

        sizeToFitContent()

        layer?.backgroundColor = bgNSColor.cgColor
        layer?.cornerRadius = isCapsule ? frame.height / 2 : 4
        layer?.cornerCurve = .continuous
        layer?.borderWidth = borderNSColor != .clear ? 1 : 0
        layer?.borderColor = borderNSColor.cgColor
    }

    func sizeToFitContent() {
        label.sizeToFit()
        var w = label.frame.width + hPad * 2
        if !iconView.isHidden { w += 13 }
        frame.size = CGSize(width: ceil(w), height: ceil(label.frame.height + vPad * 2))
    }

    override func layout() {
        super.layout()
        var x = hPad
        let contentH = bounds.height - vPad * 2

        if !iconView.isHidden {
            iconView.frame = CGRect(x: x, y: vPad, width: 10, height: contentH)
            x += 13
        }
        label.frame = CGRect(x: x, y: vPad, width: max(0, bounds.width - x - hPad), height: contentH)
    }
}

/// Group header cell. Flat section style — click toggles expand/collapse.
@MainActor
private final class GroupHeaderCellView: NSTableCellView {
    private let chevronView = NSImageView()
    private let sourceIconView = NSImageView()
    private let nameLabel = makeLabel()
    private let countBadge = PickerBadgeView()

    var rowId: String?
    private var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        chevronView.imageScaling = .scaleNone
        sourceIconView.imageScaling = .scaleNone
        addSubview(chevronView)
        addSubview(sourceIconView)
        addSubview(nameLabel)
        addSubview(countBadge)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(didClick)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func didClick() { onToggle?() }

    func configure(
        id: String,
        displayName: String,
        count: Int,
        isExpanded: Bool,
        colors: ThemeColorCache,
        chevronImage: NSImage?,
        sourceIcon: NSImage?,
        onToggle: @escaping () -> Void
    ) {
        rowId = id
        self.onToggle = onToggle

        chevronView.image = chevronImage
        chevronView.contentTintColor = colors.tertiaryText

        sourceIconView.image = sourceIcon
        sourceIconView.contentTintColor = colors.secondaryText

        nameLabel.stringValue = displayName
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = colors.primaryText

        countBadge.configure(
            text: "\(count)",
            font: .systemFont(ofSize: 10, weight: .medium),
            textColor: colors.tertiaryText,
            bgColor: colors.secondaryBackground,
            borderColor: colors.borderAlpha01,
            isCapsule: true
        )

        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let pad: CGFloat = 12

        chevronView.frame = CGRect(x: pad, y: (h - 12) / 2, width: 12, height: 12)
        sourceIconView.frame = CGRect(x: pad + 20, y: (h - 14) / 2, width: 14, height: 14)

        countBadge.sizeToFitContent()
        let badgeX = bounds.width - pad - countBadge.frame.width
        countBadge.frame.origin = CGPoint(x: badgeX, y: (h - countBadge.frame.height) / 2)

        let nameX: CGFloat = pad + 42
        nameLabel.frame = CGRect(x: nameX, y: (h - 16) / 2, width: max(0, badgeX - nameX - 8), height: 16)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        rowId = nil
        onToggle = nil
    }
}

/// Model row cell with hover/selection background.
@MainActor
private final class ModelRowCellView: NSTableCellView {
    private let bgLayer = CALayer()
    private let nameLabel = makeLabel()
    private let vlmBadge = PickerBadgeView()
    private let descLabel = makeLabel(maximumLines: 2)
    private let paramBadge = PickerBadgeView()
    private let quantBadge = PickerBadgeView()
    private let checkmarkView = NSImageView()

    var rowId: String?
    private var onSelect: (() -> Void)?
    private var hasDesc = false
    private var hasBadges = false
    private var hasVLM = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        bgLayer.cornerRadius = 8
        bgLayer.cornerCurve = .continuous
        layer?.addSublayer(bgLayer)

        descLabel.isHidden = true
        vlmBadge.isHidden = true
        paramBadge.isHidden = true
        quantBadge.isHidden = true
        checkmarkView.imageScaling = .scaleNone
        checkmarkView.isHidden = true

        addSubview(nameLabel)
        addSubview(vlmBadge)
        addSubview(descLabel)
        addSubview(paramBadge)
        addSubview(quantBadge)
        addSubview(checkmarkView)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(didClick)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func didClick() { onSelect?() }

    func configure(
        id: String,
        displayName: String,
        description: String?,
        parameterCount: String?,
        quantization: String?,
        isVLM: Bool,
        isSelected: Bool,
        isHighlighted: Bool,
        isHovered: Bool,
        colors: ThemeColorCache,
        checkmarkImage: NSImage?,
        eyeImage: NSImage?,
        onSelect: @escaping () -> Void
    ) {
        rowId = id
        self.onSelect = onSelect
        hasDesc = description?.isEmpty == false
        hasBadges = parameterCount != nil || quantization != nil
        hasVLM = isVLM

        nameLabel.stringValue = displayName
        nameLabel.font = .systemFont(ofSize: 12, weight: isSelected ? .semibold : .medium)
        nameLabel.textColor = isSelected ? colors.primaryText : colors.secondaryText

        if isVLM {
            vlmBadge.configure(
                text: "Vision",
                iconImage: eyeImage,
                font: .systemFont(ofSize: 8, weight: .medium),
                textColor: colors.accentColor,
                bgColor: colors.accentAlpha012,
                borderColor: colors.accentAlpha015,
                isCapsule: true
            )
            vlmBadge.isHidden = false
        } else {
            vlmBadge.isHidden = true
        }

        if let desc = description, !desc.isEmpty {
            descLabel.stringValue = desc
            descLabel.font = .systemFont(ofSize: 10)
            descLabel.textColor = colors.tertiaryText
            descLabel.isHidden = false
        } else {
            descLabel.isHidden = true
        }

        if let params = parameterCount {
            paramBadge.configure(
                text: params,
                textColor: colors.accentAlpha09,
                bgColor: colors.accentAlpha012
            )
            paramBadge.isHidden = false
        } else {
            paramBadge.isHidden = true
        }

        if let quant = quantization {
            quantBadge.configure(
                text: quant,
                textColor: colors.secondaryTextAlpha09,
                bgColor: colors.secondaryTextAlpha012
            )
            quantBadge.isHidden = false
        } else {
            quantBadge.isHidden = true
        }

        if isSelected {
            checkmarkView.image = checkmarkImage
            checkmarkView.contentTintColor = colors.accentColor
            checkmarkView.isHidden = false
        } else {
            checkmarkView.isHidden = true
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bgLayer.backgroundColor =
            (isHovered || isHighlighted || isSelected)
            ? colors.hoverBg.cgColor
            : nil
        CATransaction.commit()

        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        let pad: CGFloat = 12
        let topPad: CGFloat = 10
        let vSpacing: CGFloat = 3

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bgLayer.frame = bounds.insetBy(dx: 2, dy: 1)
        CATransaction.commit()

        let checkVisible = !checkmarkView.isHidden
        if checkVisible {
            checkmarkView.frame = CGRect(x: w - pad - 14, y: (h - 14) / 2, width: 14, height: 14)
        }
        let contentW = (checkVisible ? w - pad - 22 : w - pad) - pad
        var y = topPad

        let nameH: CGFloat = 16
        if hasVLM, !vlmBadge.isHidden {
            vlmBadge.sizeToFitContent()
            let nameW = contentW - vlmBadge.frame.width - 6
            nameLabel.frame = CGRect(x: pad, y: y, width: max(0, nameW), height: nameH)
            vlmBadge.frame.origin = CGPoint(
                x: nameLabel.frame.maxX + 6,
                y: y + (nameH - vlmBadge.frame.height) / 2
            )
        } else {
            nameLabel.frame = CGRect(x: pad, y: y, width: max(0, contentW), height: nameH)
        }
        y += nameH

        if hasDesc, !descLabel.isHidden {
            y += vSpacing
            descLabel.frame = CGRect(x: pad, y: y, width: max(0, contentW), height: 14)
            y += 14
        }

        if hasBadges {
            y += vSpacing
            var bx = pad
            if !paramBadge.isHidden {
                paramBadge.sizeToFitContent()
                paramBadge.frame.origin = CGPoint(x: bx, y: y)
                bx += paramBadge.frame.width + 4
            }
            if !quantBadge.isHidden {
                quantBadge.sizeToFitContent()
                quantBadge.frame.origin = CGPoint(x: bx, y: y)
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        rowId = nil
        onSelect = nil
        descLabel.isHidden = true
        vlmBadge.isHidden = true
        paramBadge.isHidden = true
        quantBadge.isHidden = true
        checkmarkView.isHidden = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bgLayer.backgroundColor = nil
        CATransaction.commit()
    }
}

// MARK: - Coordinator

extension ModelPickerTableRepresentable {

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate {

        weak var tableView: NSTableView?
        private var dataSource: NSTableViewDiffableDataSource<ModelPickerSection, String>?
        private var rowIds: [String] = []
        private var rowLookup: [String: ModelPickerRow] = [:]
        private var rowIdToIndex: [String: Int] = [:]
        private var modelIdToRowIndex: [String: Int] = [:]
        private var flatModelIds: [String] = []

        var selectedModelId: String?
        var onToggleGroup: ((String) -> Void)?
        var onSelectModel: ((String) -> Void)?
        var onDismiss: (() -> Void)?

        private var hoveredRowId: String?
        private var highlightedIndex: Int?
        private var keyMonitor: Any?
        private var isScrolling = false

        // MARK: Cached Theme Colors & Images

        private var colors = ThemeColorCache(theme: LightTheme())
        private var lastThemeTypeId: ObjectIdentifier?

        private lazy var chevronDown: NSImage? = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))

        private lazy var chevronRight: NSImage? = NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))

        private lazy var appleLogoIcon: NSImage? = NSImage(
            systemSymbolName: "apple.logo",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))

        private lazy var internalDriveIcon: NSImage? = NSImage(
            systemSymbolName: "internaldrive",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))

        private lazy var cloudIcon: NSImage? = NSImage(
            systemSymbolName: "cloud",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))

        private lazy var checkmarkImage: NSImage? = NSImage(
            systemSymbolName: "checkmark",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .bold))

        private lazy var eyeImage: NSImage? = NSImage(
            systemSymbolName: "eye",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 8, weight: .medium))

        private func sourceIcon(for source: ModelOption.Source) -> NSImage? {
            switch source {
            case .foundation: return appleLogoIcon
            case .local: return internalDriveIcon
            case .remote: return cloudIcon
            }
        }

        // MARK: Setup

        func setupDataSource(for tableView: NSTableView) {
            dataSource = NSTableViewDiffableDataSource<ModelPickerSection, String>(
                tableView: tableView
            ) { [weak self] tableView, _, row, itemId in
                self?.dequeueAndConfigure(tableView: tableView, row: row, rowId: itemId) ?? NSView()
            }
            tableView.delegate = self
        }

        func setupHoverTracking(on tableView: HoverTrackingTableView) {
            tableView.onMouseMoved = { [weak self] event in self?.handleMouseMoved(with: event) }
            tableView.onMouseExited = { [weak self] in self?.setHoveredRow(nil) }
        }

        func setupScrollObservation(for scrollView: NSScrollView) {
            let nc = NotificationCenter.default
            nc.addObserver(
                self,
                selector: #selector(onScrollStart),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )
            nc.addObserver(
                self,
                selector: #selector(onScrollEnd),
                name: NSScrollView.didEndLiveScrollNotification,
                object: scrollView
            )
        }

        @objc private func onScrollStart() { isScrolling = true; setHoveredRow(nil) }
        @objc private func onScrollEnd() { isScrolling = false }

        // MARK: Keyboard Navigation

        func installKeyMonitor() {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKeyDown(event) ?? event
            }
        }

        func removeKeyMonitor() {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }

        private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
            switch event.keyCode {
            case 125: moveHighlight(by: 1); return nil
            case 126: moveHighlight(by: -1); return nil
            case 36:
                if highlightedIndex != nil { selectHighlighted(); return nil }
                return event
            case 53: onDismiss?(); return nil
            default: return event
            }
        }

        private func moveHighlight(by offset: Int) {
            guard !flatModelIds.isEmpty else { return }
            let oldIndex = highlightedIndex
            if let current = oldIndex {
                highlightedIndex = max(0, min(flatModelIds.count - 1, current + offset))
            } else {
                highlightedIndex = offset > 0 ? 0 : flatModelIds.count - 1
            }
            if let old = oldIndex, old < flatModelIds.count,
                let rowIdx = modelIdToRowIndex[flatModelIds[old]]
            {
                reconfigureCell(at: rowIdx)
            }
            if let new = highlightedIndex, new < flatModelIds.count,
                let rowIdx = modelIdToRowIndex[flatModelIds[new]]
            {
                reconfigureCell(at: rowIdx)
                tableView?.scrollRowToVisible(rowIdx)
            }
        }

        private func selectHighlighted() {
            guard let index = highlightedIndex, index < flatModelIds.count else { return }
            onSelectModel?(flatModelIds[index])
        }

        // MARK: Theme

        func updateColorsIfNeeded(from theme: ThemeProtocol) {
            let typeId = ObjectIdentifier(type(of: theme))
            guard typeId != lastThemeTypeId else { return }
            lastThemeTypeId = typeId
            colors = ThemeColorCache(theme: theme)
        }

        // MARK: Selection

        func updateSelectedModelId(_ newId: String?) {
            guard selectedModelId != newId else { return }
            selectedModelId = newId
            reconfigureVisibleCells()
        }

        // MARK: Apply Rows

        private var lastRowCount = 0
        private var lastFirstRowId: String?
        private var lastLastRowId: String?

        func applyRows(_ rows: [ModelPickerRow]) {
            let count = rows.count
            let firstId = rows.first?.id
            let lastId = rows.last?.id
            guard count != lastRowCount || firstId != lastFirstRowId || lastId != lastLastRowId else { return }
            lastRowCount = count
            lastFirstRowId = firstId
            lastLastRowId = lastId

            let newIds = rows.map(\.id)
            let newLookup = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

            if newIds == rowIds {
                rowLookup = newLookup
                reconfigureVisibleCells()
                return
            }

            rowLookup = newLookup
            var seen = Set<String>()
            rowIds = newIds.filter { seen.insert($0).inserted }
            rebuildIndexMaps()
            highlightedIndex = nil

            var snapshot = NSDiffableDataSourceSnapshot<ModelPickerSection, String>()
            snapshot.appendSections([.main])
            snapshot.appendItems(rowIds, toSection: .main)
            dataSource?.apply(snapshot, animatingDifferences: false)
        }

        private func rebuildIndexMaps() {
            rowIdToIndex = Dictionary(
                uniqueKeysWithValues: rowIds.enumerated().map { ($1, $0) }
            )
            var modelMap: [String: Int] = [:]
            var modelIds: [String] = []
            for (idx, rowId) in rowIds.enumerated() {
                if let mId = rowLookup[rowId]?.modelId {
                    modelMap[mId] = idx
                    modelIds.append(mId)
                }
            }
            modelIdToRowIndex = modelMap
            flatModelIds = modelIds
        }

        // MARK: Cell Updates

        private func reconfigureVisibleCells() {
            guard let tableView else { return }
            let range = tableView.rows(in: tableView.visibleRect)
            for row in range.location ..< (range.location + range.length) {
                reconfigureCell(at: row)
            }
        }

        private func reconfigureCell(at row: Int) {
            guard let tableView, row < rowIds.count,
                let rowData = rowLookup[rowIds[row]]
            else { return }

            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? GroupHeaderCellView {
                configureGroupHeader(cell, with: rowData)
            } else if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ModelRowCellView {
                configureModelRow(cell, with: rowData)
            }
        }

        // MARK: Cell Factory

        private static let headerReuseId = NSUserInterfaceItemIdentifier("GroupHeaderCell")
        private static let modelReuseId = NSUserInterfaceItemIdentifier("ModelRowCell")

        private func dequeueAndConfigure(tableView: NSTableView, row: Int, rowId: String) -> NSView {
            guard let rowData = rowLookup[rowId] else { return NSView() }

            switch rowData {
            case .groupHeader:
                let cell =
                    tableView.makeView(withIdentifier: Self.headerReuseId, owner: nil) as? GroupHeaderCellView
                    ?? {
                        let c = GroupHeaderCellView(frame: .zero); c.identifier = Self.headerReuseId; return c
                    }()
                configureGroupHeader(cell, with: rowData)
                return cell

            case .model:
                let cell =
                    tableView.makeView(withIdentifier: Self.modelReuseId, owner: nil) as? ModelRowCellView
                    ?? {
                        let c = ModelRowCellView(frame: .zero); c.identifier = Self.modelReuseId; return c
                    }()
                configureModelRow(cell, with: rowData)
                return cell
            }
        }

        private func configureGroupHeader(_ cell: GroupHeaderCellView, with row: ModelPickerRow) {
            guard case .groupHeader(let sourceKey, let displayName, let sourceType, let count, let isExpanded) = row
            else { return }
            cell.configure(
                id: row.id,
                displayName: displayName,
                count: count,
                isExpanded: isExpanded,
                colors: colors,
                chevronImage: isExpanded ? chevronDown : chevronRight,
                sourceIcon: sourceIcon(for: sourceType),
                onToggle: { [weak self] in self?.onToggleGroup?(sourceKey) }
            )
        }

        private var highlightedModelId: String? {
            guard let idx = highlightedIndex, idx < flatModelIds.count else { return nil }
            return flatModelIds[idx]
        }

        private func configureModelRow(_ cell: ModelRowCellView, with row: ModelPickerRow) {
            guard case .model(let id, _, let displayName, let desc, let params, let quant, let isVLM) = row
            else { return }
            cell.configure(
                id: row.id,
                displayName: displayName,
                description: desc,
                parameterCount: params,
                quantization: quant,
                isVLM: isVLM,
                isSelected: selectedModelId == id,
                isHighlighted: highlightedModelId == id,
                isHovered: hoveredRowId == row.id,
                colors: colors,
                checkmarkImage: checkmarkImage,
                eyeImage: eyeImage,
                onSelect: { [weak self] in self?.onSelectModel?(id) }
            )
        }

        // MARK: Hover

        private func handleMouseMoved(with event: NSEvent) {
            guard !isScrolling, let tableView else { return }
            let point = tableView.convert(event.locationInWindow, from: nil)
            let row = tableView.row(at: point)
            guard row >= 0, row < rowIds.count else { return setHoveredRow(nil) }
            setHoveredRow(rowIds[row])
        }

        private func setHoveredRow(_ newRowId: String?) {
            guard hoveredRowId != newRowId else { return }
            let oldRowId = hoveredRowId
            hoveredRowId = newRowId

            for targetId in [oldRowId, newRowId] {
                guard let targetId, let idx = rowIdToIndex[targetId] else { continue }
                reconfigureCell(at: idx)
            }
        }

        // MARK: NSTableViewDelegate

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < rowIds.count, let rowData = rowLookup[rowIds[row]] else { return 44 }
            return Self.rowHeight(for: rowData)
        }

        private static func rowHeight(for row: ModelPickerRow) -> CGFloat {
            switch row {
            case .groupHeader:
                return 44
            case .model(_, _, _, let description, let parameterCount, let quantization, _):
                var h: CGFloat = 36
                if description?.isEmpty == false { h += 17 }
                if parameterCount != nil || quantization != nil { h += 17 }
                return h
            }
        }
    }
}
