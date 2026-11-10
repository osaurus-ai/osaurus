//
//  NativeMessageCellView.swift
//  osaurus
//
//  NSTableCellView subclass — pure AppKit rendering for all block types.
//

import AppKit
import QuartzCore
import SwiftUI

// MARK: - Cell Rendering Context

/// Passed to NativeMessageCellView.configure() — bundles all rendering inputs.
struct CellRenderingContext {
    var width: CGFloat
    let agentName: String
    let agentAvatar: String?
    /// Absolute filesystem path to a user-supplied custom avatar image.
    /// When present, takes precedence over `agentAvatar` (mascot id).
    let agentCustomAvatarPath: String?
    let isStreaming: Bool
    let lastAssistantTurnId: UUID?
    var showResponseMetrics: Bool = false
    let theme: any ThemeProtocol
    /// mutable so `configureCell` can override with coordinator `expandedIds` before `applyBlocks` runs again
    var expandedIds: Set<String>
    let onToggleExpand: (String) -> Void
    /// Called by native views after they've measured their own height.
    /// Coordinator updates heightCache and calls noteHeightOfRows if delta > 2pt.
    var onHeightMeasured: ((CGFloat, String) -> Void)? = nil
    var isTurnHovered: Bool = false
    /// The rows above / below are assistant paragraphs of the same reply,
    /// so the bubble squares that edge off and joins them.
    var bubbleJoinsPrevious = false
    var bubbleJoinsNext = false
    var editingTurnId: UUID? = nil
    var editText: (() -> String, (String) -> Void)? = nil
    var onConfirmEdit: (() -> Void)? = nil
    var onCancelEdit: (() -> Void)? = nil
    var onCopy: ((UUID) -> Void)? = nil
    var onRegenerate: ((UUID) -> Void)? = nil
    var onEdit: ((UUID) -> Void)? = nil
    var onDelete: ((UUID) -> Void)? = nil
    var onSpeak: ((UUID) -> Void)? = nil
    /// A tapped follow-up suggestion string → sent as the next user turn.
    var onFollowUpTap: ((String) -> Void)? = nil
    /// Deletes an assistant response. The confirmation dialog offers an option
    /// to also delete the prompting user message. Distinct from `onDelete`,
    /// which truncates a user turn and everything after it.
    var onDeleteMessage: ((UUID) -> Void)? = nil
    /// Read at menu-open time so late generation statistics do not leave a
    /// recycled action row showing a stale response's metrics.
    var responseStatsForTurn: ((UUID) -> String?)? = nil
    /// attachment or shared-artifact id string → full screen preview from ChatView
    var onUserImagePreview: ((String) -> Void)? = nil
    /// Inline markdown image (e.g. a generated image) clicked → full screen
    /// preview from ChatView, carrying the already-decoded bitmap.
    var onImagePreviewImage: ((NSImage) -> Void)? = nil
    /// Document attachment (pasted content or an attached file like a PDF/DOCX)
    /// → read-only preview sheet from ChatView. Lets users re-read the extracted
    /// text after the message is sent, mirroring the composer's chip preview.
    var onDocumentPreview: ((Attachment) -> Void)? = nil
    /// Window-local accumulator of `original -> placeholder` pairs
    /// from the Privacy Filter. Used by `NativeMarkdownView` to
    /// inline-highlight matching spans inside user + assistant
    /// bubbles. Empty dict means no privacy redactions in this
    /// session yet (the highlight pass short-circuits).
    var sessionRedactions: [String: String] = [:]
    /// Active in-conversation find query (Cmd+F). Empty when the find bar is
    /// closed. Message cells paint every case-insensitive occurrence in
    /// their body text via `NativeMarkdownView.setSearchHighlight`.
    var searchHighlightQuery: String = ""
    /// Turn owning the find bar's *current* match, or nil when no match is
    /// current (bar closed / no matches).
    var searchCurrentTurnId: UUID? = nil
    /// Zero-based occurrence index of the current match within its turn's
    /// content. Meaningless when `searchCurrentTurnId` is nil.
    var searchCurrentOccurrence: Int = 0
    /// Coordinator-scoped lookup: number of query occurrences in the
    /// searchable blocks that precede the given block id within its turn.
    /// Cells subtract it from `searchCurrentOccurrence` to translate the
    /// turn-relative index into a block-local one.
    var searchOccurrenceOffset: ((String) -> Int)? = nil
    /// Coordinator-scoped predicate: has the chart with this block id ever
    /// been drawn (and thus already played its entry animation) in the
    /// current chat? Used by `configureAsChart` to suppress the animation
    /// when a recycled cell re-mounts a NativeChartView for a chart the
    /// user has already seen.
    var hasChartBeenDrawn: ((String) -> Bool)? = nil
    /// Coordinator-scoped callback: record that the chart with this block
    /// id has been drawn so subsequent re-mounts skip the entry animation.
    var markChartDrawn: ((String) -> Void)? = nil
    /// Coordinator-scoped predicate/marker pair, same role as the chart pair
    /// above: has this follow-up row already played its entrance animation in
    /// the current chat? Lets `configureAsFollowUpSuggestions` suppress the
    /// reveal when a recycled cell re-mounts it after scrolling.
    var hasFollowUpsShown: ((String) -> Bool)? = nil
    var markFollowUpsShown: ((String) -> Void)? = nil
    /// Coordinator-scoped chart view cache lookup. Returning a non-nil
    /// view lets `configureAsChart` reparent an existing (already-rendered)
    /// `NativeChartView` instead of allocating a fresh `AAChartView`/
    /// WKWebView — eliminating the visible re-render when a chart row
    /// scrolls back into view after cell recycling.
    var cachedChartView: ((String) -> NativeChartView?)? = nil
    /// Coordinator-scoped callback: stash a newly created chart view in
    /// the coordinator's cache so subsequent re-mounts hit the lookup
    /// above. Pruned to the current block ids on each `applyBlocks`.
    var cacheChartView: ((String, NativeChartView) -> Void)? = nil
    /// Same pattern as `cachedChartView`, but for tool-call groups. When
    /// the tool finishes and blocks reflow, NSTableView often redequeues
    /// the row into a different cell — without this cache the old
    /// `NativeToolCallGroupView` is torn down and a fresh one is mounted
    /// from zero bounds, which reads as the appearance animation
    /// replaying.
    var cachedToolGroupView: ((String) -> NativeToolCallGroupView?)? = nil
    var cacheToolGroupView: ((String, NativeToolCallGroupView) -> Void)? = nil
    /// Workflows supplies outer padding at the panel, so user bubbles fill
    /// the available width.
    var fullWidthMessages: Bool = false
    var rowHorizontalInset: CGFloat { Self.threadRowInset }

    /// The table already sits inside the readable column's inset, so rows add
    /// no gutter of their own: headers, replies and cards share the left and
    /// right edges of the user bubble and the composer card.
    static let threadRowInset: CGFloat = 0

    /// Block-local occurrence index of the find bar's current match, or nil
    /// when the current match isn't in this block's turn (or precedes this
    /// block). Indices past this block's own occurrences are handled by the
    /// renderer, which simply paints no current match for them.
    func searchCurrentIndex(forBlock block: ContentBlock) -> Int? {
        guard let searchCurrentTurnId, searchCurrentTurnId == block.turnId else { return nil }
        let local = searchCurrentOccurrence - (searchOccurrenceOffset?(block.id) ?? 0)
        return local >= 0 ? local : nil
    }
}

// MARK: - Cell-Isolated ExpandedBlocksStore Proxy

// MARK: - Native Header View

/// Pure AppKit header row: name label + hover-revealed action buttons.
final class NativeHeaderView: NSView {

    private let avatarImageView = NSImageView()
    #if OSAURUS_DESIGN_SYSTEM
    private var sharedAvatarHost: NSHostingView<AnyView>?
    #endif
    private let nameLabel = NSTextField(labelWithString: "")
    private let actionStack = NSStackView()
    private var isEditing = false
    private var actionStackWidth: CGFloat = 28
    private var avatarLeadingConstraint: NSLayoutConstraint?
    private var nameLeadingToAvatar: NSLayoutConstraint?
    private var nameLeadingToSelf: NSLayoutConstraint?
    /// Default avatar diameter when the theme doesn't provide one. Theme
    /// override comes through `configure(...)` and is clamped to [16, 108]
    /// before being applied via `avatarSizeConstraints`.
    private static let defaultAvatarSize: CGFloat = 24
    static let minAvatarSize: CGFloat = 16
    static let maxAvatarSize: CGFloat = 108
    private var avatarWidthConstraint: NSLayoutConstraint?
    private var avatarHeightConstraint: NSLayoutConstraint?
    private var currentAvatarSize: CGFloat = NativeHeaderView.defaultAvatarSize

    private var turnId: UUID = UUID()
    private var messageTimestamp: Date = Date()
    /// Assistant turn that answered this message; backs the overflow menu's
    /// "Inspect response". Nil when there's no reply yet.
    private var responseTurnId: UUID?
    /// False for enveloped user turns (channel / delegated / scheduled /
    /// watcher), whose stored content is a dispatch contract rather than
    /// text the user typed — hand-editing it is never meaningful.
    private var allowsEdit = true
    private var onCopy: ((UUID) -> Void)?
    private var onRegenerate: ((UUID) -> Void)?
    private var onEdit: ((UUID) -> Void)?
    private var onDelete: ((UUID) -> Void)?
    private var storedOnCancelEdit: (() -> Void)?
    private var currentRole: MessageRole = .assistant
    private var currentTheme: (any ThemeProtocol)?
    /// The ellipsis "…" control, kept so its overflow menu can anchor to it.
    private weak var overflowControl: HeaderCircleActionControl?
    #if OSAURUS_DESIGN_SYSTEM
    private let assignedMenu = AssignedMenuPanelPresenter()
    #endif

    /// Formats the message timestamp for the overflow menu header, e.g.
    /// "Jun 20, 10:17 PM". Localized template so order/separators follow locale.
    /// Mirrors `NativeAssistantActionsView.timestampFormatter`.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd jmm")
        return formatter
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.imageScaling = .scaleProportionallyUpOrDown
        avatarImageView.isHidden = true
        avatarImageView.wantsLayer = true
        avatarImageView.layer?.cornerRadius = Self.defaultAvatarSize / 2
        avatarImageView.layer?.masksToBounds = true
        addSubview(avatarImageView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.isSelectable = true
        nameLabel.maximumNumberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.orientation = .horizontal
        actionStack.spacing = 4
        actionStack.alignment = .centerY
        // `.fill` stretches subviews on the cross axis to the stack height; that breaks square chips.
        actionStack.distribution = .equalSpacing
        actionStack.alphaValue = 0
        addSubview(actionStack)

        let avatarLeading = avatarImageView.leadingAnchor.constraint(equalTo: leadingAnchor)
        let nameToAvatar = nameLabel.leadingAnchor.constraint(
            equalTo: avatarImageView.trailingAnchor,
            constant: 6
        )
        let nameToSelf = nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor)
        nameToSelf.isActive = true
        avatarLeadingConstraint = avatarLeading
        nameLeadingToAvatar = nameToAvatar
        nameLeadingToSelf = nameToSelf

        let avatarW = avatarImageView.widthAnchor.constraint(equalToConstant: Self.defaultAvatarSize)
        let avatarH = avatarImageView.heightAnchor.constraint(equalToConstant: Self.defaultAvatarSize)
        avatarWidthConstraint = avatarW
        avatarHeightConstraint = avatarH

        NSLayoutConstraint.activate([
            avatarLeading,
            avatarImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatarW,
            avatarH,
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(
        turnId: UUID,
        role: MessageRole,
        name: String,
        avatar: String?,
        customAvatarPath: String?,
        isEditing: Bool,
        isHovered: Bool,
        timestamp: Date = Date(),
        responseTurnId: UUID? = nil,
        allowsEdit: Bool = true,
        theme: any ThemeProtocol,
        onCopy: ((UUID) -> Void)?,
        onRegenerate: ((UUID) -> Void)?,
        onEdit: ((UUID) -> Void)?,
        onDelete: ((UUID) -> Void)?,
        onCancelEdit: (() -> Void)?
    ) {
        self.turnId = turnId
        self.messageTimestamp = timestamp
        self.responseTurnId = responseTurnId
        self.allowsEdit = allowsEdit
        self.isEditing = isEditing
        self.onCopy = onCopy
        self.onRegenerate = onRegenerate
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.storedOnCancelEdit = onCancelEdit
        let theme = theme.catalogFamily(30, authoritative: true)
        self.currentRole = role
        self.currentTheme = theme
        #if OSAURUS_DESIGN_SYSTEM
        catalogAssignmentTarget(["avatarNameGap", "headerActionsGap", "headerPaddingY"].map { MessageHeaderInspectionStyle.key + "elements.layout." + $0 } + [AgentContentSurfaceAssignments.key(30, "agentHeader")], name: "Agent identity header", theme: theme)
        wantsLayer = true
        layer?.backgroundColor = NSColor(AgentContentSurfaceAssignments.color(30, "agentHeader", theme)).cgColor
        #endif
        actionStack.spacing = MessageHeaderInspectionStyle.layout("headerActionsGap", "gap", 4, theme)
        nameLeadingToAvatar?.constant = MessageHeaderInspectionStyle.layout("avatarNameGap", "gap", 6, theme)
        actionStackWidth = MessageHeaderInspectionStyle.side(theme)

        // Resolve theme-driven sizing + visibility first so avatar generation
        // matches the actual rendered size. Clamped to a sensible UI range
        // even if a malformed theme JSON lands here.
        let themeSize = CGFloat(
            max(Double(Self.minAvatarSize), min(Double(Self.maxAvatarSize), Double(MessageHeaderInspectionStyle.avatarSide(theme))))
        )
        if currentAvatarSize != themeSize {
            currentAvatarSize = themeSize
            avatarWidthConstraint?.constant = themeSize
            avatarHeightConstraint?.constant = themeSize
            avatarImageView.layer?.cornerRadius = themeSize / 2
        }

        // Assistant messages always show *some* avatar (custom > mascot >
        // monogram) so the chat header is visually consistent regardless of
        // which avatar mode the user picked, unless the theme opts out via
        // `showInlineAvatar`. User messages hide the avatar. The monogram uses
        // the agent's own colour, the same tint the sidebar row gives it.
        let agentTint = agentColorFor(name)
        avatarSource =
            role == .assistant && theme.showInlineAvatar
            ? AvatarSource(
                name: name,
                avatar: avatar,
                customAvatarPath: customAvatarPath,
                tint: NSColor(agentTint),
                background: NSColor(agentTint.opacity(0.18))
            )
            : nil
        let resolved = resolveAvatarImage()
        avatarImageView.image = resolved
        // Every avatar kind is pre-rendered at the view's exact size, so this
        // only matters as a safety net and never scales in practice.
        avatarImageView.imageScaling = .scaleProportionallyUpOrDown
        let showAvatar = resolved != nil
        avatarImageView.isHidden = !showAvatar
        avatarImageView.layer?.borderColor = NSColor(theme.border.default).cgColor
        avatarImageView.layer?.borderWidth = theme.stroke.default
        nameLeadingToSelf?.isActive = !showAvatar
        nameLeadingToAvatar?.isActive = showAvatar

        let nameVisible = role == .user || theme.showAgentName
        nameLabel.isHidden = !nameVisible
        nameLabel.stringValue = nameVisible ? name : ""
        nameLabel.font = theme.nsFont(.label)
        nameLabel.textColor = NSColor(role == .user ? theme.text.primary : theme.text.secondary)
        #if OSAURUS_DESIGN_SYSTEM
        nameLabel.attributedStringValue = MessageHeaderInspectionStyle.text(nameLabel.stringValue, property: "label", color: NSColor(theme.text.primary), theme: theme)
        // Reuse the actual shared avatar component, including saved shape/color.
        let avatarHost = sharedAvatarHost ?? NSHostingView(rootView: AnyView(EmptyView()))
        sharedAvatarHost = avatarHost
        avatarHost.frame = avatarImageView.bounds
        avatarHost.autoresizingMask = [.width, .height]
        if avatarHost.superview == nil { avatarImageView.addSubview(avatarHost) }
        avatarHost.rootView = AnyView(AgentAvatarView(mascotId: avatar, name: name, tint: agentTint,
            diameter: themeSize, customImageURL: customAvatarPath.map { URL(fileURLWithPath: $0) },
            borderWidth: 0)
            .environment(\.theme, theme))
        avatarImageView.image = nil
        avatarImageView.layer?.borderWidth = 0
        avatarImageView.layer?.masksToBounds = false
        #endif

        rebuildActionButtons(role: role, theme: theme, onCancelEdit: onCancelEdit)
        invalidateIntrinsicContentSize()
        setHovered(isHovered, animated: false)
    }

    private struct AvatarSource {
        let name: String
        let avatar: String?
        let customAvatarPath: String?
        let tint: NSColor
        let background: NSColor
    }

    /// Inputs of the current avatar, kept so the bitmap can be re-rendered
    /// when the view moves to a display with a different backing scale.
    private var avatarSource: AvatarSource?
    private var avatarRenderScale: CGFloat = 0

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    /// Custom > mascot > monogram, rendered at `currentAvatarSize` for the
    /// current backing scale. Nil when the row shows no avatar.
    private func resolveAvatarImage() -> NSImage? {
        guard let source = avatarSource else { return nil }
        let scale = backingScale
        avatarRenderScale = scale
        let renderer = AvatarBitmapRenderer.shared
        if let path = source.customAvatarPath, !path.isEmpty,
            let img = renderer.image(
                customURL: URL(fileURLWithPath: path),
                pointSize: currentAvatarSize,
                scale: scale
            )
        {
            return img
        }
        if let mascot = source.avatar.flatMap(AgentMascot.init(rawValue:)),
            let img = renderer.image(mascot: mascot, pointSize: currentAvatarSize, scale: scale)
        {
            return img
        }
        // The initial is artwork sized to the avatar disc, set in the theme's
        // heading recipe (family + weight).
        let heading = (currentTheme ?? CustomizableTheme.light()).nsFont(.heading)
        return Self.monogramImage(
            name: source.name,
            tint: source.tint,
            background: source.background,
            size: currentAvatarSize,
            font: NSFont(descriptor: heading.fontDescriptor, size: currentAvatarSize / 2) ?? heading
        )
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshAvatarForBackingScale()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshAvatarForBackingScale()
    }

    private func refreshAvatarForBackingScale() {
        guard avatarSource != nil, window != nil, backingScale != avatarRenderScale else { return }
        avatarImageView.image = resolveAvatarImage()
    }

    /// Renders a monogram avatar (initial-on-tinted-circle) into a cached
    /// NSImage so the inline header has something to show when no mascot or
    /// custom image is configured. Cached by (initial, tint, size) — themes
    /// share the same key once stringified.
    private static var monogramCache: [String: NSImage] = [:]
    private static let monogramCacheLock = NSLock()

    /// Drop all memoized monograms (memory-pressure response); re-rendered
    /// lazily on next display.
    static func clearMonogramCache() {
        monogramCacheLock.lock()
        monogramCache.removeAll()
        monogramCacheLock.unlock()
    }

    private static func monogramImage(
        name: String,
        tint: NSColor,
        background: NSColor,
        size: CGFloat,
        font: NSFont
    ) -> NSImage {
        let initial: String = {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = trimmed.first else { return "?" }
            return String(first).uppercased()
        }()
        let key = "\(initial)|\(tint.hashValue)|\(background.hashValue)|\(Int(size))|\(font.fontName)"
        monogramCacheLock.lock()
        if let hit = monogramCache[key] {
            monogramCacheLock.unlock()
            return hit
        }
        monogramCacheLock.unlock()

        let pixelSize = NSSize(width: size, height: size)
        let image = NSImage(size: pixelSize, flipped: false) { rect in
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.saveGState()
            background.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: tint,
            ]
            let str = NSAttributedString(string: initial, attributes: attrs)
            let strSize = str.size()
            let pt = NSPoint(
                x: rect.midX - strSize.width / 2,
                y: rect.midY - strSize.height / 2
            )
            str.draw(at: pt)
            ctx?.restoreGState()
            return true
        }
        monogramCacheLock.lock()
        // Safety-net cap (reset-on-overflow): keys vary by initial/tint/size,
        // and monograms are cheap to re-render.
        if monogramCache.count >= 256 { monogramCache.removeAll() }
        monogramCache[key] = image
        monogramCacheLock.unlock()
        return image
    }

    override var intrinsicContentSize: NSSize {
        let count = CGFloat(actionStack.arrangedSubviews.count)
        guard count > 0 else { return NSSize(width: NSView.noIntrinsicMetric, height: 28) }
        let stackW = count * actionStackWidth + max(0, count - 1) * actionStack.spacing
        let labelW = nameLabel.intrinsicContentSize.width
        let avatarW: CGFloat = avatarImageView.isHidden ? 0 : (currentAvatarSize + MessageHeaderInspectionStyle.layout("avatarNameGap", "gap", 6, currentTheme ?? CustomizableTheme.light()))
        let total = stackW + avatarW + (labelW > 0 ? labelW + 8 : 0)
        return NSSize(width: total, height: 28)
    }

    func setHovered(_ hovered: Bool, animated: Bool = true) {
        let alpha: CGFloat = (hovered || isEditing) ? 1 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = ThemeManager.shared.currentTheme.motion.quickInterval
                ctx.timingFunction = ThemeManager.shared.currentTheme.motion.timingFunction
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

        // Assistant actions (copy, regenerate) are rendered in a dedicated footer row
        // under every completed assistant turn, so the header only carries actions for
        // user messages now. This lets the table coordinator skip hover reconfigures
        // for assistant rows entirely.
        guard role == .user else { return }

        addBtn(icon: "doc.on.doc", help: L("Copy"), theme: theme, tint: nil) { [weak self] in
            guard let self else { return }
            self.onCopy?(self.turnId)
        }
        if allowsEdit {
            addBtn(icon: "pencil", help: L("Edit"), theme: theme, tint: nil) { [weak self] in
                guard let self else { return }
                self.onEdit?(self.turnId)
            }
        }
        addBtn(icon: "trash", help: L("Delete"), theme: theme, tint: nil) { [weak self] in
            guard let self else { return }
            self.onDelete?(self.turnId)
        }

        if isEditing, let onCancelEdit {
            addBtn(icon: "xmark", help: L("Cancel edit"), theme: theme, tint: nil, action: onCancelEdit)
        }

        // Overflow "…" carrying the message timestamp, mirroring the assistant
        // footer's overflow menu (minus the assistant-only Inspect action).
        overflowControl = addBtn(icon: "ellipsis", help: L("More"), theme: theme, tint: nil) { [weak self] in
            self?.presentOverflowMenu()
        }
    }

    /// Drops a menu under the "…" button mirroring the assistant footer's
    /// overflow menu: a disabled header showing when the message was sent, then
    /// an "Inspect response" action that opens the reply's request/response log.
    /// A user turn has no log of its own, so Inspect keys on the assistant reply
    /// rather than this turn, and is shown whenever a reply turn exists.
    ///
    /// The item is gated only on the O(1) `responseTurnId != nil` check — no log
    /// lookup happens here, so building/showing the popover never scans the log
    /// ring on the main thread. Whether the log still exists is resolved lazily
    /// on click (`inspectResponseFromMenu`), exactly like the assistant menu.
    private func presentOverflowMenu() {
        guard let anchor = overflowControl else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(
            title: Self.timestampFormatter.string(from: messageTimestamp),
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)

        if responseTurnId != nil {
            menu.addItem(.separator())
            let inspect = NSMenuItem(
                title: L("Inspect response"),
                action: #selector(inspectResponseFromMenu),
                keyEquivalent: ""
            )
            inspect.target = self
            if let theme = currentTheme {
                let pointSize = theme.pointSize(.caption)
                let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
                inspect.image = SymbolImageCache.image(
                    "waveform.path.ecg.magnifyingglass",
                    accessibilityDescription: nil
                )?.withSymbolConfiguration(cfg)
            }
            menu.addItem(inspect)
        }

        // Anchor the menu's top-left just under the button's bottom-left so it
        // opens downward like the assistant overflow menu. The button is a
        // non-flipped NSView, so its bottom edge is y == 0 and the 4pt gap sits
        // below it at a negative y.
        #if OSAURUS_DESIGN_SYSTEM
        assignedMenu.showContextMenu(menu, from: anchor, theme: currentTheme ?? CustomizableTheme.light())
        #else
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: anchor)
        #endif
    }

    @objc private func inspectResponseFromMenu() {
        // Focus the reply's request/response log. The menu only gates on a
        // reply turn existing (no log scan on the popover path), so resolve the
        // log lazily here and surface the alert when it's absent (never
        // recorded, or evicted from the in-memory ring since the turn ran).
        guard let responseTurnId else { return }
        MainActor.assumeIsolated {
            if InsightsService.shared.focus(turnId: responseTurnId) {
                AppDelegate.shared?.showManagementWindow(initialTab: .insights)
            } else {
                presentLogUnavailableAlert()
            }
        }
    }

    @MainActor
    private func presentLogUnavailableAlert() {
        // Scope the alert to this chat window when we can resolve it, so it
        // dims and centers over the chat rather than another surface.
        let scope: ThemedAlertScope =
            window.flatMap { ChatWindowManager.shared.windowId(for: $0) }
            .map { .chat($0) } ?? .content
        let requestId = UUID()
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: L("Insights Unavailable"),
                message: L(
                    "Detailed request logs are kept only for a short duration to save storage, so there's nothing to show for this response."
                ),
                buttons: [.primary(L("OK")) {}],
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }

    private static let actionButtonSize: CGFloat = 28

    @discardableResult
    private func addBtn(
        icon: String,
        help: String,
        theme: any ThemeProtocol,
        tint: NSColor?,
        action: @escaping () -> Void
    ) -> HeaderCircleActionControl {
        let control = HeaderCircleActionControl(action: action)
        let pointSize = theme.pointSize(.caption)
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        control.setSymbol(
            SymbolImageCache.image(icon, accessibilityDescription: help)?.withSymbolConfiguration(cfg),
            toolTip: help,
            theme: theme,
            iconTint: tint,
            symbolName: icon
        )
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .vertical)
        NSLayoutConstraint.activate([
            control.widthAnchor.constraint(equalToConstant: MessageHeaderInspectionStyle.side(theme)),
            control.heightAnchor.constraint(equalToConstant: MessageHeaderInspectionStyle.side(theme)),
        ])
        actionStack.addArrangedSubview(control)
        return control
    }
}

// MARK: - Circular header action buttons (matches SwiftUI `HeaderBlockContent` / `ActionButton`)

/// `NSButton`’s cell/layer often disagree with `bounds`, producing non-circular backgrounds; draw the
/// chrome on a plain `NSView` and keep a borderless `NSButton` for hit-testing and keyboard focus.
final class HeaderCircleActionControl: NSView {
    private let button: NSButton
    private var block: () -> Void
    private var fillBase: NSColor = .clear
    private var fillHover: NSColor = .clear
    private var tracking: NSTrackingArea?
    #if OSAURUS_DESIGN_SYSTEM
    private var inspectionTheme: (any ThemeProtocol)?
    private var inspectedHover = false
    private var inspectedSelected = false
    func setInspectionEnabled(_ enabled: Bool) { button.isEnabled = enabled; refreshInspectionChrome() }
    func setInspectionSelected(_ selected: Bool) { inspectedSelected = selected; refreshInspectionChrome() }
    private var sharedButtonHost: NSHostingView<AnyView>?
    private var sharedSymbolName: String?
    private func refreshInspectionChrome() {
        guard let theme = inspectionTheme else { return }
        let host: NSHostingView<AnyView>
        if let existing = sharedButtonHost { host = existing }
        else {
            host = NSHostingView(rootView: AnyView(EmptyView()))
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor), host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor)])
            sharedButtonHost = host
        }
        button.isHidden = true
        button.setAccessibilityHidden(true)
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        layer?.masksToBounds = false
        if let symbol = sharedSymbolName {
            host.rootView = AnyView(SettingsIconButton(symbol, help: button.toolTip, size: .extraSmall,
                isActive: inspectedSelected, role: .secondary) { [weak self] in self?.block() }
                .disabled(!button.isEnabled).environment(\.theme, theme))
        } else {
            let image = button.image ?? NSImage()
            host.rootView = AnyView(Button { [weak self] in self?.block() } label: {
                Image(nsImage: image).renderingMode(.template)
            }.assignedSettingsIconButtonStyle(size: .extraSmall, isActive: inspectedSelected, role: .secondary)
                .disabled(!button.isEnabled).help(button.toolTip ?? "")
                .accessibilityLabel(button.toolTip ?? "Message action").environment(\.theme, theme))
        }
    }
    #endif

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

    func setSymbol(_ image: NSImage?, toolTip: String, theme: any ThemeProtocol, iconTint: NSColor?, symbolName: String? = nil) {
        button.image = image
        button.toolTip = toolTip
        button.contentTintColor = iconTint ?? NSColor(theme.text.tertiary)
        fillBase = NSColor(theme.action.secondary.default.background)
        fillHover = NSColor(theme.action.secondary.hover.background)
        layer?.backgroundColor = fillBase.cgColor
        #if OSAURUS_DESIGN_SYSTEM
        inspectionTheme = theme
        sharedSymbolName = symbolName
        // The disabled token already supplies its intended ink; avoid a second
        // AppKit dimming pass over the symbol.
        (button.cell as? NSButtonCell)?.imageDimsWhenDisabled = false
        refreshInspectionChrome()
        #endif
    }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        layer?.cornerRadius = side > 0 ? side / 2 : 0
        #if OSAURUS_DESIGN_SYSTEM
        refreshInspectionChrome()
        #endif
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
        #if OSAURUS_DESIGN_SYSTEM
        inspectedHover = true; refreshInspectionChrome()
        #endif
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        layer?.backgroundColor = fillBase.cgColor
        #if OSAURUS_DESIGN_SYSTEM
        inspectedHover = false; refreshInspectionChrome()
        #endif
    }

    @objc private func fire() { block() }

    func setAction(_ newAction: @escaping () -> Void) {
        block = newAction
    }
}

// MARK: - Native Assistant Actions View

/// Copy + Regenerate pinned under every completed assistant turn.
/// Always visible (no hover), so the table coordinator can skip hover
/// reconfigures for assistant rows entirely.
final class NativeAssistantActionsView: NSView {

    private let copyButton: HeaderCircleActionControl
    private let regenerateButton: HeaderCircleActionControl
    let speakButton: HeaderCircleActionControl
    /// Overflow "…" menu holding the response timestamp and the Inspect action.
    let overflowButton: HeaderCircleActionControl
    /// "3 files changed · View changes" — the end-of-turn entry point into
    /// the File Changes panel. Hidden until the journal reports this turn
    /// recorded something; refreshed when history changes (e.g. a revert).
    private let fileChangesButton = NSButton(frame: .zero)
    private var fileChangesSummary: FileChangeTurnSummary?
    private var fileChangesLookupTurnId: UUID?
    nonisolated(unsafe) private var fileChangesObservation: NSObjectProtocol?

    private var turnId: UUID = UUID()
    private var responseTimestamp: Date = Date()
    private var responseStatsForTurn: ((UUID) -> String?)?
    private var onCopy: ((UUID) -> Void)?
    private var onRegenerate: ((UUID) -> Void)?
    var onSpeak: ((UUID) -> Void)?
    private var onDeleteMessage: ((UUID) -> Void)?

    /// Formats the response timestamp for the overflow menu header, e.g.
    /// "Jun 20, 10:17 PM". Localized template so order/separators follow locale.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd jmm")
        return formatter
    }()

    nonisolated(unsafe) private var ttsObservation: NSObjectProtocol?
    nonisolated(unsafe) private var ttsConfigObservation: NSObjectProtocol?
    private var currentTheme: (any ThemeProtocol)?
    private var speakWidthConstraint: NSLayoutConstraint?
    private var speakLeadingConstraint: NSLayoutConstraint?
    private var overflowWidthConstraint: NSLayoutConstraint?
    private var overflowLeadingConstraint: NSLayoutConstraint?
    /// Image-generation turns render as just the produced image, so Read-aloud
    /// (nothing to speak) and the overflow "…" Inspect (no request log) collapse
    /// away — only Copy and Regenerate stay.
    #if OSAURUS_DESIGN_SYSTEM
    private let assignedMenu = AssignedMenuPanelPresenter()
    #endif
    private var hideSecondaryActions = false
    private var actionSizeConstraints: [NSLayoutConstraint] = []
    private var regenerateLeadingConstraint: NSLayoutConstraint?
    private var fileChangesLeadingConstraint: NSLayoutConstraint?
    private var fileChangesTrailingConstraint: NSLayoutConstraint?
    private var fileChangesHiddenWidthConstraint: NSLayoutConstraint?

    override init(frame: NSRect) {
        let copyControl = HeaderCircleActionControl(action: {})
        let regenControl = HeaderCircleActionControl(action: {})
        let speakControl = HeaderCircleActionControl(action: {})
        let overflowControl = HeaderCircleActionControl(action: {})
        self.copyButton = copyControl
        self.regenerateButton = regenControl
        self.speakButton = speakControl
        self.overflowButton = overflowControl
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        copyButton.translatesAutoresizingMaskIntoConstraints = false
        regenerateButton.translatesAutoresizingMaskIntoConstraints = false
        speakButton.translatesAutoresizingMaskIntoConstraints = false
        overflowButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(copyButton)
        addSubview(regenerateButton)
        addSubview(speakButton)
        addSubview(overflowButton)

        copyButton.setAction { [weak self] in
            guard let self else { return }
            self.onCopy?(self.turnId)
        }
        regenerateButton.setAction { [weak self] in
            guard let self else { return }
            self.onRegenerate?(self.turnId)
        }
        speakButton.setAction { [weak self] in
            guard let self else { return }
            self.onSpeak?(self.turnId)
        }
        overflowButton.setAction { [weak self] in
            guard let self else { return }
            self.presentOverflowMenu()
        }

        let size: CGFloat = 28
        // Speaker sits between Regenerate and the overflow "…" button. Its
        // leading hangs off Regenerate and collapses to 0 (along with its width)
        // when TTS is disabled, so the overflow button slides left to butt
        // against Regenerate and stays the last button in the row.
        let speakLeading = speakButton.leadingAnchor.constraint(
            equalTo: regenerateButton.trailingAnchor,
            constant: 4
        )
        let speakWidth = speakButton.widthAnchor.constraint(equalToConstant: size)
        self.speakLeadingConstraint = speakLeading
        self.speakWidthConstraint = speakWidth

        // Overflow "…" normally follows Speaker and carries the trailing pin, but
        // collapses (width/leading → 0) for image-only turns the same way Speaker
        // does for TTS-off, so the row tightens to just Copy / Regenerate.
        let overflowLeading = overflowButton.leadingAnchor.constraint(
            equalTo: speakButton.trailingAnchor,
            constant: 4
        )
        let overflowWidth = overflowButton.widthAnchor.constraint(equalToConstant: size)
        self.overflowLeadingConstraint = overflowLeading
        self.overflowWidthConstraint = overflowWidth

        NSLayoutConstraint.activate([
            copyButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: size),
            copyButton.heightAnchor.constraint(equalToConstant: size),

            regenerateButton.leadingAnchor.constraint(equalTo: copyButton.trailingAnchor, constant: 4),
            regenerateButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            regenerateButton.widthAnchor.constraint(equalToConstant: size),
            regenerateButton.heightAnchor.constraint(equalToConstant: size),

            // Speaker follows Regenerate. When hidden its width/leading collapse
            // to 0 so the overflow button becomes the effective third button.
            speakLeading,
            speakButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            speakWidth,
            speakButton.heightAnchor.constraint(equalToConstant: size),

            // Overflow "…" is normally last and carries the trailing pin; it
            // collapses for image-only turns (see overflowLeading/overflowWidth).
            overflowLeading,
            overflowButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            overflowWidth,
            overflowButton.heightAnchor.constraint(equalToConstant: size),
            overflowButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])

        fileChangesButton.title = ""
        fileChangesButton.translatesAutoresizingMaskIntoConstraints = false
        fileChangesButton.isBordered = false
        fileChangesButton.bezelStyle = .inline
        fileChangesButton.imagePosition = .imageLeading
        fileChangesButton.setButtonType(.momentaryChange)
        fileChangesButton.isHidden = true
        fileChangesButton.target = self
        fileChangesButton.action = #selector(openFileChanges)
        addSubview(fileChangesButton)
        let fileChangesTrailing = fileChangesButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        fileChangesTrailingConstraint = fileChangesTrailing
        let fileChangesHiddenWidth = fileChangesButton.widthAnchor.constraint(equalToConstant: 0)
        fileChangesHiddenWidthConstraint = fileChangesHiddenWidth
        NSLayoutConstraint.activate([
            fileChangesButton.leadingAnchor.constraint(equalTo: overflowButton.trailingAnchor, constant: 10),
            fileChangesButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            fileChangesHiddenWidth,
        ])
        fileChangesObservation = NotificationCenter.default.addObserver(
            forName: .fileChangesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fileChangesLookupTurnId = nil
                self.refreshFileChangesSummary()
            }
        }

        for control in [copyButton, regenerateButton, speakButton, overflowButton] {
            actionSizeConstraints += control.constraints.filter { $0.firstAttribute == .height || ($0.firstAttribute == .width && control !== speakButton && control !== overflowButton) }
        }
        regenerateLeadingConstraint = constraints.first { $0.firstItem as? NSView === regenerateButton && $0.firstAttribute == .leading }
        fileChangesLeadingConstraint = constraints.first { $0.firstItem as? NSView === fileChangesButton && $0.firstAttribute == .leading }

        ttsObservation = NotificationCenter.default.addObserver(
            forName: .ttsPlaybackStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyTTSVisibility()
                self?.refreshSpeakIcon()
            }
        }
        ttsConfigObservation = NotificationCenter.default.addObserver(
            forName: .ttsConfigurationChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyTTSVisibility()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observation = ttsObservation {
            NotificationCenter.default.removeObserver(observation)
        }
        if let observation = ttsConfigObservation {
            NotificationCenter.default.removeObserver(observation)
        }
        if let observation = fileChangesObservation {
            NotificationCenter.default.removeObserver(observation)
        }
    }

    // MARK: - File changes summary

    private func refreshFileChangesSummary() {
        let turn = turnId
        guard fileChangesLookupTurnId != turn else {
            applyFileChangesSummary()
            return
        }
        fileChangesLookupTurnId = turn
        fileChangesSummary = nil
        setFileChangesVisible(false)
        Task { @MainActor [weak self] in
            let summary = await FileChangeJournal.shared.turnSummary(turnId: turn)
            guard let self, self.turnId == turn else { return }
            self.fileChangesSummary = summary
            self.applyFileChangesSummary()
        }
    }

    private func applyFileChangesSummary() {
        guard let summary = fileChangesSummary, let theme = currentTheme else {
            setFileChangesVisible(false)
            return
        }
        let count = summary.fileCount
        var title = count == 1 ? L("1 file changed") : L("\(count) files changed")
        title += summary.allReverted ? " · " + L("reverted") : " · " + L("View changes")
        let tint = NSColor(summary.allReverted ? theme.text.tertiary : theme.text.link)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        fileChangesButton.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: theme.nsFont(.caption, weight: .medium),
                .foregroundColor: tint,
                .paragraphStyle: paragraph,
            ]
        )
        let cfg = NSImage.SymbolConfiguration(
            pointSize: theme.pointSize(.caption),
            weight: .medium
        )
        fileChangesButton.image = SymbolImageCache.image(
            "clock.arrow.circlepath", accessibilityDescription: nil
        )?.withSymbolConfiguration(cfg)
        fileChangesButton.contentTintColor = tint
        #if OSAURUS_DESIGN_SYSTEM
        fileChangesButton.attributedTitle = MessageHeaderInspectionStyle.text(title, property: "caption", color: tint, theme: theme)
        #endif
        fileChangesButton.toolTip = L("Show in File Changes")
        fileChangesButton.setAccessibilityLabel(title)
        setFileChangesVisible(true)
    }

    /// Hidden views still take part in Auto Layout: a hidden link keeps its
    /// last title's width, so it collapses to zero instead.
    private func setFileChangesVisible(_ visible: Bool) {
        if fileChangesButton.isHidden == visible { fileChangesButton.isHidden = !visible }
        fileChangesHiddenWidthConstraint?.isActive = !visible
        fileChangesTrailingConstraint?.isActive = visible
    }

    @objc private func openFileChanges() {
        guard let summary = fileChangesSummary else { return }
        FileChangeSummaryStore.requestPanel(sessionId: summary.sessionId, focusing: summary.firstSetId)
    }

    func configure(
        turnId: UUID,
        timestamp: Date,
        theme: any ThemeProtocol,
        hideSecondaryActions: Bool,
        onCopy: ((UUID) -> Void)?,
        onRegenerate: ((UUID) -> Void)?,
        onSpeak: ((UUID) -> Void)?,
        onDeleteMessage: ((UUID) -> Void)?,
        responseStatsForTurn: ((UUID) -> String?)? = nil
    ) {
        self.turnId = turnId
        self.responseTimestamp = timestamp
        self.hideSecondaryActions = hideSecondaryActions
        self.onCopy = onCopy
        self.onRegenerate = onRegenerate
        self.onSpeak = onSpeak
        self.onDeleteMessage = onDeleteMessage
        self.responseStatsForTurn = responseStatsForTurn
        let theme = theme.catalogFamily(30, authoritative: true)
        self.currentTheme = theme
        let side = MessageHeaderInspectionStyle.side(theme)
        actionSizeConstraints.forEach { $0.constant = side }
        #if OSAURUS_DESIGN_SYSTEM
        catalogAssignmentTarget(["footerActionsGap", "fileChangesGap", "actionsPaddingX"].map { MessageHeaderInspectionStyle.key + "elements.layout." + $0 } + [AgentContentSurfaceAssignments.key(30, "replyActions")], name: "Reply action row", theme: theme)
        wantsLayer = true
        layer?.backgroundColor = NSColor(AgentContentSurfaceAssignments.color(30, "replyActions", theme)).cgColor
        #endif
        regenerateLeadingConstraint?.constant = MessageHeaderInspectionStyle.layout("footerActionsGap", "gap", 4, theme)
        fileChangesLeadingConstraint?.constant = MessageHeaderInspectionStyle.layout("fileChangesGap", "gap", 10, theme)

        let pointSize = theme.pointSize(.caption)
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        copyButton.setSymbol(
            SymbolImageCache.image("doc.on.doc", accessibilityDescription: L("Copy"))?
                .withSymbolConfiguration(cfg),
            toolTip: L("Copy"),
            theme: theme,
            iconTint: nil,
            symbolName: "doc.on.doc"
        )
        regenerateButton.setSymbol(
            SymbolImageCache.image("arrow.counterclockwise", accessibilityDescription: L("Regenerate"))?
                .withSymbolConfiguration(cfg),
            toolTip: L("Regenerate"),
            theme: theme,
            iconTint: nil,
            symbolName: "arrow.counterclockwise"
        )
        overflowButton.setSymbol(
            SymbolImageCache.image("ellipsis", accessibilityDescription: L("More"))?
                .withSymbolConfiguration(cfg),
            toolTip: L("More"),
            theme: theme,
            iconTint: nil,
            symbolName: "ellipsis"
        )
        applyTTSVisibility()
        applyOverflowVisibility()
        refreshSpeakIcon()
        refreshFileChangesSummary()
    }

    /// Drops a ChatGPT-style overflow menu under the "…" button: a disabled
    /// header showing when the response arrived, then the Inspect action.
    private func presentOverflowMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(
            title: Self.timestampFormatter.string(from: responseTimestamp),
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let inspect = NSMenuItem(
            title: L("Inspect response"),
            action: #selector(inspectFromMenu),
            keyEquivalent: ""
        )
        inspect.target = self
        if let stats = responseStatsForTurn?(turnId), !stats.isEmpty {
            let details = NSMenu()
            details.autoenablesItems = false
            for value in stats.components(separatedBy: " \u{2022} ") {
                let item = NSMenuItem(title: value, action: nil, keyEquivalent: "")
                item.isEnabled = false
                details.addItem(item)
            }
            details.addItem(.separator())
            let log = NSMenuItem(
                title: L("Open request and response log"),
                action: #selector(inspectFromMenu),
                keyEquivalent: ""
            )
            log.target = self
            details.addItem(log)
            inspect.action = nil
            inspect.submenu = details
        }
        if let theme = currentTheme {
            let pointSize = theme.pointSize(.caption)
            let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            inspect.image = SymbolImageCache.image(
                "waveform.path.ecg.magnifyingglass",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(cfg)
        }
        menu.addItem(inspect)

        if onDeleteMessage != nil {
            menu.addItem(.separator())
            let delete = NSMenuItem(
                title: L("Delete message"),
                action: #selector(deleteMessageFromMenu),
                keyEquivalent: ""
            )
            delete.target = self
            if let theme = currentTheme {
                let pointSize = theme.pointSize(.caption)
                let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
                delete.image = SymbolImageCache.image("trash", accessibilityDescription: nil)?
                    .withSymbolConfiguration(cfg)
            }
            menu.addItem(delete)
        }

        // Anchor the menu's top-left just under the button's bottom-left so it
        // opens downward like the ChatGPT overflow menu. The button is a
        // non-flipped NSView, so its bottom edge is y == 0 and the 4pt gap sits
        // below it at a negative y.
        let origin = NSPoint(x: 0, y: -4)
        #if OSAURUS_DESIGN_SYSTEM
        assignedMenu.showContextMenu(menu, from: overflowButton, theme: currentTheme ?? CustomizableTheme.light())
        #else
        menu.popUp(positioning: nil, at: origin, in: overflowButton)
        #endif
    }

    @objc private func inspectFromMenu() {
        openInsights()
    }

    @objc private func deleteMessageFromMenu() {
        onDeleteMessage?(turnId)
    }

    /// Opens the Settings → Insights tab, focused on the request/response log
    /// this assistant turn produced. Request logs live only in memory for the
    /// current app session (and are capped at a ring-buffer limit), so turns
    /// from a previous launch or evicted entries have nothing to show — in
    /// that case we surface a themed alert instead of opening an unrelated
    /// (or empty) Insights list.
    private func openInsights() {
        MainActor.assumeIsolated {
            if InsightsService.shared.focus(turnId: turnId) {
                AppDelegate.shared?.showManagementWindow(initialTab: .insights)
            } else {
                presentLogUnavailableAlert()
            }
        }
    }

    @MainActor
    private func presentLogUnavailableAlert() {
        // Scope the alert to this chat window when we can resolve it, so it
        // dims and centers over the chat rather than another surface.
        let scope: ThemedAlertScope =
            window.flatMap { ChatWindowManager.shared.windowId(for: $0) }
            .map { .chat($0) } ?? .content
        let requestId = UUID()
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: L("Insights Unavailable"),
                message: L(
                    "Detailed request logs are kept only for a short duration to save storage, so there's nothing to show for this response."
                ),
                buttons: [.primary(L("OK")) {}],
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }

    private func refreshSpeakIcon() {
        guard let theme = currentTheme else { return }
        let pointSize = theme.pointSize(.caption)
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        let isThisTurnPlaying = TTSService.shared.playingMessageId == turnId
        let symbolName = isThisTurnPlaying ? "stop.fill" : "speaker.wave.2"
        let tooltip = isThisTurnPlaying ? L("Stop") : L("Read aloud")
        speakButton.setSymbol(
            SymbolImageCache.image(symbolName, accessibilityDescription: tooltip)?
                .withSymbolConfiguration(cfg),
            toolTip: tooltip,
            theme: theme,
            iconTint: nil,
            symbolName: symbolName
        )
        #if OSAURUS_DESIGN_SYSTEM
        speakButton.setInspectionSelected(isThisTurnPlaying)
        #endif
    }

    private func applyTTSVisibility() {
        let enabled = TTSConfigurationStore.load().enabled
        // Hide only when the `speak` tool drove playback. manual
        // taps keep the button so the stop swap stays available.
        let toolDriven =
            TTSService.shared.playingMessageId == turnId
            && TTSService.shared.activeSpeakCallId != nil
        let visible = enabled && !toolDriven && !hideSecondaryActions
        speakButton.isHidden = !visible
        speakWidthConstraint?.constant = visible ? currentTheme.map(MessageHeaderInspectionStyle.side) ?? 28 : 0
        speakLeadingConstraint?.constant = visible ? currentTheme.map { MessageHeaderInspectionStyle.layout("footerActionsGap", "gap", 4, $0) } ?? 4 : 0
    }

    /// Image-only turns have no request log to inspect, so the overflow "…" button
    /// collapses (width/leading → 0) the same way Speaker does for TTS-off.
    private func applyOverflowVisibility() {
        let visible = !hideSecondaryActions
        overflowButton.isHidden = !visible
        overflowWidthConstraint?.constant = visible ? currentTheme.map(MessageHeaderInspectionStyle.side) ?? 28 : 0
        overflowLeadingConstraint?.constant = visible ? currentTheme.map { MessageHeaderInspectionStyle.layout("footerActionsGap", "gap", 4, $0) } ?? 4 : 0
    }
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
    private var hoverArea: NSTrackingArea?

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

    // Pointing-hand cursor + subtle alpha dim on hover, matching the
    // hover affordances of the SwiftUI buttons elsewhere in chat.

    override func resetCursorRects() {
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard isEnabled else { return }
        animator().alphaValue = 0.85
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        animator().alphaValue = 1.0
    }
}

// MARK: - UserMessageInlineEditView

/// AppKit counterpart to SwiftUI `InlineEditView` — editable plain text plus Cancel / Save & Regenerate.
private final class UserMessageInlineEditView: NSView, NSTextViewDelegate {

    private let scrollView = AutoSizingScrollView()
    private let textView: CustomNSTextView
    private let editBox = NSView()
    private let buttonStack = NSStackView()
    private let hintLabel = NSTextField(labelWithString: "")
    private var cancelButton: PaddedInlineButton!
    private var confirmButton: PaddedInlineButton!
    #if OSAURUS_DESIGN_SYSTEM
    private let inspectorActions = NSHostingView(rootView: AnyView(EmptyView()))
    #endif

    private var getText: () -> String = { "" }
    private var setText: (String) -> Void = { _ in }
    private var onConfirm: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var onHeightChanged: (() -> Void) = {}

    private var lastTheme: (any ThemeProtocol)?
    private var didApplyInitialFocus = false
    private var lastLayoutWidth: CGFloat = 0
    private var buttonsTopConstraint: NSLayoutConstraint?

    /// Undo state scoped to this editor's lifetime. Without this, NSTextView
    /// registers undo actions with the WINDOW's undo manager; after the edit
    /// UI is torn down those stale actions still target the deallocated text
    /// view, and a later Cmd+Z crashes in `-[NSUndoManager undoNestedGroup]`
    /// (production crash APPLE-MACOS-TG).
    private let editorUndoManager = UndoManager()

    override init(frame frameRect: NSRect) {
        // TextKit 1 from birth — avoids the lazy TextKit 2 → 1 downgrade on
        // first `.layoutManager` access (see EditableTextView.makeNSView).
        let tv = CustomNSTextView(usingTextLayoutManager: false)
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
        // Opt out of ChatView's window-level Esc monitor so Esc reaches
        // this text view's `cancelOperation(_:)` and cancels the edit
        // instead of closing the chat window.
        tv.handlesEscapeLocally = true
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
        // Non-zero spacing guarantees a visible gap between the hint
        // and the buttons even when the spacer collapses to zero on
        // narrow bubbles.
        buttonStack.spacing = 12
        buttonStack.alignment = .centerY
        buttonStack.distribution = .fill
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        // Keyboard-convention hint on the leading side of the button
        // row. Kept short — Shift+Enter behaves like every other text
        // field so it doesn't need calling out; truncates first when
        // the row gets narrow.
        hintLabel.stringValue = L("Enter to save · Esc to cancel")
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.maximumNumberOfLines = 1
        hintLabel.isSelectable = false
        hintLabel.setContentHuggingPriority(.required, for: .horizontal)
        hintLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)

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

        // Esc is handled by the text view's `cancelOperation(_:)` (see
        // `textView(_:doCommandBy:)`) and by ChatView's Esc cascade when
        // the editor isn't focused — no keyEquivalent needed here.
        cancelButton = PaddedInlineButton(frame: .zero)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.bezelStyle = .rounded
        cancelButton.isBordered = false
        cancelButton.wantsLayer = true
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        confirmButton = PaddedInlineButton(frame: .zero)
        confirmButton.target = self
        confirmButton.action = #selector(confirmTapped)
        confirmButton.bezelStyle = .rounded
        confirmButton.isBordered = false
        confirmButton.wantsLayer = true
        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        confirmButton.image = SymbolImageCache.image("arrow.clockwise", accessibilityDescription: nil)
        confirmButton.imagePosition = .imageLeading

        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
        confirmButton.setContentHuggingPriority(.required, for: .horizontal)
        cancelButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        confirmButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(editBox)
        editBox.addSubview(scrollView)
        addSubview(buttonStack)
        #if OSAURUS_DESIGN_SYSTEM
        inspectorActions.translatesAutoresizingMaskIntoConstraints = false
        inspectorActions.setContentHuggingPriority(.required, for: .horizontal)
        buttonPair.addArrangedSubview(inspectorActions)
        #else
        buttonPair.addArrangedSubview(cancelButton)
        buttonPair.addArrangedSubview(confirmButton)
        #endif
        buttonStack.addArrangedSubview(hintLabel)
        buttonStack.addArrangedSubview(spacer)
        buttonStack.addArrangedSubview(buttonPair)

        NSLayoutConstraint.activate([
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            confirmButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
        ])

        let buttonsTop = buttonStack.topAnchor.constraint(equalTo: editBox.bottomAnchor, constant: 10)
        buttonsTopConstraint = buttonsTop
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
            buttonsTop,
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
        #if OSAURUS_DESIGN_SYSTEM
        let padding = theme.assignedMetric("component.library.3.padding", fallback: 8)
        textView.textContainerInset = NSSize(width: padding, height: padding)
        buttonStack.spacing = MessageBubbleInspectionStyle.layout(28, "actionButtonsGap", fallback: 12, theme: theme)
        buttonsTopConstraint?.constant = MessageBubbleInspectionStyle.layout(28, "editorActionsGap", fallback: 10, theme: theme)
        #endif

        #if OSAURUS_DESIGN_SYSTEM
        let fieldTheme = theme.catalogFamily(3, authoritative: true)
        #else
        let fieldTheme = theme
        #endif
        let radius = CGFloat(fieldTheme.radius.medium)
        editBox.layer?.cornerRadius = radius
        // Input chrome (matches the composer / prompt-card fields) with
        // an accent border so the box reads as "actively editing".
        editBox.layer?.backgroundColor = NSColor(fieldTheme.surface.raised).cgColor
        editBox.layer?.borderWidth = CGFloat(fieldTheme.stroke.default)
        editBox.layer?.borderColor = NSColor(fieldTheme.border.focus).cgColor

        // `type.body` complete recipe: font, tracking, minimum line height.
        let bodyAttributes = fieldTheme.textAttributes(.body, color: NSColor(fieldTheme.text.primary))
        textView.font = fieldTheme.nsFont(.body)
        textView.textColor = NSColor(fieldTheme.text.primary)
        textView.insertionPointColor = NSColor(fieldTheme.assignedColor("component.library.3.accent", fallback: fieldTheme.cursor))
        textView.defaultParagraphStyle = fieldTheme.paragraphStyle(.body)
        textView.typingAttributes = bodyAttributes
        #if OSAURUS_DESIGN_SYSTEM
        editBox.layer?.borderColor = NSColor(fieldTheme.assignedColor("component.library.3.border", fallback: fieldTheme.border.default)).cgColor
        editBox.catalogAssignmentTarget(["background", "border", "borderWidth", "radius", "padding"].map { "component.library.3." + $0 }, name: "Shared multiline editor", theme: fieldTheme)
        textView.catalogAssignmentTarget(["text", "foreground"].map { "component.library.3." + $0 }, name: "Shared multiline editor text", theme: fieldTheme)
        buttonStack.catalogAssignmentTarget(["component.library.28.elements.layout.editorActionsGap", "component.library.28.elements.layout.actionButtonsGap"], name: "Editor action row spacing", theme: theme)
        #endif

        hintLabel.font = theme.nsFont(.footnote)
        hintLabel.textColor = NSColor(theme.text.tertiary)
        #if OSAURUS_DESIGN_SYSTEM
        let hintFont = theme.assignedNativeFont(UserMessageInspectionStyle.key + "caption", fallback: theme.nsFont(.footnote))
        let hintParagraph = NSMutableParagraphStyle()
        hintParagraph.minimumLineHeight = theme.assignedLineHeight(UserMessageInspectionStyle.key + "caption", fallback: theme.lineHeight(.footnote))
        hintParagraph.lineBreakMode = .byTruncatingTail
        hintLabel.font = hintFont
        hintLabel.attributedStringValue = NSAttributedString(string: hintLabel.stringValue, attributes: [
            .font: hintFont, .paragraphStyle: hintParagraph, .kern: theme.assignedTracking(UserMessageInspectionStyle.key + "caption") ?? 0, .foregroundColor: NSColor(theme.text.secondary)])
        #endif

        if textView.string != getText() {
            textView.string = getText()
            textView.invalidateIntrinsicContentSize()
            scrollView.invalidateIntrinsicContentSize()
        }
        if let storage = textView.textStorage, storage.length > 0 {
            storage.setAttributes(bodyAttributes, range: NSRange(location: 0, length: storage.length))
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

    /// Re-measure once the editor knows its real width.
    ///
    /// Row height is derived from `fittingSize`, which reads the text
    /// view's *cached intrinsic height* — and that is computed from the
    /// text container's current width, not the final bubble width (Auto
    /// Layout has no height-for-width). At configure time and even at
    /// the start of this layout pass the scroll view hasn't tiled the
    /// document view to its final width yet, so long text that wraps to
    /// more lines at the real (narrower) width measured short and
    /// rendered with the first line scrolled out of view.
    ///
    /// So on a real width change: force the document view to the final
    /// clip width *now*, re-measure, then push the new row height on
    /// the next runloop tick (mutating table row heights from inside an
    /// active layout pass is what the "never layoutSubtreeIfNeeded in
    /// measureFittedRowHeight" comment guards against). Width-gated so
    /// steady-state layout passes (scrolling, hover) do no extra work.
    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0, abs(width - lastLayoutWidth) > 0.5 else { return }
        lastLayoutWidth = width

        scrollView.tile()
        let clipWidth = scrollView.contentView.bounds.width
        if clipWidth > 0, abs(textView.frame.width - clipWidth) > 0.5 {
            textView.setFrameSize(NSSize(width: clipWidth, height: textView.frame.height))
        }

        textView.invalidateIntrinsicContentSize()
        scrollView.invalidateIntrinsicContentSize()
        refreshScrollerVisibility()
        DispatchQueue.main.async { [weak self] in
            self?.onHeightChanged()
        }
    }

    /// Matches ContentBlockView.InlineEditView — Cancel secondary chrome; Save accent + white when non-empty.
    private func updateConfirmButtons(theme: any ThemeProtocol) {
        let empty = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        confirmButton.isEnabled = !empty
        #if OSAURUS_DESIGN_SYSTEM
        inspectorActions.rootView = AnyView(HStack(spacing: MessageBubbleInspectionStyle.layout(28, "actionButtonsGap", fallback: 8, theme: theme)) {
            SettingsButton(.secondary, L("Cancel"), verbatim: true) { [weak self] in self?.cancelTapped() }
            SettingsButton(.primary, L("Save & Regenerate"), icon: "arrow.clockwise", verbatim: true) { [weak self] in self?.confirmTapped() }
                .disabled(empty)
        }.fixedSize().environment(\.theme, theme))
        inspectorActions.invalidateIntrinsicContentSize()
        return
        #endif
        // `button.radius` = `radius.medium`; caption labels keep the edit
        // box's buttons subordinate to the text being edited.
        let cancelFont = theme.nsFont(.caption, weight: .medium)
        let confirmFont = theme.nsFont(.caption, weight: .semibold)
        let radius = CGFloat(theme.radius.medium)

        cancelButton.layer?.masksToBounds = true
        confirmButton.layer?.masksToBounds = true

        cancelButton.layer?.cornerRadius = radius
        cancelButton.layer?.backgroundColor = NSColor(theme.surface.subtle).cgColor
        cancelButton.layer?.borderWidth = CGFloat(theme.stroke.default)
        cancelButton.layer?.borderColor = NSColor(theme.action.border).cgColor
        cancelButton.attributedTitle = NSAttributedString(
            string: L("Cancel"),
            attributes: [
                .foregroundColor: NSColor(theme.text.secondary),
                .font: cancelFont,
            ]
        )

        confirmButton.layer?.cornerRadius = radius
        confirmButton.layer?.borderWidth = CGFloat(theme.stroke.default)
        confirmButton.layer?.borderColor = NSColor(theme.action.border).cgColor
        if let sym = SymbolImageCache.image("arrow.clockwise", accessibilityDescription: nil) {
            let config = theme.symbolConfiguration(.footnote, weight: .semibold)
            confirmButton.image = sym.withSymbolConfiguration(config) ?? sym
        }
        confirmButton.imagePosition = .imageLeading

        if empty {
            confirmButton.layer?.backgroundColor = NSColor(theme.surface.subtle).cgColor
            confirmButton.attributedTitle = NSAttributedString(
                string: L("Save & Regenerate"),
                attributes: [
                    .foregroundColor: NSColor(theme.text.secondary),
                    .font: confirmFont,
                ]
            )
            confirmButton.contentTintColor = NSColor(theme.text.secondary)
        } else {
            confirmButton.layer?.backgroundColor = NSColor(theme.action.primary.default.background).cgColor
            confirmButton.attributedTitle = NSAttributedString(
                string: L("Save & Regenerate"),
                attributes: [
                    .foregroundColor: NSColor(theme.action.primary.default.foreground),
                    .font: confirmFont,
                ]
            )
            confirmButton.contentTintColor = NSColor(theme.action.primary.default.foreground)
        }

        let padH = CGFloat(theme.space.s12)
        let padV = CGFloat(theme.space.s2)
        let imageGap = CGFloat(theme.space.s4)
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

    func undoManager(for view: NSTextView) -> UndoManager? {
        editorUndoManager
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
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Esc cancels the inline edit. The window-level Esc monitor
            // passes the event through because our text view sets
            // `handlesEscapeLocally` (see init).
            onCancel?()
            return true
        }
        return false
    }
}

// MARK: - NativeStatsView

/// Incomplete-response warning, with measured statistics when the agent opts in.
/// The same metrics remain available in the response overflow menu.
final class NativeStatsView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = false
        label.isEditable = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(
        ttft: TimeInterval?,
        tokensPerSecond: Double?,
        tokenCount: Int?,
        unclosedReasoning: Bool = false,
        modelLoad: TimeInterval? = nil,
        cachedInputTokens: Int? = nil,
        totalDuration: TimeInterval? = nil,
        showResponseMetrics: Bool = false,
        theme: any ThemeProtocol
    ) {
        label.stringValue = showResponseMetrics
            ? Self.statsText(
                ttft: ttft, tokensPerSecond: tokensPerSecond, tokenCount: tokenCount,
                unclosedReasoning: unclosedReasoning, modelLoad: modelLoad,
                cachedInputTokens: cachedInputTokens, totalDuration: totalDuration
            )
            : (unclosedReasoning ? L("⚠ thinking didn't close — answer may be in reasoning above") : "")
        label.font = theme.nsFont(.caption, monospacedDigit: true)
        label.textColor = NSColor(theme.text.tertiary)
        #if OSAURUS_DESIGN_SYSTEM
        let scoped = theme.catalogFamily(30, authoritative: true)
        label.attributedStringValue = MessageHeaderInspectionStyle.text(label.stringValue, property: "caption", color: NSColor(unclosedReasoning ? scoped.status.error.foreground : scoped.text.secondary), theme: scoped)
        #endif
    }

    /// Response metrics for the Inspect response menu, without a view hierarchy.
    static func statsText(
        ttft: TimeInterval?,
        tokensPerSecond: Double?,
        tokenCount: Int?,
        unclosedReasoning: Bool = false,
        modelLoad: TimeInterval? = nil,
        cachedInputTokens: Int? = nil,
        totalDuration: TimeInterval? = nil
    ) -> String {
        var parts: [String] = []
        // Wall-clock from the keypress to the end of the run: model load, every
        // tool-calling step and approval prompt included.
        if let totalDuration {
            parts.append(String(format: L("Worked for %@"), Self.formatLoad(totalDuration)))
        }
        if let ttft {
            if ttft < 0.01 {
                parts.append(String(format: L("TTFT %.0fms"), ttft * 1000))
            } else {
                parts.append(String(format: L("TTFT %.2fs"), ttft))
            }
        }
        // Retain separately recorded load data on older persisted turns.
        // New typed turns do not fabricate this attribution from global
        // activity; their TTFT includes the complete request-step wait.
        if let modelLoad, modelLoad >= 0.05 {
            parts.append(String(format: L("+%@ model load"), Self.formatLoad(modelLoad)))
        }
        if let tps = tokensPerSecond {
            parts.append(String(format: L("%.1f tok/s"), tps))
        }
        if let count = tokenCount {
            parts.append(count == 1 ? L("1 token") : L("\(count) tokens"))
        }
        // Prompt-cache hits: input the provider served from its cache (and,
        // through Router or direct BYOK, billed at the discounted rate).
        // Suppressed at zero so uncached turns look exactly as before.
        if let cachedInputTokens, cachedInputTokens > 0 {
            parts.append(String(format: L("%@ cached"), cachedInputTokens.formatted()))
        }
        // Trailing diagnostic chip — vmlx tells us the model never emitted
        // `</think>` (or the family's close tag) before EOS / max_tokens.
        // Three observed scenarios all benefit from the same hint:
        //   1. Reasoning-trained Qwen3.6-A3B / DSV4 fine-tunes loop on
        //      validation prompts ("give me a 20-digit number") — answer
        //      buried in reasoning; user should toggle the model's
        //      "Disable Thinking" option for the next turn (verified live).
        //   2. Gemma-4 / harmony-channel models capped early by
        //      `max_tokens` — analysis channel didn't close; user should
        //      raise the cap (verified live, gemma-4-e2b at 32 tok cap).
        //   3. Any thinking model that emitted EOS while still in
        //      reasoning — answer is in the pane above.
        // Text intentionally does NOT name a specific toggle so the chip
        // reads accurately for every model family.
        if unclosedReasoning {
            parts.append(L("⚠ thinking didn't close — answer may be in reasoning above"))
        }
        return parts.joined(separator: " \u{2022} ")
    }

    /// Seconds below a minute, m/s above it. A cold 27 GB bundle can take
    /// minutes on a machine under memory pressure, and "212.0s" is harder to
    /// read at a glance than "3m32s" — which is exactly the number a user
    /// needs to recognise as a load rather than a stall.
    static func formatLoad(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds.rounded())
        return "\(whole / 60)m\(whole % 60)s"
    }
}

// MARK: - NativeEmptyResponseNoticeView

/// Footer shown when the Osaurus Router billed a turn that produced no visible
/// text (and no reasoning/tools). Surfaces the charge honestly with a Retry
/// affordance rather than letting the turn be silently dropped.
final class NativeEmptyResponseNoticeView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton()
    #if OSAURUS_DESIGN_SYSTEM
    private var retryHost: NSHostingView<AnyView>?
    #endif
    static func inspectionHeight(_ theme: any ThemeProtocol) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        let label = theme.assignedLineHeight(NativeComponentInspectionStyle.key(40, "label"), fallback: 18)
        let caption = theme.assignedLineHeight(NativeComponentInspectionStyle.key(40, "caption"), fallback: 16)
        return max(NativeComponentInspectionStyle.metric(40, "height", 36, theme), label + caption + NativeComponentInspectionStyle.metric(40, "gap", 1, theme) + 2 * NativeComponentInspectionStyle.metric(40, "padding", 0, theme))
        #else
        return 36
        #endif
    }

    private var turnId: UUID = UUID()
    private var onRetry: ((UUID) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        for label in [titleLabel, detailLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.isSelectable = false
            label.isEditable = false
        }

        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        retryButton.title = L("Retry")
        retryButton.target = self
        retryButton.action = #selector(retryTapped)
        retryButton.setContentHuggingPriority(.required, for: .horizontal)
        retryButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(textStack)
        #if OSAURUS_DESIGN_SYSTEM
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.translatesAutoresizingMaskIntoConstraints = false
        retryHost = host
        let actionView: NSView = host
        #else
        let actionView: NSView = retryButton
        #endif
        addSubview(actionView)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: actionView.leadingAnchor, constant: -8),

            actionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func retryTapped() {
        onRetry?(turnId)
    }

    func configure(
        turnId: UUID,
        outputTokens: Int,
        costMicro: String,
        theme: any ThemeProtocol,
        onRetry: ((UUID) -> Void)?
    ) {
        let theme = theme.catalogFamily(40, authoritative: true)
        #if OSAURUS_DESIGN_SYSTEM
        wantsLayer = true
        layer?.backgroundColor = NSColor(AgentContentSurfaceAssignments.color(40, "emptyResponse", theme)).cgColor
        catalogAssignmentTarget([AgentContentSurfaceAssignments.key(40, "emptyResponse")], name: "Empty agent response notice", theme: theme)
        #endif
        self.turnId = turnId
        self.onRetry = onRetry

        let cfg = theme.symbolConfiguration(.caption, weight: .medium)
        iconView.image = NSImage(
            systemSymbolName: "exclamationmark.bubble",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(cfg)
        iconView.contentTintColor = NSColor(theme.status.warning.foreground)

        titleLabel.stringValue = L("The model returned no visible text")
        titleLabel.font = theme.nsFont(.label, weight: .medium)
        titleLabel.textColor = NSColor(theme.text.primary)

        let formattedCost = OsaurusRouter.formatMicroAsCredits(costMicro)
        let detail: String
        if outputTokens > 0 {
            detail = String(
                format: L("You were charged %@ for %d tokens."),
                formattedCost,
                outputTokens
            )
        } else {
            detail = String(format: L("You were charged %@."), formattedCost)
        }
        detailLabel.stringValue = detail
        detailLabel.font = theme.nsFont(.caption, monospacedDigit: true)
        detailLabel.textColor = NSColor(theme.text.tertiary)
        NativeComponentInspectionStyle.label(titleLabel, family: 40, property: "label", theme: theme)
        NativeComponentInspectionStyle.label(detailLabel, family: 40, property: "caption", theme: theme)
        #if OSAURUS_DESIGN_SYSTEM
        retryHost?.rootView = AnyView(Button(L("Retry")) { [weak self] in self?.retryTapped() }.assignedSettingsButtonStyle(.secondary, size: .compact).environment(\.theme, theme))
        wantsLayer = true
        layer?.backgroundColor = NSColor(theme.surface.raised).cgColor
        layer?.borderColor = NSColor(theme.border.default).cgColor
        layer?.borderWidth = theme.stroke.default
        layer?.cornerRadius = theme.radius.medium
        let pad = NativeComponentInspectionStyle.metric(40, "padding", 0, theme)
        for c in constraints {
            if c.firstItem as? NSView === iconView, c.firstAttribute == .leading { c.constant = pad }
            if c.firstItem as? NSView === retryHost, c.firstAttribute == .trailing { c.constant = -pad }
        }
        if let stack = titleLabel.superview as? NSStackView { stack.spacing = NativeComponentInspectionStyle.metric(40, "gap", 1, theme) }
        #endif
    }
}

// MARK: - NativeMessageCellView

final class NativeMessageCellView: NSTableCellView {

    // MARK: Subviews

    private var spacerView: NSView?
    private var nativeHeaderView: NativeHeaderView?
    private var nativeHeaderHeightConstraint: NSLayoutConstraint?

    // Native views (no NSHostingView)
    private var nativeMarkdownView: NativeMarkdownView?
    private var paragraphTopConstraint: NSLayoutConstraint?
    private var paragraphLeadingConstraint: NSLayoutConstraint?
    private var paragraphTrailingConstraint: NSLayoutConstraint?
    private var assistantActionsTopConstraint: NSLayoutConstraint?
    private var messageHeaderInsetConstraints: [NSLayoutConstraint] = []
    private var assistantActionInsetConstraints: [NSLayoutConstraint] = []
    private var assistantActionHeightConstraint: NSLayoutConstraint?
    private var statsHeightConstraint: NSLayoutConstraint?
    private var userActionHeight: CGFloat = 28
    /// Shimmering single-line status shown while an image is being generated
    /// ("Generating image… 1/4"), matching the running tool/thinking titles.
    private var statusShimmerLabel: ShimmerLabel?
    private var nativeThinkingView: NativeThinkingView?
    private var nativeCompactionMarkerView: NativeCompactionMarkerView?
    private var nativeToolCallGroupView: NativeToolCallGroupView?
    private var nativeActivityGroupView: NativeActivityGroupView?
    private var userMessageContainer: NSView?
    private var userTextView: NativeMarkdownView?
    private var userInlineEditView: UserMessageInlineEditView?
    private var userImageStack: NSStackView?
    private var userDocumentStack: NSStackView?
    /// Provenance chips above an enveloped user bubble (channel / delegated /
    /// scheduled / watcher). Nil for ordinary typed messages.
    private var userBadgeRow: NativeDispatchBadgeRow?
    /// Signature of the badge set the current user-message layout was built
    /// for; a change forces a rebuild, anything else reuses the views.
    private var userEnvelopeSignature: String?
    private var nativePendingView: NativePendingToolCallView?
    private var nativeTypingView: NativeTypingIndicatorView?
    private var nativeArtifactView: NativeArtifactCardView?
    private var nativeChartView: NativeChartView?
    private var nativeFileDiffView: NativeFileDiffView?
    private var nativeStatsView: NativeStatsView?
    private var nativeAssistantActionsView: NativeAssistantActionsView?
    private var nativeEmptyNoticeView: NativeEmptyResponseNoticeView?
    /// Follow-up suggestions are low-frequency (one per completed turn), so
    /// unlike the streaming-hot cells above this one hosts the SwiftUI
    /// `FollowUpSuggestionsBar` directly — its intrinsic size drives the row
    /// height via `fittingSize`.
    private var nativeFollowUpsView: NSHostingView<AnyView>?
    private var nativeConversationEventView: NSHostingView<AnyView>?
    private var nativeOnboardingView: NSHostingView<AnyView>?
    /// The hosted panel's own height, as SwiftUI last laid it out.
    private var onboardingContentHeight: CGFloat?

    private var userBubbleCornerRadius: CGFloat = 0
    private var userBubbleWidthConstraint: NSLayoutConstraint?
    /// Height occupied by attachments above the bubble (docs + images + gaps), set during rebuild.
    private var userAttachmentsHeight: CGFloat = 0
    private var userAttachmentGeometry = ""
    private var userAttachmentGap: CGFloat = 6
    /// Last CGColor assigned to `layer.backgroundColor` for the assistant bubble, so
    /// per-token reconfigures can skip the CoreAnimation mutation when nothing changed.
    private var lastBubbleBackgroundCGColor: CGColor?
    private var lastBubbleCornerRadius: CGFloat = 0
    private var lastBubbleMaskedCorners: CACornerMask = NativeMessageCellView.allCorners
    private static let allCorners: CACornerMask = [
        .layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner,
    ]

    // MARK: State

    private var currentKindTag: ContentBlockKindTag?
    private var currentBlockId: String?

    /// Bounding rect (in this cell's coordinate space) of the find-match
    /// occurrence at `index` within this cell's rendered text, or nil when
    /// the cell renders no searchable text or the index is out of range.
    /// Used by the table coordinator to scroll to the exact line of the
    /// current match inside messages taller than the viewport.
    func searchOccurrenceRect(_ index: Int) -> NSRect? {
        guard let mv = nativeMarkdownView ?? userTextView,
            let rect = mv.rectOfSearchOccurrence(index)
        else { return nil }
        return mv.convert(rect, to: self)
    }

    /// tracks inline edit vs read-only markdown so we rebuild when edit mode toggles (same block kind)
    private var userMessageInlineEditActive: Bool = false

    /// last width from CellRenderingContext — used for systemLayoutSizeFitting when reporting row height
    private var lastContextWidth: CGFloat = 400
    private var lastFullWidthMessages = false
    private var userBubbleHorizontalInset: CGFloat = 12
    private var userBubbleBottomInset: CGFloat = NativeMessageCellView.userBubbleTextInset
    private var userOuterTopGap: CGFloat = 8
    private var userBubbleTopInset: CGFloat = NativeMessageCellView.userBubbleTextInset

    // MARK: Identity

    static let reuseId = NSUserInterfaceItemIdentifier("NativeMessageCell")

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = false
        wantsLayer = true
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // NSTableView frames each cell to its row when the row is first laid
        // out, but we report measured heights asynchronously (after layout),
        // so a later noteHeightOfRows resizes the NSTableRowView without
        // re-framing the cell. The cell then lags its row — even ending up 0pt
        // tall after a collapse. The content still *draws* (clipsToBounds is
        // false), so this stayed invisible for every non-interactive cell. But
        // a 0-height cell returns nil from hitTest before it ever consults its
        // subviews, so the file-diff card stopped receiving clicks after a
        // toggle/scroll. Pin the cell to fill its row so its frame always
        // tracks the row height and hit-testing keeps working.
        if let row = superview {
            autoresizingMask = [.width, .height]
            frame = row.bounds
        }
    }

    override func layout() {
        super.layout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        nativeMarkdownView?.resetForReuse()
        userTextView?.resetForReuse()
    }

    /// Row height from Auto Layout — avoids drift from hand-summed constants vs. actual constraints.
    /// AppKit `NSView` uses `fittingSize` (UIKit’s `systemLayoutSizeFitting` is not available here).
    /// Table view still uses `heightOfRow:` + cache (see MessageTableRepresentable); this only feeds accurate measurements.
    private func measureFittedRowHeight() -> CGFloat {
        // never call layoutSubtreeIfNeeded() here — heightOfRow / onHeightMeasured can run during an active layout pass
        let targetWidth = max(bounds.width > 1 ? bounds.width : lastContextWidth, 100)

        // user message: container is not pinned to cell bottom, so compute height manually.
        if userDocumentStack != nil || userImageStack != nil || userMessageContainer != nil {
            // Attachments above bubble (fixed heights)
            let attachOffset: CGFloat =
                userAttachmentsHeight > 0
                ? userOuterTopGap + userAttachmentsHeight + userAttachmentGap
                : userOuterTopGap

            if let container = userMessageContainer {
                var widthPin: NSLayoutConstraint?
                if bounds.width <= 1 {
                    let c = widthAnchor.constraint(equalToConstant: targetWidth)
                    c.priority = .required
                    c.isActive = true
                    widthPin = c
                }
                defer { widthPin?.isActive = false }
                var containerH = container.fittingSize.height
                if containerH < 2, let mv = userTextView {
                    let bubbleW = userBubbleWidthConstraint?.constant ?? max(lastContextWidth - 2 * CellRenderingContext.threadRowInset, 100)
                    let textH = mv.measuredHeight(for: max(bubbleW - 2 * userBubbleHorizontalInset, 1))
                    containerH = userBubbleTopInset + textH + userBubbleBottomInset
                }
                // + actions footer reserved below the bubble, then a small
                // bottom margin so the next (assistant) cell sits close.
                let footer = userActionHeight + NativeCellHeightEstimator.userActionsTopGap
                return ceil(max(attachOffset + containerH + footer + 2, 56))
            }
            // Attachment-only (no text bubble)
            return ceil(max(userOuterTopGap + userAttachmentsHeight + userActionHeight + NativeCellHeightEstimator.userActionsTopGap + 2, 56))
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
        userBubbleTopInset = Self.userBubbleTextInset - Self.leadingAboveGlyphs(context.theme)
        let tag = block.kind.kindTag
        let sameKind = tag == currentKindTag && lastFullWidthMessages == context.fullWidthMessages
        lastFullWidthMessages = context.fullWidthMessages
        currentKindTag = tag
        currentBlockId = block.id

        switch block.kind {
        case .groupSpacer:
            configureAsSpacer(sameKind: sameKind)

        case let .header(role, name, _):
            configureAsHeader(block: block, role: role, name: name, context: context, sameKind: sameKind)

        case let .paragraph(_, text, isStreaming, role):
            configureAsParagraph(
                block: block,
                text: text,
                isStreaming: isStreaming,
                role: role,
                context: context,
                sameKind: sameKind
            )

        case let .thinking(_, text, isStreaming, duration):
            configureAsThinking(
                block: block,
                text: text,
                isStreaming: isStreaming,
                duration: duration,
                context: context,
                sameKind: sameKind
            )

        case let .toolCallGroup(calls):
            configureAsToolCallGroup(block: block, calls: calls, context: context, sameKind: sameKind)

        case let .activityGroup(children):
            configureAsActivityGroup(block: block, children: children, context: context, sameKind: sameKind)

        case let .userMessage(text, attachments, timestamp, responseTurnId, envelope, author):
            configureAsUserMessage(
                block: block,
                text: text,
                attachments: attachments,
                timestamp: timestamp,
                responseTurnId: responseTurnId,
                envelope: envelope,
                author: author,
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

        case let .typingIndicator(phase):
            configureAsTypingIndicator(phase: phase, prefillProgress: block.prefillProgress, context: context, sameKind: sameKind)

        case let .sharedArtifact(artifact):
            configureAsArtifact(block: block, artifact: artifact, context: context, sameKind: sameKind)

        case let .chart(spec):
            configureAsChart(block: block, spec: spec, context: context, sameKind: sameKind)

        case let .fileDiff(diff):
            configureAsFileDiff(block: block, diff: diff, context: context, sameKind: sameKind)

        case let .generationStats(
            ttft, tokensPerSecond, tokenCount, unclosedReasoning, modelLoad, cachedInputTokens, totalDuration
        ):
            configureAsStats(
                ttft: ttft,
                tokensPerSecond: tokensPerSecond,
                tokenCount: tokenCount,
                unclosedReasoning: unclosedReasoning,
                modelLoad: modelLoad,
                cachedInputTokens: cachedInputTokens,
                totalDuration: totalDuration,
                context: context,
                sameKind: sameKind
            )

        case let .compactionMarker(savedTokens, modelName, summaryText):
            configureAsCompactionMarker(
                block: block,
                savedTokens: savedTokens,
                modelName: modelName,
                summaryText: summaryText,
                context: context,
                sameKind: sameKind
            )

        case let .assistantActions(turnId, imageOnly, timestamp):
            configureAsAssistantActions(
                turnId: turnId,
                imageOnly: imageOnly,
                timestamp: timestamp,
                context: context,
                sameKind: sameKind
            )

        case let .emptyResponseNotice(turnId, outputTokens, costMicro, _):
            configureAsEmptyResponseNotice(
                turnId: turnId,
                outputTokens: outputTokens,
                costMicro: costMicro,
                context: context,
                sameKind: sameKind
            )

        case let .followUpSuggestions(_, suggestions):
            configureAsFollowUpSuggestions(
                block: block,
                suggestions: suggestions,
                context: context,
                sameKind: sameKind
            )

        case let .conversationEvent(_, text, icon, attentionId):
            configureAsConversationEvent(
                block: block, text: text, icon: icon, attentionId: attentionId, context: context,
                sameKind: sameKind
            )

        case let .runLocation(_, text):
            configureAsOnboardingHost(
                block: block, rootView: AnyView(RunLocationLabel(text: text)), topInset: 0, context: context,
                sameKind: sameKind)

        case let .onboardingPanel(_, panel):
            configureAsOnboardingHost(
                block: block, rootView: AnyView(OnboardingPanelView(panel: panel)), topInset: 4, context: context,
                sameKind: sameKind)
        }
    }

    /// The first run's panel and run-location label: SwiftUI rows that
    /// report their fitted height like the conversation event row.
    private func configureAsOnboardingHost(
        block: ContentBlock,
        rootView: AnyView,
        topInset: CGFloat,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        let id = block.id
        // The panel reports its own fitted height: its lineup reflows with the
        // width, so a one-time fitting read goes stale. Top-aligned so a row
        // still on its old height never floats the panel down.
        let rowHeight = { (content: CGFloat) in (topInset + content + 8).rounded(.up) }
        let themed = AnyView(
            rootView
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [weak self] height in
                    self?.onboardingContentHeight = height
                    context.onHeightMeasured?(rowHeight(height), id)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .environment(\.theme, context.theme)
        )
        if !sameKind || nativeOnboardingView == nil {
            removeAllContentViews()
            onboardingContentHeight = nil
            let hv = NSHostingView(rootView: themed)
            hv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hv)
            NSLayoutConstraint.activate([
                hv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: context.rowHorizontalInset),
                hv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -context.rowHorizontalInset),
                hv.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
                hv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            ])
            nativeOnboardingView = hv
        } else {
            nativeOnboardingView?.rootView = themed
        }
        // A reused host keeps its geometry, so the new block still needs one report.
        DispatchQueue.main.async { [weak self] in
            guard let height = self?.onboardingContentHeight else { return }
            context.onHeightMeasured?(rowHeight(height), id)
        }
    }

    private func configureAsConversationEvent(
        block: ContentBlock,
        text: String,
        icon: String,
        attentionId: UUID?,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        let rootView = AnyView(
            ConversationEventRow(text: text, icon: icon, attentionId: attentionId)
                .environment(\.theme, context.theme)
        )
        if !sameKind || nativeConversationEventView == nil {
            removeAllContentViews()
            let hv = NSHostingView(rootView: rootView)
            hv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hv)
            NSLayoutConstraint.activate([
                hv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: context.rowHorizontalInset),
                hv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -context.rowHorizontalInset),
                hv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                hv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            ])
            nativeConversationEventView = hv
        } else {
            nativeConversationEventView?.rootView = rootView
        }
        let id = block.id
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            context.onHeightMeasured?(self.measureFittedRowHeight(), id)
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
            v.heightAnchor.constraint(equalToConstant: 8),
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
            let bottomGap = bottomAnchor.constraint(equalTo: hv.bottomAnchor, constant: 8)
            // below required so transient table sizing (e.g. NSView-Encapsulated-Layout-Height) can
            // squeeze the cell without fighting our top+height+bottom; row height still comes from the delegate
            bottomGap.priority = .init(999)
            let heightC = hv.heightAnchor.constraint(equalToConstant: 28)
            NSLayoutConstraint.activate([
                hv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: context.rowHorizontalInset),
                hv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -context.rowHorizontalInset),
                hv.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                heightC,
                bottomGap,
            ])
            nativeHeaderView = hv
            nativeHeaderHeightConstraint = heightC
            messageHeaderInsetConstraints = constraints.filter { $0.firstItem as? NSView === hv && $0.firstAttribute == .top }
            messageHeaderInsetConstraints.append(bottomGap)
        }
        nativeHeaderHeightConstraint?.constant = NativeCellHeightEstimator.headerInnerHeight(for: context.theme)
        let paddingY = MessageHeaderInspectionStyle.layout("headerPaddingY", "padding", 8, context.theme)
        for c in messageHeaderInsetConstraints { c.constant = paddingY }

        let displayName = role == .user ? "You" : (name.isEmpty ? L("Osaurus") : name)
        nativeHeaderView?.configure(
            turnId: block.turnId,
            role: role,
            name: displayName,
            avatar: context.agentAvatar,
            customAvatarPath: context.agentCustomAvatarPath,
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

    /// Convert the cell's session redaction dict (`original ->
    /// placeholder` from the Privacy Filter) into the form
    /// `RedactionHighlighter` consumes (`original -> (token,
    /// direction)`). Pulled out of `configureAsParagraph` /
    /// `configureAsUserMessage` because both call sites need the
    /// same conversion with a different direction.
    static func buildHighlights(
        from sessionRedactions: [String: String],
        direction: RedactionHighlight.Direction
    ) -> [String: RedactionHighlight] {
        RedactionHighlight.buildDictionary(from: sessionRedactions, direction: direction)
    }

    // MARK: - Paragraph (native NSTextView)

    /// True when an assistant paragraph is really a live image-generation status
    /// ("Loading image model…" / "Generating image… 1/4"). Matched against the
    /// same localized strings `ChatView` writes into `turn.content`.
    private static func isImageGenerationStatus(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains("\n") else { return false }
        return t == L("Loading image model…") || t.hasPrefix(L("Generating image…"))
    }

    /// Render the image-generation status as a shimmering single-line label,
    /// reusing the same `ShimmerLabel` the running tool/thinking titles use.
    private func configureAsImageStatusShimmer(text: String, context: CellRenderingContext) {
        let label: ShimmerLabel
        if let existing = statusShimmerLabel {
            label = existing
        } else {
            removeAllContentViews()
            let l = ShimmerLabel()
            l.translatesAutoresizingMaskIntoConstraints = false
            l.wantsLayer = true
            addSubview(l)
            NSLayoutConstraint.activate([
                l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: context.rowHorizontalInset),
                l.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -context.rowHorizontalInset),
                l.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            ])
            statusShimmerLabel = l
            label = l
        }
        let font = context.theme.nsFont(.body)
        label.configure(
            text: text,
            font: font,
            baseColor: NSColor(context.theme.text.primary).withAlphaComponent(0.4),
            highlightColor: NSColor(context.theme.text.primary)
        )
        label.start()
        if let id = currentBlockId {
            // Mirror the paragraph path's inset budget (top 4 + bottom 4) on top
            // of a single line so the row height matches the static text it swaps.
            context.onHeightMeasured?(ceil(context.theme.lineHeight(.body)) + 8, id)
        }
    }

    private func configureAsParagraph(
        block: ContentBlock,
        text: String,
        isStreaming: Bool,
        role: MessageRole,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        let theme = role == .assistant ? context.theme.catalogFamily(29, authoritative: true) : context.theme
        let insetX = context.rowHorizontalInset
        #if OSAURUS_DESIGN_SYSTEM
        catalogAssignmentTarget(["component.library.29.elements.layout.contentInset"], name: "Agent reply text layout", theme: theme)
        #endif
        let contentWidth = max(1, context.width - 2 * insetX)
        let minimumHeight = role == .assistant ? AssistantMessageInspectionStyle.metric("height", 0, theme) : 0
        // While an image is generating, the assistant "body" is a transient
        // status string. Render it as a shimmer to match the running tool /
        // thinking titles instead of flat, static text.
        if role == .assistant, Self.isImageGenerationStatus(text) {
            configureAsImageStatusShimmer(text: text, context: context)
            return
        }
        // Leaving the status state (e.g. the final image markdown replaces it):
        // drop the shimmer and fall through to the normal markdown path.
        if statusShimmerLabel != nil {
            removeAllContentViews()
        }

        if !sameKind || nativeMarkdownView == nil {
            removeAllContentViews()
            let mv = NativeMarkdownView()
            mv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(mv)
            let top = mv.topAnchor.constraint(equalTo: topAnchor)
            let leading = mv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insetX)
            let trailing = mv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insetX)
            NSLayoutConstraint.activate([leading, trailing, top])
            paragraphLeadingConstraint = leading
            paragraphTrailingConstraint = trailing
            paragraphTopConstraint = top
            nativeMarkdownView = mv
        }
        let mv = nativeMarkdownView!
        let verticalInset = Self.paragraphVerticalInset(for: role, theme: theme)
        let topInset = Self.paragraphTopInset(for: role, theme: theme)
        paragraphTopConstraint?.constant = topInset
        paragraphLeadingConstraint?.constant = insetX
        paragraphTrailingConstraint?.constant = -insetX
        mv.onHeightChanged = { [weak self, weak mv] in
            guard let self, let mv, let id = self.currentBlockId else { return }
            let h = mv.measuredHeight(for: contentWidth)
            context.onHeightMeasured?(max(minimumHeight, h + topInset + verticalInset), id)
        }
        mv.onImagePreview = { img in context.onImagePreviewImage?(img) }
        mv.configure(
            text: text,
            width: contentWidth,
            theme: theme,
            cacheKey: block.id,
            isStreaming: isStreaming
        )
        // Assistant bubble: any placeholder the cloud emitted has
        // already been swapped back to the original by the
        // unscrubber, so the user is reading their own PII. Flag
        // every matching span as `.inbound` so the popover reads
        // "Restored from [TOKEN]" — that's the trust signal that
        // proves the wire actually saw the token, not the original.
        mv.setRedactionHighlights(
            Self.buildHighlights(from: context.sessionRedactions, direction: .inbound),
            theme: theme
        )
        mv.setSearchHighlight(
            query: context.searchHighlightQuery,
            currentIndex: context.searchCurrentIndex(forBlock: block),
            theme: theme
        )

        // Apply assistant bubble background only when the target value actually changes —
        // configure() runs on every streaming token, so unconditional CGColor assignment
        // would churn the layer and force per-token compositor work.
        let targetBg: CGColor?
        let targetRadius: CGFloat
        if role == .assistant {
            // `component.chat.message`: opaque chat.assistant.background at
            // radius.bubble, no outline, so the paragraphs of one reply read
            // as a single surface.
            targetBg = NSColor(theme.chat.assistantBackground).cgColor
            targetRadius = CGFloat(theme.radius.bubble)
        } else {
            targetBg = nil
            targetRadius = 0
        }
        // sppress implicit CABasicAnimation on layer property mutations. Without this,
        // every backgroundColor / cornerRadius change kicks off a 0.25s animation that
        // continues compositing across frames during streaming
        let bgChanged = !cgColorsEqual(lastBubbleBackgroundCGColor, targetBg)
        let radiusChanged = lastBubbleCornerRadius != targetRadius
        #if OSAURUS_DESIGN_SYSTEM
        if role == .assistant {
            catalogAssignmentTarget(["background", "radius", "border", "borderWidth", "padding", "height"].map { AssistantMessageInspectionStyle.key + $0 }, name: "Assistant message block", theme: theme)
            nativeMarkdownView?.catalogAssignmentTarget(["text", "foreground", "accent"].map { AssistantMessageInspectionStyle.key + $0 }, name: "Assistant message text", theme: theme)
        }
        #endif
        let borderWidth = role == .assistant ? MessageBubbleInspectionStyle.borderWidth(29, theme: theme) : 0
        let borderColor = borderWidth > 0 ? NSColor(theme.border.default).cgColor : nil
        let borderChanged = layer?.borderWidth != borderWidth || !cgColorsEqual(layer?.borderColor, borderColor)
        if bgChanged || radiusChanged || borderChanged {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if targetBg != nil { self.wantsLayer = true }
            if bgChanged {
                self.layer?.backgroundColor = targetBg
                lastBubbleBackgroundCGColor = targetBg
            }
            if radiusChanged {
                self.layer?.cornerRadius = targetRadius
                lastBubbleCornerRadius = targetRadius
            }
            if borderChanged {
                layer?.borderWidth = borderWidth
                layer?.borderColor = borderColor
            }
            CATransaction.commit()
        }
        if role == .assistant {
            setBubbleJoins(previous: context.bubbleJoinsPrevious, next: context.bubbleJoinsNext)
        }

        // always report height: configure() can return early when text is unchanged (e.g. tool row
        // expand/collapse) and otherwise the table keeps a stale row height → clipped / squeezed text.
        let h = mv.measuredHeight(for: contentWidth) + topInset + verticalInset
        context.onHeightMeasured?(max(minimumHeight, h), block.id)
    }

    /// Text inset above and below a paragraph. Assistant paragraphs paint the
    /// reply surface on the cell, so they need room inside it.
    static func paragraphVerticalInset(for role: MessageRole, theme: (any ThemeProtocol)? = nil) -> CGFloat {
        if role == .assistant, let theme { return theme.catalogLayoutMetric("component.library.29.elements.layout.contentInset", inheriting: AssistantMessageInspectionStyle.metric("padding", 12, theme)) }
        return role == .assistant ? 12 : 4
    }

    /// Top inset for a paragraph. On the assistant surface it gives back the
    /// leading the minimum line height adds above the first line, so the
    /// glyphs sit at the same distance from both edges.
    static func paragraphTopInset(for role: MessageRole, theme: any ThemeProtocol) -> CGFloat {
        let inset = paragraphVerticalInset(for: role, theme: theme)
        return role == .assistant ? inset - leadingAboveGlyphs(theme) : inset
    }

    /// Text inset inside the user bubble, measured from the glyphs.
    static let userBubbleTextInset: CGFloat = 10

    /// Space TextKit puts above the glyphs when a body line is raised to the
    /// theme's minimum line height.
    static func leadingAboveGlyphs(_ theme: any ThemeProtocol) -> CGFloat {
        let font = theme.nsFont(.body)
        let natural = ceil(font.ascender - font.descender + font.leading)
        return max(0, theme.lineHeight(.body) - natural)
    }

    // MARK: - Thinking (NativeThinkingView)

    private func configureAsThinking(
        block: ContentBlock,
        text: String,
        isStreaming: Bool,
        duration: TimeInterval?,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeThinkingView == nil {
            removeAllContentViews()
            let tv = NativeThinkingView()
            tv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(tv)
            NSLayoutConstraint.activate([
                tv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: context.rowHorizontalInset),
                tv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -context.rowHorizontalInset),
                tv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            ])
            nativeThinkingView = tv
        }
        let tv = nativeThinkingView!
        let thinkingLen: Int?
        if case .thinking = block.kind { thinkingLen = text.count } else { thinkingLen = nil }

        let isExpanded = context.expandedIds.contains(block.id)
        tv.configure(
            thinking: text,
            thinkingLength: thinkingLen,
            width: context.width - 2 * context.rowHorizontalInset,
            isStreaming: isStreaming,
            isExpanded: isExpanded,
            duration: duration,
            theme: context.theme,
            blockId: block.id,
            sessionRedactions: context.sessionRedactions,
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

    // MARK: - Compaction Marker (NativeCompactionMarkerView)

    private func configureAsCompactionMarker(
        block: ContentBlock,
        savedTokens: Int,
        modelName: String,
        summaryText: String,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeCompactionMarkerView == nil {
            removeAllContentViews()
            let mv = NativeCompactionMarkerView()
            mv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(mv)
            NSLayoutConstraint.activate([
                mv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: context.rowHorizontalInset),
                mv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -context.rowHorizontalInset),
                mv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            ])
            nativeCompactionMarkerView = mv
        }
        let isExpanded = context.expandedIds.contains(block.id)
        nativeCompactionMarkerView?.configure(
            savedTokens: savedTokens,
            modelName: modelName,
            summaryText: summaryText,
            width: context.width - 2 * context.rowHorizontalInset,
            isExpanded: isExpanded,
            theme: context.theme,
            blockId: block.id,
            onToggle: { [weak self] in
                guard let self else { return }
                context.onToggleExpand(block.id)
                self.nativeCompactionMarkerView?.onHeightChanged?()
            },
            onHeightChanged: { [weak self] in
                guard let self, let mv = self.nativeCompactionMarkerView,
                    let id = self.currentBlockId
                else { return }
                let h = mv.measuredHeight() + 8
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
        // Consult the cache up front. `sameKind` alone isn't enough — the
        // same cell can be asked to render a *different* tool-call group
        // block id in back-to-back configures (snapshot diff reorder /
        // recycle). The existing `nativeToolCallGroupView` belongs to the
        // PREVIOUS block id; reusing it for the new block puts it under
        // the wrong cache binding and the new block's actual cached
        // view stays orphaned. Remount whenever the currently mounted
        // gv isn't the one the cache says belongs to `block.id`.
        let cachedGV = context.cachedToolGroupView?(block.id)
        let needsRemount =
            !sameKind
            || nativeToolCallGroupView == nil
            || nativeToolCallGroupView !== cachedGV && cachedGV != nil
        if needsRemount {
            removeAllContentViews()
            // Reuse a cached group view for this block id when one exists.
            // The cached instance retains its rendered layers (ring stroke,
            // icon, title), so reparenting after a cell recycle paints
            // instantly with no re-animation. Cache misses (first
            // appearance, or session-switch pruning) create fresh.
            let gv: NativeToolCallGroupView
            if let cached = cachedGV {
                cached.removeFromSuperview()
                gv = cached
            } else {
                gv = NativeToolCallGroupView()
                context.cacheToolGroupView?(block.id, gv)
            }
            gv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(gv)
            NSLayoutConstraint.activate([
                gv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: context.rowHorizontalInset),
                gv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -context.rowHorizontalInset),
                gv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            ])
            nativeToolCallGroupView = gv
        }
        nativeToolCallGroupView?.configure(
            calls: calls,
            expandedIds: context.expandedIds,
            width: context.width - 2 * context.rowHorizontalInset,
            theme: context.theme,
            isStreaming: context.isStreaming,
            onToggle: { id in context.onToggleExpand(id) },
            onHeightChanged: { [weak self] in
                guard let self, let gv = self.nativeToolCallGroupView, let id = self.currentBlockId else { return }
                let h = gv.measuredHeight() + 8
                context.onHeightMeasured?(h, id)
            }
        )
    }

    // MARK: - Activity Group (NativeActivityGroupView)

    private func configureAsActivityGroup(
        block: ContentBlock,
        children: [ContentBlock],
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeActivityGroupView == nil {
            removeAllContentViews()
            let av = NativeActivityGroupView()
            av.translatesAutoresizingMaskIntoConstraints = false
            addSubview(av)
            NSLayoutConstraint.activate([
                av.leadingAnchor.constraint(equalTo: leadingAnchor, constant: context.rowHorizontalInset),
                av.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -context.rowHorizontalInset),
                av.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            ])
            nativeActivityGroupView = av
        }
        let av = nativeActivityGroupView!
        av.configure(
            children: children,
            expandedIds: context.expandedIds,
            width: context.width - 2 * context.rowHorizontalInset,
            theme: context.theme,
            isStreaming: context.isStreaming,
            blockId: block.id,
            sessionRedactions: context.sessionRedactions,
            onToggleChild: { id in context.onToggleExpand(id) },
            onToggle: { [weak self] in
                guard let self else { return }
                context.onToggleExpand(block.id)
                self.nativeActivityGroupView?.onHeightChanged?()
            },
            onHeightChanged: { [weak self] in
                guard let self, let av = self.nativeActivityGroupView, let id = self.currentBlockId else { return }
                let h = av.measuredHeight() + 8
                context.onHeightMeasured?(h, id)
            }
        )
    }

    // MARK: - User Message (native text + image thumbnails)

    private func configureAsUserMessage(
        block: ContentBlock,
        text rawText: String,
        attachments: [Attachment],
        timestamp: Date,
        responseTurnId: UUID?,
        envelope: DispatchEnvelope?,
        author: ParticipantRef?,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        let images = attachments.filter(\.isImage)
        let documents = attachments.filter(\.isDocument)
        let theme = context.theme.catalogFamily(28, authoritative: true)
        let insetX = theme.catalogLayoutMetric("component.library.28.elements.layout.bubblePaddingX", inheriting: UserMessageInspectionStyle.metric("padding", 12, theme))
        let insetY = theme.catalogLayoutMetric("component.library.28.elements.layout.bubblePaddingY", inheriting: UserMessageInspectionStyle.metric("padding", Self.userBubbleTextInset, theme))
        userBubbleHorizontalInset = insetX
        userBubbleBottomInset = insetY
        userBubbleTopInset = insetY - Self.leadingAboveGlyphs(theme)
        userOuterTopGap = MessageBubbleInspectionStyle.layout(28, "topGap", fallback: 8, theme: theme)
        #if OSAURUS_DESIGN_SYSTEM
        catalogAssignmentTarget(["component.library.28.elements.layout.bubblePaddingX", "component.library.28.elements.layout.bubblePaddingY", "component.library.28.elements.layout.topGap"] + (attachments.isEmpty ? [] : ["component.library.28.elements.layout.attachmentTextGap"]), name: "User message layout", theme: theme)
        #endif
        let innerWidth = max(context.width - 2 * context.rowHorizontalInset, 100)

        // An enveloped turn (channel message, delegated task, …) paints the
        // human-authored text; the raw envelope stays in `rawText` for the
        // inline-edit fallback only.
        let text = envelope?.displayText ?? rawText
        let badges = DispatchEnvelope.badges(for: envelope, author: author)
        let badgeSignature = badges.isEmpty ? nil : NativeDispatchBadgeRow.signature(for: badges)

        let wantsInlineEdit =
            context.editingTurnId == block.turnId
            && context.editText != nil
            && context.onConfirmEdit != nil
            && context.onCancelEdit != nil

        // Ordinary Chat hugs short text and caps at 65%. Workflow creation
        // fills its already-padded panel, including short messages.
        // Attachments live outside the bubble so they don't affect its width.
        let maxBubbleWidth = context.fullWidthMessages ? innerWidth : floor(innerWidth * 0.65)
        let bubbleWidth: CGFloat = {
            if context.fullWidthMessages { return maxBubbleWidth }
            guard !text.isEmpty && !wantsInlineEdit else { return maxBubbleWidth }
            // The measurement below only exists to shrink the bubble around
            // short, single-line text; anything that wraps resolves to
            // `maxBubbleWidth`. A message containing a newline is multi-line by
            // definition, and a 65%-width bubble holds only a few dozen
            // single-line characters, so any longer text is guaranteed to wrap.
            // In both cases skip the measurement entirely — typesetting a large
            // pasted blob synchronously on the main thread hung the UI.
            let measurementCap = 512
            if text.contains("\n") || text.count > measurementCap {
                return maxBubbleWidth
            }
            let measured = (text as NSString).boundingRect(
                with: NSSize(width: max(1, maxBubbleWidth - 2 * insetX), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: theme.textAttributes(.body)
            )
            let lineHeight = theme.lineHeight(.body)
            let isMultiLine = measured.height > lineHeight * 1.5
            return isMultiLine ? maxBubbleWidth : min(ceil(measured.width) + 2 * insetX, maxBubbleWidth)
        }()

        let attachmentGeometry = AttachmentInspectionStyle.geometrySignature(theme) + "|user:" + UserMessageInspectionStyle.signature(theme)
            + "|provenance:\(NativeDispatchBadgeRow.height(for: theme))"
        let needsUserMessageRebuild =
            userAttachmentGeometry != attachmentGeometry
            || !sameKind
            || userMessageContainer == nil
            || userMessageInlineEditActive != wantsInlineEdit
            || userEnvelopeSignature != badgeSignature

        if needsUserMessageRebuild {
            removeAllContentViews()

            // Compute the heights stacked above the bubble (needed for
            // fittingSize measurement later): badge row, documents, images,
            // and the 6pt gaps between them. Mirrors
            // `NativeCellHeightEstimator.estimatedHeight(.userMessage)`.
            let innerGap = images.isEmpty && documents.isEmpty ? 6 : AttachmentInspectionStyle.metric("gap", 6, theme)
            let outerTopGap = userOuterTopGap
            var attachH: CGFloat = 0
            if !badges.isEmpty { attachH += NativeDispatchBadgeRow.height(for: theme) }
            if !documents.isEmpty { attachH += (attachH > 0 ? innerGap : 0) + AttachmentInspectionStyle.documentHeight(theme) }
            if !images.isEmpty { attachH += (attachH > 0 ? innerGap : 0) + AttachmentInspectionStyle.imageHeight(theme) }
            userAttachmentGap = MessageBubbleInspectionStyle.layout(28, "attachmentTextGap", fallback: innerGap, theme: theme)
            userAttachmentsHeight = attachH
            userAttachmentGeometry = attachmentGeometry
            userEnvelopeSignature = badgeSignature

            // Provenance row, attachments, then the bubble — all right-aligned
            // at cell level. `nextGap` is the outer top inset for the first
            // element and the inner gap for every element after it.
            var cellTopAnchor = topAnchor
            var nextGap = outerTopGap

            if !badges.isEmpty {
                let row = NativeDispatchBadgeRow()
                addSubview(row)
                NSLayoutConstraint.activate([
                    row.trailingAnchor.constraint(equalTo: trailingAnchor),
                    row.topAnchor.constraint(equalTo: cellTopAnchor, constant: nextGap),
                    row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: context.rowHorizontalInset),
                ])
                userBadgeRow = row
                cellTopAnchor = row.bottomAnchor
                nextGap = innerGap
            } else {
                userBadgeRow = nil
            }

            if !documents.isEmpty {
                let stack = NSStackView()
                stack.orientation = .horizontal
                stack.spacing = AttachmentInspectionStyle.rowGap(theme)
                stack.translatesAutoresizingMaskIntoConstraints = false
                addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                    stack.topAnchor.constraint(equalTo: cellTopAnchor, constant: nextGap),
                    stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: context.rowHorizontalInset),
                ])
                stack.alignment = .centerY
                userDocumentStack = stack
                cellTopAnchor = stack.bottomAnchor
                nextGap = innerGap
            } else {
                userDocumentStack = nil
            }

            if !images.isEmpty {
                let stack = NSStackView()
                stack.orientation = .horizontal
                stack.spacing = AttachmentInspectionStyle.rowGap(theme)
                stack.translatesAutoresizingMaskIntoConstraints = false
                addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                    stack.topAnchor.constraint(equalTo: cellTopAnchor, constant: nextGap),
                    stack.heightAnchor.constraint(equalToConstant: AttachmentInspectionStyle.imageHeight(theme)),
                    stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: context.rowHorizontalInset),
                ])
                stack.alignment = .top
                userImageStack = stack
                cellTopAnchor = stack.bottomAnchor
                nextGap = innerGap
            } else {
                userImageStack = nil
            }

            if attachH > 0 { nextGap = userAttachmentGap }

            // Text bubble — only created when there is text or inline edit.
            if !text.isEmpty || wantsInlineEdit {
                let container = NSView()
                container.translatesAutoresizingMaskIntoConstraints = false
                container.wantsLayer = true
                container.layer?.masksToBounds = false
                addSubview(container)
                let wc = container.widthAnchor.constraint(equalToConstant: bubbleWidth)
                NSLayoutConstraint.activate([
                    container.trailingAnchor.constraint(equalTo: trailingAnchor),
                    container.topAnchor.constraint(equalTo: cellTopAnchor, constant: nextGap),
                    wc,
                ])
                #if OSAURUS_DESIGN_SYSTEM
                container.heightAnchor.constraint(greaterThanOrEqualToConstant: UserMessageInspectionStyle.metric("height", 0, theme)).isActive = true
                #endif
                userBubbleWidthConstraint = wc
                userMessageContainer = container

                if wantsInlineEdit {
                    let ev = UserMessageInlineEditView()
                    ev.translatesAutoresizingMaskIntoConstraints = false
                    container.addSubview(ev)
                    NSLayoutConstraint.activate([
                        ev.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insetX),
                        ev.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insetX),
                        ev.topAnchor.constraint(equalTo: container.topAnchor, constant: insetY),
                        ev.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insetY),
                    ])
                    userInlineEditView = ev
                    userMessageInlineEditActive = true
                    userTextView = nil
                } else {
                    userMessageInlineEditActive = false
                    userInlineEditView = nil

                    let mv = NativeMarkdownView()
                    mv.includesVerticalPadding = false
                    mv.translatesAutoresizingMaskIntoConstraints = false
                    container.addSubview(mv)
                    NSLayoutConstraint.activate([
                        mv.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insetX),
                        mv.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insetX),
                        mv.topAnchor.constraint(
                            equalTo: container.topAnchor,
                            constant: insetY - Self.leadingAboveGlyphs(theme)
                        ),
                        container.bottomAnchor.constraint(equalTo: mv.bottomAnchor, constant: insetY),
                    ])
                    userTextView = mv
                }
            } else {
                userMessageContainer = nil
                userBubbleWidthConstraint = nil
                userMessageInlineEditActive = false
                userInlineEditView = nil
                userTextView = nil
            }

            // The hover action buttons anchor off the bubble when present,
            // or the first attachment stack otherwise — sitting just below it.
            let anchorView = userMessageContainer ?? userImageStack ?? userDocumentStack ?? userBadgeRow
            if let anchorView {
                let hv = NativeHeaderView()
                hv.translatesAutoresizingMaskIntoConstraints = false
                addSubview(hv)
                NSLayoutConstraint.activate([
                    // Actions sit below the bubble, right-aligned with it
                    // (ChatGPT-style), rather than floating off its left edge.
                    hv.trailingAnchor.constraint(equalTo: anchorView.trailingAnchor),
                    hv.topAnchor.constraint(
                        equalTo: anchorView.bottomAnchor,
                        constant: NativeCellHeightEstimator.userActionsTopGap
                    ),
                    hv.heightAnchor.constraint(equalToConstant: NativeCellHeightEstimator.userActionsRowHeight),
                    hv.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
                ])
                nativeHeaderView = hv
                nativeHeaderHeightConstraint = hv.constraints.first { $0.firstAttribute == .height }
            } else {
                nativeHeaderView = nil
            }

        }

        // Update width constraint even when not rebuilding (e.g. sidebar toggle changes available width)
        userBubbleWidthConstraint?.constant = bubbleWidth

        // apply bubble background
        if let container = userMessageContainer {
            // `component.chat.message`: radius.bubble, opaque
            // chat.user.background, no outline.
            let radius = CGFloat(theme.radius.bubble)
            let bubbleColor = NSColor(theme.chat.userBackground)

            container.layer?.cornerRadius = radius
            container.layer?.backgroundColor = bubbleColor.cgColor
            container.layer?.masksToBounds = true
            #if OSAURUS_DESIGN_SYSTEM
            container.catalogAssignmentTarget(["background", "radius", "border", "borderWidth", "padding", "height"].map { UserMessageInspectionStyle.key + $0 }, name: "User message bubble", theme: theme)
            userTextView?.catalogAssignmentTarget(["text", "foreground", "accent"].map { UserMessageInspectionStyle.key + $0 }, name: "User message text", theme: theme)
            container.layer?.borderWidth = MessageBubbleInspectionStyle.borderWidth(28, theme: theme)
            container.layer?.borderColor = NSColor(theme.assignedColor(UserMessageInspectionStyle.key + "border", fallback: theme.border.default)).cgColor
            #else
            container.layer?.borderWidth = 0
            container.layer?.borderColor = nil
            #endif

            userBubbleCornerRadius = radius
        }

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
            mv.onImagePreview = { img in context.onImagePreviewImage?(img) }
            mv.configure(
                text: text,
                width: max(1, bubbleWidth - 2 * insetX),
                theme: theme,
                cacheKey: block.id,
                // User messages are never themselves streaming — the
                // global `context.isStreaming` flag is true whenever the
                // assistant is generating, but propagating that here
                // would light up the streaming cursor / trailing fade on
                // the user bubble. Always false for user bubbles.
                isStreaming: false
            )
            // User bubble: the verbatim string in `ChatTurn.content`
            // is what the user TYPED, but the wire saw the
            // placeholder. Flag every matching span as `.outbound`
            // so the popover reads "Sent to cloud as [TOKEN]".
            mv.setRedactionHighlights(
                Self.buildHighlights(from: context.sessionRedactions, direction: .outbound),
                theme: theme
            )
            mv.setSearchHighlight(
                query: context.searchHighlightQuery,
                currentIndex: context.searchCurrentIndex(forBlock: block),
                theme: theme
            )
        }

        if let stack = userImageStack {
            while stack.arrangedSubviews.count < images.count {
                let iv = UserAttachmentThumbnailView()
                iv.cornerRadius = CGFloat(theme.radius.medium)
                iv.translatesAutoresizingMaskIntoConstraints = false
                // Shared attachment height; image width follows its aspect ratio.
                iv.heightAnchor.constraint(equalToConstant: AttachmentInspectionStyle.imageHeight(theme)).isActive = true
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
                iv.configure(theme: theme)
                iv.attachmentId = attachId
                iv.onTap = context.onUserImagePreview
                if let img = ChatImageCache.shared.cachedImage(for: attachId) {
                    iv.image = img
                } else if attachment.isImage {
                    // Spilled images (`imageRef`) are read from the blob
                    // store off the main thread; inline bytes skip the read.
                    Task { @MainActor [weak self] in
                        let data: Data?
                        if let inline = attachment.imageData {
                            data = inline
                        } else {
                            data = await Task.detached(priority: .userInitiated) { attachment.loadImageData() }.value
                        }
                        guard let self, let data, iv.attachmentId == attachId else { return }
                        let img = await ChatImageCache.shared.decode(data, id: attachId)
                        guard iv.attachmentId == attachId else { return }
                        iv.image = img
                        context.onHeightMeasured?(self.measureFittedRowHeight(), block.id)
                    }
                }
            }
        }

        if let stack = userDocumentStack {
            while stack.arrangedSubviews.count < documents.count {
                let chip = UserDocumentChipView()
                chip.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(chip)
            }
            while stack.arrangedSubviews.count > documents.count {
                let last = stack.arrangedSubviews.last!
                stack.removeArrangedSubview(last)
                last.removeFromSuperview()
            }

            for (index, attachment) in documents.enumerated() {
                guard let chip = stack.arrangedSubviews[index] as? UserDocumentChipView else { continue }
                // Every document chip is tappable: re-open the read-only preview
                // sheet so the user can re-read the file's extracted text (pasted
                // content or an attached PDF/DOCX) after the message is sent.
                chip.onTap = context.onDocumentPreview
                chip.configure(attachment: attachment, theme: theme)
            }
        }

        // Provenance chips: cheap to re-push (theme colors may have changed);
        // the chip content itself is skipped when the signature is unchanged.
        if !badges.isEmpty {
            userBadgeRow?.configure(badges: badges, theme: theme, availableWidth: innerWidth)
        }

        userActionHeight = MessageHeaderInspectionStyle.side(context.theme)
        nativeHeaderHeightConstraint?.constant = userActionHeight
        // Configure hover action buttons (no name label for user messages).
        // An enveloped turn hides Edit: hand-editing the wire envelope would
        // replace the dispatch contract with free text.
        nativeHeaderView?.configure(
            turnId: block.turnId,
            role: .user,
            name: "",
            avatar: nil,
            customAvatarPath: nil,
            isEditing: context.editingTurnId == block.turnId,
            isHovered: context.isTurnHovered,
            timestamp: timestamp,
            responseTurnId: responseTurnId,
            allowsEdit: envelope == nil,
            theme: context.theme,
            onCopy: context.onCopy,
            onRegenerate: context.onRegenerate,
            onEdit: context.onEdit,
            onDelete: context.onDelete,
            onCancelEdit: context.onCancelEdit
        )

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

    private func configureAsTypingIndicator(
        phase: TypingIndicatorPhase,
        prefillProgress: PrefillProgressState?,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeTypingView == nil {
            removeAllContentViews()
            let tv = NativeTypingIndicatorView()
            tv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(tv)
            NSLayoutConstraint.activate([
                tv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: context.rowHorizontalInset),
                tv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                tv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
                tv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -context.rowHorizontalInset),
            ])
            nativeTypingView = tv
        }
        nativeTypingView?.configure(theme: context.theme, phase: phase, prefillProgress: prefillProgress)
    }

    // MARK: - GenerationStats

    private func configureAsStats(
        ttft: TimeInterval?,
        tokensPerSecond: Double?,
        tokenCount: Int?,
        unclosedReasoning: Bool,
        modelLoad: TimeInterval?,
        cachedInputTokens: Int?,
        totalDuration: TimeInterval?,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeStatsView == nil {
            removeAllContentViews()
            let sv = NativeStatsView()
            sv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sv)
            NSLayoutConstraint.activate([
                sv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: context.rowHorizontalInset),
                sv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -context.rowHorizontalInset),
                sv.topAnchor.constraint(equalTo: topAnchor),
                sv.heightAnchor.constraint(equalToConstant: 24),
                sv.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            ])
            nativeStatsView = sv
            statsHeightConstraint = sv.constraints.first { $0.firstAttribute == .height }
        }
        statsHeightConstraint?.constant = MessageHeaderInspectionStyle.captionHeight(context.theme)
        nativeStatsView?.configure(
            ttft: ttft,
            tokensPerSecond: tokensPerSecond,
            tokenCount: tokenCount,
            unclosedReasoning: unclosedReasoning,
            modelLoad: modelLoad,
            cachedInputTokens: cachedInputTokens,
            totalDuration: totalDuration,
            showResponseMetrics: context.showResponseMetrics,
            theme: context.theme
        )
    }

    // MARK: - AssistantActions

    private func configureAsAssistantActions(
        turnId: UUID,
        imageOnly: Bool,
        timestamp: Date,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeAssistantActionsView == nil {
            removeAllContentViews()
            let av = NativeAssistantActionsView()
            av.translatesAutoresizingMaskIntoConstraints = false
            addSubview(av)
            let top = av.topAnchor.constraint(equalTo: topAnchor, constant: 8)
            assistantActionsTopConstraint = top
            NSLayoutConstraint.activate([
                av.leadingAnchor.constraint(equalTo: leadingAnchor, constant: context.rowHorizontalInset),
                av.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -context.rowHorizontalInset),
                top,
                av.heightAnchor.constraint(equalToConstant: 28),
                av.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            ])
            nativeAssistantActionsView = av
            assistantActionHeightConstraint = av.constraints.first { $0.firstAttribute == .height }
            assistantActionInsetConstraints = constraints.filter { $0.firstItem as? NSView === av && [.leading, .trailing].contains($0.firstAttribute) }
        }
        assistantActionHeightConstraint?.constant = MessageHeaderInspectionStyle.side(context.theme)
        for c in assistantActionInsetConstraints { c.constant = (c.firstAttribute == .trailing ? -1 : 1) * MessageHeaderInspectionStyle.layout("actionsPaddingX", "padding", 16, context.theme) }
        assistantActionsTopConstraint?.constant = MessageBubbleInspectionStyle.layout(29, "actionsGap", fallback: 8, theme: context.theme)
        #if OSAURUS_DESIGN_SYSTEM
        catalogAssignmentTarget(["component.library.29.elements.layout.actionsGap"], name: "Space between agent reply and actions", theme: context.theme)
        #endif
        nativeAssistantActionsView?.configure(
            turnId: turnId,
            timestamp: timestamp,
            theme: context.theme,
            hideSecondaryActions: imageOnly,
            onCopy: context.onCopy,
            onRegenerate: context.onRegenerate,
            onSpeak: context.onSpeak,
            onDeleteMessage: context.onDeleteMessage,
            responseStatsForTurn: context.responseStatsForTurn
        )
    }

    // MARK: - EmptyResponseNotice

    private func configureAsEmptyResponseNotice(
        turnId: UUID,
        outputTokens: Int,
        costMicro: String,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeEmptyNoticeView == nil {
            removeAllContentViews()
            let nv = NativeEmptyResponseNoticeView()
            nv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(nv)
            NSLayoutConstraint.activate([
                nv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: context.rowHorizontalInset),
                nv.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -context.rowHorizontalInset),
                nv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                nv.heightAnchor.constraint(equalToConstant: NativeEmptyResponseNoticeView.inspectionHeight(context.theme)),
                nv.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            ])
            nativeEmptyNoticeView = nv
        }
        nativeEmptyNoticeView?.constraints.first { $0.firstAttribute == .height }?.constant = NativeEmptyResponseNoticeView.inspectionHeight(context.theme)
        nativeEmptyNoticeView?.configure(
            turnId: turnId,
            outputTokens: outputTokens,
            costMicro: costMicro,
            theme: context.theme,
            onRetry: context.onRegenerate
        )
    }

    // MARK: - FollowUpSuggestions

    private func configureAsFollowUpSuggestions(
        block: ContentBlock,
        suggestions: [String],
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        let onTap = context.onFollowUpTap
        // Animate only the first time this row is shown; recycled re-mounts
        // after scrolling render in their final state (mirrors the chart cell).
        let animate = !(context.hasFollowUpsShown?(block.id) ?? false)
        context.markFollowUpsShown?(block.id)
        let rootView = AnyView(
            FollowUpSuggestionsBar(
                suggestions: suggestions,
                animate: animate,
                onSelect: { onTap?($0) }
            )
            .environment(\.theme, context.theme)
            // Measure at the real message-column width, independently of the
            // table's previously cached (possibly single-line) row height.
            .frame(width: max(1, context.width - 2 * context.rowHorizontalInset), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { height in
                guard height > 0 else { return }
                DispatchQueue.main.async {
                    context.onHeightMeasured?(height + 12, block.id)
                }
            }
        )
        if !sameKind || nativeFollowUpsView == nil {
            removeAllContentViews()
            let hv = NSHostingView(rootView: rootView)
            hv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hv)
            NSLayoutConstraint.activate([
                hv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: context.rowHorizontalInset),
                hv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -context.rowHorizontalInset),
                hv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                // Pin the bottom so the cell's `fittingSize` reflects the
                // hosted content and the row sizes to it.
                hv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            ])
            nativeFollowUpsView = hv
        } else {
            nativeFollowUpsView?.rootView = rootView
        }
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
            // Use the available width up to the chat card cap. A thumbnail's
            // intrinsic width can be zero while loading or after a preview fails.
            let preferredWidth = av.widthAnchor.constraint(equalToConstant: 420)
            preferredWidth.priority = .defaultHigh
            NSLayoutConstraint.activate([
                av.leadingAnchor.constraint(equalTo: leadingAnchor, constant: context.rowHorizontalInset),
                av.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -context.rowHorizontalInset),
                av.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
                preferredWidth,
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

    // MARK: - Chart

    private func configureAsChart(
        block: ContentBlock,
        spec: ChartSpec,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        // See `configureAsToolCallGroup` for the same-kind/different-id
        // explanation — chart cells suffer the identical bug if we trust
        // `sameKind` alone.
        let cachedCV = context.cachedChartView?(block.id)
        let needsRemount =
            !sameKind
            || nativeChartView == nil
            || nativeChartView !== cachedCV && cachedCV != nil
        if needsRemount {
            removeAllContentViews()
            // Reuse a cached NativeChartView for this block id when one exists.
            // The cached instance still holds its rendered WKWebView contents,
            // so reparenting avoids a fresh chart load (no flash, no animation).
            // Cache misses (first appearance, or after session-switch pruning)
            // fall back to a new instance and seed the cache.
            let cv: NativeChartView
            if let cached = cachedCV {
                cached.removeFromSuperview()
                cv = cached
            } else {
                cv = NativeChartView()
                context.cacheChartView?(block.id, cv)
            }
            cv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(cv)
            let bottomToCell = cv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
            bottomToCell.priority = NSLayoutConstraint.Priority(250)
            NSLayoutConstraint.activate([
                cv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: context.rowHorizontalInset),
                cv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -context.rowHorizontalInset),
                cv.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                bottomToCell,
            ])
            nativeChartView = cv
        }
        // Chart cells host an AAChartView (WKWebView). The web layer renders
        // through its own CALayer and does not respect AppKit's default
        // bounds clipping; if the row height under-estimates the chart's
        // intrinsic height even by a frame, the chart can leak into adjacent
        // rows. The cell defaults to clipsToBounds = false (so user/assistant
        // bubble shadows aren't cut off); reset that for chart cells only and
        // restore the default in `removeAllContentViews`.
        clipsToBounds = true
        wantsLayer = true
        layer?.masksToBounds = true
        let blockId = block.id
        let animateInitialDraw = !(context.hasChartBeenDrawn?(blockId) ?? false)
        nativeChartView?.configure(spec: spec, theme: context.theme, animateInitialDraw: animateInitialDraw)
        context.markChartDrawn?(blockId)
        DispatchQueue.main.async { [weak self] in
            guard let self, let cv = self.nativeChartView else { return }
            guard self.currentBlockId == blockId else { return }
            context.onHeightMeasured?(cv.measuredCardHeight() + 12, blockId)
        }
    }

    // MARK: - File Diff

    private func configureAsFileDiff(
        block: ContentBlock,
        diff: FileDiff,
        context: CellRenderingContext,
        sameKind: Bool
    ) {
        if !sameKind || nativeFileDiffView == nil {
            removeAllContentViews()
            let dv = NativeFileDiffView()
            dv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(dv)
            // Weak bottom-to-cell pin (matches the chart/artifact cells): the
            // card sizes to its own intrinsicContentSize, and this just keeps
            // the cell content anchored. The cell tracks the row height via
            // viewDidMoveToSuperview, so this constraint must NOT be strong
            // enough to stretch the card to fill the row.
            let bottomToCell = dv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
            bottomToCell.priority = NSLayoutConstraint.Priority(250)
            NSLayoutConstraint.activate([
                dv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: context.rowHorizontalInset),
                dv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -context.rowHorizontalInset),
                dv.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                bottomToCell,
            ])
            nativeFileDiffView = dv
        }
        let blockId = block.id
        // Diff cards default to collapsed; presence in the shared `expandedIds`
        // set marks a card the user has expanded. The height estimator applies
        // the same rule.
        let collapsed = !context.expandedIds.contains(blockId)
        nativeFileDiffView?.onToggleCollapse = {
            context.onToggleExpand(blockId)
        }
        let cardWidth = max(1, context.width - 2 * context.rowHorizontalInset)
        nativeFileDiffView?.onHeightChanged = { [weak self] in
            guard let self, let dv = self.nativeFileDiffView else { return }
            guard self.currentBlockId == blockId else { return }
            let h = dv.measuredCardHeight(cardWidth: cardWidth) + 12
            context.onHeightMeasured?(h, blockId)
        }
        nativeFileDiffView?.configure(
            diff: diff,
            collapsed: collapsed,
            width: cardWidth,
            theme: context.theme
        )
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

    /// Squares the assistant bubble's corners on the sides that touch another
    /// assistant paragraph row, so consecutive rows form one surface.
    func setBubbleJoins(previous: Bool, next: Bool) {
        guard lastBubbleBackgroundCGColor != nil else { return }
        // Layer geometry follows the view: max-Y is the top edge unless flipped.
        let top: CACornerMask =
            isFlipped
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner] : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        let bottom = Self.allCorners.subtracting(top)
        var mask = Self.allCorners
        if previous { mask.subtract(top) }
        if next { mask.subtract(bottom) }
        guard mask != lastBubbleMaskedCorners else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.maskedCorners = mask
        CATransaction.commit()
        lastBubbleMaskedCorners = mask
    }

    private func removeAllContentViews() {
        self.layer?.backgroundColor = nil
        self.layer?.cornerRadius = 0
        self.layer?.borderWidth = 0
        self.layer?.borderColor = nil
        lastBubbleBackgroundCGColor = nil
        lastBubbleCornerRadius = 0
        if lastBubbleMaskedCorners != Self.allCorners {
            self.layer?.maskedCorners = Self.allCorners
            lastBubbleMaskedCorners = Self.allCorners
        }
        // Restore the cell-wide default. configureAsChart opts back into
        // clipping for WKWebView-backed chart content; bubble cells rely on
        // unclipped bounds so shadows / halo affordances aren't cut off.
        clipsToBounds = false
        layer?.masksToBounds = false
        spacerView?.removeFromSuperview(); spacerView = nil
        nativeHeaderView?.removeFromSuperview(); nativeHeaderView = nil
        nativeHeaderHeightConstraint = nil
        messageHeaderInsetConstraints = []; assistantActionInsetConstraints = []
        assistantActionHeightConstraint = nil; statsHeightConstraint = nil; userActionHeight = 28
        // Detach the redaction hover controller (and its text view's
        // `.mouseMoved` tracking flag) deterministically before dropping
        // the view — this cell-reuse path otherwise bypasses
        // `NativeMarkdownView`'s own teardown (issue #1632 launch SIGABRT).
        nativeMarkdownView?.tearDownForReuse()
        nativeMarkdownView?.removeFromSuperview(); nativeMarkdownView = nil; paragraphTopConstraint = nil; paragraphLeadingConstraint = nil; paragraphTrailingConstraint = nil
        statusShimmerLabel?.stop()
        statusShimmerLabel?.removeFromSuperview(); statusShimmerLabel = nil
        nativeThinkingView?.removeFromSuperview(); nativeThinkingView = nil
        nativeCompactionMarkerView?.removeFromSuperview(); nativeCompactionMarkerView = nil
        // Coordinator-cached views: only call `removeFromSuperview` if
        // we're still the parent. After cache reuse the view may live
        // in a sibling cell already; blindly calling `removeFromSuperview`
        // would yank the view out of its new home and the row-now-owning
        // cell would render empty until the next reconfigure.
        detachIfStillParented(nativeToolCallGroupView); nativeToolCallGroupView = nil
        nativeActivityGroupView?.removeFromSuperview(); nativeActivityGroupView = nil
        nativePendingView?.removeFromSuperview(); nativePendingView = nil
        nativeTypingView?.removeFromSuperview(); nativeTypingView = nil
        nativeArtifactView?.removeFromSuperview(); nativeArtifactView = nil
        // CRITICAL: NativeChartView wraps an AAChartView (WKWebView) which
        // composites its content through a process-isolated IOSurface that
        // ignores both `clipsToBounds` and `isHidden` on the AppKit parent.
        // If we leave the chart view parented after the cell is recycled
        // (e.g. chart row dequeued, reused as a paragraph row), the old
        // chart keeps rendering at its previous frame underneath the new
        // content — visible as charts bleeding through unrelated rows once
        // the user starts scrolling and recycling kicks in.
        detachIfStillParented(nativeChartView); nativeChartView = nil
        nativeFileDiffView?.removeFromSuperview(); nativeFileDiffView = nil
        nativeStatsView?.removeFromSuperview(); nativeStatsView = nil
        nativeAssistantActionsView?.removeFromSuperview(); nativeAssistantActionsView = nil; assistantActionsTopConstraint = nil
        nativeEmptyNoticeView?.removeFromSuperview(); nativeEmptyNoticeView = nil
        nativeFollowUpsView?.removeFromSuperview(); nativeFollowUpsView = nil
        nativeConversationEventView?.removeFromSuperview(); nativeConversationEventView = nil
        nativeOnboardingView?.removeFromSuperview(); nativeOnboardingView = nil
        // User messages carry outbound redactions (PII the user typed), so
        // the user text view has the same hover controller to tear down.
        userTextView?.tearDownForReuse()
        userMessageContainer?.removeFromSuperview(); userMessageContainer = nil
        userTextView = nil
        userInlineEditView = nil
        // Image / document stacks are added directly to the cell (not to
        // userMessageContainer) because they sit above the bubble; nil'ing
        // the property without removeFromSuperview leaks them as orphaned
        // subviews on the next reuse.
        userImageStack?.removeFromSuperview(); userImageStack = nil
        userDocumentStack?.removeFromSuperview(); userDocumentStack = nil
        userBadgeRow?.removeFromSuperview(); userBadgeRow = nil
        userEnvelopeSignature = nil
        userBubbleWidthConstraint = nil
        userAttachmentsHeight = 0
        userMessageInlineEditActive = false
    }

    /// Only call `removeFromSuperview()` if the view is still parented
    /// to us. Cache-shared content views (tool-call group, chart) may
    /// have already been reparented into a sibling cell via the
    /// coordinator's cache; in that case removing them would steal them
    /// back from the cell that legitimately owns them now, and that cell
    /// would silently render empty until a reconfigure repositioned the
    /// view. No-op when `view` is nil.
    private func detachIfStillParented(_ view: NSView?) {
        guard let view, view.superview === self else { return }
        view.removeFromSuperview()
    }
}

/// Thumbnail in user bubble — tap opens full-screen preview (wired via `CellRenderingContext.onUserImagePreview`).
/// `CALayer` corner radius + `NSImageView` in `NSTableView` still drew a square trailing edge here; clipping in `draw(_:)` is the reliable fix.
private final class UserAttachmentThumbnailView: NSView {
    private var inspectionTheme: (any ThemeProtocol)?
    private var imageHeight: CGFloat = 96
    private var imagePadding: CGFloat = 0
    private var hovered = false
    private var hoverArea: NSTrackingArea?
    func configure(theme: any ThemeProtocol) {
        inspectionTheme = theme
        cornerRadius = AttachmentInspectionStyle.imageMetric("radius", theme.radius.medium, theme)
        imagePadding = AttachmentInspectionStyle.imageMetric("padding", 0, theme)
        imageHeight = max(1, AttachmentInspectionStyle.imageHeight(theme) - 2 * imagePadding)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
    /// `radius.medium`; set by the owning cell from its theme.
    var cornerRadius: CGFloat = 8 {
        didSet { if cornerRadius != oldValue { needsDisplay = true } }
    }

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
        guard let img = image else { return NSSize(width: imageHeight + 2 * imagePadding, height: imageHeight + 2 * imagePadding) }
        // Shared fixed-height rule with the composer; no aspect clamp or crop.
        let size = AttachmentThumbnailLayout.size(for: img, height: imageHeight)
        return NSSize(width: size.width + 2 * imagePadding, height: size.height + 2 * imagePadding)
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
        let rect = bounds
        guard rect.width > 0, rect.height > 0 else { return }

        #if OSAURUS_DESIGN_SYSTEM
        if let theme = inspectionTheme {
            let shape = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor(AttachmentInspectionStyle.imageColor(hovered ? "hover" : "background", theme.surface.subtle, theme)).setFill()
            shape.fill()
            if let img = image {
                let available = rect.insetBy(dx: imagePadding, dy: imagePadding)
                let size = AttachmentThumbnailLayout.size(for: img, height: imageHeight)
                let imageRect = NSRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                    width: size.width, height: size.height)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: imageRect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
                img.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            }
            let width = AttachmentInspectionStyle.imageMetric("borderWidth", theme.stroke.default, theme)
            NSColor(AttachmentInspectionStyle.imageColor("border", theme.border.default, theme)).setStroke()
            let stroke = NSBezierPath(roundedRect: rect.insetBy(dx: width / 2, dy: width / 2), xRadius: max(0, cornerRadius - width / 2), yRadius: max(0, cornerRadius - width / 2))
            stroke.lineWidth = width
            stroke.stroke()
            return
        }
        #endif
        guard let img = image else { return }

        NSGraphicsContext.saveGraphicsState()
        // clip to the actual view bounds (which now match the aspect ratio via intrinsicContentSize)
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
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
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
}

// MARK: - User Document Chip (native AppKit)

private final class UserDocumentChipView: NSView {
    override var isFlipped: Bool { true }

    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let sizeField = NSTextField(labelWithString: "")

    /// Set for pasted-content chips: tapping the chip re-opens the
    /// read-only preview sheet. `nil` for plain document chips, which
    /// stay non-interactive.
    var onTap: ((Attachment) -> Void)?
    private var attachment: Attachment?
    private var inspectionTheme: (any ThemeProtocol)?
    private var hovered = false
    private var chipHeight: CGFloat = 26
    private var chipPadding: CGFloat = 8
    private var chipGap: CGFloat = 5
    private var chipHeightConstraint: NSLayoutConstraint!
    private var iconLeadingConstraint: NSLayoutConstraint!
    private var nameLeadingConstraint: NSLayoutConstraint!
    private var detailLeadingConstraint: NSLayoutConstraint!
    private var detailTrailingConstraint: NSLayoutConstraint!
    private var textBaselineConstraint: NSLayoutConstraint!

    override var intrinsicContentSize: NSSize {
        let nameW = min(nameField.intrinsicContentSize.width, 130)
        let sizeW = sizeField.intrinsicContentSize.width
        let w = chipPadding * 2 + 14 + chipGap * 2 + nameW + sizeW
        #if OSAURUS_DESIGN_SYSTEM
        // Keep the original filename cap, but let edited type and insets fit
        // alongside metadata instead of collapsing the name to an ellipsis.
        return NSSize(width: w, height: chipHeight)
        #else
        return NSSize(width: min(w, max(220, chipPadding * 2 + 24)), height: chipHeight)
        #endif
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        for field in [nameField, sizeField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.isEditable = false
            field.isBordered = false
            field.drawsBackground = false
            field.lineBreakMode = .byTruncatingMiddle
            field.maximumNumberOfLines = 1
            addSubview(field)
        }
        addSubview(iconView)


        chipHeightConstraint = heightAnchor.constraint(equalToConstant: 26)
        iconLeadingConstraint = iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        nameLeadingConstraint = nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5)
        detailLeadingConstraint = sizeField.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 5)
        detailTrailingConstraint = sizeField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        // Centre the visible filename capitals on the icon, then align the
        // smaller metadata to the same text baseline rather than its own box.
        textBaselineConstraint = nameField.firstBaselineAnchor.constraint(equalTo: centerYAnchor)
        NSLayoutConstraint.activate([
            chipHeightConstraint,

            iconLeadingConstraint,
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            nameLeadingConstraint,
            textBaselineConstraint,
            nameField.widthAnchor.constraint(lessThanOrEqualToConstant: 130),

            detailLeadingConstraint,
            sizeField.firstBaselineAnchor.constraint(equalTo: nameField.firstBaselineAnchor),
            detailTrailingConstraint,
        ])

        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(attachment: Attachment, theme: any ThemeProtocol) {
        self.attachment = attachment
        inspectionTheme = theme
        layer?.backgroundColor = NSColor(theme.surface.subtle).cgColor
        layer?.cornerRadius = CGFloat(theme.radius.medium)
        nameField.font = theme.nsFont(.footnote, weight: .medium)
        sizeField.font = theme.nsFont(.micro)

        let summary = attachment.businessDocumentSummary
        let symbolName = summary?.systemImageName ?? attachment.fileIcon
        let config = theme.symbolConfiguration(.footnote, weight: .medium)
        iconView.image = SymbolImageCache.image(symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = NSColor(theme.text.secondary)

        nameField.stringValue = attachment.filename ?? "Document"
        nameField.textColor = NSColor(theme.text.primary)

        sizeField.stringValue = summary?.chipDetailLabel ?? attachment.fileSizeFormatted ?? ""
        sizeField.textColor = NSColor(theme.text.tertiary)

        #if OSAURUS_DESIGN_SYSTEM
        nameField.font = theme.assignedNativeFont(AttachmentInspectionStyle.key + "text", fallback: theme.nsFont(.footnote))
        sizeField.font = theme.assignedNativeFont(AttachmentInspectionStyle.key + "caption", fallback: theme.nsFont(.micro))
        chipHeight = AttachmentInspectionStyle.documentHeight(theme)
        chipPadding = AttachmentInspectionStyle.metric("padding", 8, theme)
        chipGap = AttachmentInspectionStyle.metric("gap", 5, theme)
        chipHeightConstraint.constant = chipHeight
        iconLeadingConstraint.constant = chipPadding
        nameLeadingConstraint.constant = chipGap
        detailLeadingConstraint.constant = chipGap
        detailTrailingConstraint.constant = -chipPadding
        nameField.attributedStringValue = AttachmentInspectionStyle.text(nameField.stringValue,
            property: "text", role: .footnote, color: AttachmentInspectionStyle.color("foreground", theme.text.primary, theme), theme: theme)
        sizeField.attributedStringValue = AttachmentInspectionStyle.text(sizeField.stringValue,
            property: "caption", role: .micro, color: AttachmentInspectionStyle.color("secondary", theme.text.tertiary, theme), theme: theme)
        iconView.contentTintColor = NSColor(AttachmentInspectionStyle.color("accent", theme.text.secondary, theme))
        layer?.cornerRadius = AttachmentInspectionStyle.metric("radius", theme.radius.medium, theme)
        layer?.borderWidth = AttachmentInspectionStyle.metric("borderWidth", theme.stroke.default, theme)
        layer?.borderColor = NSColor(AttachmentInspectionStyle.color("border", theme.border.default, theme)).cgColor
        updateInspectionBackground()
        #endif

        textBaselineConstraint.constant = (nameField.font?.capHeight ?? 0) / 2
        invalidateIntrinsicContentSize()
    }

    private func updateInspectionBackground() {
        #if OSAURUS_DESIGN_SYSTEM
        guard let theme = inspectionTheme else { return }
        layer?.backgroundColor = NSColor(AttachmentInspectionStyle.color(hovered && onTap != nil ? "hover" : "background", theme.surface.subtle, theme)).cgColor
        #endif
    }

    // Tracking-area + `cursorUpdate` rather than `resetCursorRects`: cursor
    // rects are unreliable for a subview nested inside the message
    // `NSTableView`/scroll view, but a `.cursorUpdate` tracking area pushes
    // the pointing hand reliably on hover. Gated on `onTap` so plain
    // (non-tappable) document chips keep the arrow cursor.
    private var cursorTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateInspectionBackground() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateInspectionBackground() }

    override func cursorUpdate(with event: NSEvent) {
        if onTap != nil {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let onTap, let attachment else {
            super.mouseDown(with: event)
            return
        }
        onTap(attachment)
    }
}

/// Tri-state equality: two nils match, one nil differs, otherwise defer to CGColor.==.
private func cgColorsEqual(_ lhs: CGColor?, _ rhs: CGColor?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case let (l?, r?): return l == r
    default: return false
    }
}

// MARK: - ContentBlockKindTag

/// Lightweight discriminator used to detect kind changes without comparing full associated values.
enum ContentBlockKindTag: Equatable {
    case header, paragraph, toolCallGroup, thinking, activityGroup, userMessage, pendingToolCall
    case generationStats, typingIndicator, groupSpacer, sharedArtifact, chart
    case assistantActions, emptyResponseNotice, fileDiff, compactionMarker, followUpSuggestions, conversationEvent
    case runLocation, onboardingPanel
    case other
}

extension ContentBlockKind {
    var kindTag: ContentBlockKindTag {
        switch self {
        case .header: return .header
        case .paragraph: return .paragraph
        case .toolCallGroup: return .toolCallGroup
        case .thinking: return .thinking
        case .activityGroup: return .activityGroup
        case .userMessage: return .userMessage
        case .pendingToolCall: return .pendingToolCall
        case .generationStats: return .generationStats
        case .typingIndicator: return .typingIndicator
        case .groupSpacer: return .groupSpacer
        case .sharedArtifact: return .sharedArtifact
        case .chart: return .chart
        case .fileDiff: return .fileDiff
        case .assistantActions: return .assistantActions
        case .emptyResponseNotice: return .emptyResponseNotice
        case .compactionMarker: return .compactionMarker
        case .followUpSuggestions: return .followUpSuggestions
        case .conversationEvent: return .conversationEvent
        case .runLocation: return .runLocation
        case .onboardingPanel: return .onboardingPanel
        }
    }
}

// MARK: - NativeCellHeightEstimator

/// Provides height estimates for rows without triggering a full SwiftUI layout pass.
/// Used by the NSTableView height delegate as a fast path.
enum NativeCellHeightEstimator {

    /// Height of the user-message action row (copy / edit / delete) reserved
    /// below the bubble, plus its gap to the bubble. Matches the constraints
    /// installed in `configureAsUserMessage`; shared so the live fit
    /// (`measureFittedRowHeight`) and the upfront estimate stay in lockstep.
    static let userActionsRowHeight: CGFloat = 28
    static let userActionsTopGap: CGFloat = 4
    static var userActionsFooterHeight: CGFloat { userActionsRowHeight + userActionsTopGap }

    /// Inner height of the assistant header row (avatar + name + actions),
    /// without the cell's 8pt top and bottom padding. Must match the constraints
    /// installed by `configureAsHeader`.
    @MainActor static func headerInnerHeight(for theme: any ThemeProtocol) -> CGFloat {
        let theme = theme.catalogFamily(30, authoritative: true)
        let clampedAvatar = max(
            NativeHeaderView.minAvatarSize,
            min(NativeHeaderView.maxAvatarSize, MessageHeaderInspectionStyle.avatarSide(theme))
        )
        let avatarSpace = theme.showInlineAvatar ? clampedAvatar : 0
        return max(MessageHeaderInspectionStyle.side(theme), avatarSpace, CGFloat(theme.lineHeight(.label)))
    }

    @MainActor static func estimatedHeight(
        for block: ContentBlock,
        width: CGFloat,
        theme: any ThemeProtocol,
        isExpanded: Bool,
        fullWidthMessages: Bool = false
    ) -> CGFloat {
        let rowInset = CellRenderingContext.threadRowInset
        switch block.kind {
        case .groupSpacer:
            return 8

        case .header:
            // 8 top + header content + 8 bottom; content grows with avatar size
            return 2 * MessageHeaderInspectionStyle.layout("headerPaddingY", "padding", 8, theme) + headerInnerHeight(for: theme)

        case .generationStats:
            return MessageHeaderInspectionStyle.captionHeight(theme)

        case .assistantActions:
            return MessageBubbleInspectionStyle.layout(29, "actionsGap", fallback: 8, theme: theme) + MessageHeaderInspectionStyle.side(theme) + 8

        case .emptyResponseNotice:
            // 4 top gap + 36 notice + 8 bottom gap
            return NativeEmptyResponseNoticeView.inspectionHeight(theme) + 12

        case .typingIndicator:
            // Same minimum as the existing native generation indicator.
            return ThinkingInspectionStyle.statusHeight(theme) + 10

        case .pendingToolCall:
            // Mirrors a single running group row (node + shimmer title) so the
            // pending → group transition doesn't change height: 8pt top inset +
            // node row + 8pt bottom inset, node centered at the same Y as a group row.
            #if OSAURUS_DESIGN_SYSTEM
            return ActivityInspectionStyle.headerHeight(theme) + 16
            #else
            return NativeToolCallRowView.rowHeaderHeight + 8
            #endif

        case let .thinking(_, text, _, _):
            if !isExpanded { return ThinkingInspectionStyle.headerHeight(theme) + ThinkingInspectionStyle.metric("padding", 4, theme) + 8 }
            let innerW = max(width - 2 * rowInset - 2 * ThinkingInspectionStyle.metric("padding", 14, theme), 100)
            let charsPerLine = max(Int(innerW / 7), 20)
            let lines = max(1, (text.count + charsPerLine - 1) / charsPerLine)
            return ThinkingInspectionStyle.headerHeight(theme) + ThinkingInspectionStyle.metric("borderWidth", 1, theme) + ThinkingInspectionStyle.layout("contentTopGap", "gap", 8, theme) + ThinkingInspectionStyle.layout("contentBottomPadding", "padding", 10, theme) + min(CGFloat(lines) * CGFloat(theme.catalogFamily(33, authoritative: true).lineHeight(.body)) + 8, 356) + 8

        case let .compactionMarker(_, _, summaryText):
            // Collapsed: 4 top inset + 32 header + 8 cell gap. Expanded adds
            // the summary text, estimated like thinking; the cell corrects
            // via the measured-height report.
            if !isExpanded { return NativeCompactionMarkerView.inspectionHeaderHeight(theme) + 12 }
            let innerW = max(width - 2 * rowInset - 2 * NativeComponentInspectionStyle.metric(40, "padding", 14, theme), 100)
            let charsPerLine = max(Int(innerW / 7), 20)
            let lines = max(1, (summaryText.count + charsPerLine - 1) / charsPerLine)
            return 44 + 8 + CGFloat(lines) * 22 + 10

        case let .paragraph(_, text, _, role):
            let theme = role == .assistant ? theme.catalogFamily(29, authoritative: true) : theme
            let minimumHeight = role == .assistant ? AssistantMessageInspectionStyle.metric("height", 0, theme) : 0
            let innerW = max(width - 2 * rowInset, 1)
            let insets =
                NativeMessageCellView.paragraphTopInset(for: role, theme: theme)
                + NativeMessageCellView.paragraphVerticalInset(for: role, theme: theme)
            let cacheKey = "\(block.id)-w\(Int(innerW))"
            if let cached = ThreadCache.shared.height(for: cacheKey) {
                return max(minimumHeight, cached + insets)
            }
            let chars = max(Int(innerW / 7), 20)
            let lines = max(1, (text.count + chars - 1) / chars)
            return max(minimumHeight, CGFloat(lines) * theme.lineHeight(.body) + insets)

        case let .userMessage(rawText, attachments, _, _, envelope, author):
            let theme = theme.catalogFamily(28, authoritative: true)
            let insetX = theme.catalogLayoutMetric("component.library.28.elements.layout.bubblePaddingX", inheriting: UserMessageInspectionStyle.metric("padding", 12, theme))
            let insetY = theme.catalogLayoutMetric("component.library.28.elements.layout.bubblePaddingY", inheriting: UserMessageInspectionStyle.metric("padding", NativeMessageCellView.userBubbleTextInset, theme))
            // Enveloped turns paint the human-authored text under a badge row.
            let text = envelope?.displayText ?? rawText
            let hasBadges = !DispatchEnvelope.badges(for: envelope, author: author).isEmpty
            var h = MessageBubbleInspectionStyle.layout(28, "topGap", fallback: 8, theme: theme)  // outerTopGap
            let innerW = max(width - 2 * rowInset, 100)

            // Stacked above the bubble (fixed heights, 6pt gaps), mirroring
            // `configureAsUserMessage`: badge row, documents, images.
            let docCount = attachments.filter(\.isDocument).count
            let imageCount = attachments.filter(\.isImage).count
            var above: CGFloat = 0
            if hasBadges { above += NativeDispatchBadgeRow.height(for: theme) }
            if docCount > 0 { above += (above > 0 ? AttachmentInspectionStyle.metric("gap", 6, theme) : 0) + AttachmentInspectionStyle.documentHeight(theme) }
            if imageCount > 0 { above += (above > 0 ? AttachmentInspectionStyle.metric("gap", 6, theme) : 0) + AttachmentInspectionStyle.imageHeight(theme) }
            h += above
            if above > 0 && !text.isEmpty { h += MessageBubbleInspectionStyle.layout(28, "attachmentTextGap", fallback: docCount + imageCount > 0 ? AttachmentInspectionStyle.metric("gap", 6, theme) : 6, theme: theme) }  // gap to bubble

            // Text bubble: equal glyph insets above and below the text
            if !text.isEmpty {
                let maxBubbleW = fullWidthMessages ? width : floor(innerW * 0.65)
                let textW = max(1, maxBubbleW - 2 * insetX)
                let cacheKey = "\(block.id)-w\(Int(textW))"
                let textH: CGFloat
                if let cached = ThreadCache.shared.height(for: cacheKey) {
                    textH = cached
                } else {
                    let chars = max(Int(textW / 7), 20)
                    let lines = max(1, (text.count + chars - 1) / chars)
                    textH = CGFloat(lines) * theme.lineHeight(.body)
                }
                h += max(UserMessageInspectionStyle.metric("height", 0, theme),
                    2 * insetY - NativeMessageCellView.leadingAboveGlyphs(theme) + textH)
            }

            // Actions footer (copy / edit / delete) reserved below the bubble,
            // matching the constraints in `configureAsUserMessage`.
            if !text.isEmpty || above > 0 {
                h += MessageHeaderInspectionStyle.side(theme) + userActionsTopGap
            }

            h += 2  // small bottom margin — keep the assistant reply close
            return max(h, 48)

        case let .toolCallGroup(calls):
            // each row self-sizes at the node header height + 1pt reserved gap
            return CGFloat(calls.count) * (ActivityInspectionStyle.headerHeight(theme) + ActivityInspectionStyle.metric("borderWidth", 1, theme)) + 8

        case let .activityGroup(children):
            // collapsed: 44pt header + 4pt inset + 8pt cell gap (matches thinking)
            let header = ActivityInspectionStyle.headerHeight(theme, fallback: 44, property: "heading")
            if !isExpanded { return header + ActivityInspectionStyle.metric("padding", 4, theme) + 8 }
            // expanded: header + separator/gaps + children estimated collapsed;
            // per-child expansion is corrected by the measured-height report
            let childrenH = children.reduce(CGFloat(0)) { acc, child in
                acc + estimatedHeight(for: child, width: width - 2 * ActivityInspectionStyle.metric("padding", 14, theme), theme: theme, isExpanded: false)
            }
            return header + ActivityInspectionStyle.metric("borderWidth", 1, theme) + ActivityInspectionStyle.layout("contentTopGap", "gap", 8, theme) + childrenH + ActivityInspectionStyle.layout("contentBottomPadding", "padding", 10, theme) + 8

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
            return max(h + 12 + 24, NativeComponentInspectionStyle.metric(37, "height", 0, theme) + 12)

        case let .chart(spec):
            // Layout: cell.top(6) + cardPadding + picker(24) + chartHeight
            //          + (note ? 6 + 16 + cardPadding : cardPadding) + cell.bottom(6)
            //
            // Title shares the picker row (centerYAnchor) so it never adds
            // height. The previous estimator added 24pt only when a title
            // was present, double-counting with title and dropping to zero
            // for no-title charts — leaving a 24pt gap that let the
            // WKWebView-backed chart layer leak into the next row. Always
            // account for the picker, never the title.
            let p = NativeChartView.cardPadding
            let pickerH: CGFloat = 24  // picker height + 4pt gap
            var h: CGFloat = 12 + p + pickerH + NativeChartView.chartHeight
            h +=
                (spec.note ?? "").isEmpty
                ? p
                : (6 + 16 + p)
            return h

        case let .fileDiff(diff):
            // Diff cards default to collapsed and only expand when the user
            // opted in via `expandedIds`. configureAsFileDiff reports
            // measuredCardHeight(...) + 12 for the cell top/bottom inset —
            // match that.
            let header = NativeFileDiffView.inspectionHeaderHeight(theme)
            if !isExpanded { return header + 12 }
            let innerW = max(width - 2 * rowInset - 2 * NativeComponentInspectionStyle.metric(38, "padding", 11, theme) - DiffBackgroundView.markerWidth, 100)
            let chars = max(Int(innerW / 7), 20)
            var lineRows = 0
            for line in diff.lines {
                lineRows += max(1, (line.text.count + chars - 1) / chars)
            }
            let fontLineHeight = theme.lineHeight(.code)
            return header + 6 + CGFloat(lineRows) * fontLineHeight + 6 + 12

        case let .conversationEvent(_, text, _, _):
            // One 11pt pill line (two when long) plus the 4pt top / 8pt
            // bottom insets; the link is 32pt tall. Corrected by the
            // measured-height report.
            let chars = max(Int(max(width - 220, 100) / 6), 20)
            return text.count > chars ? 50 : 44

        case let .followUpSuggestions(_, suggestions):
            // Mirrors `FollowUpSuggestionsBar`: outer vertical padding (8+8),
            // a "Follow up" header (~18) and 8pt gap, then one card of rows:
            // 10+10 padding around wrapped 13pt text (~18pt/line), hairline
            // dividers between and a hairline border around. Plus the cell's
            // own 4pt top / 8pt bottom insets. Text width is the cell width
            // minus the 16pt-each-side insets, the 12pt row insets, and the
            // trailing arrow column. Corrected by the measured-height report
            // either way.
            let innerW = max(width - 76, 100)
            let chars = max(Int(innerW / 7), 20)
            var rows: CGFloat = 0
            for s in suggestions {
                let lines = max(1, (s.count + chars - 1) / chars)
                rows += CGFloat(lines) * 18 + 20
            }
            let dividers = CGFloat(max(0, suggestions.count - 1))
            return 26 + rows + dividers + 2 + 16 + 12

        case .runLocation:
            // One caption line plus the 8pt bottom inset.
            return MessageHeaderInspectionStyle.captionHeight(theme) + 8

        case let .onboardingPanel(_, panel):
            // Corrected by the measured-height report.
            let asks = CGFloat(panel.buttons.filter { $0.style == .ask }.count)
            let hasControls = panel.buttons.contains(where: { $0.style != .ask })
            guard !panel.isDiscovery else {
                // A 40pt ask row each, a 28pt control row, the note.
                var h: CGFloat = 16 + 12
                if asks > 0 { h += asks * 40 + 12 }
                if hasControls { h += 28 }
                if panel.note != nil { h += 32 }
                return h
            }
            // The setup card: a 104pt header, 57pt teammate rows, the padded
            // note and topic field, 45pt ask rows, a 53pt footer.
            var h: CGFloat = 16 + 2 + 104
            if !panel.cards.isEmpty { h += 1 + CGFloat(panel.cards.count) * 57 }
            if panel.note != nil || panel.topicField {
                h += 1 + 32
                if panel.note != nil { h += 32 }
                if panel.topicField { h += 40 }
                if panel.note != nil, panel.topicField { h += 12 }
            }
            if asks > 0 { h += 1 + asks * 45 }
            if hasControls { h += 53 }
            return h
        }
    }
}
