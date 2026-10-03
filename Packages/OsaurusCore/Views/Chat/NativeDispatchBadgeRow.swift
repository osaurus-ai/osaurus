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
//  attachment chips). At most `maxVisibleBadges` chips are shown; the rest
//  fold into a "+N" chip whose tooltip lists them. Chip views are reused
//  across reconfigures and the row is only rebuilt by the cell when the
//  envelope signature changes, so hover reconfigures never touch it.
//

import AppKit

final class NativeDispatchBadgeRow: NSView {

    static let rowHeight: CGFloat = 22
    static let maxVisibleBadges = 4

    private let stack = NSStackView()
    private var lastSignature: String?

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
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.rowHeight),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Stable identity of a badge set, so the cell can skip a reconfigure
    /// when only unrelated state (hover, width) changed.
    static func signature(for badges: [DispatchEnvelope.Badge]) -> String {
        badges.map { "\($0.symbol)|\($0.label)|\($0.tone)" }.joined(separator: "\u{1F}")
    }

    func configure(badges: [DispatchEnvelope.Badge], theme: any ThemeProtocol) {
        let signature = Self.signature(for: badges)
        let sameBadges = signature == lastSignature
        lastSignature = signature

        let visible: [DispatchEnvelope.Badge]
        if badges.count > Self.maxVisibleBadges {
            let shown = Array(badges.prefix(Self.maxVisibleBadges - 1))
            let folded = Array(badges.dropFirst(Self.maxVisibleBadges - 1))
            visible =
                shown + [
                    DispatchEnvelope.Badge(
                        symbol: "ellipsis",
                        label: "+\(folded.count)",
                        tooltip: folded.map(\.label).joined(separator: "\n"),
                        tone: folded.contains { $0.tone == .error }
                            ? .error : (folded.contains { $0.tone == .warning } ? .warning : .neutral)
                    )
                ]
        } else {
            visible = badges
        }

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

        // Theme colors can change without the badges changing (theme switch),
        // so always push the palette; only the text/icon work is skipped.
        for (index, badge) in visible.enumerated() {
            guard let chip = stack.arrangedSubviews[index] as? DispatchBadgeChipView else { continue }
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
    private static let maxLabelWidth: CGFloat = 160
    private static let iconSize: CGFloat = 12
    private static let horizontalPadding: CGFloat = 8
    private static let iconGap: CGFloat = 4

    override var intrinsicContentSize: NSSize {
        let labelW = min(label.intrinsicContentSize.width, Self.maxLabelWidth)
        let w = Self.horizontalPadding + Self.iconSize + Self.iconGap + labelW + Self.horizontalPadding
        return NSSize(width: ceil(w), height: NativeDispatchBadgeRow.rowHeight)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = NativeDispatchBadgeRow.rowHeight / 2
        layer?.borderWidth = 1
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
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: NativeDispatchBadgeRow.rowHeight),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Self.iconGap),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxLabelWidth),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(badge: DispatchEnvelope.Badge, theme: any ThemeProtocol, contentUnchanged: Bool) {
        let tint: NSColor
        let fill: NSColor
        let border: NSColor
        switch badge.tone {
        case .neutral:
            tint = NSColor(theme.secondaryText)
            fill = NSColor(theme.tertiaryBackground).withAlphaComponent(0.6)
            border = NSColor(theme.primaryBorder).withAlphaComponent(0.5)
        case .warning:
            tint = NSColor(theme.warningColor)
            fill = NSColor(theme.warningColor).withAlphaComponent(0.12)
            border = NSColor(theme.warningColor).withAlphaComponent(0.35)
        case .error:
            tint = NSColor(theme.errorColor)
            fill = NSColor(theme.errorColor).withAlphaComponent(0.12)
            border = NSColor(theme.errorColor).withAlphaComponent(0.35)
        }
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = border.cgColor
        label.textColor = tint
        iconView.contentTintColor = tint

        guard !contentUnchanged || label.stringValue != badge.label else { return }
        label.stringValue = badge.label
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
