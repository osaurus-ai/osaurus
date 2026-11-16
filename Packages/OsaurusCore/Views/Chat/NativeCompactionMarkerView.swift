//
//  NativeCompactionMarkerView.swift
//  osaurus
//
//  Pure AppKit divider marker for the LLM context-compaction boundary.
//
//  Rendered where the session's ConversationSummary ends: every visible turn
//  above it is represented by the summary in the OUTBOUND context (the
//  transcript itself is untouched). The header row is a subtle divider —
//  line · pill label · line — and expands to show the exact summary text the
//  model sees, using the same expandedIds/onToggle contract as
//  NativeThinkingView so height changes stay local to the coordinator.
//

import AppKit

final class NativeCompactionMarkerView: NSView {

    // MARK: Subviews

    private let headerButton = NSButton()
    private let leftLine = NSView()
    private let rightLine = NSView()
    private let pillContainer = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private let contentContainer = NSView()
    private var markdownView: NativeMarkdownView?

    // MARK: Self-sizing height constraint

    private var selfHeight: NSLayoutConstraint?

    // MARK: State

    private var isExpanded = false
    private var currentWidth: CGFloat = 0
    private var configuredBlockId: String?
    private var inspectionTheme: (any ThemeProtocol)?
    private let inspectionHeader = InspectorActivityHeaderSurface()
    private func metric(_ property: String, _ fallback: CGFloat) -> CGFloat {
        NativeComponentInspectionStyle.metric(40, property, fallback, inspectionTheme ?? CustomizableTheme.light())
    }
    private var space: ThemeSpaceScale { (inspectionTheme ?? CustomizableTheme.light()).space }
    static func inspectionHeaderHeight(_ theme: any ThemeProtocol) -> CGFloat {
        let font = theme.assignedNativeFont(NativeComponentInspectionStyle.key(40, "label"), fallback: theme.nsFont(.label))
        return max(NativeComponentInspectionStyle.metric(40, "height", headerH, theme), max(ceil(font.ascender-font.descender+font.leading), theme.assignedLineHeight(NativeComponentInspectionStyle.key(40, "label"), fallback: 18)) + 2 * NativeComponentInspectionStyle.metric(40, "padding", theme.space.s0, theme))
    }
    private var assignedHeaderHeight: CGFloat { Self.inspectionHeaderHeight(inspectionTheme ?? CustomizableTheme.light()) }

    private static let headerH: CGFloat = 32

    // MARK: Callbacks

    var onToggle: (() -> Void)?
    var onHeightChanged: (() -> Void)?

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let h = hit {
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
        savedTokens: Int,
        modelName: String,
        summaryText: String,
        width: CGFloat,
        isExpanded: Bool,
        theme: any ThemeProtocol,
        blockId: String,
        onToggle: @escaping () -> Void,
        onHeightChanged: @escaping () -> Void
    ) {
        let theme = theme.catalogFamily(40)
        inspectionTheme = theme
        self.onToggle = onToggle
        self.onHeightChanged = onHeightChanged
        self.currentWidth = width

        let tint = NSColor(theme.text.tertiary)
        titleLabel.stringValue =
            savedTokens > 0
            ? L("Older messages summarized — ~\(Self.formatTokens(savedTokens)) tokens reclaimed")
            : L("Older messages summarized")
        titleLabel.font = theme.nsFont(.footnote, weight: .medium)
        titleLabel.textColor = tint
        iconView.contentTintColor = tint
        chevronView.contentTintColor = tint
        leftLine.layer?.backgroundColor = NSColor(theme.border.subtle).cgColor
        rightLine.layer?.backgroundColor = NSColor(theme.border.subtle).cgColor
        pillContainer.layer?.backgroundColor = NSColor(theme.assignedColor(AgentContentSurfaceAssignments.key(40, "noticePill"), fallback: theme.surface.hover)).cgColor
        pillContainer.catalogAssignmentTarget([AgentContentSurfaceAssignments.key(40, "noticePill")], name: "Conversation summary marker", theme: theme)
        pillContainer.layer?.borderColor = NSColor(theme.border.subtle).cgColor
        pillContainer.layer?.borderWidth = theme.stroke.default
        pillContainer.layer?.cornerRadius = theme.radius.medium
        toolTip = L(
            "Summarized by \(modelName). The visible chat is unchanged; the model sees this summary in place of the messages above."
        )

        let isSameBlock = configuredBlockId == blockId
        let expandTransition = isSameBlock && isExpanded && !self.isExpanded
        updateChevron(expanded: isExpanded)
        self.isExpanded = isExpanded
        configuredBlockId = blockId

        contentContainer.isHidden = !isExpanded

        if isExpanded {
            let mdv = ensureMarkdownView()
            mdv.configure(
                text: summaryText,
                width: width - 2 * metric("padding", space.s14),
                theme: theme,
                cacheKey: "\(blockId)-summary",
                isStreaming: false
            )
            mdv.onHeightChanged = { [weak self] in self?.applyHeight() }
        }

        if expandTransition { ExpandFade.run(contentContainer) }

        NativeComponentInspectionStyle.label(titleLabel, family: 40, property: "label", theme: theme)
        headerButton.constraints.first { $0.firstAttribute == .height }?.constant = assignedHeaderHeight
        pillContainer.constraints.first { $0.firstAttribute == .height }?.constant = assignedHeaderHeight
        inspectionHeader.configure(theme: theme, selected: isExpanded)
        for c in constraints {
            let v = c.firstItem as? NSView
            if v === pillContainer, c.firstAttribute == .centerY { c.constant = assignedHeaderHeight / 2 }
            if v === contentContainer {
                if c.firstAttribute == .leading { c.constant = metric("padding", space.s14) }
                if c.firstAttribute == .trailing { c.constant = -metric("padding", space.s14) }
                if c.firstAttribute == .top { c.constant = assignedHeaderHeight + metric("gap", space.s8) }
            }
        }
        for c in pillContainer.constraints {
            if c.firstAttribute == .leading { c.constant = metric("gap", c.constant) }
            if c.firstAttribute == .trailing { c.constant = -metric("padding", space.s8) }
        }
        for line in [leftLine, rightLine] { line.constraints.first { $0.firstAttribute == .height }?.constant = theme.stroke.default }
        applyHeight()
    }

    // MARK: Measured height (used by cell coordinator)

    func measuredHeight() -> CGFloat {
        guard isExpanded, let mdv = markdownView else { return assignedHeaderHeight + metric("padding", space.s4) }
        let contentH = mdv.measuredHeight(for: currentWidth - 2 * metric("padding", space.s14))
        return assignedHeaderHeight + metric("gap", space.s8) + contentH + metric("padding", space.s10)
    }

    // MARK: - Private

    private func applyHeight() {
        selfHeight?.constant = measuredHeight()
        onHeightChanged?()
    }

    private func buildViews() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.clear.cgColor

        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.title = ""
        headerButton.isBordered = false
        headerButton.bezelStyle = .inline
        headerButton.isTransparent = true
        headerButton.target = self
        headerButton.action = #selector(headerTapped)
        addSubview(headerButton)

        for line in [leftLine, rightLine] {
            line.translatesAutoresizingMaskIntoConstraints = false
            line.wantsLayer = true
            addSubview(line)
        }

        pillContainer.translatesAutoresizingMaskIntoConstraints = false
        pillContainer.wantsLayer = true
        addSubview(pillContainer)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = SymbolImageCache.image(
            "arrow.down.right.and.arrow.up.left", accessibilityDescription: nil,
            pointSize: 8, weight: .semibold)
        iconView.imageScaling = .scaleProportionallyDown
        inspectionHeader.translatesAutoresizingMaskIntoConstraints = false
        pillContainer.addSubview(inspectionHeader)
        NSLayoutConstraint.activate([inspectionHeader.leadingAnchor.constraint(equalTo: pillContainer.leadingAnchor), inspectionHeader.trailingAnchor.constraint(equalTo: pillContainer.trailingAnchor), inspectionHeader.topAnchor.constraint(equalTo: pillContainer.topAnchor), inspectionHeader.bottomAnchor.constraint(equalTo: pillContainer.bottomAnchor)])
        pillContainer.addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pillContainer.addSubview(titleLabel)

        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.image = SymbolImageCache.image(
            "chevron.right", accessibilityDescription: nil, pointSize: 8, weight: .semibold)
        chevronView.imageScaling = .scaleProportionallyDown
        pillContainer.addSubview(chevronView)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.isHidden = true
        addSubview(contentContainer)

        let h = heightAnchor.constraint(equalToConstant: assignedHeaderHeight + 4)
        h.priority = NSLayoutConstraint.Priority(rawValue: 750)
        h.isActive = true
        selfHeight = h

        NSLayoutConstraint.activate([
            headerButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerButton.topAnchor.constraint(equalTo: topAnchor),
            headerButton.heightAnchor.constraint(equalToConstant: assignedHeaderHeight),

            pillContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            pillContainer.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            pillContainer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            pillContainer.centerYAnchor.constraint(equalTo: topAnchor, constant: assignedHeaderHeight / 2),
            pillContainer.heightAnchor.constraint(equalToConstant: 20),

            iconView.leadingAnchor.constraint(equalTo: pillContainer.leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: pillContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 10),
            iconView.heightAnchor.constraint(equalToConstant: 10),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            titleLabel.centerYAnchor.constraint(equalTo: pillContainer.centerYAnchor),

            chevronView.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 5),
            chevronView.trailingAnchor.constraint(equalTo: pillContainer.trailingAnchor, constant: -8),
            chevronView.centerYAnchor.constraint(equalTo: pillContainer.centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 10),
            chevronView.heightAnchor.constraint(equalToConstant: 10),

            leftLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftLine.trailingAnchor.constraint(equalTo: pillContainer.leadingAnchor, constant: -10),
            leftLine.centerYAnchor.constraint(equalTo: pillContainer.centerYAnchor),
            leftLine.heightAnchor.constraint(equalToConstant: 1),

            rightLine.leadingAnchor.constraint(equalTo: pillContainer.trailingAnchor, constant: 10),
            rightLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            rightLine.centerYAnchor.constraint(equalTo: pillContainer.centerYAnchor),
            rightLine.heightAnchor.constraint(equalToConstant: 1),

            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            contentContainer.topAnchor.constraint(equalTo: topAnchor, constant: assignedHeaderHeight + 8),
        ])

        addSubview(headerButton, positioned: .above, relativeTo: nil)
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

    private func updateChevron(expanded: Bool) {
        chevronView.image =
            expanded
            ? SymbolImageCache.rotatedDownChevron(pointSize: 8, weight: .semibold)
            : SymbolImageCache.image(
                "chevron.right", accessibilityDescription: nil, pointSize: 8, weight: .semibold)
    }

    @objc private func headerTapped() { onToggle?() }

    private static func formatTokens(_ tokens: Int) -> String {
        if tokens < 1000 { return "\(tokens)" }
        if tokens < 10_000 { return String(format: "%.1fk", Double(tokens) / 1000) }
        return "\(tokens / 1000)k"
    }
}
