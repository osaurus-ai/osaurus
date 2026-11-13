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
import QuartzCore
import SwiftUI

// MARK: - NativeTypingIndicatorView

final class NativeTypingIndicatorView: NSView {
    private static let dotSize: CGFloat = 6

    // MARK: Subviews

    private let dotStack = NSStackView()
    private var dots: [CALayer] = []
    private let memoryIcon = NSImageView()
    private let memoryLabel = NSTextField(labelWithString: "")
    private var memoryStack: NSStackView?
    /// Inline prefill token counter, the shared `StatusChip`, next to the
    /// RAM indicator. Runtime progress augments the pending dots instead
    /// of replacing them or borrowing another request's loading phase.
    private let prefillChip = NSHostingView(rootView: AnyView(EmptyView()))
    /// The unscoped theme: the chip resolves its own catalog family.
    private var chipTheme: (any ThemeProtocol)?
    /// "Finishing up…" caption shown beside the dots in the `.finishing`
    /// phase: the model's output is complete, the run is still open on the
    /// engine's post-generation tail (Stop live, input locked). Replaces the
    /// RAM / prefill indicators, which describe generation, not the tail.
    private let statusLabel = NSTextField(labelWithString: "")

    // MARK: Animation

    nonisolated(unsafe) private var bounceTimer: Timer?
    nonisolated(unsafe) private var memoryPollTimer: Timer?
    private var currentDot = 0
    private var inspectionMinimumHeight: NSLayoutConstraint?

    // MARK: State

    private var theme: (any ThemeProtocol)?
    /// Which wait this row stands for (see `TypingIndicatorPhase`). Set by
    /// the cell from the block; `.finishing` overrides every global loading
    /// phase, because once THIS step's output is done any model load or
    /// prefill in flight belongs to another request and must not relabel it.
    private var phase: TypingIndicatorPhase = .generating

    /// Only this row's typed request can supply progress. A global model
    /// load, warm-up or another window's prefill is not this turn's phase.
    private var scopedPrefill: PrefillProgressState?

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
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

    func configure(
        theme: any ThemeProtocol,
        phase: TypingIndicatorPhase = .generating,
        prefillProgress: PrefillProgressState? = nil
    ) {
        catalogAssignmentTarget([ThinkingInspectionStyle.key + "elements.layout.statusPaddingY", AgentContentSurfaceAssignments.key(33, "generation")], name: "Generation status row", theme: theme)
        wantsLayer = true
        layer?.backgroundColor = NSColor(AgentContentSurfaceAssignments.color(33, "generation", theme)).cgColor
        chipTheme = theme
        let theme = theme.catalogFamily(33)
        self.phase = phase
        scopedPrefill = phase == .generating ? prefillProgress : nil
        refreshLoadingPhase()
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
            host.widthAnchor.constraint(equalToConstant: Self.dotSize).isActive = true
            host.heightAnchor.constraint(equalToConstant: Self.dotSize).isActive = true
            let circle = CALayer()
            circle.cornerRadius = Self.dotSize / 2
            circle.frame = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
            host.layer?.addSublayer(circle)
            dotStack.addArrangedSubview(host)
            dots.append(circle)
        }

        NSLayoutConstraint.activate([
            dotStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            dotStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // "Finishing up…" caption beside the dots (hidden unless `.finishing`).
        // Sits where the RAM indicator does in the generating phase.
        statusLabel.stringValue = L("Finishing up…")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.isHidden = true
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: dotStack.trailingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
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

    private func refreshLoadingPhase() {
        // Logical completion and producer drain are separate. This row keeps
        // Stop/input state honest while no longer animating a typing cursor.
        let finishing = phase == .finishing
        statusLabel.isHidden = !finishing
        updatePrefillBadge(finishing ? nil : scopedPrefill)
        if finishing { memoryStack?.isHidden = true }
    }

    /// Show/refresh the inline prefill token counter next to the RAM indicator.
    /// Renders `completed/total` (e.g. `0/12345`) while a prefill with a known
    /// token total is in flight; hides otherwise.
    private func updatePrefillBadge(_ progress: PrefillProgressState?) {
        let text: String
        if phase == .loadingModel {
            text = L("Loading model…")
        } else if let progress, progress.totalUnitCount > 0 {
            text = "\(progress.stage.localizedDisplayTitle) "
                + "\(progress.completedUnitCount)/\(progress.totalUnitCount) · \(Int(progress.percentCompleted))%"
        } else {
            prefillChip.isHidden = true
            return
        }
        guard let chipTheme else {
            prefillChip.isHidden = true
            return
        }
        prefillChip.rootView = AnyView(StatusChip(text).monospacedDigit().environment(\.theme, chipTheme))
        prefillChip.isHidden = false
        // The counter lives inside the RAM stack, so make sure that stack is
        // visible even if the periodic memory poll hasn't fired yet.
        memoryStack?.isHidden = false
    }

    private func updateMemoryLabel(monitor: SystemMonitorService) {
        guard monitor.totalMemoryGB > 0, phase != .finishing else {
            memoryStack?.isHidden = true
            return
        }
        let used = monitor.usedMemoryGB
        let total = monitor.totalMemoryGB
        memoryLabel.stringValue = String(format: "%.1f / %.0f GB", used, total)
        ensureMemoryStack()
        memoryStack?.isHidden = false
        if let theme { applyMemoryColors(theme) }
    }

    private func ensureMemoryStack() {
        guard memoryStack == nil else { return }

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = theme.map { ThinkingInspectionStyle.metric("gap", 4, $0) } ?? 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        configureMemoryViews()
        prefillChip.translatesAutoresizingMaskIntoConstraints = false
        prefillChip.sizingOptions = [.intrinsicContentSize]
        prefillChip.isHidden = true

        stack.addArrangedSubview(memoryIcon)
        stack.addArrangedSubview(memoryLabel)
        stack.addArrangedSubview(prefillChip)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: dotStack.trailingAnchor, constant: theme.map { ThinkingInspectionStyle.metric("gap", 10, $0) } ?? 10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        memoryStack = stack
        updatePrefillBadge(scopedPrefill)
    }

    private func configureMemoryViews() {
        memoryIcon.image = SymbolImageCache.image("memorychip", accessibilityDescription: nil)
        memoryIcon.translatesAutoresizingMaskIntoConstraints = false
        memoryIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true
        memoryIcon.heightAnchor.constraint(equalToConstant: 12).isActive = true
        memoryLabel.translatesAutoresizingMaskIntoConstraints = false
        if let theme { applyMemoryColors(theme) }
    }

    private func applyMemoryColors(_ theme: any ThemeProtocol) {
        let secondary = NSColor(theme.text.secondary)
        memoryIcon.contentTintColor = secondary
        memoryLabel.textColor = secondary
        memoryLabel.font = theme.nsFont(.micro, monospacedDigit: true)
        ThinkingInspectionStyle.label(memoryLabel, property: "caption", color: secondary, theme: theme, monospacedDigit: true)
    }

    private func updateColors(_ theme: any ThemeProtocol) {
        let primary = NSColor(theme.assignedColor(ThinkingInspectionStyle.key + "accent", fallback: theme.text.primary))
        let secondary = NSColor(theme.text.tertiary)
        for (i, dot) in dots.enumerated() {
            dot.backgroundColor = (i == currentDot ? primary : secondary).cgColor
        }
        statusLabel.textColor = NSColor(theme.text.secondary)
        statusLabel.font = theme.nsFont(.caption)
        applyMemoryColors(theme)
        layer?.backgroundColor = NSColor(AgentContentSurfaceAssignments.color(33, "generation", theme)).cgColor
        layer?.borderColor = NSColor(theme.border.default).cgColor
        layer?.borderWidth = ThinkingInspectionStyle.metric("borderWidth", 0, theme)
        layer?.cornerRadius = theme.radius.medium
        let height = ThinkingInspectionStyle.statusHeight(theme)
        if inspectionMinimumHeight == nil {
            let c = heightAnchor.constraint(greaterThanOrEqualToConstant: height)
            c.priority = .init(750); c.isActive = true; inspectionMinimumHeight = c
        }
        inspectionMinimumHeight?.constant = height
        let pad = ThinkingInspectionStyle.metric("padding", theme.space.s0, theme)
        let gap = ThinkingInspectionStyle.metric("gap", theme.space.s4, theme)
        dotStack.spacing = gap; memoryStack?.spacing = gap
        for c in constraints {
            let view = c.firstItem as? NSView
            if view === dotStack, c.firstAttribute == .leading { c.constant = pad }
            if (view === statusLabel || view === memoryStack), c.firstAttribute == .leading { c.constant = gap }
        }
        ThinkingInspectionStyle.label(statusLabel, property: "label", color: NSColor(theme.text.primary), theme: theme)
        updatePrefillBadge(scopedPrefill)
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

        let primary = (theme.map { NSColor($0.assignedColor(ThinkingInspectionStyle.key + "accent", fallback: $0.text.primary)) }) ?? .labelColor
        let secondary = (theme.map { NSColor($0.text.tertiary) }) ?? .tertiaryLabelColor

        CATransaction.begin()
        CATransaction.setAnimationDuration(ThemeManager.shared.currentTheme.motion.standardInterval)

        // raise current dot
        let bounce = CABasicAnimation(keyPath: "position.y")
        bounce.fromValue = dots[currentDot].position.y
        bounce.toValue = dots[currentDot].position.y + 4
        bounce.duration = ThemeManager.shared.currentTheme.motion.quickInterval
        bounce.autoreverses = true
        bounce.timingFunction = ThemeManager.shared.currentTheme.motion.timingFunction
        dots[currentDot].add(bounce, forKey: "bounce")
        dots[currentDot].backgroundColor = primary.cgColor

        // dim previous
        dots[prev].backgroundColor = secondary.cgColor

        CATransaction.commit()
    }

    private func isSameTheme(_ t: any ThemeProtocol) -> Bool {
        theme?.renderFingerprint == t.renderFingerprint
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
        let theme = theme.catalogFamily(34)
        layer?.backgroundColor = NSColor(AgentContentSurfaceAssignments.color(34, "pendingTool", theme)).cgColor
        catalogAssignmentTarget([AgentContentSurfaceAssignments.key(34, "pendingTool")], name: "Pending tool call", theme: theme)
        layer?.borderColor = NSColor(theme.border.default).cgColor
        layer?.borderWidth = theme.stroke.default
        layer?.cornerRadius = theme.radius.medium
        let pad = ActivityInspectionStyle.metric("padding", theme.space.s16, theme)
        let gap = ActivityInspectionStyle.metric("gap", theme.space.s10, theme)
        for c in constraints {
            if c.firstItem as? NSView === node, c.firstAttribute == .leading { c.constant = pad }
            if c.firstItem as? NSView === shimmerLabel, c.firstAttribute == .leading { c.constant = gap }
            if c.firstItem as? NSView === shimmerLabel, c.firstAttribute == .trailing { c.constant = -pad }
        }
        let titleTracking = theme.assignedTracking(ActivityInspectionStyle.key + "label")
        let titleLineHeight: CGFloat? = theme.assignedLineHeight(ActivityInspectionStyle.key + "label", fallback: 18)
        // Running node: accent-colored circle + category glyph. Subagent tools
        // take their glyph from the capability registry (SSOT) instead of the
        // generic gear the substring categorizer would assign.
        let category = ToolCategory.from(toolName: toolName)
        let glyph = SubagentCapabilityRegistry.iconName(forToolName: toolName) ?? category.icon
        node.layer?.backgroundColor = NSColor(theme.status.info.background).cgColor
        node.layer?.borderColor = NSColor(theme.status.info.border).cgColor
        node.layer?.borderWidth = ActivityInspectionStyle.metric("borderWidth", theme.stroke.focus, theme)
        let cfg = theme.symbolConfiguration(.caption, weight: .semibold)
        categoryIcon.image = SymbolImageCache.image(glyph, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        categoryIcon.contentTintColor = NSColor(theme.status.info.foreground)

        // Always running: shimmer the friendly title to signal progress. The
        // view mirrors the running group row exactly (node + shimmer title), so
        // the pending → running-group → done transition is seamless — no args
        // box flashing in and out. `argPreview` is unused; `argSize` drives the
        // liveness counter, because the DSML envelope buffers to its closing
        // tag and a long file-write otherwise renders a motionless card.
        shimmerLabel.configure(
            text: ToolDisplayName.friendly(
                for: toolName, running: true, pendingBytes: argSize),
            font: theme.assignedNativeFont(ActivityInspectionStyle.key + "label", fallback: theme.nsFont(.caption, weight: .semibold)),
            baseColor: NSColor(theme.text.tertiary),
            highlightColor: NSColor(theme.text.primary),
            tracking: titleTracking,
            lineHeight: titleLineHeight
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
    private let copyButton = PointingHandButton()
    private var codeView: CodeNSTextView?
    private var codeHeightConstraint: NSLayoutConstraint?

    // MARK: Callback

    var onHeightChanged: (() -> Void)?

    // MARK: State

    private var currentTheme: (any ThemeProtocol)?
    private var headerHeightConstraint: NSLayoutConstraint?
    private var codeInsetConstraints: [NSLayoutConstraint] = []
    private var languageInsetConstraint: NSLayoutConstraint?
    private var copiedForInspection = false
    private var lastCode = ""
    private var lastLang: String? = nil
    private var lastWidth: CGFloat = 0
    private var lastThemeFingerprint: Int?
    private var lastIsStreaming = false
    private var copyResetTask: Task<Void, Never>?

    // MARK: Streaming cursor state

    private var streamingCursor: StreamingCursorOverlay?
    private var idleTimer: Timer?
    private var lastCodeRevealAt: Date?
    private var cursorColor: NSColor?
    /// Deliberately much longer than the text cursor's 0.15s: local models
    /// decode at ~100-150ms per token, so a threshold in that range sits right
    /// on the natural inter-token gap and the dot flickers in and out on
    /// every token. Inside a code block the dot should only appear on a
    /// genuine stall (tool-call pause, prefill hiccup), not between tokens.
    private static let cursorPauseThreshold: TimeInterval = 0.75

    // MARK: Streaming highlight throttle

    /// Pending mid-stream highlight pass. Per-tick updates append plain text;
    /// this work item re-runs a full highlight over the current code at a
    /// bounded cadence so colors appear progressively without paying the
    /// JavaScriptCore cost on every delta.
    private var streamingHighlightWork: DispatchWorkItem?
    /// Set once the streaming code crosses `streamingHighlightMaxLength`.
    /// Per-delta appends inherit the trailing character's attributes, and
    /// the periodic full pass was what corrected them — so the first crossing
    /// does one plain rebuild (everything after streams uncolored instead of
    /// wearing the last token's color), and later passes are skipped.
    private var streamingHighlightCapped = false
    private static let streamingHighlightInterval: TimeInterval = 0.4
    /// UTF-16 offset of the line start where the next mid-stream pass begins.
    /// Lines before it were colored by an earlier pass and stay as they are;
    /// the finalize pass recolors the whole block with full context.
    private var streamingHighlightedThrough = 0
    /// Gutter digit count the live-colored text was indented for.
    private var streamingHighlightGutterDigits = 0

    /// A mid-stream pass highlights synchronously on main, and JSC's
    /// tokenizer cost grows super-linearly — past this size a single pass
    /// (or a GC pause inside it) can hit the hang watchdog. A tail longer
    /// than this stops live coloring; the appended plain text keeps
    /// streaming, and the finalize pass (under the shared 50k gate) colorizes
    /// the finished block once.
    private static let streamingHighlightMaxLength = 16_384

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Recycled/offscreen instances must not keep the idle timer alive.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { exitStreamingMode() }
    }

    // MARK: Configure

    /// `isStreaming: true` marks a code block whose fence is still open and
    /// growing: syntax highlighting is skipped (a full Highlightr pass per
    /// delta stalls the main thread) and a blinking cursor mirrors the text
    /// path's "still going" signal during stream pauses. The one real
    /// highlight pass runs when the flag flips back to false.
    func configure(
        code: String,
        language: String?,
        width: CGFloat,
        theme: any ThemeProtocol,
        isStreaming: Bool = false
    ) {
        let theme = CodeBlockInspectionStyle.scope(theme)
        catalogAssignmentTarget(["background", "border", "borderWidth", "radius", "padding"].map { CodeBlockInspectionStyle.key + $0 } + ["codePaddingX", "codeBottomPadding", "gutterGap"].map { CodeBlockInspectionStyle.key + "elements.layout." + $0 }, name: "Code block container and layout", theme: theme)
        headerView.catalogAssignmentTarget(["height"].map { CodeBlockInspectionStyle.key + $0 } + ["headerPaddingX", "headerPaddingY"].map { CodeBlockInspectionStyle.key + "elements.layout." + $0 }, name: "Code block header", theme: theme)
        langLabel.catalogAssignmentTarget(["caption", "secondary"].map { CodeBlockInspectionStyle.key + $0 }, name: "Language label", theme: theme)
        currentTheme = theme
        let codeChanged = code != lastCode || language != lastLang
        let widthChanged = abs(width - lastWidth) > 0.5
        let themeChanged = theme.renderFingerprint != lastThemeFingerprint
        let streamingChanged = isStreaming != lastIsStreaming

        guard codeChanged || widthChanged || themeChanged || streamingChanged else { return }

        lastCode = code
        lastLang = language
        lastWidth = width
        lastThemeFingerprint = theme.renderFingerprint
        lastIsStreaming = isStreaming

        ensureHighlightrTheme(for: theme)

        langLabel.stringValue = language?.lowercased() ?? "code"
        langLabel.font = theme.nsFont(.footnote, weight: .medium, family: .code)
        langLabel.textColor = NSColor(theme.text.tertiary)
        // Complete language-label recipe from32.
        let paragraph = theme.paragraphStyle(.caption)
        langLabel.attributedStringValue = NSAttributedString(string: langLabel.stringValue, attributes: [.font: theme.assignedNativeFont(CodeBlockInspectionStyle.key + "caption", fallback: theme.nsFont(.caption)), .foregroundColor: NSColor(theme.text.secondary), .kern: theme.assignedTracking(CodeBlockInspectionStyle.key + "caption") ?? 0, .paragraphStyle: paragraph])
        layer?.borderColor = NSColor(theme.border.default).cgColor
        layer?.borderWidth = CodeBlockInspectionStyle.metric("borderWidth", 1, theme)
        copyButton.configureInspection(theme, copied: copiedForInspection)
        copyButton.alphaValue = 1
        headerHeightConstraint?.constant = CodeBlockInspectionStyle.headerHeight(theme)
        languageInsetConstraint?.constant = theme.catalogLayoutMetric("component.library.32.elements.layout.headerPaddingX", inheriting: CodeBlockInspectionStyle.metric("padding", theme.space.s12, theme))
        for c in codeInsetConstraints { c.constant = (c.firstAttribute == .leading ? 1 : -1) * (c.firstAttribute == .bottom ? theme.catalogLayoutMetric("component.library.32.elements.layout.codeBottomPadding", inheriting: CodeBlockInspectionStyle.metric("padding", theme.space.s8, theme)) : theme.catalogLayoutMetric("component.library.32.elements.layout.codePaddingX", inheriting: CodeBlockInspectionStyle.metric("padding", theme.space.s12, theme))) }

        layer?.backgroundColor = NSColor(theme.surface.code).cgColor
        layer?.cornerRadius = theme.radius.medium

        let cv = ensureCodeView(theme: theme)
        cv.catalogAssignmentTarget(["code", "foreground", "selected", "accent"].map { CodeBlockInspectionStyle.key + $0 }, name: "Code text", theme: theme)
        if themeChanged {
            cv.selectedTextAttributes = [.backgroundColor: NSColor(theme.selection.background)]
            cv.insertionPointColor = NSColor(theme.cursor)
        }
        if widthChanged {
            cv.textContainer?.containerSize = NSSize(width: max(1, width - 2 * theme.catalogLayoutMetric("component.library.32.elements.layout.codePaddingX", inheriting: CodeBlockInspectionStyle.metric("padding", theme.space.s12, theme))), height: .greatestFiniteMagnitude)
        }
        if codeChanged || themeChanged || widthChanged || streamingChanged {
            if isStreaming {
                applyStreamingText(
                    to: cv,
                    code: code,
                    theme: theme,
                    fullRebuild: widthChanged || themeChanged
                )
                scheduleStreamingHighlight(theme: theme)
            } else {
                // Stream over (or static content): one authoritative,
                // cache-backed highlight pass.
                applyHighlighting(to: cv, code: code, language: language, theme: theme)
            }
        }

        if isStreaming {
            if codeChanged { notifyCodeReveal() }
            enterStreamingMode(theme: theme)
        } else {
            exitStreamingMode()
        }
    }

    /// Per-tick text update while the fence is still open. Appends the new
    /// tail with the trailing character's attributes when the previous
    /// content is a prefix of the new code (the overwhelmingly common case),
    /// avoiding a full TextKit rebuild per delta. Falls back to a full plain
    /// rebuild otherwise.
    private func applyStreamingText(
        to cv: CodeNSTextView,
        code: String,
        theme: any ThemeProtocol,
        fullRebuild: Bool
    ) {
        let current = cv.textStorage?.string ?? ""
        if !fullRebuild, !current.isEmpty, code.hasPrefix(current), let storage = cv.textStorage {
            let suffix = String(code.dropFirst(current.count))
            if !suffix.isEmpty {
                let attrs = storage.attributes(at: storage.length - 1, effectiveRange: nil)
                storage.append(NSAttributedString(string: suffix, attributes: attrs))
            }
        } else {
            cv.textStorage?.setAttributedString(
                CodeContentView.attributedString(
                    code: code,
                    language: lastLang,
                    baseWidth: max(1, lastWidth - 2 * theme.catalogLayoutMetric("component.library.32.elements.layout.codePaddingX", inheriting: CodeBlockInspectionStyle.metric("padding", theme.space.s12, theme))),
                    theme: theme,
                    highlight: false
                )
            )
            streamingHighlightedThrough = 0
        }
        refreshMetricsAndHeight(cv, code: code, theme: theme)
    }

    /// Leading-edge throttle for the mid-stream highlight wave: if a pass is
    /// already pending, let it fire on schedule. Each pass colors only the
    /// lines since the previous pass (plus the line still being written), so
    /// its cost tracks the new text rather than the whole block. It skips the
    /// shared highlight cache so streaming prefixes don't pollute it.
    private func scheduleStreamingHighlight(theme: any ThemeProtocol) {
        guard streamingHighlightWork == nil, !streamingHighlightCapped else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.streamingHighlightWork = nil
            guard self.lastIsStreaming, let cv = self.codeView else { return }
            self.highlightStreamingTail(cv, theme: theme)
        }
        streamingHighlightWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.streamingHighlightInterval,
            execute: work
        )
    }

    private func highlightStreamingTail(_ cv: CodeNSTextView, theme: any ThemeProtocol) {
        let code = lastCode as NSString
        guard let storage = cv.textStorage, storage.length == code.length else { return }
        let start = min(streamingHighlightedThrough, code.length)
        guard code.length - start <= Self.streamingHighlightMaxLength else {
            streamingHighlightCapped = true
            applyStreamingText(to: cv, code: lastCode, theme: theme, fullRebuild: true)
            return
        }
        let lineCount = CodeContentView.lineCount(of: lastCode)
        let tail = CodeContentView.attributedString(
            code: code.substring(from: start),
            language: lastLang,
            baseWidth: max(1, lastWidth - 2 * theme.catalogLayoutMetric("component.library.32.elements.layout.codePaddingX", inheriting: CodeBlockInspectionStyle.metric("padding", theme.space.s12, theme))),
            theme: theme,
            cacheHighlight: false,
            gutterLineCount: lineCount
        )
        // Same characters, new attributes. Anything else means the text
        // moved under us; the next configure rebuilds it.
        guard tail.length == storage.length - start else { return }
        let digits = "\(lineCount)".count
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: tail)
        if digits != streamingHighlightGutterDigits, start > 0, tail.length > 0,
            let style = tail.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
        {
            storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: start))
        }
        storage.endEditing()
        streamingHighlightGutterDigits = digits
        let lastNewline = code.range(of: "\n", options: .backwards)
        streamingHighlightedThrough = lastNewline.location == NSNotFound ? 0 : lastNewline.location + 1
        refreshMetricsAndHeight(cv, code: lastCode, theme: theme)
    }

    /// TextKit-only height for parents (`NativeMarkdownView.measuredHeight`) — must not call
    /// `layoutSubtreeIfNeeded()` on this view; that re-enters AppKit layout while a tool row is expanding.
    func measureHeightForOuterWidth(_ outerWidth: CGFloat) -> CGFloat {
        guard let cv = codeView, let tc = cv.textContainer, let lm = cv.layoutManager else {
            return max(intrinsicContentSize.height, 60)
        }
        let theme = currentTheme ?? CustomizableTheme.light()
        let innerW = max(1, outerWidth - 2 * theme.catalogLayoutMetric("component.library.32.elements.layout.codePaddingX", inheriting: CodeBlockInspectionStyle.metric("padding", theme.space.s12, theme)))
        // Resizing the container invalidates all of its layout, and restoring
        // it does so again; skip both when the width already matches.
        let target = NSSize(width: innerW, height: CGFloat.greatestFiniteMagnitude)
        let resize = tc.containerSize != target
        let wasTracking = tc.widthTracksTextView
        let wasSize = tc.containerSize
        if resize {
            tc.widthTracksTextView = false
            tc.containerSize = target
        }
        defer {
            if resize {
                tc.widthTracksTextView = wasTracking
                tc.containerSize = wasSize
            }
        }
        lm.ensureLayout(for: tc)
        let textH = ceil(lm.usedRect(for: tc).height)
        return CodeBlockInspectionStyle.headerHeight(theme) + max(textH, 1) + theme.catalogLayoutMetric("component.library.32.elements.layout.codeBottomPadding", inheriting: CodeBlockInspectionStyle.metric("padding", theme.space.s8, theme))
    }

    // MARK: - Private: Build

    private func buildViews() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerCurve = .continuous

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
        headerHeightConstraint = headerView.constraints.first { $0.firstAttribute == .height }
        languageInsetConstraint = headerView.constraints.first { $0.firstItem as? NSView === langLabel && $0.firstAttribute == .leading }
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
        cv.textContainer?.containerSize = NSSize(width: max(1, lastWidth - 2 * theme.catalogLayoutMetric("component.library.32.elements.layout.codePaddingX", inheriting: CodeBlockInspectionStyle.metric("padding", theme.space.s12, theme))), height: .greatestFiniteMagnitude)
        cv.textContainer?.widthTracksTextView = false
        cv.textContainer?.lineFragmentPadding = 0
        cv.selectedTextAttributes = [.backgroundColor: NSColor(theme.selection.background)]
        cv.insertionPointColor = NSColor(theme.cursor)
        cv.lineNumberColor = NSColor(theme.text.tertiary)
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
        codeInsetConstraints = constraints.filter { $0.firstItem as? NSView === cv && [.leading, .trailing, .bottom].contains($0.firstAttribute) }
        for c in codeInsetConstraints { c.constant = (c.firstAttribute == .leading ? 1 : -1) * (c.firstAttribute == .bottom ? theme.catalogLayoutMetric("component.library.32.elements.layout.codeBottomPadding", inheriting: CodeBlockInspectionStyle.metric("padding", theme.space.s8, theme)) : theme.catalogLayoutMetric("component.library.32.elements.layout.codePaddingX", inheriting: CodeBlockInspectionStyle.metric("padding", theme.space.s12, theme))) }
        codeView = cv
        return cv
    }

    // provide intrinsic content size so the view can size itself
    override var intrinsicContentSize: NSSize {
        let codeHeight = codeHeightConstraint?.constant ?? 0
        let theme = currentTheme ?? CustomizableTheme.light()
        let totalHeight = CodeBlockInspectionStyle.headerHeight(theme) + codeHeight + theme.catalogLayoutMetric("component.library.32.elements.layout.codeBottomPadding", inheriting: CodeBlockInspectionStyle.metric("padding", theme.space.s8, theme))  // header + code + padding
        // ensure minimum visible height even if code hasn't been measured yet
        return NSSize(width: NSView.noIntrinsicMetric, height: max(totalHeight, 60))
    }

    private func applyHighlighting(
        to cv: CodeNSTextView,
        code: String,
        language: String?,
        theme: any ThemeProtocol,
        cacheHighlight: Bool = true
    ) {
        let attrStr = CodeContentView.attributedString(
            code: code,
            language: language,
            baseWidth: max(1, lastWidth - 2 * theme.catalogLayoutMetric("component.library.32.elements.layout.codePaddingX", inheriting: CodeBlockInspectionStyle.metric("padding", theme.space.s12, theme))),
            theme: theme,
            cacheHighlight: cacheHighlight
        )
        cv.textStorage?.setAttributedString(attrStr)
        refreshMetricsAndHeight(cv, code: code, theme: theme)
    }

    private func refreshMetricsAndHeight(_ cv: CodeNSTextView, code: String, theme: any ThemeProtocol) {
        // Must match CodeContentView.buildAttributedString, whose gutter
        // indent is measured with the same font and inset.
        cv.codeFont = theme.nsFont(.code)
        cv.gutterInset = theme.catalogLayoutMetric("component.library.32.elements.layout.gutterGap", inheriting: CodeBlockInspectionStyle.metric("gap", theme.space.s12, theme))
        cv.lineNumberColor = NSColor(theme.text.tertiary)
        cv.lineCount = CodeContentView.lineCount(of: code)

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

    // MARK: - Streaming cursor (mirrors NativeMarkdownView's interpunct)

    /// Start the idle-check timer; the cursor itself only shows once the
    /// stream has been quiet past the pause threshold (see `idleTick`).
    private func enterStreamingMode(theme: any ThemeProtocol) {
        cursorColor = NSColor(theme.assignedColor(CodeBlockInspectionStyle.key + "accent", fallback: theme.text.primary))
        guard idleTimer == nil else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.idleTick()
            }
        }
    }

    private func exitStreamingMode() {
        idleTimer?.invalidate()
        idleTimer = nil
        lastCodeRevealAt = nil
        streamingCursor?.removeFromSuperview()
        streamingCursor = nil
        streamingHighlightWork?.cancel()
        streamingHighlightWork = nil
        streamingHighlightCapped = false
        streamingHighlightedThrough = 0
        streamingHighlightGutterDigits = 0
    }

    /// New code landed — actively revealing is the opposite of "waiting".
    private func notifyCodeReveal() {
        lastCodeRevealAt = Date()
        streamingCursor?.removeFromSuperview()
        streamingCursor = nil
    }

    private func idleTick() {
        guard idleTimer != nil else { return }
        let elapsed = lastCodeRevealAt.map { Date().timeIntervalSince($0) }
            ?? (Self.cursorPauseThreshold + 1)
        if elapsed > Self.cursorPauseThreshold {
            if streamingCursor == nil, let color = cursorColor {
                let overlay = StreamingCursorOverlay()
                overlay.updateColor(color)
                addSubview(overlay)
                streamingCursor = overlay
            }
            repositionStreamingCursor()
        } else if streamingCursor != nil {
            streamingCursor?.removeFromSuperview()
            streamingCursor = nil
        }
    }

    /// Park the dot just past the last glyph of the code text, vertically
    /// centered on that line's cap-height band (same math as the markdown
    /// text cursor).
    private func repositionStreamingCursor() {
        guard let cursor = streamingCursor, let cv = codeView,
            let lm = cv.layoutManager, let tc = cv.textContainer,
            let storage = cv.textStorage
        else { return }
        lm.ensureLayout(for: tc)

        let origin = cv.textContainerOrigin
        let trailingFont =
            storage.length > 0
            ? storage.attribute(.font, at: storage.length - 1, effectiveRange: nil) as? NSFont : nil
        guard let font = trailingFont ?? cv.codeFont ?? cv.font else { return }
        let slotWidth: CGFloat = StreamingCursorOverlay.dotDiameter + 4
        let slotHeight: CGFloat = StreamingCursorOverlay.dotDiameter

        let trailingX: CGFloat
        let baselineInTV: CGFloat
        if storage.length == 0 {
            trailingX = origin.x + 6
            baselineInTV = origin.y + font.ascender
        } else {
            let lastGlyphIdx = lm.glyphIndexForCharacter(at: storage.length - 1)
            let usedRect = lm.lineFragmentUsedRect(forGlyphAt: lastGlyphIdx, effectiveRange: nil)
            let lineFragRect = lm.lineFragmentRect(forGlyphAt: lastGlyphIdx, effectiveRange: nil)
            let baselineOffset = lm.location(forGlyphAt: lastGlyphIdx).y
            trailingX = usedRect.maxX + origin.x + 6
            baselineInTV = lineFragRect.minY + baselineOffset + origin.y
        }

        let textMiddleInTV = baselineInTV - font.capHeight / 2
        let centerInSelf = cv.convert(NSPoint(x: trailingX, y: textMiddleInTV), to: self)
        cursor.frame = NSRect(
            x: centerInSelf.x,
            y: centerInSelf.y - slotHeight / 2,
            width: slotWidth,
            height: slotHeight
        )
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
            ctx.duration = ThemeManager.shared.currentTheme.motion.quickInterval
            copyButton.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        copyButton.alphaValue = 1
        return
        // keep a non-zero alpha so the control stays hit-testable (alpha 0 can drop clicks through to views below)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = ThemeManager.shared.currentTheme.motion.quickInterval
            copyButton.animator().alphaValue = 0.45
        }
    }

    // MARK: Actions

    @objc private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastCode, forType: .string)
        ToastManager.shared.success(L("Code copied to clipboard"))
        copyButton.image = SymbolImageCache.image("checkmark", accessibilityDescription: nil)
        copyButton.contentTintColor = .systemGreen
        copiedForInspection = true
        if let theme = currentTheme { copyButton.configureInspection(theme, copied: true) }
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor [weak self] in
            // A repeat tap cancels this task. `try?` alone would swallow the
            // CancellationError and run the reset at once, wiping the new
            // checkmark, so bail on cancellation instead.
            guard (try? await Task.sleep(nanoseconds: 2_000_000_000)) != nil,
                let self
            else { return }
            self.copyButton.image = SymbolImageCache.image("doc.on.doc", accessibilityDescription: nil)
            self.copyButton.contentTintColor = nil
            self.copiedForInspection = false
            if let theme = self.currentTheme { self.copyButton.configureInspection(theme, copied: false) }
        }
    }
}

// MARK: - PointingHandButton

/// Borderless button that shows the pointing-hand cursor on hover. Uses a
/// `.cursorUpdate` tracking area rather than cursor rects, which don't
/// survive layer-backed table-cell recycling in the message list.
private final class PointingHandButton: NSButton {
    private var inspectionTheme: (any ThemeProtocol)?
    private var copied = false
    private var inspectedHover = false
    func configureInspection(_ theme: any ThemeProtocol, copied: Bool) {
        inspectionTheme = theme; self.copied = copied
        wantsLayer = true
        (cell as? NSButtonCell)?.imageDimsWhenDisabled = false
        refreshInspection()
    }
    private func refreshInspection() {
        guard let theme = inspectionTheme else { return }
        contentTintColor = NSColor(!isEnabled ? theme.text.disabled : (copied ? theme.border.focus : theme.text.secondary))
        layer?.backgroundColor = NSColor(!isEnabled ? theme.surface.disabled : (inspectedHover ? theme.surface.hover : theme.surface.code)).cgColor
        layer?.cornerRadius = theme.radius.small
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); inspectedHover = true; refreshInspection() }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); inspectedHover = false; refreshInspection() }
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

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }
}

// MARK: - CellTextView

/// NSTextView subclass used as a grid cell. Keeps attributed-string formatting
/// intact on focus and supports native selection within the cell.
final class CellTextView: NSTextView, CrossSelectableTextView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isSelectable }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isSelectable }

    /// Slice of the thread-wide cross-block selection (see ChatCrossSelection).
    var crossSelectionRange: NSRange? {
        didSet {
            guard oldValue != crossSelectionRange else { return }
            needsDisplay = true
        }
    }

    /// See SelectableNSTextView.copy — the cross-block selection wins.
    override func copy(_ sender: Any?) {
        if copyCrossSelectionIfActive() { return }
        super.copy(sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        crossSelectionEnablesCopy(item) || super.validateUserInterfaceItem(item)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawCrossSelectionHighlight()
        super.draw(dirtyRect)
    }

    /// Cursor comes from a `.cursorUpdate` tracking area — legacy cursor
    /// rects don't survive layer-backed table-cell recycling (see
    /// `chatTextCursorUpdate`).
    private var cursorTrackingArea: NSTrackingArea?

    override func cursorUpdate(with event: NSEvent) {
        guard isSelectable else {
            super.cursorUpdate(with: event)
            return
        }
        chatTextCursorUpdate(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }
        guard isSelectable else {
            cursorTrackingArea = nil
            return
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    /// See SelectableNSTextView.mouseDown — single-click drags go through
    /// the cross-block selection controller (#2129).
    override func mouseDown(with event: NSEvent) {
        if isSelectable, event.clickCount == 1 {
            ChatCrossSelection.shared.beginDrag(from: self, with: event)
            return
        }
        ChatCrossSelection.shared.clear()
        super.mouseDown(with: event)
    }

}

// MARK: - NativeMarkdownTableView

/// Grid-based renderer for markdown tables. Each cell is a wrapping NSTextField,
/// so long cell content flows onto additional lines within its column instead of
/// overflowing into neighbours
/// Inline markdown in cells is rendered via SelectableTextView's attributed-string
/// builder so `**bold**` etc. work uniformly with the rest of the message.
final class NativeMarkdownTableView: NSView {

    // MARK: State

    private var currentTheme: (any ThemeProtocol)?
    private var headers: [String] = []
    private var rows: [[String]] = []
    private var lastWidth: CGFloat = 0
    private var lastThemeFingerprint: Int?
    /// Width used by the most recent `relayoutImpl` pass; `layout()` skips
    /// re-measuring when it would run with the same width again.
    private var lastRelayoutWidth: CGFloat = -1
    private var heightConstraint: NSLayoutConstraint?

    // [row][col]; row 0 is headers
    private var cellFields: [[CellTextView]] = []
    // Source text currently rendered in each cell, used to skip re-rendering
    // unchanged cells when the grid reconfigures during streaming
    private var cellTexts: [[String]] = []
    private let separator = NSView()

    // Per-row measurement cache. A streaming table reconfigures once per
    // delta, and re-running TextKit layout for EVERY row of the whole table
    // on each tick made large tables O(rows) per delta — a >3s main-thread
    // hang in production (APPLE-MACOS-19C). Only rows whose text changed
    // since the last measure (or a new column width) are re-measured.
    private var measuredRowTexts: [[String]] = []
    private var measuredRowHeights: [CGFloat] = []
    private var measuredColumnWidth: CGFloat = -1

    /// Called after the grid re-measures and its height changes.
    var onHeightChanged: (() -> Void)?

    override var isFlipped: Bool { true }

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        addSubview(separator)

        let hc = heightAnchor.constraint(equalToConstant: 24)
        hc.priority = .required
        hc.isActive = true
        heightConstraint = hc
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Configure

    func configure(headers: [String], rows: [[String]], width: CGFloat, theme: any ThemeProtocol) {
        let theme = RichTextInspectionStyle.scope(theme)
        currentTheme = theme
        layer?.backgroundColor = NSColor(theme.surface.code).cgColor
        layer?.cornerRadius = theme.radius.medium
        layer?.borderColor = NSColor(theme.border.default).cgColor
        layer?.borderWidth = RichTextInspectionStyle.metric("borderWidth", 1, theme)
        // The divider is positioned by relayoutImpl, so use a plain layer-backed
        // view without NSBox's intrinsic sizing or inset content view.
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor(theme.border.default).cgColor
        let fingerprint = theme.renderFingerprint
        let contentChanged = headers != self.headers || rows != self.rows
        let widthChanged = abs(width - lastWidth) > 0.5
        let themeChanged = fingerprint != lastThemeFingerprint
        guard contentChanged || widthChanged || themeChanged else { return }

        self.headers = headers
        self.rows = rows
        lastWidth = width
        lastThemeFingerprint = fingerprint

        if contentChanged || themeChanged {
            updateCells(theme: theme, rerenderAll: themeChanged)
        }
        relayout(width: width)
    }

    // MARK: Measurement

    func measuredHeight() -> CGFloat { heightConstraint?.constant ?? 24 }

    override func layout() {
        super.layout()
        // Only re-measure when the width actually changed. Every streaming
        // tick triggers a layout pass on the cell, and unconditionally
        // re-measuring every cell of every visible table per tick was the
        // dominant markdown streaming cost (ChatPerfTrace: 4,536 relayouts /
        // 7.8s over one stream). Content changes route through `configure`,
        // which calls `relayout` directly.
        if bounds.width > 0.5, abs(bounds.width - lastRelayoutWidth) > 0.5 {
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

        // A theme change re-renders cells without
        // changing their source text, so cached row heights are stale.
        if rerenderAll {
            measuredRowTexts.removeAll()
            measuredRowHeights.removeAll()
            measuredColumnWidth = -1
        }

        // A column-count change invalidates per-cell reuse; start over.
        if columnCount == 0 || cellFields.first?.count != columnCount {
            for row in cellFields { for cell in row { cell.removeFromSuperview() } }
            cellFields.removeAll()
            cellTexts.removeAll()
            measuredRowTexts.removeAll()
            measuredRowHeights.removeAll()
            measuredColumnWidth = -1
        }
        guard columnCount > 0 else { return }

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
                            .backgroundColor: NSColor(theme.selection.background)
                        ]
                        cell.insertionPointColor = NSColor(theme.cursor)
                    }
                    guard rerenderAll || cellTexts[rowIdx][colIdx] != text else { continue }
                    let attr = renderCellAttributedString(
                        text: text,
                        weight: weight,
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
        tv.selectedTextAttributes = [.backgroundColor: NSColor(theme.selection.background)]
        tv.insertionPointColor = NSColor(theme.cursor)
        let attr = renderCellAttributedString(
            text: text,
            weight: weight,
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

        // Cells keep the body line height without paragraph spacing.
        mutable.addAttribute(.paragraphStyle, value: theme.paragraphStyle(.body), range: fullRange)

        // Header row: upgrade every run's font to semibold (preserving italic/monospace).
        if weight == .semibold {
            let k = RichTextInspectionStyle.key + "label"
            mutable.enumerateAttributes(in: fullRange) { attributes, range, _ in
                guard !SelectableTextView.inlineIntent(attributes).contains(.code) else { return }
                mutable.addAttribute(.font, value: theme.assignedNativeFont(k, fallback: theme.nsFont(.label)), range: range)
                mutable.addAttribute(.kern, value: theme.assignedTracking(k) ?? 0, range: range)
            }
            let paragraph = theme.paragraphStyle(.label)
            mutable.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
        }
        return mutable
    }

    // MARK: - Private: Layout

    private func relayout(width: CGFloat) {
        // Traced: table relayout during streaming is a suspected
        // O(whole-table)-per-tick cost.
        ChatPerfTrace.shared.time("markdown.tableRelayout") {
            relayoutImpl(width: width)
        }
    }

    private func relayoutImpl(width: CGFloat) {
        lastRelayoutWidth = width
        let columnCount = cellFields.first?.count ?? 0
        guard columnCount > 0, width > 1 else {
            heightConstraint?.constant = 1
            return
        }

        let theme = currentTheme ?? CustomizableTheme.light()
        let pad = RichTextInspectionStyle.metric("padding", theme.space.s0, theme)
        let columnGap = RichTextInspectionStyle.metric("gap", theme.space.s16, theme)
        let rowGap = RichTextInspectionStyle.metric("gap", theme.space.s8, theme)
        let separatorGap: CGFloat = 6
        let headerPaddingBottom: CGFloat = 6

        let totalGaps = CGFloat(columnCount - 1) * columnGap
        let usable = max(width - 2 * pad - totalGaps, CGFloat(columnCount) * 40)
        let columnWidth = floor(usable / CGFloat(columnCount))

        // Measure row heights via each cell's own TextKit layout, reusing the
        // cached height for rows whose text hasn't changed since the last
        // measure at this column width (see `measuredRowTexts`).
        let cacheUsable = columnWidth == measuredColumnWidth
        var rowHeights: [CGFloat] = []
        for (rowIdx, row) in cellFields.enumerated() {
            if cacheUsable,
                rowIdx < measuredRowTexts.count,
                rowIdx < cellTexts.count,
                measuredRowTexts[rowIdx] == cellTexts[rowIdx]
            {
                rowHeights.append(measuredRowHeights[rowIdx])
                continue
            }
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
            rowHeights.append(max(maxH, RichTextInspectionStyle.metric("height", 18, theme)))
        }
        measuredRowTexts = cellTexts
        measuredRowHeights = rowHeights
        measuredColumnWidth = columnWidth

        // Place cells
        var y: CGFloat = pad
        for (rowIdx, row) in cellFields.enumerated() {
            var x: CGFloat = pad
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
                separator.frame = NSRect(x: pad, y: y, width: max(0, width - 2 * pad), height: RichTextInspectionStyle.metric("borderWidth", 1, theme))
                separator.isHidden = false
                y += separatorGap
            } else if rowIdx < cellFields.count - 1 {
                y += rowGap
            }
        }

        let newH = max(y + pad, 1)
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
