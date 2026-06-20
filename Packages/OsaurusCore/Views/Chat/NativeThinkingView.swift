//
//  NativeThinkingView.swift
//  osaurus
//
//  Pure AppKit thinking/reasoning disclosure block.
//  Replaces the SwiftUI ThinkingBlockView for table cells, eliminating NSHostingView
//  overhead and keeping expand/collapse height changes local to the coordinator.
//
//  Self-sizing: the view owns a selfHeight constraint (priority 750) so it can
//  report the correct height to the coordinator without a bottomAnchor pin to the cell.
//

import AppKit
import SwiftUI

// MARK: - NativeThinkingView

final class NativeThinkingView: NSView {

    // MARK: Subviews

    private let headerButton = NSButton()
    /// Circular tinted node holding the thinking glyph, matching the tool
    /// timeline nodes (this block is a separate borderless unit — no rail).
    private let iconNode = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: L("Thinking"))
    /// Shown in place of `titleLabel` while streaming — the title shimmers to
    /// signal in-progress reasoning (replaces the old streaming spinner).
    private let shimmerLabel = ShimmerLabel()
    private let charCountLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private let separatorView = NSView()
    private let contentContainer = NSView()
    private var markdownView: NativeMarkdownView?

    // MARK: Self-sizing height constraint

    private var selfHeight: NSLayoutConstraint?

    // MARK: State

    private var isExpanded = false
    private var currentWidth: CGFloat = 0

    // MARK: Callbacks

    var onToggle: (() -> Void)?
    var onHeightChanged: (() -> Void)?

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let h = hit {
            // `contentContainer` can return itself for transparent gaps; route into markdown for selection
            if h === contentContainer && isExpanded, let mdv = markdownView {
                let p = convert(point, to: mdv)
                return mdv.hitTest(p) ?? h
            }
            return h
        }
        guard isExpanded, let mdv = markdownView else { return nil }
        let p = convert(point, to: mdv)
        return mdv.hitTest(p)
    }

    // MARK: Configure

    func configure(
        thinking: String,
        thinkingLength: Int?,
        width: CGFloat,
        isStreaming: Bool,
        isExpanded: Bool,
        duration: TimeInterval?,
        theme: any ThemeProtocol,
        blockId: String,
        sessionRedactions: [String: String] = [:],
        onToggle: @escaping () -> Void,
        onHeightChanged: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onHeightChanged = onHeightChanged
        self.currentWidth = width

        let charCount = thinkingLength ?? thinking.count

        // Thinking chrome follows the current theme's text color.
        let tint = NSColor(theme.primaryText)
        let titleFont = NSFont.systemFont(ofSize: CGFloat(theme.captionSize), weight: .semibold)
        titleLabel.font = titleFont
        titleLabel.textColor = tint

        iconView.contentTintColor = tint
        iconNode.layer?.backgroundColor = tint.withAlphaComponent(0.15).cgColor
        iconNode.layer?.borderColor = tint.withAlphaComponent(0.55).cgColor

        // While streaming, shimmer the present-tense "Thinking" title; once done,
        // show past tense with the elapsed time ("Thought for 30s") when known.
        if isStreaming {
            shimmerLabel.configure(
                text: L("Thinking"),
                font: titleFont,
                baseColor: tint.withAlphaComponent(0.45),
                highlightColor: tint
            )
            titleLabel.isHidden = true
            shimmerLabel.isHidden = false
            shimmerLabel.start()
        } else {
            shimmerLabel.stop()
            shimmerLabel.isHidden = true
            if let duration {
                titleLabel.stringValue = "\(L("Thought for")) \(Self.formatDuration(duration))"
            } else {
                titleLabel.stringValue = L("Thought")
            }
            titleLabel.isHidden = false
        }

        charCountLabel.isHidden = isExpanded || charCount == 0
        charCountLabel.stringValue = formatCharCount(charCount)
        charCountLabel.font = NSFont.systemFont(ofSize: CGFloat(theme.captionSize) - 2, weight: .medium)
        charCountLabel.textColor = NSColor(theme.tertiaryText)

        updateChevron(expanded: isExpanded, animated: isExpanded != self.isExpanded)
        self.isExpanded = isExpanded

        contentContainer.isHidden = !isExpanded
        separatorView.isHidden = !isExpanded

        if isExpanded {
            let mdv = ensureMarkdownView()
            mdv.configure(
                text: thinking,
                width: width - 28,
                theme: theme,
                cacheKey: "\(blockId)-thinking",
                isStreaming: isStreaming
            )
            // Reasoning text is assistant-side restored content
            // (the unscrubber rewrote any placeholders before the
            // string reached this view), so direction is always
            // `.inbound`. Empty `sessionRedactions` short-circuits
            // inside the highlighter so non-Privacy chats stay
            // allocation-free.
            mdv.setRedactionHighlights(
                RedactionHighlight.buildDictionary(
                    from: sessionRedactions,
                    direction: .inbound
                ),
                theme: theme
            )
            mdv.onHeightChanged = { [weak self] in self?.applyHeight() }
        }

        applyHeight()
    }

    // MARK: Measured height (used by cell coordinator)

    func measuredHeight() -> CGFloat {
        let headerH: CGFloat = 44
        // collapsed: header only — avoid reserving expanded-content slack (was +14, looked like a dead gap)
        let collapsedBottomInset: CGFloat = 4
        guard isExpanded, let mdv = markdownView else { return headerH + collapsedBottomInset }
        // must match `mdv.configure(..., width: width - 28)` — do not subtract container insets twice
        let contentH = mdv.measuredHeight(for: currentWidth - 28)
        return headerH + 1 + 8 + contentH + 10
    }

    // MARK: - Private

    private func applyHeight() {
        selfHeight?.constant = measuredHeight()
        onHeightChanged?()
    }

    private func buildViews() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // Borderless: no card fill, border, or shadow — the block reads as a
        // standalone unit distinguished only by its glyph + title.
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.clear.cgColor

        // header button in back - transparent overlay covering the header row for click handling
        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.title = ""; headerButton.isBordered = false; headerButton.bezelStyle = .inline
        headerButton.target = self; headerButton.action = #selector(headerTapped)
        addSubview(headerButton)

        // Circular node (tinted fill + ring), matching the tool timeline nodes.
        // Colors are applied per-theme in configure(); these are neutral defaults.
        iconNode.translatesAutoresizingMaskIntoConstraints = false
        iconNode.wantsLayer = true
        iconNode.layer?.cornerRadius = 14
        iconNode.layer?.borderWidth = 1.5
        iconNode.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.15).cgColor
        iconNode.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.55).cgColor
        addSubview(iconNode)

        // glyph in the node foreground
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = SymbolImageCache.image("brain", accessibilityDescription: nil)
        iconView.contentTintColor = NSColor.labelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconNode.addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.isEditable = false; titleLabel.isBordered = false; titleLabel.drawsBackground = false
        addSubview(titleLabel)

        // Shimmering "Thinking" title (streaming state); overlays titleLabel's slot.
        shimmerLabel.translatesAutoresizingMaskIntoConstraints = false
        shimmerLabel.isHidden = true
        addSubview(shimmerLabel)

        charCountLabel.translatesAutoresizingMaskIntoConstraints = false
        charCountLabel.isEditable = false; charCountLabel.isBordered = false; charCountLabel.drawsBackground = false
        addSubview(charCountLabel)

        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.wantsLayer = true
        chevronView.image = SymbolImageCache.image("chevron.right", accessibilityDescription: nil)
        chevronView.contentTintColor = .tertiaryLabelColor
        chevronView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(chevronView)

        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.wantsLayer = true
        separatorView.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
        separatorView.isHidden = true
        addSubview(separatorView)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.isHidden = true
        addSubview(contentContainer)

        let headerH: CGFloat = 44

        // self sizing height constraint (priority 750, overridden by external bottomAnchor if present)
        let h = heightAnchor.constraint(equalToConstant: headerH + 4)
        h.priority = NSLayoutConstraint.Priority(rawValue: 750)
        h.isActive = true
        selfHeight = h

        NSLayoutConstraint.activate([
            headerButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerButton.topAnchor.constraint(equalTo: topAnchor),
            headerButton.heightAnchor.constraint(equalToConstant: headerH),

            iconNode.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconNode.centerYAnchor.constraint(equalTo: topAnchor, constant: headerH / 2),
            iconNode.widthAnchor.constraint(equalToConstant: 28),
            iconNode.heightAnchor.constraint(equalToConstant: 28),

            iconView.centerXAnchor.constraint(equalTo: iconNode.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconNode.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: iconNode.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: iconNode.centerYAnchor),

            // Shimmer title occupies the same slot as titleLabel (only one shows).
            shimmerLabel.leadingAnchor.constraint(equalTo: iconNode.trailingAnchor, constant: 10),
            shimmerLabel.centerYAnchor.constraint(equalTo: iconNode.centerYAnchor),

            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            chevronView.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.heightAnchor.constraint(equalToConstant: 12),

            charCountLabel.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -8),
            charCountLabel.centerYAnchor.constraint(equalTo: chevronView.centerYAnchor),

            separatorView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            separatorView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            separatorView.topAnchor.constraint(equalTo: topAnchor, constant: headerH),
            separatorView.heightAnchor.constraint(equalToConstant: 1),

            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            contentContainer.topAnchor.constraint(equalTo: separatorView.bottomAnchor, constant: 8),
        ])

        // keep the transparent header control behind expanded content so it cannot steal clicks
        addSubview(headerButton, positioned: .below, relativeTo: nil)
    }

    private func ensureMarkdownView() -> NativeMarkdownView {
        if let mdv = markdownView { return mdv }
        let mdv = NativeMarkdownView()
        mdv.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(mdv)
        NSLayoutConstraint.activate([
            mdv.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            mdv.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            mdv.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            mdv.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        markdownView = mdv
        return mdv
    }

    private func updateChevron(expanded: Bool, animated: Bool) {
        let angle: CGFloat = expanded ? .pi / 2 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                chevronView.layer?.setAffineTransform(CGAffineTransform(rotationAngle: angle))
            }
        } else {
            chevronView.layer?.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        }
    }

    @objc private func headerTapped() { onToggle?() }

    private func formatCharCount(_ count: Int) -> String {
        if count < 1000 { return "\(count) chars" }
        if count < 10_000 { return String(format: "%.1fk chars", Double(count) / 1000) }
        return "\(count / 1000)k chars"
    }

    /// Compact duration for "Thought for …": "320ms", "4.2s", "30s", "1m 5s".
    private static func formatDuration(_ t: TimeInterval) -> String {
        if t < 1 { return "\(Int((t * 1000).rounded()))ms" }
        if t < 10 { return String(format: "%.1fs", t) }
        if t < 60 { return "\(Int(t.rounded()))s" }
        return "\(Int(t) / 60)m \(Int(t) % 60)s"
    }
}
