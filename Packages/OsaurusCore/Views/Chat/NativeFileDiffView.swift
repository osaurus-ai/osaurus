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
                layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
                    let local = self.convert(rect, from: tv)
                    guard local.maxY >= dirtyRect.minY, local.minY <= dirtyRect.maxY else { return }
                    bg.setFill()
                    NSRect(x: 0, y: local.origin.y, width: fullWidth, height: local.height).fill()
                    bar.setFill()
                    NSRect(x: 0, y: local.origin.y, width: 3, height: local.height).fill()
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

    /// Left text inset leaves room past the 3pt accent bar.
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
    private let fileLabel = NSTextField(labelWithString: "")
    private let addedLabel = NSTextField(labelWithString: "")
    private let removedLabel = NSTextField(labelWithString: "")
    private let previewBadge = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let collapseButton = NSButton()
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
    private var lastWidth: CGFloat = 0
    private var lastThemeId = ""
    private var isCollapsed = false
    private var copyResetTask: Task<Void, Never>?

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Configure

    func configure(diff: FileDiff, collapsed: Bool, width: CGFloat, theme: any ThemeProtocol) {
        let themeId = "\(theme.monoFontName)|\(theme.codeSize)|\(theme.isDark)"
        // Only the expensive syntax-highlight pass is gated; header styling and
        // layout always run so every reconfigure reports an accurate height —
        // an early return here let the row get stuck after a few toggles when a
        // SwiftUI update wiped the height cache without a fresh measurement.
        let diffChanged = diff != lastDiff
        let themeChanged = themeId != lastThemeId

        lastDiff = diff
        lastWidth = width
        lastThemeId = themeId
        isCollapsed = collapsed

        applyHeaderStyling(diff: diff, theme: theme)
        updateCollapseChevron(theme: theme)

        let tv = ensureTextView(theme: theme)
        if diffChanged || themeChanged {
            applyDiffText(to: tv, diff: diff, theme: theme)
        }
        layoutBody(width: width, collapsed: collapsed, theme: theme)
    }

    /// TextKit-only height for the cell's height cache — never calls
    /// `layoutSubtreeIfNeeded()` (re-entering AppKit layout mid-reconfigure is
    /// what the chart / tool-group height paths guard against). Uses the view's
    /// own `isCollapsed` so a local toggle reports the correct height without the
    /// caller threading a (potentially stale) collapsed flag.
    func measuredCardHeight(outerWidth: CGFloat) -> CGFloat {
        if isCollapsed { return Self.headerHeight }
        guard let tv = diffTextView, let tc = tv.textContainer, let lm = tv.layoutManager else {
            return Self.headerHeight + 40
        }
        let innerW = max(1, bodyTextWidth(forOuterWidth: outerWidth))
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
        return Self.headerHeight + Self.textInsetTop + max(textH, 1) + Self.textInsetBottom
    }

    // MARK: - Private: Build

    private func buildViews() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.masksToBounds = true

        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.wantsLayer = true
        addSubview(headerView)

        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        iconLabel.isEditable = false
        iconLabel.isBordered = false
        iconLabel.drawsBackground = false
        headerView.addSubview(iconLabel)

        for label in [fileLabel, addedLabel, removedLabel, previewBadge] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            headerView.addSubview(label)
        }
        fileLabel.lineBreakMode = .byTruncatingMiddle

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
            headerButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor),
        ])

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            iconLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 10),
            iconLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            fileLabel.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 7),
            fileLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            addedLabel.leadingAnchor.constraint(equalTo: fileLabel.trailingAnchor, constant: 8),
            addedLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            removedLabel.leadingAnchor.constraint(equalTo: addedLabel.trailingAnchor, constant: 5),
            removedLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            previewBadge.leadingAnchor.constraint(equalTo: removedLabel.trailingAnchor, constant: 8),
            previewBadge.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            previewBadge.trailingAnchor.constraint(
                lessThanOrEqualTo: copyButton.leadingAnchor,
                constant: -8
            ),

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
        tv.selectedTextAttributes = [.backgroundColor: NSColor(theme.selectionColor)]
        addSubview(tv)
        bgView.textView = tv

        let hc = tv.heightAnchor.constraint(equalToConstant: 0)
        hc.isActive = true
        bodyHeightConstraint = hc

        NSLayoutConstraint.activate([
            tv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInsetLeft),
            tv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.textInsetRight),
            tv.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: Self.textInsetTop),

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
        let bgColor = highlightrThemeBackgroundNSColor()
        layer?.backgroundColor = bgColor.cgColor
        layer?.borderColor =
            NSColor(theme.primaryBorder)
            .withAlphaComponent(theme.borderOpacity).cgColor
        headerView.layer?.backgroundColor = bgColor.withAlphaComponent(0.6).cgColor

        iconLabel.font = NSFont.monospacedSystemFont(
            ofSize: CGFloat(theme.captionSize),
            weight: .semibold
        )
        iconLabel.textColor = NSColor(theme.tertiaryText)

        fileLabel.stringValue = diff.fileName
        fileLabel.font = NSFont.systemFont(ofSize: CGFloat(theme.captionSize), weight: .semibold)
        fileLabel.textColor = NSColor(theme.primaryText)

        let countFont = NSFont.monospacedDigitSystemFont(
            ofSize: CGFloat(theme.captionSize) - 1,
            weight: .medium
        )
        addedLabel.font = countFont
        removedLabel.font = countFont
        addedLabel.stringValue = diff.addedCount > 0 ? "+\(diff.addedCount)" : ""
        removedLabel.stringValue = diff.removedCount > 0 ? "−\(diff.removedCount)" : ""
        addedLabel.textColor = NSColor(theme.successColor)
        removedLabel.textColor = NSColor(theme.errorColor)

        if diff.isPreview {
            previewBadge.stringValue = L("preview")
            previewBadge.font = NSFont.systemFont(ofSize: CGFloat(theme.captionSize) - 2, weight: .medium)
            previewBadge.textColor = NSColor(theme.tertiaryText)
            previewBadge.isHidden = false
        } else {
            previewBadge.stringValue = ""
            previewBadge.isHidden = true
        }

        copyButton.contentTintColor = NSColor(theme.tertiaryText)
        collapseButton.contentTintColor = NSColor(theme.tertiaryText)
    }

    private func updateCollapseChevron(theme: any ThemeProtocol) {
        let symbol = isCollapsed ? "chevron.right" : "chevron.down"
        collapseButton.image = SymbolImageCache.image(symbol, accessibilityDescription: nil)
        collapseButton.contentTintColor = NSColor(theme.tertiaryText)
    }

    private func applyDiffText(to tv: CodeNSTextView, diff: FileDiff, theme: any ThemeProtocol) {
        let fontSize = max(10, CGFloat(theme.codeSize) - 1)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byCharWrapping

        tv.textStorage?.setAttributedString(
            highlightedBody(diff: diff, theme: theme, font: font, paragraphStyle: para)
        )

        diffBackground?.lineKinds = diff.lines.map(\.kind)
        diffBackground?.addedBackground = NSColor(theme.successColor).withAlphaComponent(0.14)
        diffBackground?.removedBackground = NSColor(theme.errorColor).withAlphaComponent(0.14)
        diffBackground?.addedBar = NSColor(theme.successColor).withAlphaComponent(0.6)
        diffBackground?.removedBar = NSColor(theme.errorColor).withAlphaComponent(0.6)
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

        if let language = diff.language,
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
            let color = line.kind == .meta ? NSColor(theme.tertiaryText) : NSColor(theme.primaryText)
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

    private func bodyTextWidth(forOuterWidth outerWidth: CGFloat) -> CGFloat {
        // Card spans the cell minus 16pt insets on each side (see configureAsFileDiff);
        // the text view is further inset by the left/right insets.
        let cardWidth = outerWidth - 32
        return cardWidth - Self.textInsetLeft - Self.textInsetRight
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
        let innerW = max(1, bodyTextWidth(forOuterWidth: width))
        tc.containerSize = NSSize(width: innerW, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let h = ceil(lm.usedRect(for: tc).height)
        bodyHeightConstraint?.constant = h
        diffBackground?.needsDisplay = true
        invalidateIntrinsicContentSize()
        onHeightChanged?()
    }

    override var intrinsicContentSize: NSSize {
        let bodyH = isCollapsed ? 0 : (Self.textInsetTop + (bodyHeightConstraint?.constant ?? 0) + Self.textInsetBottom)
        return NSSize(width: NSView.noIntrinsicMetric, height: Self.headerHeight + bodyH)
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
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            copyButton.animator().alphaValue = 1
            collapseButton.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            copyButton.animator().alphaValue = 0.55
            collapseButton.animator().alphaValue = 0.55
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
        copyButton.contentTintColor = .systemGreen
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.copyButton.image = SymbolImageCache.image("doc.on.doc", accessibilityDescription: nil)
            self.copyButton.contentTintColor = nil
        }
    }
}
