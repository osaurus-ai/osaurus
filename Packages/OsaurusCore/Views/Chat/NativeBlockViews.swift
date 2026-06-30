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
    /// Inline prefill token counter rendered as a small status badge next to the
    /// RAM indicator. Kept separate from `loadingLabel` so prefill never hides
    /// the bouncing dots; it augments the existing indicator instead of
    /// replacing it.
    private let prefillBadge = NSStackView()
    private let prefillTitleLabel = NSTextField(labelWithString: "Prefill")
    private let prefillCountLabel = NSTextField(labelWithString: "")
    private let loadingLabel = NSTextField(labelWithString: "")

    // MARK: Animation

    nonisolated(unsafe) private var bounceTimer: Timer?
    nonisolated(unsafe) private var memoryPollTimer: Timer?
    private var currentDot = 0
    private var cancellables: [Any] = []  // Combine sinks

    // MARK: State

    private var theme: (any ThemeProtocol)?
    private var isShowingLoadingLabel = false

    /// Latest prefill state, captured from the Combine stream's emitted value
    /// rather than re-read from the singleton. Prefill updates can arrive in a
    /// tight burst (e.g. a cold prompt where vmlx buffers prompt-processing
    /// events and releases them together); re-reading the singleton in a
    /// deferred sink would collapse those to the final (already-cleared) state,
    /// dropping every intermediate percentage. Carrying the value keeps each
    /// delivered frame honest.
    private var cachedPrefill: PrefillProgressState?

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

    /// Mutually-exclusive loading states. Order of evaluation in
    /// `currentLoadingPhase` encodes priority: sandbox provisioning blocks the
    /// rest of the turn, so it wins over a raw model-load tick.
    private enum LoadingPhase {
        case sandbox
        case prefill(PrefillProgressState)
        case modelLoad

        var replacementText: String? {
            switch self {
            case .sandbox:
                return L("Sandbox is still loading...")
            case .prefill:
                return nil
            case .modelLoad:
                return L("Loading Model...")
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

        cachedPrefill = progress.prefillProgress

        // Prefill is observed on its own so the emitted value is captured
        // directly (see `cachedPrefill`), instead of being flattened to a Void
        // tick that forces a stale re-read of the singleton.
        cancellables.append(
            progress.$prefillProgress
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    self?.cachedPrefill = state
                    self?.refreshLoadingPhase()
                }
        )

        let triggers: [AnyPublisher<Void, Never>] = [
            progress.$loadInFlightCount.map { _ in () }.eraseToAnyPublisher(),
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
        if let prefillProgress = cachedPrefill { return .prefill(prefillProgress) }
        if progress.loadInFlightCount > 0 { return .modelLoad }
        return nil
    }

    private func applyLoadingPhase(_ phase: LoadingPhase?) {
        // Prefill is rendered inline next to the RAM indicator (`completed/total`)
        // and keeps the bouncing dots visible. The coarse phases (sandbox boot,
        // model load) still take over the whole row with a replacement label.
        if case .prefill(let progress) = phase {
            applyReplacementLabel(nil)
            updatePrefillBadge(progress)
            return
        }
        updatePrefillBadge(nil)
        applyReplacementLabel(phase)
    }

    /// Drive the full-width replacement label used for the coarse loading phases
    /// (sandbox / model load). When `phase` is nil the dots + RAM indicator are
    /// restored.
    private func applyReplacementLabel(_ phase: LoadingPhase?) {
        let showing = phase != nil
        let expectedText = phase?.replacementText ?? loadingLabel.stringValue

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

    /// Show/refresh the inline prefill token counter next to the RAM indicator.
    /// Renders `completed/total` (e.g. `0/12345`) while a prefill with a known
    /// token total is in flight; hides otherwise.
    private func updatePrefillBadge(_ progress: PrefillProgressState?) {
        guard let progress, progress.totalUnitCount > 0 else {
            prefillBadge.isHidden = true
            prefillCountLabel.stringValue = ""
            return
        }
        prefillCountLabel.stringValue = "\(progress.completedUnitCount)/\(progress.totalUnitCount)"
        prefillBadge.isHidden = false
        // The counter lives inside the RAM stack, so make sure that stack is
        // visible even if the periodic memory poll hasn't fired yet.
        memoryStack?.isHidden = false
    }

    private func updateMemoryLabel(monitor: SystemMonitorService) {
        guard monitor.totalMemoryGB > 0, !isShowingLoadingLabel else {
            memoryStack?.isHidden = true
            return
        }
        let used = monitor.usedMemoryGB
        let total = monitor.totalMemoryGB
        memoryLabel.stringValue = String(format: "%.1f / %.0f GB", used, total)
        ensureMemoryStack()
        memoryStack?.isHidden = false
    }

    private func ensureMemoryStack() {
        guard memoryStack == nil else { return }

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        configureMemoryViews()
        configurePrefillBadge()

        stack.addArrangedSubview(memoryIcon)
        stack.addArrangedSubview(memoryLabel)
        stack.addArrangedSubview(prefillBadge)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: dotStack.trailingAnchor, constant: 10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        memoryStack = stack
        updatePrefillBadge(cachedPrefill)
    }

    private func configureMemoryViews() {
        memoryIcon.image = SymbolImageCache.image("memorychip", accessibilityDescription: nil)
        memoryIcon.contentTintColor = .orange
        memoryIcon.translatesAutoresizingMaskIntoConstraints = false
        memoryIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true
        memoryIcon.heightAnchor.constraint(equalToConstant: 12).isActive = true

        memoryLabel.translatesAutoresizingMaskIntoConstraints = false
        memoryLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        memoryLabel.textColor = .orange
    }

    private func configurePrefillBadge() {
        prefillBadge.orientation = .horizontal
        prefillBadge.alignment = .centerY
        prefillBadge.spacing = 4
        prefillBadge.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        prefillBadge.translatesAutoresizingMaskIntoConstraints = false
        prefillBadge.wantsLayer = true
        prefillBadge.layer?.cornerRadius = 6
        prefillBadge.layer?.cornerCurve = .continuous
        prefillBadge.layer?.borderWidth = 1
        prefillBadge.isHidden = true

        prefillTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        prefillTitleLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)

        prefillCountLabel.translatesAutoresizingMaskIntoConstraints = false
        prefillCountLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

        prefillBadge.addArrangedSubview(prefillTitleLabel)
        prefillBadge.addArrangedSubview(prefillCountLabel)
        applyPrefillBadgeColors()
    }

    private func updateColors(_ theme: any ThemeProtocol) {
        let primary = NSColor(theme.accentColor)
        let secondary = NSColor(theme.tertiaryText).withAlphaComponent(0.6)
        for (i, dot) in dots.enumerated() {
            dot.backgroundColor = (i == currentDot ? primary : secondary).cgColor
        }
        loadingLabel.textColor = NSColor(theme.secondaryText)
        applyPrefillBadgeColors()
    }

    private func applyPrefillBadgeColors() {
        let accent = theme.map { NSColor($0.accentColor) } ?? .controlAccentColor
        let secondary = theme.map { NSColor($0.secondaryText) } ?? .secondaryLabelColor
        prefillTitleLabel.textColor = secondary.withAlphaComponent(0.9)
        prefillCountLabel.textColor = accent
        prefillBadge.layer?.backgroundColor = accent.withAlphaComponent(0.12).cgColor
        prefillBadge.layer?.borderColor = accent.withAlphaComponent(0.24).cgColor
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
        // Running node: accent-colored circle + category glyph. Subagent tools
        // take their glyph from the capability registry (SSOT) instead of the
        // generic gear the substring categorizer would assign.
        let category = ToolCategory.from(toolName: toolName)
        let glyph = SubagentCapabilityRegistry.iconName(forToolName: toolName) ?? category.icon
        let accent = NSColor(theme.accentColor)
        node.layer?.backgroundColor = accent.withAlphaComponent(0.14).cgColor
        node.layer?.borderColor = accent.withAlphaComponent(0.55).cgColor
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        categoryIcon.image = SymbolImageCache.image(glyph, accessibilityDescription: nil)?
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
        copyButton.image = SymbolImageCache.image("doc.on.doc", accessibilityDescription: nil)
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
    // Source text currently rendered in each cell, used to skip re-rendering
    // unchanged cells when the grid reconfigures during streaming
    private var cellTexts: [[String]] = []
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

        // Width only affects rendered text when it crosses a typography scale
        // step; otherwise a width change is purely a relayout.
        let scaleChanged =
            Typography.scale(for: max(width, 1)) != Typography.scale(for: max(lastWidth, 1))

        self.headers = headers
        self.rows = rows
        lastWidth = width
        lastThemeFingerprint = fingerprint

        if contentChanged || themeChanged || scaleChanged {
            updateCells(theme: theme, rerenderAll: themeChanged || scaleChanged)
        }
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

    /// Reconcile the cell grid against the current headers/rows in place.
    /// A streaming table reconfigures once per delta, and tearing down and
    /// recreating every NSTextView each time hangs the UI on large tables,
    /// so existing cells are reused and only changed text is re-rendered.
    private func updateCells(theme: any ThemeProtocol, rerenderAll: Bool) {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)

        // A column-count change invalidates per-cell reuse; start over.
        if columnCount == 0 || cellFields.first?.count != columnCount {
            for row in cellFields { for cell in row { cell.removeFromSuperview() } }
            cellFields.removeAll()
            cellTexts.removeAll()
        }
        guard columnCount > 0 else { return }

        let scale = Typography.scale(for: max(lastWidth, 1))
        let bodyFontSize = CGFloat(theme.bodySize) * scale

        // Target grid; row 0 is headers
        var grid: [[String]] = [(0 ..< columnCount).map { $0 < headers.count ? headers[$0] : "" }]
        for row in rows {
            grid.append((0 ..< columnCount).map { $0 < row.count ? row[$0] : "" })
        }

        // Drop rows that no longer exist
        while cellFields.count > grid.count {
            for cell in cellFields.removeLast() { cell.removeFromSuperview() }
            cellTexts.removeLast()
        }

        for (rowIdx, rowTexts) in grid.enumerated() {
            let weight: NSFont.Weight = rowIdx == 0 ? .semibold : .regular
            if rowIdx < cellFields.count {
                // Existing row: re-render only the cells whose text changed
                for (colIdx, text) in rowTexts.enumerated() {
                    let cell = cellFields[rowIdx][colIdx]
                    if rerenderAll {
                        cell.selectedTextAttributes = [
                            .backgroundColor: NSColor(theme.selectionColor)
                        ]
                        cell.insertionPointColor = NSColor(theme.cursorColor)
                    }
                    guard rerenderAll || cellTexts[rowIdx][colIdx] != text else { continue }
                    let attr = renderCellAttributedString(
                        text: text,
                        weight: weight,
                        fontSize: bodyFontSize,
                        theme: theme
                    )
                    cell.textStorage?.setAttributedString(attr)
                    cellTexts[rowIdx][colIdx] = text
                }
            } else {
                // New row appended by the stream
                let cells = rowTexts.map { text in
                    makeCellField(
                        text: text,
                        weight: weight,
                        fontSize: bodyFontSize,
                        theme: theme
                    )
                }
                cellFields.append(cells)
                cellTexts.append(rowTexts)
                for cell in cells { addSubview(cell) }
            }
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
                let frame = NSRect(
                    x: x,
                    y: y,
                    width: columnWidth,
                    height: rowH
                )
                // Setting an NSTextView's frame kicks off ruler and inspector
                // bar updates even when nothing moved, so skip no-op writes.
                if field.frame != frame {
                    field.frame = frame
                }
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
