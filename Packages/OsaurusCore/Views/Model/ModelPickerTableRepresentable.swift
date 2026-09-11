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
//  - Pure AppKit cells for model/header rows (no NSHostingView) for 60fps
//    scroll performance. The single inline "Model Options" row under the
//    selected model is the one hosted SwiftUI cell, measured once per
//    options state and cached.
//  - Selection/highlight state separated from row data for O(visible) updates.
//  - Single NSTrackingArea for hover instead of per-row trackers.
//  - Keyboard: up/down highlight (skipping header/options rows), return
//    selects, left/right switch sidebar groups, ⌘D toggles favorite.
//  - Every model row shares one flipped two-line layout: a leading
//    checkmark gutter (NSMenu style, reserved on all rows), a name line
//    with badges and a trailing star, and an optional metadata line — so
//    selection never shifts content.
//

import AppKit
import SwiftUI

// MARK: - Supporting Types

enum ModelPickerSection: Hashable {
    case main
}

/// Flattened row model. Contains only structural data — visual state
/// (selection, highlight, hover) lives in the coordinator.
/// `providerLabel` is non-nil in unified search / Favorites, where results
/// from all providers are mixed together and need per-row attribution.
struct ModelPickerRow: Equatable, Identifiable {
    enum Kind: Equatable {
        /// A section caption (search results grouped by provider).
        case header(title: String)
        /// A selectable model.
        case model
        /// The inline Model Options expansion under the selected model.
        case options(forModelId: String)
    }

    let kind: Kind
    let modelId: String
    let sourceKey: String
    let displayName: String
    /// Second-line text: the structured metadata line (context · price) or
    /// the model's free-text description when nothing structured is known.
    let description: String?
    /// Long-form provider description, shown as the row tooltip.
    let tooltip: String?
    let parameterCount: String?
    let quantization: String?
    let isVLM: Bool
    /// Provider-published capability claims. Nil = no claim (no badge).
    let supportsTools: Bool?
    let supportsReasoning: Bool?
    let isDeprecated: Bool
    /// Non-nil when the row carries the Recommended badge; the value is the
    /// badge tooltip explaining the source of the recommendation.
    let recommendedReason: String?
    let mediaKind: MediaGenerationKind?
    /// False when the bundle is on disk but not in MLX format — the row is
    /// dimmed and made non-selectable so the user can't pick a model that
    /// would fail at load. Defaults to true (every selectable model).
    let isMLXFormat: Bool
    let providerLabel: String?
    /// Whether this model is currently bookmarked. Drives the row's star
    /// fill so favourited rows read as favourited everywhere, not only in
    /// the Favorites group.
    let isFavorite: Bool

    init(
        modelId: String,
        sourceKey: String,
        displayName: String,
        description: String?,
        parameterCount: String?,
        quantization: String?,
        isVLM: Bool,
        supportsTools: Bool? = nil,
        supportsReasoning: Bool? = nil,
        isDeprecated: Bool = false,
        recommendedReason: String? = nil,
        tooltip: String? = nil,
        mediaKind: MediaGenerationKind? = nil,
        isMLXFormat: Bool = true,
        providerLabel: String? = nil,
        isFavorite: Bool = false
    ) {
        self.kind = .model
        self.modelId = modelId
        self.sourceKey = sourceKey
        self.displayName = displayName
        self.description = description
        self.tooltip = tooltip
        self.parameterCount = parameterCount
        self.quantization = quantization
        self.isVLM = isVLM
        self.supportsTools = supportsTools
        self.supportsReasoning = supportsReasoning
        self.isDeprecated = isDeprecated
        self.recommendedReason = recommendedReason
        self.mediaKind = mediaKind
        self.isMLXFormat = isMLXFormat
        self.providerLabel = providerLabel
        self.isFavorite = isFavorite
    }

    private init(kind: Kind, modelId: String, sourceKey: String, displayName: String) {
        self.kind = kind
        self.modelId = modelId
        self.sourceKey = sourceKey
        self.displayName = displayName
        self.description = nil
        self.tooltip = nil
        self.parameterCount = nil
        self.quantization = nil
        self.isVLM = false
        self.supportsTools = nil
        self.supportsReasoning = nil
        self.isDeprecated = false
        self.recommendedReason = nil
        self.mediaKind = nil
        self.isMLXFormat = true
        self.providerLabel = nil
        self.isFavorite = false
    }

    /// A non-selectable section caption.
    static func header(title: String, key: String) -> ModelPickerRow {
        ModelPickerRow(kind: .header(title: title), modelId: "", sourceKey: key, displayName: title)
    }

    /// The inline options expansion for the model row directly above it.
    static func options(forModelId modelId: String, sourceKey: String) -> ModelPickerRow {
        ModelPickerRow(kind: .options(forModelId: modelId), modelId: modelId, sourceKey: sourceKey, displayName: "")
    }

    var id: String {
        switch kind {
        case .header: return "header-\(sourceKey)"
        case .model: return "model-\(sourceKey)-\(modelId)"
        case .options: return "options-\(sourceKey)-\(modelId)"
        }
    }

    var isModel: Bool {
        if case .model = kind { return true }
        return false
    }

    var isOptions: Bool {
        if case .options = kind { return true }
        return false
    }

    /// Whether ↑/↓ and Return may land on this row.
    var isNavigable: Bool { isModel && isMLXFormat }

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
    /// Continuous tint shared by the selected model row and its inline
    /// options row so the pair reads as one card.
    let selectedBg: NSColor
    let warningText: NSColor
    let warningBg: NSColor
    let starFill: NSColor

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
        selectedBg = accentColor.withAlphaComponent(theme.isDark ? 0.14 : 0.10)
        warningText = NSColor.systemOrange
        warningBg = NSColor.systemOrange.withAlphaComponent(0.14)
        starFill = NSColor.systemYellow
    }
}

// MARK: - ModelPickerTableRepresentable

struct ModelPickerTableRepresentable: NSViewRepresentable {

    let rows: [ModelPickerRow]
    let theme: ThemeProtocol
    var selectedModelId: String?
    /// True while the Favorites group is active: the star becomes an
    /// always-visible filled star (remove) instead of a hover-only star.
    var isFavoritesGroup: Bool = false
    /// Hosted SwiftUI content for the `.options` row, when one is present in
    /// `rows`. The view passes the same content for every options row id.
    var optionsContent: AnyView? = nil
    /// Cache key for the options row's measured height; must change whenever
    /// the rendered rows could change height.
    var optionsLayoutKey: String = ""
    /// Fallback height when live measurement is unavailable.
    var optionsEstimatedHeight: CGFloat = 0
    var onSelectModel: ((String) -> Void)?
    var onSwitchGroup: ((Int) -> Void)?
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
        coordinator.setupWidthObservation(for: tableView)
        coordinator.installKeyMonitor()

        coordinator.onSelectModel = onSelectModel
        coordinator.onSwitchGroup = onSwitchGroup
        coordinator.onToggleFavorite = onToggleFavorite
        coordinator.onDismiss = onDismiss
        coordinator.isFavoritesGroup = isFavoritesGroup
        coordinator.updateColorsIfNeeded(from: theme)
        coordinator.updateSelectedModelId(selectedModelId)
        coordinator.updateOptions(
            content: optionsContent,
            layoutKey: optionsLayoutKey,
            estimatedHeight: optionsEstimatedHeight
        )
        coordinator.applyRows(rows)
        applyScrollerStyle(to: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelectModel = onSelectModel
        coordinator.onSwitchGroup = onSwitchGroup
        coordinator.onToggleFavorite = onToggleFavorite
        coordinator.onDismiss = onDismiss
        coordinator.updateFavoritesGroup(isFavoritesGroup)
        coordinator.updateColorsIfNeeded(from: theme)
        coordinator.updateSelectedModelId(selectedModelId)
        coordinator.updateOptions(
            content: optionsContent,
            layoutKey: optionsLayoutKey,
            estimatedHeight: optionsEstimatedHeight
        )
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
        let needsUpdate =
            cachedText != text || cachedFont != font || cachedIsCapsule != isCapsule
            || (iconImage != nil) != !iconView.isHidden

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

    /// Icon-only, unfilled variant: a single tinted symbol in a fixed
    /// 16×16 slot with no background, used for per-row capability marks.
    func configureGlyph(image: NSImage?, tintColor: NSColor) {
        let needsUpdate = cachedText != "" || cachedIsCapsule != false
        if needsUpdate {
            label.stringValue = ""
            cachedText = ""
            cachedFont = nil
            cachedIsCapsule = false
        }
        iconView.image = image
        iconView.contentTintColor = tintColor
        iconView.isHidden = image == nil
        bgNSColor = .clear
        borderNSColor = .clear
        isCapsule = false
        hPad = 2
        vPad = 2
        frame.size = CGSize(width: 16, height: 16)
        layer?.backgroundColor = nil
        layer?.borderWidth = 0
    }

    func sizeToFitContent() {
        if text.isEmpty, !iconView.isHidden, bgNSColor == .clear {
            frame.size = CGSize(width: 16, height: 16)
            return
        }
        label.sizeToFit()
        var w = label.frame.width + hPad * 2
        if !iconView.isHidden { w += text.isEmpty ? 6 : 13 }
        frame.size = CGSize(width: ceil(w), height: ceil(max(label.frame.height, 12) + vPad * 2))
    }

    private var text: String { label.stringValue }

    override func layout() {
        super.layout()
        if text.isEmpty, !iconView.isHidden, bgNSColor == .clear {
            iconView.frame = bounds.insetBy(dx: 2, dy: 2)
            label.frame = .zero
            return
        }
        var x = hPad
        let contentH = bounds.height - vPad * 2

        if !iconView.isHidden {
            iconView.frame = CGRect(x: x, y: vPad, width: 10, height: contentH)
            x += text.isEmpty ? 6 : 13
        }
        label.frame = CGRect(x: x, y: vPad, width: max(0, bounds.width - x - hPad), height: contentH)
    }
}

/// The trailing favourite control shown on a row, if any. A hover-only star
/// in normal groups, an always-visible filled star (remove) in Favorites.
private enum RowAccessoryKind: Equatable {
    case none
    case star  // not yet favourited — outline, shown on hover
    case starFill  // favourited — filled, shown persistently
    case favoritesRemove  // Favorites group — filled star, removes, always shown
}

/// Everything a model row cell needs beyond the row data: theme colors,
/// cached images and fonts. Built once by the coordinator.
@MainActor
private struct RowRenderResources {
    let colors: ThemeColorCache
    let checkmarkImage: NSImage?
    let eyeImage: NSImage?
    let toolsImage: NSImage?
    let reasoningImage: NSImage?
    let imageMediaImage: NSImage?
    let textToVideoImage: NSImage?
    let imageToVideoImage: NSImage?
    let starImage: NSImage?
    let starFillImage: NSImage?
    let regularFont: NSFont
    let semiboldFont: NSFont
    let descFont: NSFont
    let badgeFont: NSFont
    let badgeFontSmall: NSFont
    let headerFont: NSFont
}

/// Model row cell with hover/selection background.
@MainActor
private final class ModelRowCellView: NSTableCellView, NSGestureRecognizerDelegate {
    private let bgLayer = CALayer()
    private let nameLabel = makeLabel()
    private let recommendedBadge = PickerBadgeView()
    private let deprecatedBadge = PickerBadgeView()
    private let vlmBadge = PickerBadgeView()
    private let toolsBadge = PickerBadgeView()
    private let reasoningBadge = PickerBadgeView()
    private let mediaBadge = PickerBadgeView()
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

    private var accessoryKind: RowAccessoryKind = .none

    // structural flags from the last configure, compared against incoming
    // values to skip relayout when nothing structural changed
    private var hasDesc = false
    private var hasBadges = false
    private var cachedRow: ModelPickerRow?

    // visual state from the last configure, compared to skip redundant
    // background/checkmark updates
    private var cachedIsSelected = false
    private var cachedIsHovered = false
    private var cachedIsHighlighted = false
    private var cachedJoinsBelow = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        bgLayer.cornerRadius = 8
        bgLayer.cornerCurve = .continuous
        layer?.addSublayer(bgLayer)

        for badge in allBadges { badge.isHidden = true }
        descLabel.isHidden = true
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
        for badge in allBadges { addSubview(badge) }
        addSubview(descLabel)
        addSubview(checkmarkView)
        addSubview(accessoryButton)
        let click = NSClickGestureRecognizer(target: self, action: #selector(didClick))
        click.delegate = self
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var allBadges: [PickerBadgeView] {
        [
            recommendedBadge, deprecatedBadge, vlmBadge, toolsBadge, reasoningBadge, mediaBadge,
            providerBadge, paramBadge, quantBadge,
        ]
    }

    @objc private func didClick() { onSelect?() }
    @objc private func didClickAccessory() { onAccessory?() }

    // The row select is an NSClickGestureRecognizer, which only real mouse
    // events drive — without an accessibility action, VoiceOver and AX
    // automation can open the picker but can never actually choose a model.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? {
        nameLabel.stringValue
    }
    override func accessibilityPerformPress() -> Bool {
        guard onSelect != nil else { return false }
        onSelect?()
        return true
    }

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
        row: ModelPickerRow,
        isSelected: Bool,
        isHighlighted: Bool,
        isHovered: Bool,
        favoritesMode: Bool,
        joinsOptionsBelow: Bool,
        resources: RowRenderResources,
        onSelect: @escaping () -> Void,
        onAccessory: @escaping () -> Void
    ) {
        let colors = resources.colors
        let isNewRow = rowId != row.id
        rowId = row.id
        self.onSelect = onSelect
        self.onAccessory = onAccessory

        let newHasDesc = row.description?.isEmpty == false
        let newHasBadges = row.parameterCount != nil || row.quantization != nil

        // only trigger full layout if structural content changed
        let structureChanged = isNewRow || cachedRow != row
        hasDesc = newHasDesc
        hasBadges = newHasBadges
        cachedRow = row

        if structureChanged || cachedIsSelected != isSelected {
            nameLabel.stringValue = row.displayName
            nameLabel.font = isSelected ? resources.semiboldFont : resources.regularFont
            nameLabel.textColor = isSelected ? colors.primaryText : colors.secondaryText
        }

        // Line 1, after the name: Recommended / Deprecated.
        if let reason = row.recommendedReason {
            if structureChanged {
                recommendedBadge.configure(
                    text: L("Recommended"),
                    font: resources.badgeFontSmall,
                    textColor: colors.accentColor,
                    bgColor: colors.accentAlpha012,
                    borderColor: colors.accentAlpha015,
                    isCapsule: true
                )
                recommendedBadge.toolTip = reason
            }
            recommendedBadge.isHidden = false
        } else {
            recommendedBadge.isHidden = true
        }

        if row.isDeprecated {
            if structureChanged {
                deprecatedBadge.configure(
                    text: L("Deprecated"),
                    font: resources.badgeFontSmall,
                    textColor: colors.warningText,
                    bgColor: colors.warningBg,
                    isCapsule: true
                )
                deprecatedBadge.toolTip = L("The provider has marked this model as deprecated")
            }
            deprecatedBadge.isHidden = false
        } else {
            deprecatedBadge.isHidden = true
        }

        // Line 1, trailing: capability glyphs (only positive provider
        // claims). Icon-only and unfilled — a labelled capsule per
        // capability on every row drowned the names in a 277-model group.
        // The tooltip carries the word; the header filters spell them out.
        if row.isVLM {
            if structureChanged {
                vlmBadge.configureGlyph(image: resources.eyeImage, tintColor: colors.tertiaryText)
                vlmBadge.toolTip = L("Vision — accepts images")
            }
            vlmBadge.isHidden = false
        } else {
            vlmBadge.isHidden = true
        }

        if row.supportsTools == true {
            if structureChanged {
                toolsBadge.configureGlyph(image: resources.toolsImage, tintColor: colors.tertiaryText)
                toolsBadge.toolTip = L("Tools — supports tool calling")
            }
            toolsBadge.isHidden = false
        } else {
            toolsBadge.isHidden = true
        }

        if row.supportsReasoning == true {
            if structureChanged {
                reasoningBadge.configureGlyph(image: resources.reasoningImage, tintColor: colors.tertiaryText)
                reasoningBadge.toolTip = L("Reasoning — exposes a reasoning channel")
            }
            reasoningBadge.isHidden = false
        } else {
            reasoningBadge.isHidden = true
        }

        if let mediaKind = row.mediaKind {
            let label: String
            let icon: NSImage?
            switch mediaKind {
            case .image:
                label = L("Image")
                icon = resources.imageMediaImage
            case .textToVideo:
                label = L("Text → Video")
                icon = resources.textToVideoImage
            case .imageToVideo:
                label = L("Image → Video")
                icon = resources.imageToVideoImage
            }
            if structureChanged {
                // Muted capsule: the kind matters for choosing, but an accent
                // pill on every media row shouted over the names.
                mediaBadge.configure(
                    text: label,
                    iconImage: icon,
                    font: resources.badgeFontSmall,
                    textColor: colors.secondaryTextAlpha09,
                    bgColor: colors.secondaryTextAlpha012,
                    isCapsule: true
                )
            }
            mediaBadge.isHidden = false
        } else {
            mediaBadge.isHidden = true
        }

        if let provider = row.providerLabel, !provider.isEmpty {
            if structureChanged {
                providerBadge.configure(
                    text: provider,
                    font: resources.badgeFont,
                    textColor: colors.secondaryTextAlpha09,
                    bgColor: colors.secondaryTextAlpha012,
                    isCapsule: true
                )
            }
            providerBadge.isHidden = false
        } else {
            providerBadge.isHidden = true
        }

        if let desc = row.description, !desc.isEmpty {
            if structureChanged {
                descLabel.stringValue = desc
                descLabel.font = resources.descFont
                descLabel.textColor = colors.tertiaryText
            }
            descLabel.isHidden = false
        } else {
            descLabel.isHidden = true
        }

        if let params = row.parameterCount {
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

        if let quant = row.quantization {
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
            if cachedIsSelected != isSelected || isNewRow {
                checkmarkView.image = resources.checkmarkImage
                checkmarkView.contentTintColor = colors.accentColor
            }
            checkmarkView.isHidden = false
        } else {
            checkmarkView.isHidden = true
        }

        // only update background if hover/selection state changed
        if cachedIsHovered != isHovered || cachedIsHighlighted != isHighlighted
            || cachedIsSelected != isSelected || cachedJoinsBelow != joinsOptionsBelow || isNewRow
        {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if isSelected {
                bgLayer.backgroundColor = colors.selectedBg.cgColor
            } else if isHovered || isHighlighted {
                bgLayer.backgroundColor = colors.hoverBg.cgColor
            } else {
                bgLayer.backgroundColor = nil
            }
            // When the options row follows, only round the top corners so the
            // two rows read as one continuous card.
            bgLayer.maskedCorners =
                joinsOptionsBelow
                ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            CATransaction.commit()
        }

        cachedIsSelected = isSelected
        cachedIsHovered = isHovered
        cachedIsHighlighted = isHighlighted
        if cachedJoinsBelow != joinsOptionsBelow {
            cachedJoinsBelow = joinsOptionsBelow
            needsLayout = true
        }

        // Trailing favourite control. In the Favorites group it's an
        // always-visible filled star (remove); elsewhere it's a star — shown
        // filled and persistent once favourited, and as an outline on hover so
        // an un-favourited row can be bookmarked. `RowAccessoryKind` is compared
        // against the last value so an unchanged hover/selection pass skips the
        // image swap and the relayout.
        let newAccessoryKind: RowAccessoryKind
        if favoritesMode {
            newAccessoryKind = .favoritesRemove
        } else if row.isFavorite {
            newAccessoryKind = .starFill
        } else if isHovered || isHighlighted {
            newAccessoryKind = .star
        } else {
            newAccessoryKind = .none
        }

        if newAccessoryKind != accessoryKind || isNewRow {
            switch newAccessoryKind {
            case .none:
                accessoryButton.isHidden = true
            case .star:
                accessoryButton.image = resources.starImage
                accessoryButton.contentTintColor = colors.tertiaryText
                accessoryButton.isHidden = false
            case .starFill, .favoritesRemove:
                accessoryButton.image = resources.starFillImage
                accessoryButton.contentTintColor = colors.starFill
                accessoryButton.isHidden = false
            }
            accessoryButton.toolTip =
                newAccessoryKind == .star
                ? L("Add to favorites (⌘D)")
                : L("Remove from favorites (⌘D)")
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
        let starSlot: CGFloat = 18

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The card inset leaves a hairline gap between rows; when joined to
        // the options row below, extend to the bottom edge so there is no seam.
        bgLayer.frame =
            cachedJoinsBelow
            ? CGRect(x: 2, y: 1, width: w - 4, height: h - 1)
            : bounds.insetBy(dx: 2, dy: 1)
        CATransaction.commit()

        // Every row uses the same two-line structure:
        //   gutter: leading checkmark column reserved on ALL rows (NSMenu
        //           style) so selection never shifts the content
        //   line 1: name (+ Recommended/Deprecated) … capability badges,
        //           provider badge, star slot
        //   line 2 (optional): param/quant badges + metadata text
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

        // Star slot is always reserved at the trailing edge so badges never
        // shift when the star appears on hover.
        var trailingX = w - pad
        if accessoryKind != .none {
            let imgSize = accessoryButton.image?.size ?? CGSize(width: 14, height: 14)
            accessoryButton.frame = CGRect(
                x: trailingX - starSlot + (starSlot - imgSize.width) / 2,
                y: nameY + (nameH - imgSize.height) / 2,
                width: imgSize.width,
                height: imgSize.height
            )
        }
        trailingX -= starSlot + 6

        if !providerBadge.isHidden {
            providerBadge.sizeToFitContent()
            trailingX -= providerBadge.frame.width
            providerBadge.frame.origin = CGPoint(
                x: trailingX,
                y: nameY + (nameH - providerBadge.frame.height) / 2
            )
            trailingX -= 8
        }
        var badgeX = trailingX
        for badge in [mediaBadge, reasoningBadge, toolsBadge, vlmBadge] where !badge.isHidden {
            badge.sizeToFitContent()
            badgeX -= badge.frame.width
            badge.frame.origin = CGPoint(
                x: badgeX,
                y: nameY + (nameH - badge.frame.height) / 2
            )
            badgeX -= badge === mediaBadge ? 6 : 2
        }

        // Name, then Recommended / Deprecated right after the name text,
        // clamped so they never run into the trailing badges.
        let nameAvailable = max(0, badgeX - contentX)
        var inlineBadgesWidth: CGFloat = 0
        for badge in [recommendedBadge, deprecatedBadge] where !badge.isHidden {
            badge.sizeToFitContent()
            inlineBadgesWidth += badge.frame.width + 6
        }
        // Measure the name's natural width against unbounded bounds: a
        // truncating single-line NSTextField reports an `intrinsicContentSize`
        // clamped to whatever frame it last had, so a reused cell that was
        // narrow once would keep truncating names that fit.
        let nameNatural =
            nameLabel.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: 100_000, height: nameH)).width
            ?? nameLabel.intrinsicContentSize.width
        let nameW = min(ceil(nameNatural), max(0, nameAvailable - inlineBadgesWidth))
        nameLabel.frame = CGRect(x: contentX, y: nameY, width: nameW, height: nameH)
        var inlineX = contentX + nameW + 6
        for badge in [recommendedBadge, deprecatedBadge] where !badge.isHidden {
            badge.frame.origin = CGPoint(
                x: min(inlineX, badgeX - badge.frame.width),
                y: nameY + (nameH - badge.frame.height) / 2
            )
            inlineX += badge.frame.width + 6
        }

        if hasMeta {
            let metaY = nameY + nameH + 3
            var x = contentX
            for badge in [paramBadge, quantBadge] where !badge.isHidden {
                badge.sizeToFitContent()
                badge.frame.origin = CGPoint(x: x, y: metaY + (metaH - badge.frame.height) / 2)
                x += badge.frame.width + 4
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
        for badge in allBadges { badge.isHidden = true }
        checkmarkView.isHidden = true
        accessoryButton.isHidden = true
        accessoryKind = .none
        hasDesc = false
        hasBadges = false
        cachedRow = nil
        cachedIsSelected = false
        cachedIsHovered = false
        cachedIsHighlighted = false
        cachedJoinsBelow = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bgLayer.backgroundColor = nil
        CATransaction.commit()
    }
}

/// Non-interactive section caption used to attribute search results to
/// their provider group.
@MainActor
private final class HeaderRowCellView: NSTableCellView {
    private let titleLabel = makeLabel()
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(titleLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { titleLabel.stringValue }

    func configure(title: String, resources: RowRenderResources) {
        titleLabel.stringValue = title.uppercased()
        titleLabel.font = resources.headerFont
        titleLabel.textColor = resources.colors.tertiaryText
        needsLayout = true
    }

    override func layout() {
        super.layout()
        titleLabel.frame = CGRect(x: 14, y: bounds.height - 18, width: bounds.width - 28, height: 14)
    }
}

/// The single hosted SwiftUI cell: the selected model's option rows,
/// drawn on the same tint as the model row above so they read as one card.
@MainActor
private final class OptionsRowCellView: NSTableCellView {
    private let bgLayer = CALayer()
    private var hostingView: NSHostingView<AnyView>?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        bgLayer.cornerRadius = 8
        bgLayer.cornerCurve = .continuous
        bgLayer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer?.addSublayer(bgLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(content: AnyView, colors: ThemeColorCache) {
        if let hostingView {
            hostingView.rootView = content
        } else {
            let host = NSHostingView(rootView: content)
            host.translatesAutoresizingMaskIntoConstraints = true
            addSubview(host)
            hostingView = host
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bgLayer.backgroundColor = colors.selectedBg.cgColor
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bgLayer.frame = CGRect(x: 2, y: 0, width: bounds.width - 4, height: bounds.height - 1)
        CATransaction.commit()
        hostingView?.frame = CGRect(x: 2, y: 0, width: bounds.width - 4, height: bounds.height - 1)
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
        /// Called with -1 / +1 for left / right arrow group switching. Set to
        /// nil while searching so arrows fall through to the search field.
        var onSwitchGroup: ((Int) -> Void)?
        var onToggleFavorite: ((ModelPickerRow) -> Void)?
        var onDismiss: (() -> Void)?

        /// True while the Favorites group is active: rows show an
        /// always-visible filled-star remove control instead of the
        /// hover-only star.
        var isFavoritesGroup = false

        private var hoveredRowId: String?
        private var highlightedIndex: Int?
        private var keyMonitor: Any?
        private var isScrolling = false
        /// Scroll the selected model into view once, on the first non-empty
        /// snapshot, so a long list opens on the current selection.
        private var hasScrolledToSelection = false
        /// Model whose options row was last scrolled into view, so a
        /// same-selection rows refresh (option edit, favorite toggle) does
        /// not re-scroll under the pointer.
        private var revealedOptionsForModelId: String?

        // MARK: Options row

        private var optionsContent: AnyView?
        private var optionsLayoutKey = ""
        private var optionsEstimatedHeight: CGFloat = 0
        private var measuredOptionsHeight: CGFloat?
        private var measuredOptionsKey: String?
        private var measuredOptionsWidth: CGFloat = 0
        private lazy var measuringHost = NSHostingView(rootView: AnyView(EmptyView()))

        // MARK: Cached Theme Colors & Images

        private var colors = ThemeColorCache(theme: LightTheme())
        private var lastThemeTypeId: ObjectIdentifier?
        private var resources: RowRenderResources?

        private func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: weight))
        }

        private func makeResources() -> RowRenderResources {
            RowRenderResources(
                colors: colors,
                checkmarkImage: symbol("checkmark", size: 11, weight: .bold),
                eyeImage: symbol("eye", size: 10, weight: .medium),
                toolsImage: symbol("wrench.and.screwdriver", size: 10, weight: .medium),
                reasoningImage: symbol("brain", size: 10, weight: .medium),
                imageMediaImage: symbol("photo", size: 8, weight: .medium),
                textToVideoImage: symbol("film", size: 8, weight: .medium),
                imageToVideoImage: symbol("photo.on.rectangle", size: 8, weight: .medium),
                starImage: symbol("star", size: 11, weight: .medium),
                starFillImage: symbol("star.fill", size: 11, weight: .medium),
                regularFont: .systemFont(ofSize: 12, weight: .medium),
                semiboldFont: .systemFont(ofSize: 12, weight: .semibold),
                descFont: .systemFont(ofSize: 10),
                badgeFont: .systemFont(ofSize: 9, weight: .medium),
                badgeFontSmall: .systemFont(ofSize: 8, weight: .medium),
                headerFont: .systemFont(ofSize: 10, weight: .semibold)
            )
        }

        private var renderResources: RowRenderResources {
            if let resources { return resources }
            let built = makeResources()
            resources = built
            return built
        }

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

        /// The options row is measured at the table's width, but the first
        /// `heightOfRow` pass runs before the popover has laid the table out
        /// (narrow or zero width), so the hosted content wraps and the row
        /// keeps that inflated height. Re-ask for the height whenever the
        /// table's width changes from the width the row was measured at.
        func setupWidthObservation(for tableView: NSTableView) {
            tableView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(onTableFrameChanged),
                name: NSView.frameDidChangeNotification,
                object: tableView
            )
        }

        @objc private func onTableFrameChanged() {
            guard let tableView, optionsContent != nil else { return }
            let width = tableView.bounds.width - 4
            guard width > 40, width != measuredOptionsWidth else { return }
            guard let optionsIndex = rowIds.firstIndex(where: { rowLookup[$0]?.isOptions == true }) else { return }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: optionsIndex))
            NSAnimationContext.endGrouping()
        }

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
            // A table that is no longer on screen (popover closed, view
            // swapped for the empty state) must not act on keystrokes.
            guard let tableView, tableView.window != nil else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.command) {
                // ⌘D toggles the favourite on the highlighted row, or on the
                // selected model's row when nothing is highlighted.
                if event.keyCode == 2 {
                    toggleFavoriteForKeyboardTarget()
                    return nil
                }
                return event
            }
            switch event.keyCode {
            case 125: moveHighlight(by: 1); return nil
            case 126: moveHighlight(by: -1); return nil
            case 123:
                if let onSwitchGroup { onSwitchGroup(-1); return nil }
                return event
            case 124:
                if let onSwitchGroup { onSwitchGroup(1); return nil }
                return event
            case 36:
                if highlightedIndex != nil { selectHighlighted(); return nil }
                return event
            case 53: onDismiss?(); return nil
            default:
                refocusSearchFieldForTyping(event, modifiers: modifiers)
                return event
            }
        }

        /// Type-to-search recovery: clicking a hosted control (the options
        /// row's switch, a header button) moves first responder off the search
        /// field, and printable keys would then be dropped. Hand focus back to
        /// the picker's search field before the event is dispatched so the
        /// keystroke lands there; the event itself is left alone (the popover
        /// routes it to the new first responder), so nothing is inserted twice.
        private func refocusSearchFieldForTyping(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) {
            guard !modifiers.contains(.control),
                let window = tableView?.window, window.isVisible,
                let eventWindow = event.window,
                eventWindow === window || eventWindow === window.parent,
                let chars = event.characters, !chars.isEmpty,
                chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                let root = window.contentView, let field = Self.findSearchField(in: root),
                window.firstResponder !== field
            else { return }
            if !window.isKeyWindow { window.makeKey() }
            window.makeFirstResponder(field)
        }

        private static func findSearchField(in view: NSView) -> IMETrackingTextView? {
            if let field = view as? IMETrackingTextView { return field }
            for subview in view.subviews {
                if let found = findSearchField(in: subview) { return found }
            }
            return nil
        }

        private func toggleFavoriteForKeyboardTarget() {
            if let index = highlightedIndex, index < rowIds.count, let row = rowLookup[rowIds[index]],
                row.isModel
            {
                onToggleFavorite?(row)
                return
            }
            if let selectedModelId,
                let row = rowIds.lazy.compactMap({ self.rowLookup[$0] })
                    .first(where: { $0.isModel && $0.modelId == selectedModelId })
            {
                onToggleFavorite?(row)
            }
        }

        /// Move the keyboard highlight to the next navigable (model) row in
        /// `offset` direction, skipping headers and the options row.
        private func moveHighlight(by offset: Int) {
            guard !rowIds.isEmpty else { return }
            let oldIndex = highlightedIndex
            var candidate: Int
            if let current = oldIndex {
                candidate = current + offset
            } else {
                candidate = offset > 0 ? 0 : rowIds.count - 1
            }
            while candidate >= 0, candidate < rowIds.count,
                rowLookup[rowIds[candidate]]?.isNavigable != true
            {
                candidate += offset
            }
            guard candidate >= 0, candidate < rowIds.count else { return }
            highlightedIndex = candidate
            if let old = oldIndex, old < rowIds.count {
                reconfigureCell(at: old)
            }
            reconfigureCell(at: candidate)
            tableView?.scrollRowToVisible(candidate)
        }

        private func selectHighlighted() {
            guard let index = highlightedIndex, index < rowIds.count,
                let row = rowLookup[rowIds[index]],
                row.isNavigable
            else { return }
            onSelectModel?(row.modelId)
        }

        // MARK: Theme

        func updateColorsIfNeeded(from theme: ThemeProtocol) {
            let typeId = ObjectIdentifier(type(of: theme))
            guard typeId != lastThemeTypeId else { return }
            lastThemeTypeId = typeId
            colors = ThemeColorCache(theme: theme)
            resources = nil
        }

        // MARK: Selection

        func updateSelectedModelId(_ newId: String?) {
            guard selectedModelId != newId else { return }
            selectedModelId = newId
            reconfigureVisibleCells()
        }

        /// Switch the trailing control between hover-star and always-on remove star.
        /// Only repaints when the mode actually flips; `applyRows` covers the
        /// row-content refresh that normally accompanies a group change.
        func updateFavoritesGroup(_ newValue: Bool) {
            guard isFavoritesGroup != newValue else { return }
            isFavoritesGroup = newValue
            reconfigureVisibleCells()
        }

        // MARK: Options

        func updateOptions(content: AnyView?, layoutKey: String, estimatedHeight: CGFloat) {
            optionsContent = content
            optionsEstimatedHeight = estimatedHeight
            let keyChanged = optionsLayoutKey != layoutKey
            optionsLayoutKey = layoutKey
            guard let tableView else { return }
            // Re-render the hosted content in place (option edits keep the
            // popover open, so the cell must pick up new values), and re-measure
            // when anything height-relevant changed.
            if let optionsIndex = rowIds.firstIndex(where: { rowLookup[$0]?.isOptions == true }) {
                if keyChanged {
                    measuredOptionsKey = nil
                    tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: optionsIndex))
                }
                if let cell = tableView.view(atColumn: 0, row: optionsIndex, makeIfNecessary: false)
                    as? OptionsRowCellView, let content
                {
                    cell.configure(content: content, colors: colors)
                }
            }
        }

        /// Height for the options row: live-measured hosted content at the
        /// table's current width, cached per layout key; the view's estimate
        /// when the table has no width yet.
        private func optionsRowHeight() -> CGFloat {
            guard let content = optionsContent else { return optionsEstimatedHeight }
            let width = (tableView?.bounds.width ?? 0) - 4
            guard width > 40 else { return optionsEstimatedHeight }
            if let measured = measuredOptionsHeight, measuredOptionsKey == optionsLayoutKey,
                measuredOptionsWidth == width
            {
                return measured
            }
            measuringHost.rootView = AnyView(content.frame(width: width, alignment: .leading))
            let fitted = measuringHost.fittingSize.height
            let height = fitted.isFinite && fitted > 8 ? ceil(fitted) + 1 : optionsEstimatedHeight
            measuredOptionsHeight = height
            measuredOptionsKey = optionsLayoutKey
            measuredOptionsWidth = width
            return height
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
            // Keep the keyboard highlight on the same row across a rebuild
            // (e.g. the options row moving under a newly selected model) so
            // ↑/↓ continue from where the user was; a group switch drops it.
            let previousHighlightId = highlightedIndex.flatMap { $0 < rowIds.count ? rowIds[$0] : nil }
            var seen = Set<String>()
            rowIds = newIds.filter { seen.insert($0).inserted }
            rebuildIndexMaps()
            highlightedIndex = previousHighlightId.flatMap { rowIdToIndex[$0] }

            var snapshot = NSDiffableDataSourceSnapshot<ModelPickerSection, String>()
            snapshot.appendSections([.main])
            snapshot.appendItems(rowIds, toSection: .main)
            dataSource?.apply(snapshot, animatingDifferences: false)

            let selectedIndex = selectedModelId.flatMap { selected in
                rowIds.firstIndex(where: {
                    guard let row = rowLookup[$0] else { return false }
                    return row.isModel && row.modelId == selected
                })
            }
            if !hasScrolledToSelection, let index = selectedIndex {
                hasScrolledToSelection = true
                revealedOptionsForModelId = selectedModelId
                // Show the selected row with a little context above it.
                tableView?.scrollRowToVisible(max(0, index - 1))
                tableView?.scrollRowToVisible(index)
            } else if let index = selectedIndex, revealedOptionsForModelId != selectedModelId,
                index + 1 < rowIds.count, rowLookup[rowIds[index + 1]]?.isOptions == true
            {
                // A model with options was just picked while the popover
                // stayed open: bring its freshly expanded options row into
                // view (the row is below the click, so it may be off-screen).
                revealedOptionsForModelId = selectedModelId
                tableView?.scrollRowToVisible(index + 1)
                tableView?.scrollRowToVisible(index)
            }
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

            let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
            switch rowData.kind {
            case .model:
                if let cell = view as? ModelRowCellView {
                    configureModelRow(cell, with: rowData, at: row)
                }
            case .header(let title):
                if let cell = view as? HeaderRowCellView {
                    cell.configure(title: title, resources: renderResources)
                }
            case .options:
                if let cell = view as? OptionsRowCellView, let optionsContent {
                    cell.configure(content: optionsContent, colors: colors)
                }
            }
        }

        // MARK: Cell Factory

        private static let modelReuseId = NSUserInterfaceItemIdentifier("ModelRowCell")
        private static let headerReuseId = NSUserInterfaceItemIdentifier("HeaderRowCell")
        private static let optionsReuseId = NSUserInterfaceItemIdentifier("OptionsRowCell")

        private func dequeueAndConfigure(tableView: NSTableView, rowId: String) -> NSView {
            guard let rowData = rowLookup[rowId] else { return NSView() }
            let index = rowIdToIndex[rowId] ?? 0

            switch rowData.kind {
            case .model:
                let cell =
                    tableView.makeView(withIdentifier: Self.modelReuseId, owner: nil) as? ModelRowCellView
                    ?? {
                        let c = ModelRowCellView(frame: .zero); c.identifier = Self.modelReuseId; return c
                    }()
                configureModelRow(cell, with: rowData, at: index)
                return cell
            case .header(let title):
                let cell =
                    tableView.makeView(withIdentifier: Self.headerReuseId, owner: nil) as? HeaderRowCellView
                    ?? {
                        let c = HeaderRowCellView(frame: .zero); c.identifier = Self.headerReuseId; return c
                    }()
                cell.configure(title: title, resources: renderResources)
                return cell
            case .options:
                let cell =
                    tableView.makeView(withIdentifier: Self.optionsReuseId, owner: nil) as? OptionsRowCellView
                    ?? {
                        let c = OptionsRowCellView(frame: .zero); c.identifier = Self.optionsReuseId; return c
                    }()
                if let optionsContent {
                    cell.configure(content: optionsContent, colors: colors)
                }
                return cell
            }
        }

        private var highlightedRowId: String? {
            guard let idx = highlightedIndex, idx < rowIds.count else { return nil }
            return rowIds[idx]
        }

        private func configureModelRow(_ cell: ModelRowCellView, with row: ModelPickerRow, at index: Int) {
            let id = row.modelId
            // Non-MLX bundles are shown but dimmed and non-selectable: picking
            // one would just fail at load. Alpha + tooltip are always assigned
            // (both branches) so a reused cell never keeps a stale dim state.
            cell.alphaValue = row.isMLXFormat ? 1.0 : 0.45
            cell.toolTip =
                !row.isMLXFormat
                ? L("Not an MLX model — the local engine can't load this bundle")
                : (row.mediaKind == nil ? row.tooltip : row.description)
            let isSelected = selectedModelId == id
            let nextIsOptions =
                isSelected && index + 1 < rowIds.count
                && (rowLookup[rowIds[index + 1]]?.isOptions ?? false)
            cell.configure(
                row: row,
                isSelected: isSelected,
                isHighlighted: highlightedRowId == row.id,
                isHovered: hoveredRowId == row.id,
                favoritesMode: isFavoritesGroup,
                joinsOptionsBelow: nextIsOptions,
                resources: renderResources,
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
            guard row >= 0, row < rowIds.count, rowLookup[rowIds[row]]?.isModel == true else {
                return setHoveredRow(nil)
            }
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
            switch rowData.kind {
            case .header: return Self.headerRowHeight
            case .options: return optionsRowHeight()
            case .model: return Self.rowHeight(for: rowData)
            }
        }

        static let headerRowHeight: CGFloat = 26

        /// Two consistent heights: a name-only row, or name + one metadata
        /// line (param/quant badges and description share that line).
        static func rowHeight(for row: ModelPickerRow) -> CGFloat {
            let hasMeta =
                row.description?.isEmpty == false
                || row.parameterCount != nil
                || row.quantization != nil
            return hasMeta ? 54 : 36
        }
    }
}
