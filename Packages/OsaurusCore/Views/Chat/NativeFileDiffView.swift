//
//  NativeFileDiffView.swift
//  osaurus
//
//  AppKit diff card rendered for folder-scoped file edits, replacing the
//  generic tool-call row. Header carries the file name + add/remove counts +
//  copy / collapse controls. The body composes a plain `CodeNSTextView` for
//  text with a sibling `DiffBackgroundView` that paints per-line add/remove
//  tints behind it — keeping the diff concern out of `CodeNSTextView`.
//

import AppKit

// MARK: - DiffBackgroundView

/// Paints full-width add/remove backgrounds (plus a left accent bar) behind the
/// changed lines of an associated text view. Sized to the full card width and
/// placed under the text view; line geometry is read from the text view's own
/// layout manager and converted into this view's coordinate space, so the two
/// stay aligned without coupling the text view to diff state.
final class DiffBackgroundView: NSView {
    weak var textView: CodeNSTextView?
    /// Index-aligned with the logical lines of `textView`'s text storage.
    var lineKinds: [FileDiff.LineKind] = []
    var addedBackground: NSColor = .clear
    var removedBackground: NSColor = .clear
    var addedBar: NSColor = .clear
    var removedBar: NSColor = .clear
    var markerFont: NSFont?
    static let markerWidth: CGFloat = 16

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // never intercept clicks

    override func draw(_ dirtyRect: NSRect) {
        guard let tv = textView,
            let layoutManager = tv.layoutManager,
            let textStorage = tv.textStorage,
            !lineKinds.isEmpty
        else { return }

        let nsString = textStorage.string as NSString
        let fullWidth = bounds.width
        var charIndex = 0
        var lineIdx = 0

        while charIndex < textStorage.length, lineIdx < lineKinds.count {
            let lineRange = nsString.lineRange(for: NSRange(location: charIndex, length: 0))
            let kind = lineKinds[lineIdx]

            if kind == .added || kind == .removed {
                let bg = kind == .added ? addedBackground : removedBackground
                let bar = kind == .added ? addedBar : removedBar
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: lineRange,
                    actualCharacterRange: nil
                )
                layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, fragmentRange, _ in
                    let local = self.convert(rect, from: tv)
                    guard local.maxY >= dirtyRect.minY, local.minY <= dirtyRect.maxY else { return }
                    bg.setFill()
                    NSRect(x: 0, y: local.origin.y, width: fullWidth, height: local.height).fill()
                    bar.setFill()
                    NSRect(x: 0, y: local.origin.y, width: 2, height: local.height).fill()
                    if fragmentRange.location == glyphRange.location {
                        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: bar]
                        attributes[.font] = self.markerFont ?? tv.font
                        let marker = NSAttributedString(
                            string: kind == .added ? "+" : "−",
                            attributes: attributes
                        )
                        let size = marker.size()
                        marker.draw(at: NSPoint(
                            x: local.minX - (Self.markerWidth + size.width) / 2,
                            y: local.midY - size.height / 2
                        ))
                    }
                }
            }

            charIndex = NSMaxRange(lineRange)
            lineIdx += 1
        }
    }
}

// MARK: - NativeFileDiffView

final class NativeFileDiffView: NSView {

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Layout constants

    /// The leading inset leaves room for change markers and the edge rule.
    private static let textInsetLeft: CGFloat = 14
    private static let textInsetRight: CGFloat = 8
    private static let textInsetTop: CGFloat = 6
    private static let textInsetBottom: CGFloat = 6
    static let headerHeight: CGFloat = 36

    // MARK: Subviews

    private let headerView = NSView()
    /// Transparent overlay covering the header up to the action buttons; toggles
    /// the card on click. Mirrors `NativeToolCallRowView.headerButton` — an
    /// NSButton handles repeated clicks reliably inside a table cell, unlike a
    /// view's `mouseDown`.
    private let headerButton = NSButton()
    /// Literal "</>" code glyph — drawn as text so it renders regardless of SF
    /// Symbol availability, shown before the file name in every state.
    private let iconLabel = NSTextField(labelWithString: "</>")
    /// Shown in place of the code glyph while a collapsed card is still
    /// receiving streamed content, so the header signals work in progress.
    private let loadingIndicator = NSProgressIndicator()
    private let fileLabel = NSTextField(labelWithString: "")
    private let addedLabel = NSTextField(labelWithString: "")
    private let removedLabel = NSTextField(labelWithString: "")
    private let previewBadge = NSTextField(labelWithString: "")
    private let metadataStack = NSStackView()
    private let headerDivider = NSView()
    private let copyButton = NSButton()
    private let collapseButton = NSButton()
    /// File-history controls: status badge ("Reverted"), View (opens the
    /// File Changes inspector on this write) and Revert / Undo.
    private let historyStack = NSStackView()
    private let historyBadge = NSTextField(labelWithString: "")
    private let viewButton = NSButton()
    private let revertButton = NSButton()
    private var diffBackground: DiffBackgroundView?
    private var diffTextView: CodeNSTextView?
    private var bodyHeightConstraint: NSLayoutConstraint?

    // MARK: Callbacks

    var onHeightChanged: (() -> Void)?
    /// Invoked when the disclosure chevron is tapped; the cell forwards this to
    /// the coordinator's expand/collapse store.
    var onToggleCollapse: (() -> Void)?

    // MARK: State

    private var lastDiff: FileDiff?
    private var lastThemeFingerprint: Int?
    private var isCollapsed = false
    private var copyResetTask: Task<Void, Never>?
    private var lastTheme: (any ThemeProtocol)?
    private var inspectorHovered = false
    private func metric(_ property: String, _ fallback: CGFloat) -> CGFloat {
        NativeComponentInspectionStyle.metric(38, property, fallback, lastTheme ?? CustomizableTheme.light())
    }
    static func inspectionHeaderHeight(_ theme: any ThemeProtocol) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        let name = theme.assignedNativeFont(NativeComponentInspectionStyle.key(38, "heading"), fallback: theme.nsFont(.caption))
        let caption = theme.assignedNativeFont(NativeComponentInspectionStyle.key(38, "caption"), fallback: theme.nsFont(.caption))
        let textHeight = max(ceil(name.ascender - name.descender + name.leading), ceil(caption.ascender - caption.descender + caption.leading), theme.assignedLineHeight(NativeComponentInspectionStyle.key(38, "heading"), fallback: 18), theme.assignedLineHeight(NativeComponentInspectionStyle.key(38, "caption"), fallback: 16))
        return max(NativeComponentInspectionStyle.metric(38, "height", headerHeight, theme), textHeight + 2 * theme.space.s8)
        #else
        return headerHeight
        #endif
    }
    private var assignedHeaderHeight: CGFloat { Self.inspectionHeaderHeight(lastTheme ?? CustomizableTheme.light()) }
    private var historySetId: UUID?
    private var historySessionId: String?
    private var historyStatus: FileChangeSetStatus?
    private var historyUndoSetId: UUID?
    private var historyBusy = false
    nonisolated(unsafe) private var historyObserver: NSObjectProtocol?

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let historyObserver { NotificationCenter.default.removeObserver(historyObserver) }
    }

    // MARK: Configure

    func configure(diff: FileDiff, collapsed: Bool, width: CGFloat, theme: any ThemeProtocol) {
        let theme = theme.catalogFamily(38, authoritative: true)
        let themeId = theme.renderFingerprint
        // Only the expensive syntax-highlight pass is gated; header styling and
        // layout always run so every reconfigure reports an accurate height —
        // an early return here let the row get stuck after a few toggles when a
        // SwiftUI update wiped the height cache without a fresh measurement.
        let diffChanged = diff != lastDiff
        let themeChanged = themeId != lastThemeFingerprint

        lastDiff = diff
        lastThemeFingerprint = themeId
        isCollapsed = collapsed
        lastTheme = theme

        let setId = diff.isPreview || diff.isStreamingPreview ? nil : diff.operationId
        if setId != historySetId {
            historySetId = setId
            historySessionId = nil
            historyStatus = nil
            historyUndoSetId = nil
            refreshHistoryState()
        }

        applyHeaderStyling(diff: diff, theme: theme)
        applyHistoryControls(theme: theme)
        updateCollapseChevron(theme: theme)

        let tv = ensureTextView(theme: theme)
        if diffChanged || themeChanged {
            applyDiffText(to: tv, diff: diff, theme: theme)
        }
        applyInspectionStyle(theme)
        layoutBody(width: width, collapsed: collapsed, theme: theme)
    }

    /// TextKit-only height for the cell's height cache — never calls
    /// `layoutSubtreeIfNeeded()` (re-entering AppKit layout mid-reconfigure is
    /// what the chart / tool-group height paths guard against). Uses the view's
    /// own `isCollapsed` so a local toggle reports the correct height without the
    /// caller threading a (potentially stale) collapsed flag.
    func measuredCardHeight(cardWidth: CGFloat) -> CGFloat {
        if isCollapsed { return assignedHeaderHeight }
        guard let tv = diffTextView, let tc = tv.textContainer, let lm = tv.layoutManager else {
            return assignedHeaderHeight + 40
        }
        let innerW = max(1, bodyTextWidth(forCardWidth: cardWidth))
        let wasTracking = tc.widthTracksTextView
        let wasSize = tc.containerSize
        tc.widthTracksTextView = false
        tc.containerSize = NSSize(width: innerW, height: .greatestFiniteMagnitude)
        defer {
            tc.widthTracksTextView = wasTracking
            tc.containerSize = wasSize
        }
        lm.ensureLayout(for: tc)
        let textH = ceil(lm.usedRect(for: tc).height)
        return assignedHeaderHeight + metric("padding", Self.textInsetTop) + max(textH, 1) + metric("padding", Self.textInsetBottom)
    }

    private func applyInspectionStyle(_ theme: any ThemeProtocol) {
        #if OSAURUS_DESIGN_SYSTEM
        headerView.constraints.first { $0.firstAttribute == .height }?.constant = assignedHeaderHeight
        let gap = metric("gap", 8)
        historyStack.spacing = gap
        for c in headerView.constraints {
            let view = c.firstItem as? NSView
            if view === iconLabel, c.firstAttribute == .leading { c.constant = metric("padding", 10) }
            if c.firstAttribute == .leading, view === fileLabel || view === metadataStack { c.constant = gap }
            if c.firstAttribute == .trailing, view === collapseButton { c.constant = -metric("padding", 8) }
        }
        for c in constraints where c.firstItem as? NSView === diffTextView {
            if c.firstAttribute == .leading { c.constant = (metric("padding", Self.textInsetLeft) + DiffBackgroundView.markerWidth) }
            if c.firstAttribute == .trailing { c.constant = -metric("padding", Self.textInsetRight) }
            if c.firstAttribute == .top { c.constant = metric("padding", Self.textInsetTop) }
        }
        NativeComponentInspectionStyle.label(fileLabel, family: 38, property: "heading", theme: theme)
        NativeComponentInspectionStyle.label(iconLabel, family: 38, property: "code", theme: theme)
        for field in [addedLabel, removedLabel, previewBadge, historyBadge] { NativeComponentInspectionStyle.label(field, family: 38, property: "caption", theme: theme) }
        diffTextView?.selectedTextAttributes = [.backgroundColor: NSColor(theme.selection.background)]
        diffTextView?.insertionPointColor = NSColor(theme.cursor)
        #endif
    }

    // MARK: - Private: Build

    private func buildViews() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true

        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.wantsLayer = true
        addSubview(headerView)

        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        iconLabel.isEditable = false
        iconLabel.isBordered = false
        iconLabel.drawsBackground = false
        headerView.addSubview(iconLabel)

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isDisplayedWhenStopped = false
        headerView.addSubview(loadingIndicator)

        for label in [fileLabel, addedLabel, removedLabel, previewBadge] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
        }
        headerView.addSubview(fileLabel)
        fileLabel.lineBreakMode = .byTruncatingMiddle

        metadataStack.translatesAutoresizingMaskIntoConstraints = false
        metadataStack.orientation = .horizontal
        metadataStack.alignment = .firstBaseline
        metadataStack.spacing = 4
        for label in [addedLabel, removedLabel, previewBadge] {
            metadataStack.addArrangedSubview(label)
        }
        headerView.addSubview(metadataStack)

        headerDivider.translatesAutoresizingMaskIntoConstraints = false
        headerDivider.wantsLayer = true
        headerView.addSubview(headerDivider)

        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.title = ""
        copyButton.image = SymbolImageCache.image("doc.on.doc", accessibilityDescription: nil)
        copyButton.isBordered = false
        copyButton.target = self
        copyButton.action = #selector(copyDiff)
        copyButton.alphaValue = 0.55
        headerView.addSubview(copyButton)

        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        collapseButton.title = ""
        collapseButton.image = SymbolImageCache.image("chevron.down", accessibilityDescription: nil)
        collapseButton.isBordered = false
        collapseButton.target = self
        collapseButton.action = #selector(toggleCollapse)
        collapseButton.alphaValue = 0.55
        headerView.addSubview(collapseButton)

        historyStack.translatesAutoresizingMaskIntoConstraints = false
        historyStack.orientation = .horizontal
        historyStack.spacing = 6
        historyStack.alignment = .centerY
        historyBadge.isEditable = false
        historyBadge.isBordered = false
        historyBadge.drawsBackground = false
        viewButton.title = ""
        viewButton.image = SymbolImageCache.image("sidebar.right", accessibilityDescription: L("View change"))
        viewButton.toolTip = L("Show in File Changes")
        viewButton.isBordered = false
        viewButton.target = self
        viewButton.action = #selector(openInPanel)
        viewButton.alphaValue = 0.55
        viewButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
        viewButton.heightAnchor.constraint(equalToConstant: 20).isActive = true
        revertButton.isBordered = false
        revertButton.bezelStyle = .inline
        revertButton.target = self
        revertButton.action = #selector(revertOrUndo)
        revertButton.alphaValue = 0.75
        for view in [historyBadge, viewButton, revertButton] as [NSView] {
            historyStack.addArrangedSubview(view)
        }
        historyStack.isHidden = true
        headerView.addSubview(historyStack)

        // Transparent toggle overlay over the header up to the action buttons,
        // added last so it sits in front of the icon/labels and captures their
        // clicks while copy / collapse keep their own.
        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.title = ""
        headerButton.isBordered = false
        headerButton.bezelStyle = .inline
        headerButton.isTransparent = true
        headerButton.focusRingType = .none
        headerButton.target = self
        headerButton.action = #selector(toggleCollapse)
        headerView.addSubview(headerButton)

        NSLayoutConstraint.activate([
            headerButton.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            headerButton.topAnchor.constraint(equalTo: headerView.topAnchor),
            headerButton.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
            headerButton.trailingAnchor.constraint(equalTo: historyStack.leadingAnchor),
        ])

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: assignedHeaderHeight),

            iconLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 10),
            // The file name is the header's single vertical reference: the icon
            // glyph and streaming spinner align to ITS row rather than each
            // taking their own centerY on the header. Independently centered,
            // the spinner drifted below the text (NSProgressIndicator's drawn
            // glyph doesn't sit where its squeezed 14pt frame's center says),
            // leaving the collapsed card's header visibly misaligned.
            iconLabel.firstBaselineAnchor.constraint(equalTo: fileLabel.firstBaselineAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: iconLabel.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: fileLabel.centerYAnchor),
            // Size to the `.small` spinning style's natural 16pt. A smaller frame
            // (we used to pin 14pt) is below the indicator's intrinsic content
            // size, so AppKit draws the animated glyph outside — below — the
            // squeezed frame's center: the frame is centered on the file name but
            // the visible spinner hangs ~5pt low. Matching the natural size keeps
            // frame == drawn content so centerY actually lands on the text row.
            loadingIndicator.widthAnchor.constraint(equalToConstant: 16),
            loadingIndicator.heightAnchor.constraint(equalToConstant: 16),

            fileLabel.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 7),
            fileLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            metadataStack.leadingAnchor.constraint(equalTo: fileLabel.trailingAnchor, constant: 8),
            metadataStack.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            metadataStack.trailingAnchor.constraint(lessThanOrEqualTo: historyStack.leadingAnchor, constant: -8),

            headerDivider.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            headerDivider.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
            headerDivider.heightAnchor.constraint(equalToConstant: 1),

            historyStack.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -6),
            historyStack.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            collapseButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -8),
            collapseButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            collapseButton.widthAnchor.constraint(equalToConstant: 20),
            collapseButton.heightAnchor.constraint(equalToConstant: 20),

            copyButton.trailingAnchor.constraint(equalTo: collapseButton.leadingAnchor, constant: -4),
            copyButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 20),
            copyButton.heightAnchor.constraint(equalToConstant: 20),
        ])

        // Keep the file name from shoving the counts off the trailing edge.
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        removedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        historyStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        historyObserver = NotificationCenter.default.addObserver(
            forName: .fileChangesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshHistoryState() }
        }
    }

    private func ensureTextView(theme: any ThemeProtocol) -> CodeNSTextView {
        if let tv = diffTextView { return tv }

        // Background sits under the text, spanning the full card width so the
        // line tint runs edge-to-edge.
        let bgView = DiffBackgroundView()
        bgView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bgView)
        diffBackground = bgView

        let tv = CodeNSTextView()
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.lineFragmentPadding = 0
        // Diff card draws no gutter — keep CodeNSTextView's line numbers off.
        tv.lineCount = 0
        tv.selectedTextAttributes = [.backgroundColor: NSColor(theme.selection.background)]
        addSubview(tv)
        bgView.textView = tv

        let hc = tv.heightAnchor.constraint(equalToConstant: 0)
        hc.isActive = true
        bodyHeightConstraint = hc

        NSLayoutConstraint.activate([
            tv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: (metric("padding", Self.textInsetLeft) + DiffBackgroundView.markerWidth)),
            tv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -metric("padding", Self.textInsetRight)),
            tv.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: metric("padding", Self.textInsetTop)),

            bgView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bgView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bgView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            bgView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        diffTextView = tv
        return tv
    }

    // MARK: - Private: Styling

    private func applyHeaderStyling(diff: FileDiff, theme: any ThemeProtocol) {
        // Match NativeCodeBlockView: pair the card with the active highlight
        // theme's background so syntax colors land on the surface they were
        // tuned for. Diff tints are semi-transparent and blend over it.
        ensureHighlightrTheme(for: theme)
        #if OSAURUS_DESIGN_SYSTEM
        layer?.backgroundColor = NSColor(theme.surface.code).cgColor
        headerView.layer?.backgroundColor = inspectorHovered ? NSColor(theme.surface.hover).cgColor : nil
        catalogAssignmentTarget(["background", "hover", "border"].map { "component.library.38." + $0 }, name: "File-change preview", theme: theme)
        #else
        layer?.backgroundColor = NSColor(theme.surface.code).cgColor
        #endif
        layer?.borderColor = NSColor(theme.border.default).cgColor
        layer?.borderWidth = theme.stroke.default
        layer?.cornerRadius = theme.radius.medium
        headerDivider.layer?.backgroundColor = NSColor(theme.border.subtle).cgColor
        headerDivider.isHidden = isCollapsed

        iconLabel.font = theme.nsFont(.caption, weight: .semibold, family: .code)
        iconLabel.textColor = NSColor(theme.text.tertiary)

        // Collapsed + still streaming: swap the code glyph for a spinner so the
        // header shows the write is in flight even with the body hidden.
        let showSpinner = isCollapsed && diff.isStreamingPreview
        iconLabel.isHidden = showSpinner
        if showSpinner {
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.stopAnimation(nil)
        }

        // The path argument may not have streamed yet — hold the name slot
        // with a placeholder so the header doesn't render as a bare count.
        fileLabel.stringValue = diff.fileName.isEmpty ? L("Untitled") : diff.fileName
        fileLabel.toolTip = diff.fileName.isEmpty ? nil : diff.fileName
        fileLabel.font = theme.nsFont(.caption, weight: .semibold)
        fileLabel.textColor = NSColor(theme.text.primary)

        let countFont = theme.nsFont(.caption, monospacedDigit: true)
        addedLabel.font = countFont
        removedLabel.font = countFont
        addedLabel.stringValue = diff.addedCount > 0 ? "+\(diff.addedCount)" : ""
        removedLabel.stringValue = diff.removedCount > 0 ? "−\(diff.removedCount)" : ""
        addedLabel.isHidden = diff.addedCount == 0
        removedLabel.isHidden = diff.removedCount == 0
        addedLabel.textColor = NSColor(theme.status.success.foreground)
        removedLabel.textColor = NSColor(theme.status.error.foreground)

        // The spinner already signals streaming; the "…" badge would duplicate it.
        if showSpinner {
            previewBadge.stringValue = ""
            previewBadge.isHidden = true
        } else if diff.isStreamingPreview || diff.isPreview {
            previewBadge.stringValue = diff.isStreamingPreview ? "…" : L("Preview")
            previewBadge.font = theme.nsFont(.micro, weight: .medium)
            previewBadge.textColor = NSColor(theme.text.tertiary)
            previewBadge.isHidden = false
        } else {
            previewBadge.stringValue = ""
            previewBadge.isHidden = true
        }

        copyButton.contentTintColor = NSColor(theme.text.tertiary)
        collapseButton.contentTintColor = NSColor(theme.text.tertiary)
    }

    private func updateCollapseChevron(theme: any ThemeProtocol) {
        let symbol = isCollapsed ? "chevron.right" : "chevron.down"
        collapseButton.image = SymbolImageCache.image(symbol, accessibilityDescription: nil)
        collapseButton.contentTintColor = NSColor(theme.text.tertiary)
    }

    private func applyDiffText(to tv: CodeNSTextView, diff: FileDiff, theme: any ThemeProtocol) {
        let font = theme.nsFont(.code)
        let para = theme.paragraphStyle(.code, lineBreakMode: .byCharWrapping)

        let body = NSMutableAttributedString(attributedString: highlightedBody(diff: diff, theme: theme, font: font, paragraphStyle: para))
        #if OSAURUS_DESIGN_SYSTEM
        body.addAttribute(.kern, value: theme.assignedTracking(NativeComponentInspectionStyle.key(38, "code")) ?? 0, range: NSRange(location: 0, length: body.length))
        #endif
        tv.textStorage?.setAttributedString(body)

        diffBackground?.lineKinds = diff.lines.map(\.kind)
        diffBackground?.markerFont = font
        diffBackground?.addedBackground = NSColor(theme.status.success.foreground).withAlphaComponent(0.14)
        diffBackground?.removedBackground = NSColor(theme.status.error.foreground).withAlphaComponent(0.14)
        diffBackground?.addedBar = NSColor(theme.status.success.foreground).withAlphaComponent(0.6)
        diffBackground?.removedBar = NSColor(theme.status.error.foreground).withAlphaComponent(0.6)
    }

    /// Builds the body text. When a language is known, the hunk is syntax-
    /// highlighted as one document (preserving multi-line token context) and our
    /// monospaced font + char-wrap paragraph style are overlaid on top of the
    /// highlighter's foreground colors. Falls back to flat coloring otherwise.
    private func highlightedBody(
        diff: FileDiff,
        theme: any ThemeProtocol,
        font: NSFont,
        paragraphStyle para: NSParagraphStyle
    ) -> NSAttributedString {
        let fullText = diff.lines.map(\.text).joined(separator: "\n")
        let fullRange = NSRange(location: 0, length: (fullText as NSString).length)

        // While the card is live-streaming, re-highlighting the whole document
        // on every arg fragment is wasted work — use the flat path and let the
        // final card (isStreamingPreview == false) do the one real pass.
        if !diff.isStreamingPreview,
            let language = diff.language,
            let highlighted = highlightCode(fullText, language: language, theme: theme)
        {
            let body = NSMutableAttributedString(attributedString: highlighted)
            // Highlightr can append a trailing newline; trim anything past the
            // source length so line indices stay aligned with `lineKinds`.
            if body.length > fullRange.length {
                body.deleteCharacters(
                    in: NSRange(location: fullRange.length, length: body.length - fullRange.length)
                )
            }
            // Only trust positional attributes if the characters are unchanged.
            if body.length == fullRange.length, body.string == fullText {
                // Override font (Highlightr ships its own) so all lines share one
                // fixed advance — required for the diff to stay column-aligned —
                // and pin the wrapping style, keeping per-token foreground colors.
                body.addAttribute(.font, value: font, range: fullRange)
                body.addAttribute(.paragraphStyle, value: para, range: fullRange)
                return body
            }
        }

        // Plain fallback: meta lines dimmed, everything else primary text.
        let body = NSMutableAttributedString()
        for (idx, line) in diff.lines.enumerated() {
            let color = line.kind == .meta ? NSColor(theme.text.tertiary) : NSColor(theme.text.primary)
            let text = idx == diff.lines.count - 1 ? line.text : line.text + "\n"
            body.append(
                NSAttributedString(
                    string: text,
                    attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para]
                )
            )
        }
        return body
    }

    private func bodyTextWidth(forCardWidth cardWidth: CGFloat) -> CGFloat {
        cardWidth - metric("padding", Self.textInsetLeft) - DiffBackgroundView.markerWidth
            - metric("padding", Self.textInsetRight)
    }

    private func layoutBody(width: CGFloat, collapsed: Bool, theme: any ThemeProtocol) {
        guard let tv = diffTextView, let tc = tv.textContainer, let lm = tv.layoutManager else {
            return
        }
        tv.isHidden = collapsed
        diffBackground?.isHidden = collapsed
        if collapsed {
            bodyHeightConstraint?.constant = 0
            invalidateIntrinsicContentSize()
            onHeightChanged?()
            return
        }
        let innerW = max(1, bodyTextWidth(forCardWidth: width))
        tc.containerSize = NSSize(width: innerW, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let h = ceil(lm.usedRect(for: tc).height)
        bodyHeightConstraint?.constant = h
        diffBackground?.needsDisplay = true
        invalidateIntrinsicContentSize()
        onHeightChanged?()
    }

    override var intrinsicContentSize: NSSize {
        let bodyH = isCollapsed ? 0 : (metric("padding", Self.textInsetTop) + (bodyHeightConstraint?.constant ?? 0) + metric("padding", Self.textInsetBottom))
        return NSSize(width: NSView.noIntrinsicMetric, height: assignedHeaderHeight + bodyH)
    }

    // MARK: - Hover (copy button visibility)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        inspectorHovered = true
        #if OSAURUS_DESIGN_SYSTEM
        if let theme = lastTheme { headerView.layer?.backgroundColor = NSColor(theme.surface.hover).cgColor }
        #endif
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = ThemeManager.shared.currentTheme.motion.quickInterval
            copyButton.animator().alphaValue = 1
            collapseButton.animator().alphaValue = 1
            viewButton.animator().alphaValue = 1
            revertButton.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        inspectorHovered = false
        #if OSAURUS_DESIGN_SYSTEM
        headerView.layer?.backgroundColor = nil
        #endif
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = ThemeManager.shared.currentTheme.motion.quickInterval
            copyButton.animator().alphaValue = 0.55
            collapseButton.animator().alphaValue = 0.55
            viewButton.animator().alphaValue = 0.55
            revertButton.animator().alphaValue = 0.75
        }
    }

    // MARK: - Actions

    @objc private func toggleCollapse() {
        // Notify the coordinator only — it flips the shared expand store and
        // reconfigures this cell, which re-lays-out and re-measures. Mirrors the
        // tool-call group's toggle exactly (no local synchronous relayout, which
        // re-entered table layout from inside the button action).
        onToggleCollapse?()
    }

    @objc private func copyDiff() {
        guard let diff = lastDiff else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diff.rawDiff, forType: .string)
        copyButton.image = SymbolImageCache.image("checkmark", accessibilityDescription: nil)
        #if OSAURUS_DESIGN_SYSTEM
        copyButton.contentTintColor = lastTheme.map { NSColor($0.status.success.foreground) } ?? .systemGreen
        #else
        copyButton.contentTintColor = .systemGreen
        #endif
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.copyButton.image = SymbolImageCache.image("doc.on.doc", accessibilityDescription: nil)
            #if OSAURUS_DESIGN_SYSTEM
            self.copyButton.contentTintColor = self.lastTheme.map { NSColor($0.text.tertiary) }
            #else
            self.copyButton.contentTintColor = nil
            #endif
        }
    }

    // MARK: - File history

    private func refreshHistoryState() {
        guard let setId = historySetId else { return }
        Task { @MainActor [weak self] in
            let journal = FileChangeJournal.shared
            let set = await journal.changeSet(id: setId)
            let undo: FileChangeSet?
            if let set {
                undo = await journal.activeRevert(of: setId, sessionId: set.sessionId)
            } else {
                undo = nil
            }
            guard let self, self.historySetId == setId else { return }
            self.historySessionId = set?.sessionId
            self.historyStatus = set?.status
            self.historyUndoSetId = undo?.id
            if let theme = self.lastTheme { self.applyHistoryControls(theme: theme) }
        }
    }

    private func applyHistoryControls(theme: any ThemeProtocol) {
        guard historySetId != nil, historySessionId != nil, let status = historyStatus else {
            historyStack.isHidden = true
            return
        }
        historyStack.isHidden = false
        let captionFont = theme.nsFont(.footnote, weight: .medium)

        let badge: String?
        switch status {
        case .reverted: badge = L("Reverted")
        case .partiallyReverted: badge = L("Partly reverted")
        case .untracked: badge = L("Not tracked")
        default: badge = nil
        }
        historyBadge.stringValue = badge ?? ""
        historyBadge.isHidden = badge == nil
        historyBadge.font = captionFont
        historyBadge.textColor = NSColor(theme.text.tertiary)

        let title: String?
        if status == .reverted {
            title = historyUndoSetId == nil ? nil : L("Undo")
        } else if status == .applied || status == .partiallyReverted {
            title = L("Revert")
        } else {
            title = nil
        }
        revertButton.isHidden = title == nil
        revertButton.isEnabled = !historyBusy
        if let title {
            revertButton.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: captionFont, .foregroundColor: NSColor(theme.text.secondary)]
            )
            revertButton.toolTip =
                status == .reverted
                ? L("Put this change back")
                : L("Restore the file to how it was before this change")
        }
        viewButton.contentTintColor = NSColor(theme.text.tertiary)
        NativeComponentInspectionStyle.label(historyBadge, family: 38, property: "caption", theme: theme)
        #if OSAURUS_DESIGN_SYSTEM
        let actionTheme = theme.catalogFamily(38, enabled: revertButton.isEnabled, authoritative: true)
        revertButton.contentTintColor = NSColor(actionTheme.text.secondary)
        #endif
        NativeComponentInspectionStyle.button(revertButton, family: 38, property: "label", theme: theme.catalogFamily(38, enabled: revertButton.isEnabled, authoritative: true))
    }

    @objc private func openInPanel() {
        guard let setId = historySetId, let sessionId = historySessionId else { return }
        FileChangeSummaryStore.requestPanel(sessionId: sessionId, focusing: setId)
    }

    @objc private func revertOrUndo() {
        guard !historyBusy, let setId = historySetId, let sessionId = historySessionId else { return }
        historyBusy = true
        revertButton.isEnabled = false
        let undoSetId = historyStatus == .reverted ? historyUndoSetId : nil
        Task { @MainActor [weak self] in
            let journal = FileChangeJournal.shared
            let scope: FileChangeJournal.RevertScope = .set(undoSetId ?? setId)
            // Anything that needs a decision (files edited since, snapshots
            // unavailable) goes through the inspector's confirmation flow.
            let preview = await journal.previewRevert(scope, sessionId: sessionId)
            var needsPanel = preview.conflictCount > 0 || preview.unrestorableCount > 0
            if !needsPanel {
                let summary = await journal.revert(scope, sessionId: sessionId)
                needsPanel = !summary.isClean
            }
            guard let self else { return }
            self.historyBusy = false
            if needsPanel { self.openInPanel() }
            self.refreshHistoryState()
        }
    }
}
