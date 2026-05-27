//
//  NativeBlockViews.swift
//  osaurus
//
//  Pure AppKit views for block types that avoid SwiftUI in table cells.
//
//    NativeTypingIndicatorView     — bouncing CALayer dots + memory label
//    NativePendingToolCallView     — pulsing dot + tool name + scrolling arg preview
//    (NativeArtifactCardView lives in NativeArtifactCardView.swift)
//

import AppKit
import Combine
import QuartzCore

// MARK: - NativeTypingIndicatorView

final class NativeTypingIndicatorView: NSView {

    // MARK: Subviews

    private let dotStack = NSStackView()
    private var dots: [CALayer] = []
    private let memoryIcon = NSImageView()
    private let memoryLabel = NSTextField(labelWithString: "")
    private var memoryStack: NSStackView?
    private let loadingLabel = NSTextField(labelWithString: "")

    // MARK: Animation

    nonisolated(unsafe) private var bounceTimer: Timer?
    nonisolated(unsafe) private var memoryPollTimer: Timer?
    private var currentDot = 0
    private var cancellables: [Any] = []  // Combine sinks

    // MARK: State

    private var theme: (any ThemeProtocol)?
    private var isShowingLoadingLabel = false

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
        observeModelLoading()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        bounceTimer?.invalidate()
        memoryPollTimer?.invalidate()
    }

    /// Stop animations + memory polling when the cell scrolls offscreen or gets reused —
    /// otherwise every live typing indicator instance keeps firing CABasicAnimation ticks
    /// into WindowServer regardless of visibility.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startAnimation()
            observeMemory()
        } else {
            bounceTimer?.invalidate(); bounceTimer = nil
            memoryPollTimer?.invalidate(); memoryPollTimer = nil
        }
    }

    func configure(theme: any ThemeProtocol) {
        guard self.theme == nil || !isSameTheme(theme) else { return }
        self.theme = theme
        updateColors(theme)
    }

    // MARK: - Private: Build

    private func buildViews() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Dot container
        dotStack.orientation = .horizontal
        dotStack.spacing = 4
        dotStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dotStack)

        // Create 3 dot host views (CALayer circles drawn inside)
        for _ in 0 ..< 3 {
            let host = NSView()
            host.translatesAutoresizingMaskIntoConstraints = false
            host.wantsLayer = true
            host.widthAnchor.constraint(equalToConstant: 6).isActive = true
            host.heightAnchor.constraint(equalToConstant: 6).isActive = true
            let circle = CALayer()
            circle.cornerRadius = 3
            circle.backgroundColor = NSColor.tertiaryLabelColor.cgColor
            circle.frame = CGRect(x: 0, y: 0, width: 6, height: 6)
            host.layer?.addSublayer(circle)
            dotStack.addArrangedSubview(host)
            dots.append(circle)
        }

        NSLayoutConstraint.activate([
            dotStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            dotStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // "Loading Model..." label (hidden by default, shown during model load)
        loadingLabel.stringValue = "Loading Model..."
        loadingLabel.font = .systemFont(ofSize: 12, weight: .medium)
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.isHidden = true
        addSubview(loadingLabel)
        NSLayoutConstraint.activate([
            loadingLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            loadingLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // height is controlled by the parent cell — no fixed height constraint here
    }

    private func observeMemory() {
        memoryPollTimer?.invalidate()
        let monitor = SystemMonitorService.shared
        let t = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateMemoryLabel(monitor: monitor)
            }
        }
        t.tolerance = 0.5
        memoryPollTimer = t

        updateMemoryLabel(monitor: monitor)
    }

    /// Mutually-exclusive states the typing indicator can advertise on its
    /// inline label. Order of evaluation in `currentLoadingPhase` encodes
    /// priority: sandbox provisioning blocks the rest of the turn, so it
    /// wins over preflight (which only runs once the model is up), which
    /// in turn wins over a raw model-load tick.
    private enum LoadingPhase {
        case sandbox
        case preflight
        case modelLoad

        var labelText: String {
            switch self {
            case .sandbox: "Sandbox is still loading..."
            case .preflight: "Searching capabilities..."
            case .modelLoad: "Loading Model..."
            }
        }
    }

    private func observeModelLoading() {
        // Merge every truth source the label depends on into a single Void
        // tick stream and recompute synchronously in the sink. Evaluating
        // eagerly against the MainActor singletons is cleaner than threading
        // six values through CombineLatest, especially since the sandbox
        // gate also requires a per-agent `effectiveAutonomousExec` lookup.
        let progress = InferenceProgressManager.shared
        let sandbox = SandboxManager.State.shared
        let agents = AgentManager.shared

        let triggers: [AnyPublisher<Void, Never>] = [
            progress.$loadInFlightCount.map { _ in () }.eraseToAnyPublisher(),
            progress.$isPreflighting.map { _ in () }.eraseToAnyPublisher(),
            sandbox.$status.map { _ in () }.eraseToAnyPublisher(),
            sandbox.$isProvisioning.map { _ in () }.eraseToAnyPublisher(),
            agents.$activeAgentId.map { _ in () }.eraseToAnyPublisher(),
            agents.$agents.map { _ in () }.eraseToAnyPublisher(),
        ]

        cancellables.append(
            Publishers.MergeMany(triggers)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshLoadingPhase() }
        )
    }

    /// Recompute and apply the current loading phase. Must be called on
    /// the main thread — caller is responsible for hopping there.
    private func refreshLoadingPhase() {
        applyLoadingPhase(currentLoadingPhase())
    }

    private func currentLoadingPhase() -> LoadingPhase? {
        let progress = InferenceProgressManager.shared
        let sandbox = SandboxManager.State.shared
        let agents = AgentManager.shared

        let agentUsesSandbox =
            agents.effectiveAutonomousExec(for: agents.activeAgentId)?.enabled == true
        let sandboxBooting = sandbox.status == .starting || sandbox.isProvisioning

        if agentUsesSandbox && sandboxBooting { return .sandbox }
        if progress.isPreflighting { return .preflight }
        if progress.loadInFlightCount > 0 { return .modelLoad }
        return nil
    }

    private func applyLoadingPhase(_ phase: LoadingPhase?) {
        let showing = phase != nil
        let expectedText = phase?.labelText ?? loadingLabel.stringValue

        guard
            showing != isShowingLoadingLabel
                || (showing && loadingLabel.stringValue != expectedText)
        else { return }

        isShowingLoadingLabel = showing
        loadingLabel.stringValue = expectedText
        loadingLabel.isHidden = !showing
        dotStack.isHidden = showing
        memoryStack?.isHidden = showing
    }

    private func updateMemoryLabel(monitor: SystemMonitorService) {
        guard monitor.totalMemoryGB > 0, !isShowingLoadingLabel else {
            memoryStack?.isHidden = true
            return
        }
        let used = monitor.usedMemoryGB
        let total = monitor.totalMemoryGB
        memoryLabel.stringValue = String(format: "%.1f / %.0f GB", used, total)

        if memoryStack == nil {
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 4
            stack.translatesAutoresizingMaskIntoConstraints = false

            memoryIcon.image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: nil)
            memoryIcon.contentTintColor = .orange
            memoryIcon.translatesAutoresizingMaskIntoConstraints = false
            memoryIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true
            memoryIcon.heightAnchor.constraint(equalToConstant: 12).isActive = true

            memoryLabel.translatesAutoresizingMaskIntoConstraints = false
            memoryLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            memoryLabel.textColor = .orange

            stack.addArrangedSubview(memoryIcon)
            stack.addArrangedSubview(memoryLabel)
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: dotStack.trailingAnchor, constant: 10),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            memoryStack = stack
        }
        memoryStack?.isHidden = false
    }

    private func updateColors(_ theme: any ThemeProtocol) {
        let primary = NSColor(theme.accentColor)
        let secondary = NSColor(theme.tertiaryText).withAlphaComponent(0.6)
        for (i, dot) in dots.enumerated() {
            dot.backgroundColor = (i == currentDot ? primary : secondary).cgColor
        }
        loadingLabel.textColor = NSColor(theme.secondaryText)
    }

    private func startAnimation() {
        bounceTimer?.invalidate()
        bounceTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.bounceDot()
            }
        }
    }

    private func bounceDot() {
        let prev = currentDot
        currentDot = (currentDot + 1) % 3

        let primary = (theme.map { NSColor($0.accentColor) }) ?? .controlAccentColor
        let secondary = NSColor.tertiaryLabelColor.withAlphaComponent(0.6)

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)

        // raise current dot
        let bounce = CABasicAnimation(keyPath: "position.y")
        bounce.fromValue = dots[currentDot].position.y
        bounce.toValue = dots[currentDot].position.y + 4
        bounce.duration = 0.15
        bounce.autoreverses = true
        bounce.timingFunction = CAMediaTimingFunction(name: .easeOut)
        dots[currentDot].add(bounce, forKey: "bounce")
        dots[currentDot].backgroundColor = primary.cgColor

        // dim previous
        dots[prev].backgroundColor = secondary.cgColor

        CATransaction.commit()
    }

    private func isSameTheme(_ t: any ThemeProtocol) -> Bool {
        theme?.primaryFontName == t.primaryFontName
    }
}

// MARK: - NativePendingToolCallView

final class NativePendingToolCallView: NSView {

    // MARK: Subviews

    /// Circular running node, matching the completed timeline node
    /// (status-tinted fill + accent ring) with the category glyph in front.
    private let node = NSView()
    private let categoryIcon = NSImageView()
    /// Always running here, so the title shimmers to signal progress.
    private let shimmerLabel = ShimmerLabel()

    private static let nodeSize: CGFloat = 28

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Stop the shimmer when the cell leaves the window so recycled/offscreen
    /// instances don't keep animating.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            shimmerLabel.start()
        } else {
            shimmerLabel.stop()
        }
    }

    // MARK: Configure

    func configure(
        toolName: String,
        argPreview: String?,
        argSize: Int,
        theme: any ThemeProtocol
    ) {
        // Running node: accent-colored circle + category glyph.
        let category = ToolCategory.from(toolName: toolName)
        let accent = NSColor(theme.accentColor)
        node.layer?.backgroundColor = accent.withAlphaComponent(0.14).cgColor
        node.layer?.borderColor = accent.withAlphaComponent(0.55).cgColor
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        categoryIcon.image = NSImage(systemSymbolName: category.icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        categoryIcon.contentTintColor = accent

        // Always running: shimmer the friendly title to signal progress. The
        // view mirrors the running group row exactly (node + shimmer title), so
        // the pending → running-group → done transition is seamless — no args
        // box flashing in and out. `argPreview`/`argSize` are unused.
        shimmerLabel.configure(
            text: ToolDisplayName.friendly(for: toolName, running: true),
            font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            baseColor: NSColor(theme.primaryText).withAlphaComponent(0.4),
            highlightColor: NSColor(theme.primaryText)
        )
        shimmerLabel.start()
    }

    // MARK: - Private: Build

    private func buildViews() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Circular running node
        node.translatesAutoresizingMaskIntoConstraints = false
        node.wantsLayer = true
        node.layer?.cornerRadius = Self.nodeSize / 2
        node.layer?.borderWidth = 1.5
        addSubview(node)

        // Category glyph in the node foreground
        categoryIcon.translatesAutoresizingMaskIntoConstraints = false
        categoryIcon.imageScaling = .scaleProportionallyUpOrDown
        node.addSubview(categoryIcon)

        // Shimmering title
        shimmerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shimmerLabel)

        // Node vertically centered in the cell so it lands at the same spot as
        // the running group row's node (seamless pending → group transition).
        NSLayoutConstraint.activate([
            node.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            node.centerYAnchor.constraint(equalTo: centerYAnchor),
            node.widthAnchor.constraint(equalToConstant: Self.nodeSize),
            node.heightAnchor.constraint(equalToConstant: Self.nodeSize),

            categoryIcon.centerXAnchor.constraint(equalTo: node.centerXAnchor),
            categoryIcon.centerYAnchor.constraint(equalTo: node.centerYAnchor),
            categoryIcon.widthAnchor.constraint(equalToConstant: 14),
            categoryIcon.heightAnchor.constraint(equalToConstant: 14),

            shimmerLabel.leadingAnchor.constraint(equalTo: node.trailingAnchor, constant: 10),
            shimmerLabel.centerYAnchor.constraint(equalTo: node.centerYAnchor),
            shimmerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }
}

// MARK: - Preflight row height (NSTableView delegate fast path)

enum PreflightCapabilitiesRowHeight {
    private static let rowHeight: CGFloat = 22
    private static let chipSpacing: CGFloat = 4
    private static let iconSize: CGFloat = 14
    private static let iconTrailingGap: CGFloat = 6

    static func estimated(items: [PreflightCapabilityItem], tableWidth: CGFloat) -> CGFloat {
        guard !items.isEmpty else { return 1 }
        let innerW = max(tableWidth - 32 - iconSize - iconTrailingGap, 40)
        var x: CGFloat = 0
        var y: CGFloat = 0
        for item in items {
            let w = CGFloat(item.name.count) * 7 + 16
            if x + w > innerW && x > 0 {
                x = 0
                y += rowHeight + chipSpacing
            }
            x += w + chipSpacing
        }
        return y + rowHeight
    }
}

// MARK: - Preflight chip cell (vertical centering)

/// default `NSTextFieldCell` baseline layout leaves uneven padding in short fixed-height pills
private final class PreflightChipTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        guard let font = font else { return super.drawingRect(forBounds: rect) }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor ?? NSColor.labelColor,
        ]
        let s = NSAttributedString(string: stringValue, attributes: attrs)
        let textH = ceil(
            s.boundingRect(
                with: NSSize(width: max(rect.width - 8, 1), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height
        )
        let y = rect.minY + floor((rect.height - textH) / 2)
        return NSRect(x: rect.minX + 4, y: y, width: rect.width - 8, height: textH)
    }

    /// `drawingRect(forBounds:)` alone is not enough: `NSTextFieldCell` still places glyphs on a
    /// baseline inside that rect (NeXT-era metrics), which reads top-heavy in flipped, short rows.
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let font = font else {
            super.drawInterior(withFrame: cellFrame, in: controlView)
            return
        }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor ?? NSColor.labelColor,
            .paragraphStyle: paragraphStyle,
        ]
        let s = NSAttributedString(string: stringValue, attributes: attrs)
        let r = drawingRect(forBounds: cellFrame)
        s.draw(with: r, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }

    override init(textCell string: String) {
        super.init(textCell: string)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }
}

// MARK: - NativePreflightCapabilitiesView

/// icon + wrapping monospaced chips; flipped coords + manual frames; no SwiftUI
final class NativePreflightCapabilitiesView: NSView {

    static let rowHeight: CGFloat = 22
    private static let chipSpacing: CGFloat = 4
    private static let iconSize: CGFloat = 14
    private static let iconTrailingGap: CGFloat = 6

    private let iconView = NSImageView()
    private var chipFields: [NSTextField] = []
    private var heightConstraint: NSLayoutConstraint?
    private var layoutWidthHint: CGFloat = 400
    private var contentHeight: CGFloat = 0

    var onHeightChanged: (() -> Void)?

    override var isFlipped: Bool { true }

    func measuredContentHeight() -> CGFloat {
        heightConstraint?.constant ?? contentHeight
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        let hc = heightAnchor.constraint(equalToConstant: Self.rowHeight)
        hc.priority = .required
        hc.isActive = true
        heightConstraint = hc

        let rowCenter = Self.rowHeight / 2
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: topAnchor, constant: rowCenter),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(items: [PreflightCapabilityItem], theme: any ThemeProtocol, layoutWidth: CGFloat) {
        layoutWidthHint = max(layoutWidth, 100)

        let types = Set(items.map(\.type))
        let iconName: String
        if types.count == 1, let only = types.first { iconName = only.icon } else { iconName = "sparkles" }
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        iconView.contentTintColor = NSColor(theme.tertiaryText)

        for f in chipFields { f.removeFromSuperview() }
        chipFields = []

        guard !items.isEmpty else {
            iconView.isHidden = true
            setContentHeight(0)
            return
        }

        iconView.isHidden = false
        for item in items {
            let f = makeChipField(text: item.name, theme: theme)
            addSubview(f)
            chipFields.append(f)
        }
        needsLayout = true
        layoutChips()
    }

    override func layout() {
        super.layout()
        layoutChips()
    }

    private func setContentHeight(_ h: CGFloat) {
        guard contentHeight != h else { return }
        contentHeight = h
        heightConstraint?.constant = max(h, 0)
        onHeightChanged?()
    }

    private func layoutChips() {
        guard !chipFields.isEmpty else { return }
        let leftInset = Self.iconSize + Self.iconTrailingGap
        var cw = bounds.width - leftInset
        if cw < 1 {
            let pfvW: CGFloat
            if let cell = superview, cell.bounds.width > 1 {
                pfvW = max(cell.bounds.width - 32, 40)
            } else {
                pfvW = max(layoutWidthHint - 32, 40)
            }
            cw = max(pfvW - leftInset, 1)
        }
        guard cw > 0 else { return }

        var x: CGFloat = 0
        var y: CGFloat = 0
        let rowH = Self.rowHeight
        let spacing = Self.chipSpacing

        for field in chipFields {
            let font = field.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            let textW = (field.stringValue as NSString).size(withAttributes: [.font: font]).width
            let w = max(ceil(textW) + 16, 28)
            if x + w > cw && x > 0 {
                x = 0
                y += rowH + spacing
            }
            field.translatesAutoresizingMaskIntoConstraints = false
            field.frame = CGRect(x: leftInset + x, y: y, width: w, height: rowH)
            field.isHidden = false
            x += w + spacing
        }
        setContentHeight(y + rowH)
    }

    private func makeChipField(text: String, theme: any ThemeProtocol) -> NSTextField {
        let cell = PreflightChipTextFieldCell(textCell: text)
        cell.font = NSFont.monospacedSystemFont(ofSize: CGFloat(theme.captionSize) - 1, weight: .medium)
        cell.textColor = NSColor(theme.secondaryText)
        cell.isEditable = false
        cell.isBordered = false
        cell.drawsBackground = true
        cell.backgroundColor = NSColor(theme.tertiaryBackground).withAlphaComponent(0.4)
        cell.alignment = .center
        cell.lineBreakMode = .byTruncatingTail
        cell.usesSingleLineMode = true

        let label = NSTextField(frame: .zero)
        label.cell = cell
        label.wantsLayer = true
        label.layer?.cornerRadius = 6
        label.layer?.masksToBounds = true
        label.layer?.borderWidth = 0.5
        label.layer?.borderColor = NSColor(theme.primaryBorder).withAlphaComponent(0.3).cgColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

// MARK: - NativeCodeBlockView

final class NativeCodeBlockView: NSView {

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let sub = super.hitTest(point) { return sub }
        if NSPointInRect(point, bounds) { return self }
        return nil
    }

    // MARK: Subviews

    private let headerView = NSView()
    private let langLabel = NSTextField(labelWithString: L("code"))
    private let copyButton = NSButton()
    private var codeView: CodeNSTextView?
    private var codeHeightConstraint: NSLayoutConstraint?

    // MARK: Callback

    var onHeightChanged: (() -> Void)?

    // MARK: State

    private var lastCode = ""
    private var lastLang: String? = nil
    private var lastWidth: CGFloat = 0
    private var lastThemeId = ""
    private var copyResetTask: Task<Void, Never>?

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Configure

    func configure(code: String, language: String?, width: CGFloat, theme: any ThemeProtocol) {
        let resolvedHL = theme.codeHighlightTheme ?? (theme.isDark ? "auto-dark" : "auto-light")
        let themeId = "\(theme.monoFontName)|\(theme.codeSize)|\(resolvedHL)"
        let codeChanged = code != lastCode || language != lastLang
        let widthChanged = abs(width - lastWidth) > 0.5
        let themeChanged = themeId != lastThemeId

        guard codeChanged || widthChanged || themeChanged else { return }

        lastCode = code
        lastLang = language
        lastWidth = width
        lastThemeId = themeId

        ensureHighlightrTheme(for: theme)
        let bgColor = highlightrThemeBackgroundNSColor()

        langLabel.stringValue = language?.lowercased() ?? "code"
        langLabel.font = NSFont.monospacedSystemFont(ofSize: CGFloat(theme.captionSize) - 1, weight: .medium)
        langLabel.textColor = NSColor(theme.tertiaryText)

        headerView.layer?.backgroundColor = bgColor.withAlphaComponent(0.6).cgColor
        layer?.backgroundColor = bgColor.cgColor

        let cv = ensureCodeView(theme: theme)
        if widthChanged {
            cv.textContainer?.containerSize = NSSize(width: width - 24, height: .greatestFiniteMagnitude)
        }
        if codeChanged || themeChanged || widthChanged {
            applyHighlighting(to: cv, code: code, language: language, theme: theme)
        }
    }

    /// TextKit-only height for parents (`NativeMarkdownView.measuredHeight`) — must not call
    /// `layoutSubtreeIfNeeded()` on this view; that re-enters AppKit layout while a tool row is expanding.
    func measureHeightForOuterWidth(_ outerWidth: CGFloat) -> CGFloat {
        guard let cv = codeView, let tc = cv.textContainer, let lm = cv.layoutManager else {
            return max(intrinsicContentSize.height, 60)
        }
        let innerW = max(1, outerWidth - 24)
        let wasTracking = tc.widthTracksTextView
        let wasSize = tc.containerSize
        tc.widthTracksTextView = false
        tc.containerSize = NSSize(width: innerW, height: CGFloat.greatestFiniteMagnitude)
        defer {
            tc.widthTracksTextView = wasTracking
            tc.containerSize = wasSize
        }
        lm.ensureLayout(for: tc)
        let textH = ceil(lm.usedRect(for: tc).height)
        return 28 + max(textH, 1) + 8
    }

    // MARK: - Private: Build

    private func buildViews() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.wantsLayer = true
        addSubview(headerView)

        langLabel.translatesAutoresizingMaskIntoConstraints = false
        langLabel.isEditable = false; langLabel.isBordered = false; langLabel.drawsBackground = false
        headerView.addSubview(langLabel)

        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.title = ""
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyButton.isBordered = false
        copyButton.alphaValue = 1  // Ensure it's visible
        copyButton.target = self
        copyButton.action = #selector(copyCode)
        copyButton.alphaValue = 0.45
        headerView.addSubview(copyButton)

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 28),

            langLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12),
            langLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            copyButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -8),
            copyButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 20),
            copyButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    private func ensureCodeView(theme: any ThemeProtocol) -> CodeNSTextView {
        if let cv = codeView { return cv }
        let cv = CodeNSTextView()
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.isEditable = false
        cv.isSelectable = true
        cv.isRichText = true
        cv.drawsBackground = false
        cv.backgroundColor = .clear
        cv.textContainerInset = .zero
        cv.isVerticallyResizable = false
        cv.isHorizontallyResizable = false
        cv.textContainer?.containerSize = NSSize(width: lastWidth - 24, height: .greatestFiniteMagnitude)
        cv.textContainer?.widthTracksTextView = false
        cv.textContainer?.lineFragmentPadding = 0
        cv.selectedTextAttributes = [.backgroundColor: NSColor(theme.selectionColor)]
        cv.insertionPointColor = NSColor(theme.cursorColor)
        cv.lineNumberColor = NSColor(theme.tertiaryText).withAlphaComponent(0.4)
        addSubview(cv)

        let hc = cv.heightAnchor.constraint(equalToConstant: 0)
        hc.isActive = true
        codeHeightConstraint = hc

        NSLayoutConstraint.activate([
            cv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            cv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            cv.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            cv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        codeView = cv
        return cv
    }

    // provide intrinsic content size so the view can size itself
    override var intrinsicContentSize: NSSize {
        let codeHeight = codeHeightConstraint?.constant ?? 0
        let totalHeight = 28 + codeHeight + 8  // header + code + padding
        // ensure minimum visible height even if code hasn't been measured yet
        return NSSize(width: NSView.noIntrinsicMetric, height: max(totalHeight, 60))
    }

    private func applyHighlighting(
        to cv: CodeNSTextView,
        code: String,
        language: String?,
        theme: any ThemeProtocol
    ) {
        let attrStr = CodeContentView.attributedString(
            code: code,
            language: language,
            baseWidth: lastWidth - 24,
            theme: theme
        )
        cv.textStorage?.setAttributedString(attrStr)
        // must match CodeContentView.buildAttributedString: gutter + headIndent use
        // bodySize * Typography.scale * 0.85 — not theme.codeSize, or drawn line
        // numbers use different metrics than the text and crowd the code when narrow
        let scale = Typography.scale(for: lastWidth - 24)
        let bodyFontSize = CGFloat(theme.bodySize) * scale
        cv.codeFontSize = bodyFontSize * 0.85
        cv.lineCount = code.components(separatedBy: "\n").count

        // update height constraint based on measured text height
        if let tc = cv.textContainer, let lm = cv.layoutManager {
            lm.ensureLayout(for: tc)
            let h = ceil(lm.usedRect(for: tc).height)
            codeHeightConstraint?.constant = h
            // invalidate intrinsic content size so the view can resize
            invalidateIntrinsicContentSize()
            // notify parent that height has changed
            onHeightChanged?()
        }
    }

    // MARK: - Mouse tracking for copy button visibility

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
        }
    }

    override func mouseExited(with event: NSEvent) {
        // keep a non-zero alpha so the control stays hit-testable (alpha 0 can drop clicks through to views below)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            copyButton.animator().alphaValue = 0.45
        }
    }

    // MARK: Actions

    @objc private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastCode, forType: .string)
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        copyButton.contentTintColor = .systemGreen
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            self.copyButton.contentTintColor = nil
        }
    }
}

// MARK: - CellTextView

/// NSTextView subclass used as a grid cell. Keeps attributed-string formatting
/// intact on focus and supports native selection within the cell.
final class CellTextView: NSTextView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isSelectable }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isSelectable }
}

// MARK: - NativeMarkdownTableView

/// Grid-based renderer for markdown tables. Each cell is a wrapping NSTextField,
/// so long cell content flows onto additional lines within its column instead of
/// overflowing into neighbours
/// Inline markdown in cells is rendered via SelectableTextView's attributed-string
/// builder so `**bold**` etc. work uniformly with the rest of the message.
final class NativeMarkdownTableView: NSView {

    // MARK: State

    private var headers: [String] = []
    private var rows: [[String]] = []
    private var lastWidth: CGFloat = 0
    private var lastThemeFingerprint: String = ""
    private var heightConstraint: NSLayoutConstraint?

    // [row][col]; row 0 is headers
    private var cellFields: [[CellTextView]] = []
    private let separator = NSBox()

    /// Called after the grid re-measures and its height changes.
    var onHeightChanged: (() -> Void)?

    override var isFlipped: Bool { true }

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        let hc = heightAnchor.constraint(equalToConstant: 24)
        hc.priority = .required
        hc.isActive = true
        heightConstraint = hc
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Configure

    func configure(headers: [String], rows: [[String]], width: CGFloat, theme: any ThemeProtocol) {
        let fingerprint = "\(theme.primaryFontName)|\(theme.bodySize)|\(theme.isDark)"
        let contentChanged = headers != self.headers || rows != self.rows
        let widthChanged = abs(width - lastWidth) > 0.5
        let themeChanged = fingerprint != lastThemeFingerprint
        guard contentChanged || widthChanged || themeChanged else { return }

        self.headers = headers
        self.rows = rows
        lastWidth = width
        lastThemeFingerprint = fingerprint

        rebuildCells(theme: theme)
        relayout(width: width)
    }

    // MARK: Measurement

    func measuredHeight() -> CGFloat { heightConstraint?.constant ?? 24 }

    override func layout() {
        super.layout()
        if bounds.width > 0.5 {
            relayout(width: bounds.width)
        }
    }

    // MARK: - Private: Cell Construction

    private func rebuildCells(theme: any ThemeProtocol) {
        for row in cellFields { for cell in row { cell.removeFromSuperview() } }
        cellFields.removeAll()

        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return }

        let scale = Typography.scale(for: max(lastWidth, 1))
        let bodyFontSize = CGFloat(theme.bodySize) * scale

        // Header row
        let headerCells: [CellTextView] = (0 ..< columnCount).map { i in
            let text = i < headers.count ? headers[i] : ""
            return makeCellField(
                text: text,
                weight: .semibold,
                fontSize: bodyFontSize,
                theme: theme
            )
        }
        cellFields.append(headerCells)
        for cell in headerCells { addSubview(cell) }

        // Body rows
        for row in rows {
            let cells: [CellTextView] = (0 ..< columnCount).map { i in
                let text = i < row.count ? row[i] : ""
                return makeCellField(
                    text: text,
                    weight: .regular,
                    fontSize: bodyFontSize,
                    theme: theme
                )
            }
            cellFields.append(cells)
            for cell in cells { addSubview(cell) }
        }
    }

    private func makeCellField(
        text: String,
        weight: NSFont.Weight,
        fontSize: CGFloat,
        theme: any ThemeProtocol
    ) -> CellTextView {
        let tv = CellTextView(frame: .zero)
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
        tv.selectedTextAttributes = [.backgroundColor: NSColor(theme.selectionColor)]
        tv.insertionPointColor = NSColor(theme.cursorColor)
        let attr = renderCellAttributedString(
            text: text,
            weight: weight,
            fontSize: fontSize,
            theme: theme
        )
        tv.textStorage?.setAttributedString(attr)
        return tv
    }

    /// Render a cell's inline markdown via `NSAttributedString(markdown:)`, then apply
    /// theme fonts/weights/colors. Header cells get semibold applied to every run.
    private func renderCellAttributedString(
        text: String,
        weight: NSFont.Weight,
        fontSize: CGFloat,
        theme: any ThemeProtocol
    ) -> NSAttributedString {
        // Render as a paragraph so font size stays at body size. SelectableTextView
        // handles inline bold/italic/code and math.
        let attr = SelectableTextView.attributedString(
            for: [.paragraph(text)],
            width: lastWidth,
            theme: theme
        )
        let mutable = NSMutableAttributedString(attributedString: attr)
        let fullRange = NSRange(location: 0, length: mutable.length)

        // Tighten cell spacing.
        let tight = NSMutableParagraphStyle()
        tight.lineSpacing = 2
        tight.paragraphSpacingBefore = 0
        tight.paragraphSpacing = 0
        tight.lineBreakMode = .byWordWrapping
        mutable.addAttribute(.paragraphStyle, value: tight, range: fullRange)

        // Header row: upgrade every run's font to semibold (preserving italic/monospace).
        if weight == .semibold {
            let fontManager = NSFontManager.shared
            mutable.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
                guard let font = value as? NSFont else { return }
                let bold = fontManager.convert(font, toHaveTrait: .boldFontMask)
                mutable.addAttribute(.font, value: bold, range: range)
            }
        }
        return mutable
    }

    // MARK: - Private: Layout

    private func relayout(width: CGFloat) {
        let columnCount = cellFields.first?.count ?? 0
        guard columnCount > 0, width > 1 else {
            heightConstraint?.constant = 1
            return
        }

        let columnGap: CGFloat = 16
        let rowGap: CGFloat = 8
        let separatorGap: CGFloat = 6
        let headerPaddingBottom: CGFloat = 6

        let totalGaps = CGFloat(columnCount - 1) * columnGap
        let usable = max(width - totalGaps, CGFloat(columnCount) * 40)
        let columnWidth = floor(usable / CGFloat(columnCount))

        // Measure row heights via each cell's own TextKit layout
        var rowHeights: [CGFloat] = []
        for row in cellFields {
            var maxH: CGFloat = 0
            for cell in row {
                cell.textContainer?.containerSize = NSSize(
                    width: columnWidth,
                    height: .greatestFiniteMagnitude
                )
                if let lm = cell.layoutManager, let tc = cell.textContainer {
                    lm.ensureLayout(for: tc)
                    let h = ceil(lm.usedRect(for: tc).height)
                    maxH = max(maxH, h + 2)
                }
            }
            rowHeights.append(max(maxH, 18))
        }

        // Place cells
        var y: CGFloat = 0
        for (rowIdx, row) in cellFields.enumerated() {
            var x: CGFloat = 0
            let rowH = rowHeights[rowIdx]
            for (colIdx, field) in row.enumerated() {
                field.frame = NSRect(
                    x: x,
                    y: y,
                    width: columnWidth,
                    height: rowH
                )
                x += columnWidth
                if colIdx < row.count - 1 { x += columnGap }
            }
            y += rowH
            if rowIdx == 0 {
                // Header → separator
                y += headerPaddingBottom
                separator.frame = NSRect(x: 0, y: y, width: width, height: 1)
                separator.isHidden = false
                y += separatorGap
            } else if rowIdx < cellFields.count - 1 {
                y += rowGap
            }
        }

        let newH = max(y, 1)
        if abs((heightConstraint?.constant ?? 0) - newH) > 0.5 {
            heightConstraint?.constant = newH
            invalidateIntrinsicContentSize()
            onHeightChanged?()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: heightConstraint?.constant ?? 1)
    }
}
