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
//  - Keyboard: up/down highlight, return selects, left/right switch tabs.
//  - Every row shares one flipped two-line layout: a leading checkmark
//    gutter (NSMenu style, reserved on all rows), a name line, and an
//    optional metadata line — so selection never shifts content.
//

import AppKit
import SwiftUI

// MARK: - Supporting Types

enum ModelPickerSection: Hashable {
    case main
}

/// Flattened row model. Contains only structural data — visual state
/// (selection, highlight, hover) lives in the coordinator.
/// `providerLabel` is non-nil only in unified search mode, where results
/// from all providers are mixed together and need per-row attribution.
struct ModelPickerRow: Equatable, Identifiable {
    let modelId: String
    let sourceKey: String
    let displayName: String
    let description: String?
    let parameterCount: String?
    let quantization: String?
    let isVLM: Bool
    /// False when the bundle is on disk but not in MLX format — the row is
    /// dimmed and made non-selectable so the user can't pick a model that
    /// would fail at load. Defaults to true (every selectable model).
    let isMLXFormat: Bool
    let providerLabel: String?
    /// Whether this model is currently bookmarked. Drives the row's heart fill
    /// so favourited rows read as favourited everywhere, not only in the
    /// Favourites tab.
    let isFavorite: Bool

    init(
        modelId: String,
        sourceKey: String,
        displayName: String,
        description: String?,
        parameterCount: String?,
        quantization: String?,
        isVLM: Bool,
        isMLXFormat: Bool = true,
        providerLabel: String? = nil,
        isFavorite: Bool = false
    ) {
        self.modelId = modelId
        self.sourceKey = sourceKey
        self.displayName = displayName
        self.description = description
        self.parameterCount = parameterCount
        self.quantization = quantization
        self.isVLM = isVLM
        self.isMLXFormat = isMLXFormat
        self.providerLabel = providerLabel
        self.isFavorite = isFavorite
    }

    var id: String { "model-\(sourceKey)-\(modelId)" }

    /// Cross-provider key this row is stored under in the favourites list —
    /// matches `ModelPickerItem.favoriteKey` for the same model.
    var favoriteKey: String {
        FavoriteModelsStore.key(sourceKey: sourceKey, modelId: modelId)
    }
}

/// Pre-converted NSColors from the SwiftUI theme, built once per theme change
/// to avoid expensive `NSColor(SwiftUI.Color)` bridging on every cell configure.
struct ThemeColorCache {
    let primaryText: NSColor
    let secondaryText: NSColor
    let tertiaryText: NSColor
    let accentColor: NSColor

    let accentAlpha09: NSColor
    let accentAlpha012: NSColor
    let accentAlpha015: NSColor
    let secondaryTextAlpha09: NSColor
    let secondaryTextAlpha012: NSColor
    let hoverBg: NSColor

    init(theme: ThemeProtocol) {
        primaryText = NSColor(theme.primaryText)
        secondaryText = NSColor(theme.secondaryText)
        tertiaryText = NSColor(theme.tertiaryText)
        accentColor = NSColor(theme.accentColor)

        accentAlpha09 = accentColor.withAlphaComponent(0.9)
        accentAlpha012 = accentColor.withAlphaComponent(0.12)
        accentAlpha015 = accentColor.withAlphaComponent(0.15)
        secondaryTextAlpha09 = secondaryText.withAlphaComponent(0.9)
        secondaryTextAlpha012 = secondaryText.withAlphaComponent(0.12)
        hoverBg = NSColor(theme.secondaryBackground).withAlphaComponent(0.7)
    }
}

// MARK: - ModelPickerTableRepresentable

struct ModelPickerTableRepresentable: NSViewRepresentable {

    let rows: [ModelPickerRow]
    let theme: ThemeProtocol
    var selectedModelId: String?
    /// True while the Favourites tab is active: the trailing control becomes an
    /// always-visible trash (remove) instead of a hover-only heart (toggle).
    var isFavoritesTab: Bool = false
    var onSelectModel: ((String) -> Void)?
    var onSwitchTab: ((Int) -> Void)?
    var onToggleFavorite: ((ModelPickerRow) -> Void)?
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

        coordinator.onSelectModel = onSelectModel
        coordinator.onSwitchTab = onSwitchTab
        coordinator.onToggleFavorite = onToggleFavorite
        coordinator.onDismiss = onDismiss
        coordinator.isFavoritesTab = isFavoritesTab
        coordinator.updateColorsIfNeeded(from: theme)
        coordinator.updateSelectedModelId(selectedModelId)
        coordinator.applyRows(rows)
        applyScrollerStyle(to: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelectModel = onSelectModel
        coordinator.onSwitchTab = onSwitchTab
        coordinator.onToggleFavorite = onToggleFavorite
        coordinator.onDismiss = onDismiss
        coordinator.updateFavoritesTab(isFavoritesTab)
        coordinator.updateColorsIfNeeded(from: theme)
        coordinator.updateSelectedModelId(selectedModelId)
        coordinator.applyRows(rows)
        applyScrollerStyle(to: scrollView)
    }

    private func applyScrollerStyle(to scrollView: NSScrollView) {
        let knobStyle: NSScroller.KnobStyle = theme.isDark ? .light : .dark
        scrollView.scrollerKnobStyle = knobStyle
        scrollView.verticalScroller?.knobStyle = knobStyle
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
private func makeLabel(lineBreakMode: NSLineBreakMode = .byTruncatingTail) -> NSTextField {
    let tf = NSTextField(labelWithString: "")
    tf.isEditable = false
    tf.isSelectable = false
    tf.isBordered = false
    tf.drawsBackground = false
    tf.lineBreakMode = lineBreakMode
    tf.maximumNumberOfLines = 1
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

    // cache to avoid redundant configuration
    private var cachedText: String?
    private var cachedFont: NSFont?
    private var cachedIsCapsule: Bool?

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
        // check if we need to update
        let needsUpdate = cachedText != text || cachedFont != font || cachedIsCapsule != isCapsule

        if needsUpdate {
            label.stringValue = text
            label.font = font
            cachedText = text
            cachedFont = font
            cachedIsCapsule = isCapsule
        }

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

        if needsUpdate {
            sizeToFitContent()
        }

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

/// The trailing favourite control shown on a row, if any. A hover-only heart
/// in normal tabs, an always-visible trash in the Favourites tab.
private enum RowAccessoryKind: Equatable {
    case none
    case heart  // not yet favourited — outline, shown on hover
    case heartFill  // favourited — filled, shown persistently
    case trash  // Favourites tab — remove, always shown
}

/// Model row cell with hover/selection background.
@MainActor
private final class ModelRowCellView: NSTableCellView, NSGestureRecognizerDelegate {
    private let bgLayer = CALayer()
    private let nameLabel = makeLabel()
    private let vlmBadge = PickerBadgeView()
    private let providerBadge = PickerBadgeView()
    private let descLabel = makeLabel()
    private let paramBadge = PickerBadgeView()
    private let quantBadge = PickerBadgeView()
    private let checkmarkView = NSImageView()
    private let accessoryButton = NSButton()

    /// Manual top-down layout. Without this, NSView's default unflipped
    /// coordinates render the rows bottom-up (description above the name),
    /// which made row layouts look inconsistent.
    override var isFlipped: Bool { true }

    private var rowId: String?
    private var onSelect: (() -> Void)?
    private var onAccessory: (() -> Void)?

    /// Fixed side of the trailing accessory hit target. Kept in sync between
    /// `configure`/`layout` so provider-badge space is carved correctly.
    private static let accessorySide: CGFloat = 22
    private var accessoryKind: RowAccessoryKind = .none

    // structural flags from the last configure, compared against incoming
    // values to skip relayout when nothing structural changed
    private var hasDesc = false
    private var hasBadges = false
    private var hasVLM = false
    private var hasProvider = false
    private var cachedDisplayName: String?
    private var cachedProviderLabel: String?

    // visual state from the last configure, compared to skip redundant
    // background/checkmark updates
    private var cachedIsSelected = false
    private var cachedIsHovered = false
    private var cachedIsHighlighted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        bgLayer.cornerRadius = 8
        bgLayer.cornerCurve = .continuous
        layer?.addSublayer(bgLayer)

        descLabel.isHidden = true
        vlmBadge.isHidden = true
        providerBadge.isHidden = true
        paramBadge.isHidden = true
        quantBadge.isHidden = true
        checkmarkView.imageScaling = .scaleNone
        checkmarkView.isHidden = true

        accessoryButton.isBordered = false
        accessoryButton.bezelStyle = .regularSquare
        accessoryButton.imagePosition = .imageOnly
        accessoryButton.imageScaling = .scaleProportionallyDown
        accessoryButton.setButtonType(.momentaryChange)
        accessoryButton.target = self
        accessoryButton.action = #selector(didClickAccessory)
        accessoryButton.isHidden = true

        addSubview(nameLabel)
        addSubview(vlmBadge)
        addSubview(providerBadge)
        addSubview(descLabel)
        addSubview(paramBadge)
        addSubview(quantBadge)
        addSubview(checkmarkView)
        addSubview(accessoryButton)
        let click = NSClickGestureRecognizer(target: self, action: #selector(didClick))
        click.delegate = self
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func didClick() { onSelect?() }
    @objc private func didClickAccessory() { onAccessory?() }

    /// Keep the whole-row select gesture from firing when the click lands on the
    /// visible favourite control — otherwise toggling a favourite would also
    /// select the model and dismiss the picker. The button's own action still
    /// runs.
    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldAttemptToRecognizeWith event: NSEvent
    ) -> Bool {
        guard !accessoryButton.isHidden else { return true }
        let point = accessoryButton.convert(event.locationInWindow, from: nil)
        return !accessoryButton.bounds.contains(point)
    }

    func configure(
        id: String,
        displayName: String,
        description: String?,
        parameterCount: String?,
        quantization: String?,
        isVLM: Bool,
        providerLabel: String?,
        isSelected: Bool,
        isHighlighted: Bool,
        isHovered: Bool,
        isFavorite: Bool,
        favoritesMode: Bool,
        colors: ThemeColorCache,
        checkmarkImage: NSImage?,
        eyeImage: NSImage?,
        heartImage: NSImage?,
        heartFillImage: NSImage?,
        trashImage: NSImage?,
        regularFont: NSFont,
        semiboldFont: NSFont,
        descFont: NSFont,
        badgeFont: NSFont,
        badgeFontSmall: NSFont,
        onSelect: @escaping () -> Void,
        onAccessory: @escaping () -> Void
    ) {
        let isNewRow = rowId != id
        rowId = id
        self.onSelect = onSelect
        self.onAccessory = onAccessory

        let newHasDesc = description?.isEmpty == false
        let newHasBadges = parameterCount != nil || quantization != nil
        let newHasVLM = isVLM
        let newHasProvider = providerLabel?.isEmpty == false

        // only trigger full layout if structural content changed
        let structureChanged =
            isNewRow || hasDesc != newHasDesc || hasBadges != newHasBadges || hasVLM != newHasVLM
            || hasProvider != newHasProvider || cachedProviderLabel != providerLabel
            || cachedDisplayName != displayName
        hasDesc = newHasDesc
        hasBadges = newHasBadges
        hasVLM = newHasVLM
        hasProvider = newHasProvider
        cachedDisplayName = displayName
        cachedProviderLabel = providerLabel

        if structureChanged || cachedIsSelected != isSelected {
            nameLabel.stringValue = displayName
            nameLabel.font = isSelected ? semiboldFont : regularFont
            nameLabel.textColor = isSelected ? colors.primaryText : colors.secondaryText
        }

        if isVLM {
            if structureChanged {
                vlmBadge.configure(
                    text: "Vision",
                    iconImage: eyeImage,
                    font: badgeFontSmall,
                    textColor: colors.accentColor,
                    bgColor: colors.accentAlpha012,
                    borderColor: colors.accentAlpha015,
                    isCapsule: true
                )
            }
            vlmBadge.isHidden = false
        } else {
            vlmBadge.isHidden = true
        }

        if let provider = providerLabel, !provider.isEmpty {
            if structureChanged {
                providerBadge.configure(
                    text: provider,
                    font: badgeFont,
                    textColor: colors.secondaryTextAlpha09,
                    bgColor: colors.secondaryTextAlpha012,
                    isCapsule: true
                )
            }
            providerBadge.isHidden = false
        } else {
            providerBadge.isHidden = true
        }

        if let desc = description, !desc.isEmpty {
            if structureChanged {
                descLabel.stringValue = desc
                descLabel.font = descFont
                descLabel.textColor = colors.tertiaryText
            }
            descLabel.isHidden = false
        } else {
            descLabel.isHidden = true
        }

        if let params = parameterCount {
            if structureChanged {
                paramBadge.configure(
                    text: params,
                    textColor: colors.accentAlpha09,
                    bgColor: colors.accentAlpha012
                )
            }
            paramBadge.isHidden = false
        } else {
            paramBadge.isHidden = true
        }

        if let quant = quantization {
            if structureChanged {
                quantBadge.configure(
                    text: quant,
                    textColor: colors.secondaryTextAlpha09,
                    bgColor: colors.secondaryTextAlpha012
                )
            }
            quantBadge.isHidden = false
        } else {
            quantBadge.isHidden = true
        }

        if isSelected {
            if cachedIsSelected != isSelected {
                checkmarkView.image = checkmarkImage
                checkmarkView.contentTintColor = colors.accentColor
            }
            checkmarkView.isHidden = false
        } else {
            checkmarkView.isHidden = true
        }

        // only update background if hover/selection state changed
        if cachedIsHovered != isHovered || cachedIsHighlighted != isHighlighted || cachedIsSelected != isSelected {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bgLayer.backgroundColor =
                (isHovered || isHighlighted || isSelected)
                ? colors.hoverBg.cgColor
                : nil
            CATransaction.commit()
        }

        cachedIsSelected = isSelected
        cachedIsHovered = isHovered
        cachedIsHighlighted = isHighlighted

        // Trailing favourite control. In the Favourites tab it's an
        // always-visible trash (remove); elsewhere it's a heart — shown filled
        // and persistent once favourited, and as an outline on hover so an
        // un-favourited row can be bookmarked. `RowAccessoryKind` is compared
        // against the last value so an unchanged hover/selection pass skips the
        // image swap and the relayout.
        let newAccessoryKind: RowAccessoryKind
        if favoritesMode {
            newAccessoryKind = .trash
        } else if isFavorite {
            newAccessoryKind = .heartFill
        } else if isHovered {
            newAccessoryKind = .heart
        } else {
            newAccessoryKind = .none
        }

        if newAccessoryKind != accessoryKind {
            switch newAccessoryKind {
            case .none:
                accessoryButton.isHidden = true
            case .heart:
                accessoryButton.image = heartImage
                accessoryButton.contentTintColor = colors.tertiaryText
                accessoryButton.isHidden = false
            case .heartFill:
                accessoryButton.image = heartFillImage
                accessoryButton.contentTintColor = colors.accentColor
                accessoryButton.isHidden = false
            case .trash:
                accessoryButton.image = trashImage
                accessoryButton.contentTintColor = colors.secondaryText
                accessoryButton.isHidden = false
            }
            accessoryButton.toolTip =
                newAccessoryKind == .trash
                ? L("Remove from favourites")
                : (newAccessoryKind == .heartFill
                    ? L("Remove from favourites")
                    : L("Add to favourites"))
            // Visibility change shifts the trailing content, so relayout even
            // when the row's structural content is otherwise unchanged.
            if (newAccessoryKind == .none) != (accessoryKind == .none) {
                needsLayout = true
            }
            accessoryKind = newAccessoryKind
        }

        // only trigger layout if structure changed
        if structureChanged {
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        let pad: CGFloat = 12
        let nameH: CGFloat = 16
        let metaH: CGFloat = 16

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bgLayer.frame = bounds.insetBy(dx: 2, dy: 1)
        CATransaction.commit()

        // Every row uses the same two-line structure:
        //   gutter: leading checkmark column reserved on ALL rows (NSMenu
        //           style) so selection never shifts the content
        //   line 1: name (+ Vision badge) ... provider badge
        //   line 2 (optional): param/quant badges + description
        // Name-only rows center the name line vertically.
        let hasMeta = hasDesc || hasBadges
        let nameY: CGFloat = hasMeta ? 10 : (h - nameH) / 2

        if !checkmarkView.isHidden {
            checkmarkView.frame = CGRect(
                x: pad,
                y: nameY + (nameH - 14) / 2,
                width: 14,
                height: 14
            )
        }
        let contentX = pad + 14 + 6

        var trailingX = w - pad
        // The favourite control sits at the far trailing edge, vertically
        // centred on the whole row so it reads the same on one- and two-line
        // rows. Provider badge (and content) shrink to its left.
        if accessoryKind != .none {
            let side = Self.accessorySide
            accessoryButton.frame = CGRect(
                x: trailingX - side,
                y: (h - side) / 2,
                width: side,
                height: side
            )
            trailingX -= (side + 6)
        }
        if !providerBadge.isHidden {
            providerBadge.sizeToFitContent()
            trailingX -= providerBadge.frame.width
            providerBadge.frame.origin = CGPoint(
                x: trailingX,
                y: nameY + (nameH - providerBadge.frame.height) / 2
            )
            trailingX -= 8
        }
        let contentW = trailingX - contentX

        if !vlmBadge.isHidden {
            vlmBadge.sizeToFitContent()
            let nameW = contentW - vlmBadge.frame.width - 6
            nameLabel.frame = CGRect(x: contentX, y: nameY, width: max(0, nameW), height: nameH)
            vlmBadge.frame.origin = CGPoint(
                x: nameLabel.frame.maxX + 6,
                y: nameY + (nameH - vlmBadge.frame.height) / 2
            )
        } else {
            nameLabel.frame = CGRect(x: contentX, y: nameY, width: max(0, contentW), height: nameH)
        }

        if hasMeta {
            let metaY = nameY + nameH + 4
            var x = contentX
            if !paramBadge.isHidden {
                paramBadge.sizeToFitContent()
                paramBadge.frame.origin = CGPoint(
                    x: x,
                    y: metaY + (metaH - paramBadge.frame.height) / 2
                )
                x += paramBadge.frame.width + 4
            }
            if !quantBadge.isHidden {
                quantBadge.sizeToFitContent()
                quantBadge.frame.origin = CGPoint(
                    x: x,
                    y: metaY + (metaH - quantBadge.frame.height) / 2
                )
                x += quantBadge.frame.width + 4
            }
            if !descLabel.isHidden {
                if x > contentX { x += 4 }
                let descW = w - pad - x
                descLabel.frame = CGRect(x: x, y: metaY + 1, width: max(0, descW), height: 14)
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        rowId = nil
        onSelect = nil
        onAccessory = nil
        descLabel.isHidden = true
        vlmBadge.isHidden = true
        providerBadge.isHidden = true
        paramBadge.isHidden = true
        quantBadge.isHidden = true
        checkmarkView.isHidden = true
        accessoryButton.isHidden = true
        accessoryKind = .none
        hasDesc = false
        hasBadges = false
        hasVLM = false
        hasProvider = false
        cachedDisplayName = nil
        cachedProviderLabel = nil
        cachedIsSelected = false
        cachedIsHovered = false
        cachedIsHighlighted = false
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

        var selectedModelId: String?
        var onSelectModel: ((String) -> Void)?
        /// Called with -1 / +1 for left / right arrow tab switching. Set to
        /// nil while searching (tabs hidden) so arrows fall through to the
        /// search field.
        var onSwitchTab: ((Int) -> Void)?
        var onToggleFavorite: ((ModelPickerRow) -> Void)?
        var onDismiss: (() -> Void)?

        /// True while the Favourites tab is active: rows show an always-visible
        /// trash control instead of the hover-only heart.
        var isFavoritesTab = false

        private var hoveredRowId: String?
        private var highlightedIndex: Int?
        private var keyMonitor: Any?
        private var isScrolling = false

        // MARK: Cached Theme Colors & Images

        private var colors = ThemeColorCache(theme: LightTheme())
        private var lastThemeTypeId: ObjectIdentifier?

        // MARK: Cached Fonts

        private lazy var regularFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        private lazy var semiboldFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        private lazy var descFont = NSFont.systemFont(ofSize: 10)
        private lazy var badgeFont = NSFont.systemFont(ofSize: 9, weight: .medium)
        private lazy var badgeFontSmall = NSFont.systemFont(ofSize: 8, weight: .medium)

        private lazy var checkmarkImage: NSImage? = NSImage(
            systemSymbolName: "checkmark",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .bold))

        private lazy var eyeImage: NSImage? = NSImage(
            systemSymbolName: "eye",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 8, weight: .medium))

        private lazy var heartImage: NSImage? = NSImage(
            systemSymbolName: "heart",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))

        private lazy var heartFillImage: NSImage? = NSImage(
            systemSymbolName: "heart.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))

        private lazy var trashImage: NSImage? = NSImage(
            systemSymbolName: "trash",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))

        // MARK: Setup

        func setupDataSource(for tableView: NSTableView) {
            dataSource = NSTableViewDiffableDataSource<ModelPickerSection, String>(
                tableView: tableView
            ) { [weak self] tableView, _, _, itemId in
                self?.dequeueAndConfigure(tableView: tableView, rowId: itemId) ?? NSView()
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
            case 123:
                if let onSwitchTab { onSwitchTab(-1); return nil }
                return event
            case 124:
                if let onSwitchTab { onSwitchTab(1); return nil }
                return event
            case 36:
                if highlightedIndex != nil { selectHighlighted(); return nil }
                return event
            case 53: onDismiss?(); return nil
            default: return event
            }
        }

        private func moveHighlight(by offset: Int) {
            guard !rowIds.isEmpty else { return }
            let oldIndex = highlightedIndex
            if let current = oldIndex {
                highlightedIndex = max(0, min(rowIds.count - 1, current + offset))
            } else {
                highlightedIndex = offset > 0 ? 0 : rowIds.count - 1
            }
            if let old = oldIndex, old < rowIds.count {
                reconfigureCell(at: old)
            }
            if let new = highlightedIndex, new < rowIds.count {
                reconfigureCell(at: new)
                tableView?.scrollRowToVisible(new)
            }
        }

        private func selectHighlighted() {
            guard let index = highlightedIndex, index < rowIds.count,
                let row = rowLookup[rowIds[index]],
                row.isMLXFormat
            else { return }
            onSelectModel?(row.modelId)
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

        /// Switch the trailing control between hover-heart and always-on trash.
        /// Only repaints when the mode actually flips; `applyRows` covers the
        /// row-content refresh that normally accompanies a tab change.
        func updateFavoritesTab(_ newValue: Bool) {
            guard isFavoritesTab != newValue else { return }
            isFavoritesTab = newValue
            reconfigureVisibleCells()
        }

        // MARK: Apply Rows

        private var lastRowIdsHash: Int?

        func applyRows(_ rows: [ModelPickerRow]) {
            let newIds = rows.map(\.id)
            let newLookup = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

            // Order-sensitive hash so a pure reorder (e.g. price sort) is
            // detected. A commutative combine (summing hashValues) would treat
            // a reordered list as unchanged and skip the snapshot apply.
            var hasher = Hasher()
            for id in newIds { hasher.combine(id) }
            let newHash = hasher.finalize()

            if newHash == lastRowIdsHash && newIds.count == rowIds.count {
                // Same id sequence: only row contents (e.g. description) may
                // have changed. Refresh the lookup and reconfigure visible
                // cells without rebuilding the snapshot.
                rowLookup = newLookup
                reconfigureVisibleCells()
                return
            }

            lastRowIdsHash = newHash
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

            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ModelRowCellView {
                configureModelRow(cell, with: rowData)
            }
        }

        // MARK: Cell Factory

        private static let modelReuseId = NSUserInterfaceItemIdentifier("ModelRowCell")

        private func dequeueAndConfigure(tableView: NSTableView, rowId: String) -> NSView {
            guard let rowData = rowLookup[rowId] else { return NSView() }

            let cell =
                tableView.makeView(withIdentifier: Self.modelReuseId, owner: nil) as? ModelRowCellView
                ?? {
                    let c = ModelRowCellView(frame: .zero); c.identifier = Self.modelReuseId; return c
                }()
            configureModelRow(cell, with: rowData)
            return cell
        }

        private var highlightedRowId: String? {
            guard let idx = highlightedIndex, idx < rowIds.count else { return nil }
            return rowIds[idx]
        }

        private func configureModelRow(_ cell: ModelRowCellView, with row: ModelPickerRow) {
            let id = row.modelId
            // Non-MLX bundles are shown but dimmed and non-selectable: picking
            // one would just fail at load. Alpha + tooltip are always assigned
            // (both branches) so a reused cell never keeps a stale dim state.
            cell.alphaValue = row.isMLXFormat ? 1.0 : 0.45
            cell.toolTip =
                row.isMLXFormat
                ? nil
                : L("Not an MLX model — the local engine can't load this bundle")
            cell.configure(
                id: row.id,
                displayName: row.displayName,
                description: row.description,
                parameterCount: row.parameterCount,
                quantization: row.quantization,
                isVLM: row.isVLM,
                providerLabel: row.providerLabel,
                isSelected: selectedModelId == id,
                isHighlighted: highlightedRowId == row.id,
                isHovered: hoveredRowId == row.id,
                isFavorite: row.isFavorite,
                favoritesMode: isFavoritesTab,
                colors: colors,
                checkmarkImage: checkmarkImage,
                eyeImage: eyeImage,
                heartImage: heartImage,
                heartFillImage: heartFillImage,
                trashImage: trashImage,
                regularFont: regularFont,
                semiboldFont: semiboldFont,
                descFont: descFont,
                badgeFont: badgeFont,
                badgeFontSmall: badgeFontSmall,
                onSelect: { [weak self] in
                    guard row.isMLXFormat else { return }
                    self?.onSelectModel?(id)
                },
                onAccessory: { [weak self] in
                    self?.onToggleFavorite?(row)
                }
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
            guard row < rowIds.count, let rowData = rowLookup[rowIds[row]] else { return 36 }
            return Self.rowHeight(for: rowData)
        }

        /// Two consistent heights: a name-only row, or name + one metadata
        /// line (param/quant badges and description share that line).
        private static func rowHeight(for row: ModelPickerRow) -> CGFloat {
            let hasMeta =
                row.description?.isEmpty == false
                || row.parameterCount != nil
                || row.quantization != nil
            return hasMeta ? 56 : 36
        }
    }
}
