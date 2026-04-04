//
//  NativeMessageCellView.swift
//  osaurus
//
//  NSTableCellView subclass — pure AppKit rendering for all block types
//  (preflight chips: NativePreflightCapabilitiesView).
//

import AppKit
import QuartzCore

// MARK: - Cell Rendering Context

/// Passed to NativeMessageCellView.configure() — bundles all rendering inputs.
struct CellRenderingContext {
    let width: CGFloat
    let agentName: String
    let isStreaming: Bool
    let lastAssistantTurnId: UUID?
    let theme: any ThemeProtocol
    /// mutable so `configureCell` can override with coordinator `expandedIds` before `applyBlocks` runs again
    var expandedIds: Set<String>
    let onToggleExpand: (String) -> Void
    /// Called by native views after they've measured their own height.
    /// Coordinator updates heightCache and calls noteHeightOfRows if delta > 2pt.
    var onHeightMeasured: ((CGFloat, String) -> Void)? = nil
    var isTurnHovered: Bool = false
    var editingTurnId: UUID? = nil
    var editText: (() -> String, (String) -> Void)? = nil
    var onConfirmEdit: (() -> Void)? = nil
    var onCancelEdit: (() -> Void)? = nil
    var onCopy: ((UUID) -> Void)? = nil
    var onRegenerate: ((UUID) -> Void)? = nil
    var onEdit: ((UUID) -> Void)? = nil
    var onDelete: ((UUID) -> Void)? = nil
    /// attachment or shared-artifact id string → full screen preview from ChatView
    var onUserImagePreview: ((String) -> Void)? = nil
}

// MARK: - Cell-Isolated ExpandedBlocksStore Proxy

// MARK: - Native Header View

/// Pure AppKit header row: name label + hover-revealed action buttons.
final class NativeHeaderView: NSView {

    private let nameLabel = NSTextField(labelWithString: "")
    private let editingBadge = NSTextField(labelWithString: "Editing")
    private let actionStack = NSStackView()
    private var isEditing = false

    private var turnId: UUID = UUID()
    private var onCopy: ((UUID) -> Void)?
    private var onRegenerate: ((UUID) -> Void)?
    private var onEdit: ((UUID) -> Void)?
    private var onDelete: ((UUID) -> Void)?
    private var storedOnCancelEdit: (() -> Void)?
    private var currentRole: MessageRole = .assistant
    private var currentTheme: (any ThemeProtocol)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.isSelectable = true
        nameLabel.maximumNumberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        editingBadge.translatesAutoresizingMaskIntoConstraints = false
        editingBadge.isSelectable = true
        editingBadge.isHidden = true
        addSubview(editingBadge)

        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.orientation = .horizontal
        actionStack.spacing = 4
        actionStack.alignment = .centerY
        // `.fill` stretches subviews on the cross axis to the stack height; that breaks square chips.
        actionStack.distribution = .equalSpacing
        actionStack.alphaValue = 0
        addSubview(actionStack)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            editingBadge.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            editingBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(
        turnId: UUID,
        role: MessageRole,
        name: String,
        isEditing: Bool,
        isHovered: Bool,
        theme: any ThemeProtocol,
        onCopy: ((UUID) -> Void)?,
        onRegenerate: ((UUID) -> Void)?,
        onEdit: ((UUID) -> Void)?,
        onDelete: ((UUID) -> Void)?,
        onCancelEdit: (() -> Void)?
    ) {
        self.turnId = turnId
        self.isEditing = isEditing
        self.onCopy = onCopy
        self.onRegenerate = onRegenerate
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.storedOnCancelEdit = onCancelEdit
        self.currentRole = role
        self.currentTheme = theme

        nameLabel.stringValue = name
        nameLabel.font = NSFont.systemFont(ofSize: CGFloat(theme.captionSize) + 1, weight: .semibold)
        nameLabel.textColor = role == .user ? NSColor(theme.accentColor) : NSColor(theme.secondaryText)

        editingBadge.stringValue = "Editing"
        editingBadge.font = NSFont.systemFont(ofSize: CGFloat(theme.captionSize) - 1, weight: .medium)
        editingBadge.textColor = NSColor(theme.accentColor).withAlphaComponent(0.7)
        editingBadge.isHidden = !isEditing

        rebuildActionButtons(role: role, theme: theme, onCancelEdit: onCancelEdit)
        setHovered(isHovered, animated: false)
    }

    func setHovered(_ hovered: Bool, animated: Bool = true) {
        let alpha: CGFloat = (hovered || isEditing) ? 1 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                actionStack.animator().alphaValue = alpha
            }
        } else {
            actionStack.alphaValue = alpha
        }
    }

    private func rebuildActionButtons(role: MessageRole, theme: any ThemeProtocol, onCancelEdit: (() -> Void)?) {
        for v in actionStack.arrangedSubviews {
            actionStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        addBtn(icon: "doc.on.doc", help: "Copy", theme: theme, tint: nil) { [weak self] in
            guard let self else { return }
            self.onCopy?(self.turnId)
        }

        if role == .assistant {
            addBtn(icon: "arrow.counterclockwise", help: "Regenerate", theme: theme, tint: nil) { [weak self] in
                guard let self else { return }
                self.onRegenerate?(self.turnId)
            }
        } else {
            addBtn(icon: "pencil", help: "Edit", theme: theme, tint: nil) { [weak self] in
                guard let self else { return }
                self.onEdit?(self.turnId)
            }
            addBtn(icon: "trash", help: "Delete", theme: theme, tint: nil) { [weak self] in
                guard let self else { return }
                self.onDelete?(self.turnId)
            }
        }

        if isEditing, let onCancelEdit {
            addBtn(icon: "xmark", help: "Cancel edit", theme: theme, tint: nil, action: onCancelEdit)
        }
    }

    private static let actionButtonSize: CGFloat = 28

    private func addBtn(
        icon: String,
        help: String,
        theme: any ThemeProtocol,
        tint: NSColor?,
        action: @escaping () -> Void
    ) {
        let control = HeaderCircleActionControl(action: action)
        let pointSize = CGFloat(theme.captionSize) - 1
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        control.setSymbol(
            NSImage(systemSymbolName: icon, accessibilityDescription: help)?.withSymbolConfiguration(cfg),
            toolTip: help,
            theme: theme,
            iconTint: tint
        )
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .vertical)
        NSLayoutConstraint.activate([
            control.widthAnchor.constraint(equalToConstant: Self.actionButtonSize),
            control.heightAnchor.constraint(equalToConstant: Self.actionButtonSize),
        ])
        actionStack.addArrangedSubview(control)
    }
}

// MARK: - Circular header action buttons (matches SwiftUI `HeaderBlockContent` / `ActionButton`)

/// `NSButton`’s cell/layer often disagree with `bounds`, producing non-circular backgrounds; draw the
/// chrome on a plain `NSView` and keep a borderless `NSButton` for hit-testing and keyboard focus.
private final class HeaderCircleActionControl: NSView {
    private let button: NSButton
    private let block: () -> Void
    private var fillBase: NSColor = .clear
    private var fillHover: NSColor = .clear
    private var tracking: NSTrackingArea?

    init(action: @escaping () -> Void) {
        self.block = action
        let btn = NSButton(frame: .zero)
        self.button = btn
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true

        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.target = self
        btn.action = #selector(fire)
        btn.isBordered = false
        btn.bezelStyle = .inline
        btn.focusRingType = .none
        btn.imagePosition = .imageOnly
        btn.imageScaling = .scaleProportionallyDown
        btn.wantsLayer = false
        addSubview(btn)
        NSLayoutConstraint.activate([
            btn.leadingAnchor.constraint(equalTo: leadingAnchor),
            btn.trailingAnchor.constraint(equalTo: trailingAnchor),
            btn.topAnchor.constraint(equalTo: topAnchor),
            btn.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ image: NSImage?, toolTip: String, theme: any ThemeProtocol, iconTint: NSColor?) {
        button.image = image
        button.toolTip = toolTip
        button.contentTintColor = iconTint ?? NSColor(theme.tertiaryText)
        let secondary = NSColor(theme.secondaryBackground)
        fillBase = secondary.withAlphaComponent(0.8)
        fillHover = secondary.withAlphaComponent(0.95)
        layer?.backgroundColor = fillBase.cgColor
    }

    override func layout() {
        super.layout()
        layer?.frame = bounds
        let side = min(bounds.width, bounds.height)
        layer?.cornerRadius = side > 0 ? side / 2 : 0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        tracking = ta
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        layer?.backgroundColor = fillHover.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        layer?.backgroundColor = fillBase.cgColor
    }

    @objc private func fire() { block() }
}

// MARK: - Padded inline edit buttons

/// Insets image/title layout so borderless buttons don’t hug the layer edge; extra gap after the icon.
private final class PaddedInlineButtonCell: NSButtonCell {
    var horizontalPadding: CGFloat = 14
    var verticalPadding: CGFloat = 2
    /// additional space between SF Symbol and title (beyond default cell spacing)
    var imageTitleSpacing: CGFloat = 6

    override init(textCell string: String) {
        super.init(textCell: string)
        setButtonType(.momentaryPushIn)
    }

    required init(coder: NSCoder) {
        fatalError()
    }

    private func insetBounds(_ rect: NSRect) -> NSRect {
        rect.insetBy(dx: horizontalPadding, dy: verticalPadding)
    }

    override func imageRect(forBounds rect: NSRect) -> NSRect {
        super.imageRect(forBounds: insetBounds(rect))
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var r = super.titleRect(forBounds: insetBounds(rect))
        if image != nil {
            r.origin.x += imageTitleSpacing
        }
        return r
    }

    override func cellSize(forBounds rect: NSRect) -> NSSize {
        var s = super.cellSize(forBounds: rect)
        s.width += horizontalPadding * 2
        s.height += verticalPadding * 2
        if image != nil {
            s.width += imageTitleSpacing
        }
        return s
    }
}

private final class PaddedInlineButton: NSButton {
    private let paddedButtonCell: PaddedInlineButtonCell

    fileprivate var paddedCell: PaddedInlineButtonCell { paddedButtonCell }

    override init(frame frameRect: NSRect) {
        let buttonCell = PaddedInlineButtonCell(textCell: "")
        buttonCell.bezelStyle = .rounded
        buttonCell.isBordered = false
        self.paddedButtonCell = buttonCell
        super.init(frame: frameRect)
        cell = buttonCell
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - UserMessageInlineEditView

/// AppKit counterpart to SwiftUI `InlineEditView` — editable plain text plus Cancel / Save & Regenerate.
private final class UserMessageInlineEditView: NSView, NSTextViewDelegate {

    private let scrollView = AutoSizingScrollView()
    private let textView: CustomNSTextView
    private let editBox = NSView()
    private let buttonStack = NSStackView()
    private var cancelButton: PaddedInlineButton!
    private var confirmButton: PaddedInlineButton!

    private var getText: () -> String = { "" }
    private var setText: (String) -> Void = { _ in }
    private var onConfirm: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var onHeightChanged: (() -> Void) = {}

    private var lastTheme: (any ThemeProtocol)?
    private var didApplyInitialFocus = false

    override init(frame frameRect: NSRect) {
        let tv = CustomNSTextView()
        tv.maxHeight = 240
        tv.focusRingType = .none
        tv.isRichText = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = NSSize(width: 8, height: 6)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        self.textView = tv
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        textView.delegate = self

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.focusRingType = .none
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        editBox.wantsLayer = true
        editBox.translatesAutoresizingMaskIntoConstraints = false

        buttonStack.orientation = .horizontal
        buttonStack.spacing = 0
        buttonStack.alignment = .centerY
        buttonStack.distribution = .fill
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // isolate cancel + confirm from the leading spacer so `.fill` cannot widen only the CTA
        let buttonPair = NSStackView()
        buttonPair.orientation = .horizontal
        buttonPair.spacing = 8
        buttonPair.alignment = .centerY
        buttonPair.distribution = .fillProportionally
        buttonPair.translatesAutoresizingMaskIntoConstraints = false
        buttonPair.setContentHuggingPriority(.required, for: .horizontal)
        buttonPair.setContentCompressionResistancePriority(.required, for: .horizontal)

        cancelButton = PaddedInlineButton(frame: .zero)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.bezelStyle = .rounded
        cancelButton.isBordered = false
        cancelButton.wantsLayer = true
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []

        confirmButton = PaddedInlineButton(frame: .zero)
        confirmButton.target = self
        confirmButton.action = #selector(confirmTapped)
        confirmButton.bezelStyle = .rounded
        confirmButton.isBordered = false
        confirmButton.wantsLayer = true
        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        confirmButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        confirmButton.imagePosition = .imageLeading

        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
        confirmButton.setContentHuggingPriority(.required, for: .horizontal)
        cancelButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        confirmButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(editBox)
        editBox.addSubview(scrollView)
        addSubview(buttonStack)
        buttonPair.addArrangedSubview(cancelButton)
        buttonPair.addArrangedSubview(confirmButton)
        buttonStack.addArrangedSubview(spacer)
        buttonStack.addArrangedSubview(buttonPair)

        NSLayoutConstraint.activate([
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            confirmButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
        ])

        NSLayoutConstraint.activate([
            editBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            editBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            editBox.topAnchor.constraint(equalTo: topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: editBox.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: editBox.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: editBox.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: editBox.bottomAnchor),

            buttonStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttonStack.topAnchor.constraint(equalTo: editBox.bottomAnchor, constant: 10),
            buttonStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(
        theme: any ThemeProtocol,
        getText: @escaping () -> String,
        setText: @escaping (String) -> Void,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onHeightChanged: @escaping () -> Void
    ) {
        self.getText = getText
        self.setText = setText
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.onHeightChanged = onHeightChanged
        lastTheme = theme

        let radius = CGFloat(theme.inputCornerRadius)
        editBox.layer?.cornerRadius = radius
        editBox.layer?.backgroundColor = NSColor(theme.primaryBackground).cgColor
        editBox.layer?.borderWidth = CGFloat(theme.defaultBorderWidth)
        editBox.layer?.borderColor = NSColor(theme.accentColor).withAlphaComponent(theme.borderOpacity + 0.2).cgColor

        let body = CGFloat(theme.bodySize)
        textView.font = .systemFont(ofSize: body)
        textView.textColor = NSColor(theme.primaryText)
        textView.insertionPointColor = NSColor(theme.accentColor)

        if textView.string != getText() {
            textView.string = getText()
            textView.invalidateIntrinsicContentSize()
            scrollView.invalidateIntrinsicContentSize()
        }

        refreshScrollerVisibility()
        updateConfirmButtons(theme: theme)

        if !didApplyInitialFocus {
            didApplyInitialFocus = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.textView.window?.makeFirstResponder(self.textView)
                self.refreshScrollerVisibility()
                self.onHeightChanged()
            }
        }

        onHeightChanged()
    }

    private func refreshScrollerVisibility() {
        if let tc = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: tc)
        }
        let maxH = textView.maxHeight
        let needsScroller = textView.contentHeight > maxH + 0.5
        if scrollView.hasVerticalScroller != needsScroller {
            scrollView.hasVerticalScroller = needsScroller
            scrollView.invalidateIntrinsicContentSize()
        }
        scrollView.tile()
    }

    /// Matches ContentBlockView.InlineEditView — Cancel secondary chrome; Save accent + white when non-empty.
    private func updateConfirmButtons(theme: any ThemeProtocol) {
        let empty = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        confirmButton.isEnabled = !empty
        let cap = CGFloat(theme.captionSize)

        cancelButton.layer?.masksToBounds = true
        confirmButton.layer?.masksToBounds = true

        cancelButton.layer?.cornerRadius = 6
        cancelButton.layer?.backgroundColor = NSColor(theme.secondaryBackground).cgColor
        cancelButton.layer?.borderWidth = CGFloat(theme.defaultBorderWidth)
        cancelButton.layer?.borderColor = NSColor(theme.primaryBorder).withAlphaComponent(theme.borderOpacity).cgColor
        cancelButton.attributedTitle = NSAttributedString(
            string: "Cancel",
            attributes: [
                .foregroundColor: NSColor(theme.secondaryText),
                .font: NSFont.systemFont(ofSize: cap, weight: .medium),
            ]
        )

        confirmButton.layer?.cornerRadius = 6
        if let sym = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: cap - 1, weight: .semibold)
            confirmButton.image = sym.withSymbolConfiguration(config) ?? sym
        }
        confirmButton.imagePosition = .imageLeading

        if empty {
            confirmButton.layer?.backgroundColor = NSColor(theme.secondaryBackground).cgColor
            confirmButton.attributedTitle = NSAttributedString(
                string: "Save & Regenerate",
                attributes: [
                    .foregroundColor: NSColor(theme.secondaryText),
                    .font: NSFont.systemFont(ofSize: cap, weight: .semibold),
                ]
            )
            confirmButton.contentTintColor = NSColor(theme.secondaryText)
        } else {
            confirmButton.layer?.backgroundColor = NSColor(theme.accentColor).cgColor
            confirmButton.attributedTitle = NSAttributedString(
                string: "Save & Regenerate",
                attributes: [
                    .foregroundColor: NSColor.white,
                    .font: NSFont.systemFont(ofSize: cap, weight: .semibold),
                ]
            )
            confirmButton.contentTintColor = .white
        }

        let padH = max(12, cap + 4)
        let padV: CGFloat = 2
        let imageGap = max(4, cap * 0.35)
        for btn in [cancelButton, confirmButton] {
            btn?.paddedCell.horizontalPadding = padH
            btn?.paddedCell.verticalPadding = padV
            btn?.invalidateIntrinsicContentSize()
        }
        confirmButton.paddedCell.imageTitleSpacing = imageGap
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    @objc private func confirmTapped() {
        guard !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onConfirm?()
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView, tv === textView else { return }
        setText(tv.string)
        tv.invalidateIntrinsicContentSize()
        scrollView.invalidateIntrinsicContentSize()
        refreshScrollerVisibility()
        if let theme = lastTheme {
            updateConfirmButtons(theme: theme)
        }
        onHeightChanged()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
                return false
            }
            confirmTapped()
            return true
        }
        return false
    }
}

// MARK: - NativeMessageCellView

final class NativeMessageCellView: NSTableCellView {

    // MARK: Subviews

    private var spacerView: NSView?
    private var nativeHeaderView: NativeHeaderView?

    // Native views (no NSHostingView)
    private var nativeMarkdownView: NativeMarkdownView?
    private var nativeThinkingView: NativeThinkingView?
    private var nativeToolCallGroupView: NativeToolCallGroupView?
    private var userMessageContainer: NSView?
    private var userTextView: NativeMarkdownView?
    private var userInlineEditView: UserMessageInlineEditView?
    private var userImageStack: NSStackView?
    private var nativePendingView: NativePendingToolCallView?
    private var nativeTypingView: NativeTypingIndicatorView?
    private var nativeArtifactView: NativeArtifactCardView?
    private var nativePreflightView: NativePreflightCapabilitiesView?

    /// inset stroke so rounded corners are not clipped by ancestor views
    private var userBubbleBorderLayer: CAShapeLayer?
    private var userBubbleBorderWidth: CGFloat = 0
    private var userBubbleBorderColor: NSColor = .clear
    private var userBubbleCornerRadius: CGFloat = 0

    // MARK: State

    private var currentKindTag: ContentBlockKindTag?
    private var currentBlockId: String?

    /// tracks inline edit vs read-only markdown so we rebuild when edit mode toggles (same block kind)
    private var userMessageInlineEditActive: Bool = false

    /// last width from CellRenderingContext — used for systemLayoutSizeFitting when reporting row height
    private var lastContextWidth: CGFloat = 400

    // MARK: Identity

    static let reuseId = NSUserInterfaceItemIdentifier("NativeMessageCell")

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = false
        wantsLayer = true
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        updateUserBubbleBorderStroke()
    }

    /// Row height from Auto Layout — avoids drift from hand-summed constants vs. actual constraints.
    /// AppKit `NSView` uses `fittingSize` (UIKit’s `systemLayoutSizeFitting` is not available here).
    /// Table view still uses `heightOfRow:` + cache (see MessageTableRepresentable); this only feeds accurate measurements.
    private func measureFittedRowHeight() -> CGFloat {
        // never call layoutSubtreeIfNeeded() here — heightOfRow / onHeightMeasured can run during an active layout pass
        let targetWidth = max(bounds.width > 1 ? bounds.width : lastContextWidth, 100)

        // user message: measure bubble subtree height (container bottom is tied to content, not the cell — see configureAsUserMessage)
        if let container = userMessageContainer {
            var widthPin: NSLayoutConstraint?
            if bounds.width <= 1 {
                let c = widthAnchor.constraint(equalToConstant: targetWidth)
                c.priority = NSLayoutConstraint.Priority.required
                c.isActive = true
                widthPin = c
            }
            defer { widthPin?.isActive = false }
            var h = container.fittingSize.height
            if h < 2, let mv = userTextView {
                let inner = max(lastContextWidth - 32, 100)
                let textW = max(inner - 24, 100)
                let textH = mv.measuredHeight(for: textW)
                h = 38 + textH + 16
            }
            return ceil(max(h, 1))
        }

        var widthPin: NSLayoutConstraint?
        if bounds.width <= 1 {
            let c = widthAnchor.constraint(equalToConstant: targetWidth)
            c.priority = NSLayoutConstraint.Priority.required
            c.isActive = true
            widthPin = c
        }
        defer { widthPin?.isActive = false }
        let h = fittingSize.height
        return ceil(max(h, 1))
    }

    // MARK: Configure

    func configure(block: ContentBlock, context: CellRenderingContext) {
        lastContextWidth = context.width
        let tag = block.kind.kindTag
        let sameKind = tag == currentKindTag
        currentKindTag = tag
        currentBlockId = block.id

        switch block.kind {
        case .groupSpacer:
            configureAsSpacer(sameKind: sameKind)

        case let .header(role, name, _):
            configureAsHeader(block: block, role: role, name: name, context: context, sameKind: sameKind)

        case let .paragraph(_, text, isStreaming, _):
            configureAsParagraph(
                block: block,
                text: text,
                isStreaming: isStreaming,
                context: context,
                sameKind: sameKind
            )

        case let .thinking(_, text, isStreaming):
            configureAsThinking(
                block: block,
                text: text,
                isStreaming: isStreaming,
                context: context,
                sameKind: sameKind
            )

        case let .toolCallGroup(calls):
            configureAsToolCallGroup(block: block, calls: calls, context: context, sameKind: sameKind)

        case let .userMessage(text, attachments):
            configureAsUserMessage(
                block: block,
                text: text,
                attachments: attachments,
                context: context,
                sameKind: sameKind
            )

        case let .pendingToolCall(toolName, argPreview, argSize):
            configureAsPendingToolCall(
                block: block,
                toolName: toolName,
                argPreview: argPreview,
                argSize: argSize,
                context: context,
                sameKind: sameKind
            )

        case .typingIndicator:
            configureAsTypingIndicator(context: context, sameKind: sameKind)

        case let .sharedArtifact(artifact):
            configureAsArtifact(block: block, artifact: artifact, context: context, sameKind: sameKind)

        case let .preflightCapabilities(items):
            configureAsPreflight(block: block, items: items, context: context, sameKind: sameKind)

        default:
            // last resort: no hosted fallback — render a compact unsupported-block placeholder
            configureAsUnsupported(sameKind: sameKind)
        }
    }

    /// Direct hover update on the header row — no SwiftUI re-render needed.
    func setTurnHovered(_ hovered: Bool) {
        nativeHeaderView?.setHovered(hovered)
    }

    // MARK: - Spacer

    private func configureAsSpacer(sameKind: Bool) {
        guard !sameKind || spacerView == nil else { return }
        removeAllContentViews()
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.topAnchor.constraint(equalTo: topAnchor),
            v.heightAnchor.constraint(equalToConstant: 16),
        ])
        spacerView = v
    }

    // MARK: - Header

    private func configureAsHeader(
        block: ContentBlock,
        role: MessageRole,
        name: String,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeHeaderView == nil {
            removeAllContentViews()
            let hv = NativeHeaderView()
            hv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hv)
            let bottomGap = bottomAnchor.constraint(equalTo: hv.bottomAnchor, constant: 12)
            // below required so transient table sizing (e.g. NSView-Encapsulated-Layout-Height) can
            // squeeze the cell without fighting 12 + 28 + 12; row height still comes from the delegate
            bottomGap.priority = .init(999)
            NSLayoutConstraint.activate([
                hv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                hv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                hv.topAnchor.constraint(equalTo: topAnchor, constant: 12),
                hv.heightAnchor.constraint(equalToConstant: 28),
                bottomGap,
            ])
            nativeHeaderView = hv
        }

        let displayName = role == .user ? "You" : (name.isEmpty ? "Assistant" : name)
        nativeHeaderView?.configure(
            turnId: block.turnId,
            role: role,
            name: displayName,
            isEditing: context.editingTurnId == block.turnId,
            isHovered: context.isTurnHovered,
            theme: context.theme,
            onCopy: context.onCopy,
            onRegenerate: context.onRegenerate,
            onEdit: context.onEdit,
            onDelete: context.onDelete,
            onCancelEdit: context.onCancelEdit
        )
    }

    // MARK: - Paragraph (native NSTextView)

    private func configureAsParagraph(
        block: ContentBlock,
        text: String,
        isStreaming: Bool,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeMarkdownView == nil {
            removeAllContentViews()
            let mv = NativeMarkdownView()
            mv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(mv)
            NSLayoutConstraint.activate([
                mv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                mv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                mv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            ])
            nativeMarkdownView = mv
        }
        let mv = nativeMarkdownView!
        mv.onHeightChanged = { [weak self, weak mv] in
            guard let self, let mv, let id = self.currentBlockId else { return }
            let h = mv.measuredHeight(for: context.width - 32)
            context.onHeightMeasured?(h + 8, id)
        }
        mv.configure(
            text: text,
            width: context.width - 32,
            theme: context.theme,
            cacheKey: block.id,
            isStreaming: isStreaming
        )
        // always report height: configure() can return early when text is unchanged (e.g. tool row
        // expand/collapse) and otherwise the table keeps a stale row height → clipped / squeezed text.
        let h = mv.measuredHeight(for: context.width - 32) + 8
        context.onHeightMeasured?(h, block.id)
    }

    // MARK: - Thinking (NativeThinkingView)

    private func configureAsThinking(
        block: ContentBlock,
        text: String,
        isStreaming: Bool,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeThinkingView == nil {
            removeAllContentViews()
            let tv = NativeThinkingView()
            tv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(tv)
            NSLayoutConstraint.activate([
                tv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                tv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                tv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            ])
            nativeThinkingView = tv
        }
        let tv = nativeThinkingView!
        let thinkingLen: Int?
        if case .thinking(_, _, _) = block.kind { thinkingLen = text.count } else { thinkingLen = nil }

        tv.configure(
            thinking: text,
            thinkingLength: thinkingLen,
            width: context.width - 32,
            isStreaming: isStreaming,
            isExpanded: context.expandedIds.contains(block.id),
            theme: context.theme,
            blockId: block.id,
            onToggle: { [weak self] in
                guard let self else { return }
                context.onToggleExpand(block.id)
                self.nativeThinkingView?.onHeightChanged?()
            },
            onHeightChanged: { [weak self] in
                guard let self, let tv = self.nativeThinkingView, let id = self.currentBlockId else { return }
                let h = tv.measuredHeight() + 8
                context.onHeightMeasured?(h, id)
            }
        )
    }

    // MARK: - Tool Call Group (NativeToolCallGroupView)

    private func configureAsToolCallGroup(
        block: ContentBlock,
        calls: [ToolCallItem],
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeToolCallGroupView == nil {
            removeAllContentViews()
            let gv = NativeToolCallGroupView()
            gv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(gv)
            NSLayoutConstraint.activate([
                gv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                gv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                gv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            ])
            nativeToolCallGroupView = gv
        }
        nativeToolCallGroupView?.configure(
            calls: calls,
            expandedIds: context.expandedIds,
            width: context.width - 32,
            theme: context.theme,
            onToggle: { id in context.onToggleExpand(id) },
            onHeightChanged: { [weak self] in
                guard let self, let gv = self.nativeToolCallGroupView, let id = self.currentBlockId else { return }
                let h = gv.measuredHeight() + 8
                context.onHeightMeasured?(h, id)
            }
        )
    }

    // MARK: - User Message (native text + image thumbnails)

    private func configureAsUserMessage(
        block: ContentBlock,
        text: String,
        attachments: [Attachment],
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        let images = attachments.filter(\.isImage)
        let theme = context.theme
        let innerWidth = max(context.width - 32, 100)

        let wantsInlineEdit =
            context.editingTurnId == block.turnId
            && context.editText != nil
            && context.onConfirmEdit != nil
            && context.onCancelEdit != nil

        let needsUserMessageRebuild =
            !sameKind || userMessageContainer == nil || userMessageInlineEditActive != wantsInlineEdit

        if needsUserMessageRebuild {
            removeAllContentViews()

            // bubble height comes from content (pins below). do not pin container.bottom to the cell — that stretches
            // the bubble to whatever row height the table has (often an over-estimate), leaving empty space below text.
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.wantsLayer = true
            container.layer?.masksToBounds = false  // prevent border clipping
            addSubview(container)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                container.topAnchor.constraint(equalTo: topAnchor),
            ])
            userMessageContainer = container

            // "You" header inside the bubble (matches SwiftUI HeaderBlockContent behavior)
            let hv = NativeHeaderView()
            hv.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(hv)
            NSLayoutConstraint.activate([
                hv.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                hv.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                hv.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
                hv.heightAnchor.constraint(equalToConstant: 24),
            ])
            nativeHeaderView = hv

            if wantsInlineEdit {
                let ev = UserMessageInlineEditView()
                ev.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(ev)
                NSLayoutConstraint.activate([
                    ev.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                    ev.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                    ev.topAnchor.constraint(equalTo: hv.bottomAnchor, constant: 4),
                    ev.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
                ])
                userInlineEditView = ev
                userMessageInlineEditActive = true
                userImageStack = nil
                userTextView = nil
            } else {
                userMessageInlineEditActive = false
                userInlineEditView = nil

                var anchorBelowHeader = hv.bottomAnchor
                let topGapAfterHeader: CGFloat = 6

                if !images.isEmpty {
                    let stack = NSStackView()
                    stack.orientation = .horizontal
                    stack.spacing = 8
                    stack.translatesAutoresizingMaskIntoConstraints = false
                    container.addSubview(stack)
                    NSLayoutConstraint.activate([
                        stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                        stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
                        stack.topAnchor.constraint(equalTo: anchorBelowHeader, constant: topGapAfterHeader),
                        stack.heightAnchor.constraint(equalToConstant: 96),
                    ])
                    stack.alignment = .top
                    userImageStack = stack
                    anchorBelowHeader = stack.bottomAnchor
                } else {
                    userImageStack = nil
                }

                if !text.isEmpty {
                    let mv = NativeMarkdownView()
                    mv.translatesAutoresizingMaskIntoConstraints = false
                    container.addSubview(mv)
                    let gapBeforeText: CGFloat = images.isEmpty ? 4 : 8
                    NSLayoutConstraint.activate([
                        mv.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                        mv.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                        mv.topAnchor.constraint(equalTo: anchorBelowHeader, constant: gapBeforeText),
                    ])
                    userTextView = mv
                } else {
                    userTextView = nil
                }

                if let mv = userTextView {
                    NSLayoutConstraint.activate([
                        container.bottomAnchor.constraint(equalTo: mv.bottomAnchor, constant: 16)
                    ])
                } else if userImageStack != nil, let stack = userImageStack {
                    NSLayoutConstraint.activate([
                        container.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 16)
                    ])
                } else {
                    NSLayoutConstraint.activate([
                        hv.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
                    ])
                }
            }
        }

        // apply bubble background + inset stroke (layer border is centered on the edge and clips at corners)
        if let container = userMessageContainer {
            let radius = CGFloat(theme.bubbleCornerRadius)
            let bubbleColor: NSColor = {
                if let c = theme.userBubbleColor { return NSColor(c).withAlphaComponent(theme.userBubbleOpacity) }
                return NSColor(theme.accentColor).withAlphaComponent(theme.userBubbleOpacity)
            }()
            let borderW = CGFloat(theme.messageBorderWidth)
            let borderColor: NSColor =
                theme.showEdgeLight
                ? NSColor(theme.glassEdgeLight)
                : NSColor(theme.primaryBorder).withAlphaComponent(theme.borderOpacity)

            container.layer?.cornerRadius = radius
            container.layer?.backgroundColor = bubbleColor.cgColor
            container.layer?.masksToBounds = true
            container.layer?.borderWidth = 0
            container.layer?.borderColor = nil

            userBubbleCornerRadius = radius
            userBubbleBorderWidth = borderW
            userBubbleBorderColor = borderColor

            if userBubbleBorderLayer == nil {
                let stroke = CAShapeLayer()
                stroke.fillColor = nil
                stroke.zPosition = 10
                container.layer?.addSublayer(stroke)
                userBubbleBorderLayer = stroke
            }
            updateUserBubbleBorderStroke()
        }

        // update "You" header
        nativeHeaderView?.configure(
            turnId: block.turnId,
            role: .user,
            name: "You",
            isEditing: context.editingTurnId == block.turnId,
            isHovered: context.isTurnHovered,
            theme: theme,
            onCopy: context.onCopy,
            onRegenerate: nil,
            onEdit: context.onEdit,
            onDelete: context.onDelete,
            onCancelEdit: context.onCancelEdit
        )

        if wantsInlineEdit, let editPair = context.editText, let onConfirm = context.onConfirmEdit,
            let onCancel = context.onCancelEdit, let ev = userInlineEditView
        {
            let getT = editPair.0
            let setT = editPair.1
            ev.configure(
                theme: theme,
                getText: getT,
                setText: setT,
                onConfirm: onConfirm,
                onCancel: onCancel,
                onHeightChanged: { [weak self] in
                    guard let self, let id = self.currentBlockId else { return }
                    let totalH = self.measureFittedRowHeight()
                    context.onHeightMeasured?(totalH, id)
                }
            )
        } else if let mv = userTextView, !text.isEmpty {
            mv.onHeightChanged = { [weak self] in
                guard let self, let id = self.currentBlockId else { return }
                let totalH = self.measureFittedRowHeight()
                context.onHeightMeasured?(totalH, id)
            }
            mv.configure(
                text: text,
                width: innerWidth - 24,
                theme: theme,
                cacheKey: block.id,
                isStreaming: context.isStreaming
            )
        }

        if let stack = userImageStack {
            while stack.arrangedSubviews.count < images.count {
                let iv = UserAttachmentThumbnailView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                // height is fixed at 96; width is flexible via intrinsicContentSize
                iv.heightAnchor.constraint(equalToConstant: 96).isActive = true
                stack.addArrangedSubview(iv)
            }
            while stack.arrangedSubviews.count > images.count {
                let last = stack.arrangedSubviews.last!
                stack.removeArrangedSubview(last)
                last.removeFromSuperview()
            }

            for (index, attachment) in images.enumerated() {
                guard let iv = stack.arrangedSubviews[index] as? UserAttachmentThumbnailView else { continue }
                let attachId = attachment.id.uuidString
                iv.attachmentId = attachId
                iv.onTap = context.onUserImagePreview
                if let img = ChatImageCache.shared.cachedImage(for: attachId) {
                    iv.image = img
                } else if let data = attachment.imageData {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let img = await ChatImageCache.shared.decode(data, id: attachId)
                        iv.image = img
                        context.onHeightMeasured?(self.measureFittedRowHeight(), block.id)
                    }
                }
            }
        }

        // push fitted height even when NativeMarkdownView.configure returns early (no onHeightChanged),
        // and so row height updates when estimate vs fittingSize differ by only 1–2pt (see reportMeasuredHeight)
        context.onHeightMeasured?(measureFittedRowHeight(), block.id)
    }

    // MARK: - PendingToolCall

    private func configureAsPendingToolCall(
        block: ContentBlock,
        toolName: String,
        argPreview: String?,
        argSize: Int,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativePendingView == nil {
            removeAllContentViews()
            let pv = NativePendingToolCallView()
            pv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(pv)
            NSLayoutConstraint.activate([
                pv.leadingAnchor.constraint(equalTo: leadingAnchor),
                pv.trailingAnchor.constraint(equalTo: trailingAnchor),
                pv.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                pv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            ])
            nativePendingView = pv
        }
        nativePendingView?.configure(toolName: toolName, argPreview: argPreview, argSize: argSize, theme: context.theme)
    }

    // MARK: - TypingIndicator

    private func configureAsTypingIndicator(context: CellRenderingContext, sameKind: Bool) {
        if !sameKind || nativeTypingView == nil {
            removeAllContentViews()
            let tv = NativeTypingIndicatorView()
            tv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(tv)
            NSLayoutConstraint.activate([
                tv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                tv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                tv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
                tv.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            ])
            nativeTypingView = tv
        }
        nativeTypingView?.configure(theme: context.theme)
    }

    // MARK: - SharedArtifact

    private func configureAsArtifact(
        block: ContentBlock,
        artifact: SharedArtifact,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeArtifactView == nil {
            removeAllContentViews()
            let av = NativeArtifactCardView()
            av.translatesAutoresizingMaskIntoConstraints = false
            addSubview(av)
            let bottomToCell = av.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
            // low priority: intrinsic card height should drive row via onHeightMeasured; if row is still too short, footer clips (mitigated by generous NativeCellHeightEstimator slack)
            bottomToCell.priority = NSLayoutConstraint.Priority(250)
            NSLayoutConstraint.activate([
                av.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                av.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
                av.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
                av.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                bottomToCell,
            ])
            nativeArtifactView = av
        }
        let blockId = block.id
        nativeArtifactView?.onHeightChanged = { [weak self] in
            guard let self, let av = self.nativeArtifactView else { return }
            guard self.currentBlockId == blockId else { return }
            context.onHeightMeasured?(av.measuredCardHeight() + 12, blockId)
        }
        nativeArtifactView?.onImagePreviewTap = { id in context.onUserImagePreview?(id) }
        nativeArtifactView?.configure(artifact: artifact, theme: context.theme)
        // fittingSize before layout often omits footerStack height — row cache would clip Open in Finder.
        DispatchQueue.main.async { [weak self] in
            guard let self, let av = self.nativeArtifactView else { return }
            guard self.currentBlockId == blockId else { return }
            av.layoutSubtreeIfNeeded()
            context.onHeightMeasured?(av.measuredCardHeight() + 12, blockId)
        }
    }

    // MARK: - PreflightCapabilities

    private func configureAsPreflight(
        block: ContentBlock,
        items: [PreflightCapabilityItem],
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativePreflightView == nil {
            removeAllContentViews()
            let pfv = NativePreflightCapabilitiesView()
            pfv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(pfv)
            NSLayoutConstraint.activate([
                pfv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                pfv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                pfv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            ])
            nativePreflightView = pfv
        }
        guard let pfv = nativePreflightView else { return }
        pfv.onHeightChanged = { [weak self, weak pfv] in
            guard let self, let pfv, let id = self.currentBlockId else { return }
            context.onHeightMeasured?(pfv.measuredContentHeight() + 8, id)
        }
        pfv.configure(items: items, theme: context.theme, layoutWidth: context.width)
        let est = PreflightCapabilitiesRowHeight.estimated(items: items, tableWidth: context.width)
        let h = max(pfv.measuredContentHeight(), est) + 8
        context.onHeightMeasured?(h, block.id)
    }

    // MARK: - Unsupported (should never appear; zero-height placeholder)

    private func configureAsUnsupported(sameKind: Bool) {
        guard !sameKind || spacerView == nil else { return }
        removeAllContentViews()
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.topAnchor.constraint(equalTo: topAnchor),
            v.heightAnchor.constraint(equalToConstant: 0),
        ])
        spacerView = v
    }

    // MARK: - Helpers

    private func updateUserBubbleBorderStroke() {
        guard let container = userMessageContainer,
            let stroke = userBubbleBorderLayer,
            userBubbleBorderWidth > 0
        else { return }
        let bounds = container.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        let w = userBubbleBorderWidth
        let inset = w / 2
        stroke.frame = bounds
        let r = max(userBubbleCornerRadius - inset, 0)
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
        stroke.path = path.cgPath
        stroke.lineWidth = w
        stroke.strokeColor = userBubbleBorderColor.cgColor
        stroke.fillColor = nil
        stroke.lineJoin = .round
    }

    private func removeAllContentViews() {
        spacerView?.removeFromSuperview(); spacerView = nil
        nativeHeaderView?.removeFromSuperview(); nativeHeaderView = nil
        nativeMarkdownView?.removeFromSuperview(); nativeMarkdownView = nil
        nativeThinkingView?.removeFromSuperview(); nativeThinkingView = nil
        nativeToolCallGroupView?.removeFromSuperview(); nativeToolCallGroupView = nil
        nativePendingView?.removeFromSuperview(); nativePendingView = nil
        nativeTypingView?.removeFromSuperview(); nativeTypingView = nil
        nativeArtifactView?.removeFromSuperview(); nativeArtifactView = nil
        nativePreflightView?.removeFromSuperview(); nativePreflightView = nil
        userMessageContainer?.removeFromSuperview(); userMessageContainer = nil
        userTextView = nil
        userInlineEditView = nil
        userImageStack = nil
        userMessageInlineEditActive = false
        userBubbleBorderLayer = nil
        userBubbleBorderWidth = 0
    }
}

/// Thumbnail in user bubble — tap opens full-screen preview (wired via `CellRenderingContext.onUserImagePreview`).
/// `CALayer` corner radius + `NSImageView` in `NSTableView` still drew a square trailing edge here; clipping in `draw(_:)` is the reliable fix.
private final class UserAttachmentThumbnailView: NSView {
    private static let cornerRadius: CGFloat = 8

    override var isFlipped: Bool { true }

    var attachmentId: String = ""
    var onTap: ((String) -> Void)?

    private var lastDrawBounds: NSRect = .zero

    var image: NSImage? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        guard let img = image else { return NSSize(width: 96, height: 96) }
        let size = img.size
        guard size.width > 0, size.height > 0 else { return NSSize(width: 96, height: 96) }

        let aspectRatio = size.width / size.height
        if aspectRatio > 1 {
            // landscape: fixed width 96, height shrinks (to stay within 96x96 box)
            return NSSize(width: 96, height: max(16, 96 / aspectRatio))
        } else {
            // portrait/square: fixed height 96, width shrinks
            return NSSize(width: max(16, 96 * aspectRatio), height: 96)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // parent `NativeMessageCellView` is layer-backed; this makes `draw(_:)` reliably update the bitmap
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func layout() {
        super.layout()
        if bounds != lastDrawBounds {
            lastDrawBounds = bounds
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let img = image else { return }
        let rect = bounds
        guard rect.width > 0, rect.height > 0 else { return }

        NSGraphicsContext.saveGraphicsState()
        // clip to the actual view bounds (which now match the aspect ratio via intrinsicContentSize)
        NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).addClip()
        NSGraphicsContext.current?.imageInterpolation = .high

        // since the view bounds (rect) already match the aspect ratio,
        // simple drawing into rect will show the full image correctly without stretching.
        img.draw(
            in: rect,
            from: NSRect(origin: .zero, size: img.size),
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        onTap?(attachmentId)
    }
}

// MARK: - ContentBlockKindTag

/// Lightweight discriminator used to detect kind changes without comparing full associated values.
enum ContentBlockKindTag: Equatable {
    case header, paragraph, toolCallGroup, thinking, userMessage, pendingToolCall
    case typingIndicator, groupSpacer, sharedArtifact, preflightCapabilities, other
}

extension ContentBlockKind {
    var kindTag: ContentBlockKindTag {
        switch self {
        case .header: return .header
        case .paragraph: return .paragraph
        case .toolCallGroup: return .toolCallGroup
        case .thinking: return .thinking
        case .userMessage: return .userMessage
        case .pendingToolCall: return .pendingToolCall
        case .typingIndicator: return .typingIndicator
        case .groupSpacer: return .groupSpacer
        case .sharedArtifact: return .sharedArtifact
        case .preflightCapabilities: return .preflightCapabilities
        }
    }
}

// MARK: - NativeCellHeightEstimator

/// Provides height estimates for rows without triggering a full SwiftUI layout pass.
/// Used by the NSTableView height delegate as a fast path.
enum NativeCellHeightEstimator {

    @MainActor static func estimatedHeight(
        for block: ContentBlock,
        width: CGFloat,
        theme: any ThemeProtocol,
        isExpanded: Bool
    ) -> CGFloat {
        switch block.kind {
        case .groupSpacer:
            return 16

        case .header:
            // 12 top + 28 label + 12 bottom
            return 52

        case .typingIndicator:
            // 4 top + ~22 content + 6 bottom (tight to header / thinking row above)
            return 32

        case let .pendingToolCall(_, argPreview, _):
            // header row + 52pt arg box + cell vertical insets
            return argPreview != nil ? 112 : 62

        case let .thinking(_, text, _):
            if !isExpanded { return 56 }
            let innerW = max(width - 64, 100)
            let charsPerLine = max(Int(innerW / 7), 20)
            let lines = max(1, (text.count + charsPerLine - 1) / charsPerLine)
            return 58 + min(CGFloat(lines) * 22 + 32, 356)

        case let .paragraph(_, text, _, _):
            let innerW = max(width - 32, 100)
            let cacheKey = "\(block.id)-w\(Int(innerW))"
            if let cached = ThreadCache.shared.height(for: cacheKey) {
                return cached + 24
            }
            let chars = max(Int(innerW / 7), 20)
            let lines = max(1, (text.count + chars - 1) / chars)
            return CGFloat(lines) * 22 + 24

        case let .userMessage(text, attachments):
            // header: 10 top + 24 label + 4 gap = 38pt; text below; 16pt bottom = 54pt base

            // "You" header
            var h: CGFloat = 38
            let innerW = max(width - 32, 100)
            if !text.isEmpty {
                let textW = innerW - 24
                let cacheKey = "\(block.id)-w\(Int(textW))"
                if let cached = ThreadCache.shared.height(for: cacheKey) {
                    h += cached + 16
                } else {
                    let chars = max(Int(textW / 7), 20)
                    let lines = max(1, (text.count + chars - 1) / chars)
                    h += CGFloat(lines) * 22 + 16
                }
            }
            h += CGFloat(attachments.filter(\.isImage).count) * 120
            return max(h, 64)

        case let .toolCallGroup(calls):
            // each row self-sizes at ~41pt (40pt header + 1pt separator)
            return CGFloat(calls.count) * 41 + 8

        case let .preflightCapabilities(items):
            return 8 + PreflightCapabilitiesRowHeight.estimated(items: items, tableWidth: width)

        case let .sharedArtifact(artifact):
            // matches NativeArtifactCardView: inner top 12 + bottom 8 (footerVerticalGap), symmetric gap above/below footer row
            var h: CGFloat = 12 + 24 + 8 + 8 + 40 + 4 + 4
            if let d = artifact.description, !d.isEmpty { h += 20 }
            let pathEmpty = artifact.hostPath.isEmpty
            if pathEmpty {
                if artifact.isText, let c = artifact.content, !c.isEmpty {
                    let lines = min(6, max(1, c.components(separatedBy: "\n").count))
                    h += CGFloat(lines) * 14 + 8
                }
            } else if artifact.isImage || artifact.isPDF || artifact.isVideo {
                h += 160 + 8
            } else if artifact.isAudio {
                h += 56 + 8
            } else if artifact.isHTML || artifact.isDirectory {
                h += 44 + 8
            } else if artifact.isText, let c = artifact.content, !c.isEmpty {
                let lines = min(6, max(1, c.components(separatedBy: "\n").count))
                h += CGFloat(lines) * 14 + 8
            }
            // configureAsArtifact reports measuredCardHeight() + 12 for cell top/bottom inset — match that here
            // extra slack: intrinsic footer + deferred layout can exceed this; too-small row clips Open in Finder
            return h + 12 + 24
        }
    }
}
