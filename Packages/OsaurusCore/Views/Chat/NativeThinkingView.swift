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
    private static let iconNodeSize: CGFloat = 28
    private let iconView = NSImageView()
    // Streaming status (in-progress), deliberately a separate catalog key
    // from the mode label `thinking.mode.label` (#2621).
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
    private let heightAnimation = DisclosureHeightAnimation()

    // MARK: State

    private var isExpanded = false
    private var currentTheme: (any ThemeProtocol)?
    private let headerBackdrop = NSView()
    private var headerHover = false
    private var headerTracking: NSTrackingArea?
    private var currentWidth: CGFloat = 0
    /// Block this view was last configured for. The chevron only animates on
    /// an expand-state change within the same block — a fresh or recycled
    /// cell arriving mid-stream must snap to its state, not replay the
    /// collapsed→expanded rotation on every reconfigure.
    private var configuredBlockId: String?

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
        // AppKit resets view-managed layer geometry during layout, wiping the
        // chevron's rotation. Streaming deltas re-layout on every height
        // change, so reapply the current rotation or the arrow visibly snaps
        // back to the collapsed direction between reconfigures.
        updateChevron(expanded: isExpanded, animated: false)
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
        let theme = theme.catalogFamily(33)
        heightAnimation.isConfiguring = true
        currentTheme = theme
        self.onToggle = onToggle
        self.onHeightChanged = onHeightChanged
        self.currentWidth = width

        let charCount = thinkingLength ?? thinking.count

        // Thinking chrome follows the current theme's text color.
        let tint = NSColor(theme.text.primary)
        let titleFont = theme.assignedNativeFont(ThinkingInspectionStyle.key + "label", fallback: theme.nsFont(.label))
        let titleTracking = theme.assignedTracking(ThinkingInspectionStyle.key + "label")
        let titleLineHeight: CGFloat? = theme.assignedLineHeight(ThinkingInspectionStyle.key + "label", fallback: titleFont.pointSize)
        titleLabel.font = titleFont
        titleLabel.textColor = tint

        iconView.contentTintColor = tint
        iconNode.layer?.backgroundColor = NSColor(theme.surface.hover).cgColor
        iconNode.layer?.borderColor = NSColor(theme.border.default).cgColor
        iconNode.layer?.borderWidth = theme.stroke.default
        separatorView.layer?.backgroundColor = NSColor(theme.border.subtle).cgColor

        // While streaming, shimmer the present-tense "Thinking" title; once done,
        // show past tense with the elapsed time ("Thought for 30s") when known.
        if isStreaming {
            shimmerLabel.configure(
                text: L("Thinking"),
                font: titleFont,
                baseColor: NSColor(theme.text.tertiary),
                highlightColor: tint,
                tracking: titleTracking,
                lineHeight: titleLineHeight
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
        charCountLabel.font = theme.nsFont(.micro, weight: .medium)
        charCountLabel.textColor = NSColor(theme.text.tertiary)

        let isSameBlock = configuredBlockId == blockId
        if !isSameBlock { heightAnimation.cancel() }
        // Same-block collapsed → expanded: fade the reasoning in instead of
        // popping (cell recycling and streaming reconfigures must not fade).
        let expandTransition = isSameBlock && isExpanded && !self.isExpanded
        let toggled = isSameBlock && isExpanded != self.isExpanded
        updateChevron(expanded: isExpanded, animated: toggled)
        self.isExpanded = isExpanded
        headerButton.setAccessibilityLabel(isExpanded ? L("Collapse reasoning") : L("Expand reasoning"))
        headerButton.setAccessibilityValue(isExpanded ? L("Expanded") : L("Collapsed"))
        ThinkingInspectionStyle.label(titleLabel, property: "label", color: tint, theme: theme)
        ThinkingInspectionStyle.label(charCountLabel, property: "caption", color: NSColor(theme.text.secondary), theme: theme)
        iconView.contentTintColor = NSColor(isStreaming ? theme.border.focus : theme.status.success.foreground)
        iconNode.layer?.backgroundColor = NSColor(theme.surface.raised).cgColor
        catalogAssignmentTarget([AgentContentSurfaceAssignments.key(33, "reasoningCard")], name: "Reasoning card", theme: theme)
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor(AgentContentSurfaceAssignments.color(33, "reasoningContent", theme)).cgColor
        iconNode.layer?.borderColor = NSColor(theme.border.default).cgColor
        iconNode.layer?.cornerRadius = min(CGFloat(theme.radius.medium), Self.iconNodeSize / 2)
        chevronView.contentTintColor = NSColor(theme.text.secondary)
        layer?.backgroundColor = NSColor(AgentContentSurfaceAssignments.color(33, "reasoningCard", theme)).cgColor
        layer?.borderColor = NSColor(theme.border.subtle).cgColor
        layer?.borderWidth = ThinkingInspectionStyle.metric("borderWidth", 0, theme)
        layer?.cornerRadius = theme.radius.medium
        applyAssignedLayout(theme)
        refreshHeaderFill()
        configuredBlockId = blockId

        // A collapse in motion keeps the reasoning drawn until it finishes.
        let showsContent = isExpanded || toggled || heightAnimation.isRunning
        contentContainer.isHidden = !showsContent
        separatorView.isHidden = !showsContent

        if isExpanded {
            let mdv = ensureMarkdownView()
            mdv.configure(
                text: thinking,
                width: max(1, width - 2 * ThinkingInspectionStyle.layout("contentPaddingX", "padding", theme.space.s14, theme)),
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

        // After the markdown view exists — on a first-ever expand it is only
        // created above, and a reveal fired before that would find an empty
        // container and do nothing.
        if expandTransition { ExpandFade.run(contentContainer) }

        heightAnimation.isConfiguring = false
        if toggled {
            heightAnimation.run(
                on: self,
                from: selfHeight?.constant ?? measuredHeight(),
                target: { [weak self] in self?.measuredHeight() ?? 0 },
                apply: { [weak self] in self?.setHeight($0) },
                finish: { [weak self] in
                    guard let self, !self.isExpanded else { return }
                    self.contentContainer.isHidden = true
                    self.separatorView.isHidden = true
                }
            )
        } else {
            applyHeight()
        }
    }

    // MARK: Measured height (used by cell coordinator)

    func measuredHeight() -> CGFloat {
        let theme = currentTheme ?? CustomizableTheme.light()
        let headerH = ThinkingInspectionStyle.headerHeight(theme)
        // The header already includes its vertical padding. A collapsed
        // disclosure has no content below it, so reserve only the header.
        guard isExpanded, let mdv = markdownView else { return headerH }
        // must match `mdv.configure(..., width: width - 28)` — do not subtract container insets twice
        let contentH = mdv.measuredHeight(for: max(1, currentWidth - 2 * ThinkingInspectionStyle.layout("contentPaddingX", "padding", theme.space.s14, theme)))
        return headerH + ThinkingInspectionStyle.metric("borderWidth", 1, theme) + ThinkingInspectionStyle.layout("contentTopGap", "gap", theme.space.s8, theme) + contentH + ThinkingInspectionStyle.layout("contentBottomPadding", "padding", theme.space.s10, theme)
    }

    // MARK: - Private

    /// Height the view occupies now: mid-disclosure the animated value.
    func displayedHeight() -> CGFloat { heightAnimation.height(measured: measuredHeight()) }

    private func applyHeight() {
        guard !heightAnimation.holdsHeight else { return }
        setHeight(measuredHeight())
    }

    private func setHeight(_ height: CGFloat) {
        selfHeight?.constant = height
        onHeightChanged?()
    }

    private func buildViews() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // Borderless: no card fill, border, or shadow — the block reads as a
        // standalone unit distinguished only by its glyph + title.
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.clear.cgColor

        // transparent overlay covering the header row for click handling;
        // re-ordered to the front once all header views exist (see below)
        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.title = ""; headerButton.isBordered = false; headerButton.bezelStyle = .inline
        headerButton.isTransparent = true
        headerButton.target = self; headerButton.action = #selector(headerTapped)
        addSubview(headerButton)

        // Circular node (tinted fill + ring), matching the tool timeline nodes.
        // Colors and stroke are applied per-theme in configure().
        iconNode.translatesAutoresizingMaskIntoConstraints = false
        iconNode.wantsLayer = true
        iconNode.layer?.cornerRadius = Self.iconNodeSize / 2
        addSubview(iconNode)

        // glyph in the node foreground
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = SymbolImageCache.image("brain", accessibilityDescription: nil)
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
        chevronView.image = SymbolImageCache.image(
            "chevron.right", accessibilityDescription: nil, pointSize: 10, weight: .semibold)
        chevronView.contentTintColor = .tertiaryLabelColor
        // Down-only scaling + a fixed symbol point size keep the right and
        // down chevrons visually the same size; proportional up-scaling into
        // the square frame inflated whichever glyph was wider.
        chevronView.imageScaling = .scaleProportionallyDown
        addSubview(chevronView)

        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.wantsLayer = true
        separatorView.isHidden = true
        addSubview(separatorView)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.isHidden = true
        addSubview(contentContainer)

        let headerH: CGFloat = 44

        // self sizing height constraint (priority 750, overridden by external bottomAnchor if present)
        let h = heightAnchor.constraint(equalToConstant: headerH)
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
            iconNode.widthAnchor.constraint(equalToConstant: Self.iconNodeSize),
            iconNode.heightAnchor.constraint(equalToConstant: Self.iconNodeSize),

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

        // Front of Z-order so the title and count labels cannot swallow header
        // clicks. The button is pinned to the 44pt header row, so it never
        // overlaps expanded content below.
        addSubview(headerButton, positioned: .above, relativeTo: nil)
        headerBackdrop.translatesAutoresizingMaskIntoConstraints = false
        headerBackdrop.wantsLayer = true
        addSubview(headerBackdrop, positioned: .below, relativeTo: iconNode)
        NSLayoutConstraint.activate([headerBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor), headerBackdrop.trailingAnchor.constraint(equalTo: trailingAnchor), headerBackdrop.topAnchor.constraint(equalTo: topAnchor), headerBackdrop.heightAnchor.constraint(equalTo: headerButton.heightAnchor)])
    }

    private func applyAssignedLayout(_ theme: any ThemeProtocol) {
        let pad = ThinkingInspectionStyle.layout("headerPaddingX", "padding", theme.space.s14, theme)
        let contentPad = ThinkingInspectionStyle.layout("contentPaddingX", "padding", theme.space.s14, theme)
        let gap = ThinkingInspectionStyle.layout("headerIconGap", "gap", theme.space.s8, theme)
        let height = ThinkingInspectionStyle.headerHeight(theme)
        headerButton.catalogAssignmentTarget(["headerPaddingX", "headerPaddingY", "headerIconGap", "headerCountGap"].map { ThinkingInspectionStyle.key + "elements.layout." + $0 } + ["background", "hover", "selected"].map { AgentContentSurfaceAssignments.key(33, "reasoningHeader", $0) }, name: "Reasoning header", theme: theme)
        contentContainer.catalogAssignmentTarget(["contentPaddingX", "contentTopGap", "contentBottomPadding"].map { ThinkingInspectionStyle.key + "elements.layout." + $0 } + [AgentContentSurfaceAssignments.key(33, "reasoningContent")], name: "Expanded reasoning content", theme: theme)
        headerButton.constraints.first { $0.firstAttribute == .height }?.constant = height
        separatorView.constraints.first { $0.firstAttribute == .height }?.constant = ThinkingInspectionStyle.metric("borderWidth", 1, theme)
        separatorView.layer?.backgroundColor = NSColor(theme.border.subtle).cgColor
        for c in constraints {
            let view = c.firstItem as? NSView
            if view === iconNode, c.firstAttribute == .leading { c.constant = pad }
            if view === iconNode, c.firstAttribute == .centerY { c.constant = height / 2 }
            if (view === titleLabel || view === shimmerLabel), c.firstAttribute == .leading { c.constant = gap }
            if view === charCountLabel, c.firstAttribute == .trailing { c.constant = -ThinkingInspectionStyle.layout("headerCountGap", "gap", theme.space.s8, theme) }
            if view === chevronView, c.firstAttribute == .trailing { c.constant = -pad }
            if view === separatorView, c.firstAttribute == .top { c.constant = height }
            if (view === separatorView || view === contentContainer), c.firstAttribute == .leading { c.constant = contentPad }
            if (view === separatorView || view === contentContainer), c.firstAttribute == .trailing { c.constant = -contentPad }
            if view === contentContainer, c.firstAttribute == .top { c.constant = ThinkingInspectionStyle.layout("contentTopGap", "gap", theme.space.s8, theme) }
        }
    }
    private func refreshHeaderFill() {
        guard let theme = currentTheme else { return }
        headerBackdrop.layer?.cornerRadius = theme.radius.medium
        headerBackdrop.layer?.backgroundColor = NSColor(AgentContentSurfaceAssignments.color(33, "reasoningHeader", theme, state: headerHover ? "hover" : isExpanded ? "selected" : "background")).cgColor
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let headerTracking { removeTrackingArea(headerTracking) }
        let tracking = NSTrackingArea(rect: headerButton.convert(headerButton.bounds, to: self), options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self)
        addTrackingArea(tracking); headerTracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); headerHover = true; refreshHeaderFill() }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); headerHover = false; refreshHeaderFill() }

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
        // Swap the symbol instead of rotating the layer: table-cell relayout
        // resets layer transforms, leaving an expanded row with a right-
        // pointing chevron (mirrors NativeFileDiffView's collapse chevron).
        // The down state is the right chevron rotated (not chevron.down, a
        // differently-proportioned glyph) so both states are the same size.
        chevronView.image =
            expanded
            ? SymbolImageCache.rotatedDownChevron(pointSize: 10, weight: .semibold)
            : SymbolImageCache.image(
                "chevron.right", accessibilityDescription: nil, pointSize: 10, weight: .semibold)
    }

    @objc private func headerTapped() { onToggle?() }

    private func formatCharCount(_ count: Int) -> String {
        if count < 1000 { return count == 1 ? "1 char" : "\(count) chars" }
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
