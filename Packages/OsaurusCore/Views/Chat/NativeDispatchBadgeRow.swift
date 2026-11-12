//
//  NativeDispatchBadgeRow.swift
//  osaurus
//
//  Pure AppKit provenance row rendered above a user bubble whose content is a
//  machine-generated dispatch envelope (channel message, delegated task,
//  self-scheduled run, watcher run). One small chip per `DispatchEnvelope.Badge`
//  — icon + label, details in the tooltip — so the message text below stays
//  the visual focus while the reader still learns where it came from.
//
//  Layout is a right-aligned horizontal stack (matching the bubble and the
//  attachment chips). At most `maxVisibleBadges` chips are shown, warnings
//  and errors first; the rest fold into a "+N" chip whose tooltip lists them. Chip views are reused
//  across reconfigures and the row is only rebuilt by the cell when the
//  envelope signature changes, so hover reconfigures never touch it.
//

import AppKit

final class NativeDispatchBadgeRow: NSView {

    static let rowHeight: CGFloat = 22
    static let maxVisibleBadges = 4
    static func height(for theme: any ThemeProtocol) -> CGFloat {
        return max(rowHeight, theme.assignedLineHeight("component.library.28.caption", fallback: 16) + 6)
    }

    private let stack = NSStackView()
    private var lastSignature: String?
    private var rowHeightConstraint: NSLayoutConstraint!

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.distribution = .gravityAreas
        addSubview(stack)
        rowHeightConstraint = heightAnchor.constraint(equalToConstant: Self.rowHeight)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowHeightConstraint,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Stable identity of a badge set, so the cell can skip a reconfigure
    /// when only unrelated state (hover, width) changed.
    static func signature(for badges: [DispatchEnvelope.Badge]) -> String {
        badges.map { "\($0.symbol)|\($0.label)|\($0.tone)" }.joined(separator: "\u{1F}")
    }

    /// The chips shown when the row clips: errors and warnings first, then
    /// the leading provenance chip (the author or the channel), then the
    /// rest in order; everything else folds into "+N". Kept chips stay in
    /// display order.
    static func visibleBadges(_ badges: [DispatchEnvelope.Badge]) -> [DispatchEnvelope.Badge] {
        guard badges.count > maxVisibleBadges else { return badges }
        func rank(_ index: Int) -> Int {
            switch badges[index].tone {
            case .error: return 0
            case .warning: return 1
            case .neutral: return index == 0 ? 2 : 3
            }
        }
        let kept = Set(
            badges.indices.sorted { (rank($0), $0) < (rank($1), $1) }.prefix(maxVisibleBadges - 1))
        let shown = badges.indices.filter(kept.contains).map { badges[$0] }
        let folded = badges.indices.filter { !kept.contains($0) }.map { badges[$0] }
        return shown + [
            DispatchEnvelope.Badge(
                symbol: "ellipsis",
                label: "+\(folded.count)",
                tooltip: folded.map(\.label).joined(separator: "\n"),
                tone: folded.contains { $0.tone == .error }
                    ? .error : (folded.contains { $0.tone == .warning } ? .warning : .neutral)
            )
        ]
    }

    func configure(badges: [DispatchEnvelope.Badge], theme: any ThemeProtocol, availableWidth: CGFloat? = nil) {
        rowHeightConstraint.constant = Self.height(for: theme)
        let signature = Self.signature(for: badges)
        let sameBadges = signature == lastSignature
        lastSignature = signature

        let visible = Self.visibleBadges(badges)

        // Match the chip count to the badge count, reusing existing views.
        while stack.arrangedSubviews.count < visible.count {
            let chip = DispatchBadgeChipView()
            stack.addArrangedSubview(chip)
        }
        while stack.arrangedSubviews.count > visible.count {
            let last = stack.arrangedSubviews.last!
            stack.removeArrangedSubview(last)
            last.removeFromSuperview()
        }

        // Preserve the original count, middle truncation and full tooltips,
        // while keeping larger labels inside the owning message's width.
        let widths = visible.map { min(CGFloat(160), ($0.label as NSString).size(withAttributes: [.font: theme.assignedNativeFont("component.library.28.caption", fallback: theme.nsFont(.footnote))]).width) }
        let total = widths.reduce(0, +)
        let budget = max(0, (availableWidth ?? bounds.width) - CGFloat(visible.count) * 32 - CGFloat(max(0, visible.count - 1)) * 6)
        let factor = total > 0 ? min(1, budget / total) : 1
        // Theme colors can change without the badges changing (theme switch),
        // so always push the palette; only the text/icon work is skipped.
        for (index, badge) in visible.enumerated() {
            guard let chip = stack.arrangedSubviews[index] as? DispatchBadgeChipView else { continue }
            chip.setMaximumLabelWidth(widths[index] * factor)
            chip.configure(badge: badge, theme: theme, contentUnchanged: sameBadges)
        }
    }
}

// MARK: - Chip

/// One pill: 12pt SF Symbol + 11pt medium label. Mirrors the user document
/// chip's metrics so the row reads as part of the same family.
private final class DispatchBadgeChipView: NSView {
    override var isFlipped: Bool { true }

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var chipHeightConstraint: NSLayoutConstraint!
    private var currentHeight: CGFloat = NativeDispatchBadgeRow.rowHeight
    private var maxLabelWidth: CGFloat = 160
    private var labelWidthConstraint: NSLayoutConstraint!
    private static let iconSize: CGFloat = 12
    private static let horizontalPadding: CGFloat = 8
    private static let iconGap: CGFloat = 4

    override var intrinsicContentSize: NSSize {
        let labelW = min(label.intrinsicContentSize.width, maxLabelWidth)
        let w = Self.horizontalPadding + Self.iconSize + Self.iconGap + labelW + Self.horizontalPadding
        return NSSize(width: ceil(w), height: currentHeight)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = NativeDispatchBadgeRow.rowHeight / 2
        layer?.masksToBounds = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.font = ThemeManager.shared.chatTheme.nsFont(.footnote, weight: .medium)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        chipHeightConstraint = heightAnchor.constraint(equalToConstant: NativeDispatchBadgeRow.rowHeight)
        labelWidthConstraint = label.widthAnchor.constraint(lessThanOrEqualToConstant: maxLabelWidth)
        NSLayoutConstraint.activate([
            chipHeightConstraint,
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Self.iconGap),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            labelWidthConstraint,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setMaximumLabelWidth(_ width: CGFloat) {
        maxLabelWidth = max(0, width)
        labelWidthConstraint.constant = maxLabelWidth
        invalidateIntrinsicContentSize()
    }

    func configure(badge: DispatchEnvelope.Badge, theme: any ThemeProtocol, contentUnchanged: Bool) {
        currentHeight = NativeDispatchBadgeRow.height(for: theme)
        chipHeightConstraint.constant = currentHeight
        layer?.cornerRadius = currentHeight / 2
        let tint: NSColor
        let fill: NSColor
        let border: NSColor
        switch badge.tone {
        case .neutral:
            tint = NSColor(theme.text.secondary)
            fill = NSColor(theme.surface.hover)
            border = NSColor(theme.border.subtle)
        case .warning:
            tint = NSColor(theme.status.warning.foreground)
            fill = NSColor(theme.status.warning.background)
            border = NSColor(theme.status.warning.border)
        case .error:
            tint = NSColor(theme.status.error.foreground)
            fill = NSColor(theme.status.error.background)
            border = NSColor(theme.status.error.border)
        }
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = border.cgColor
        layer?.borderWidth = theme.stroke.default
        label.textColor = tint
        iconView.contentTintColor = tint
        label.font = theme.nsFont(.footnote, weight: .medium)
        if !contentUnchanged || label.stringValue != badge.label { label.stringValue = badge.label }
        NativeComponentInspectionStyle.label(label, family: 28, property: "caption", theme: theme)
        invalidateIntrinsicContentSize()

        guard !contentUnchanged || label.stringValue != badge.label else { return }
        iconView.image = SymbolImageCache.image(
            badge.symbol,
            accessibilityDescription: badge.label,
            pointSize: Self.iconSize,
            weight: .medium
        )
        toolTip = badge.tooltip
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(badge.tooltip.map { "\(badge.label). \($0)" } ?? badge.label)
        invalidateIntrinsicContentSize()
    }
}
