//
//  NativeActivityGroupView.swift
//  osaurus
//
//  Pure AppKit rollup for a run of consecutive thinking / tool-call blocks.
//  Collapsed it is a single disclosure row ("Worked for 12s · 6 steps");
//  expanded it stacks the run's individual NativeThinkingView /
//  NativeToolCallGroupView children, whose own per-item expansion keeps
//  working through the shared expandedIds set.
//
//  Self-sizing: owns a selfHeight constraint (priority 750) like
//  NativeThinkingView so it reports height to the coordinator without a
//  bottomAnchor pin to the cell.
//

import AppKit

final class NativeActivityGroupView: NSView {

    // MARK: Subviews

    private let headerButton = NSButton()
    /// Circular tinted node matching the thinking block / tool timeline nodes.
    private let iconNode = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    /// Shown in place of `titleLabel` while any child is still streaming.
    private let shimmerLabel = ShimmerLabel()
    /// Collapsed-state step preview: overlapping status circles (one per
    /// step, capped at 3) plus a trailing "steps" word for the overflow case.
    private let stepChipsStack = NSStackView()
    private let stepCountLabel = NSTextField(labelWithString: "")
    /// Signature of the currently built chips so per-token reconfigures
    /// don't tear down and rebuild identical circles.
    private var stepChipsSignature: String?
    /// Shown while the group is expanded — expands every step inside the
    /// group (in batches, see `expandAllTapped`).
    private let expandAllButton = NSButton()
    private let chevronView = NSImageView()
    private let separatorView = NSView()
    private let contentContainer = NSView()
    private let childStack = NSStackView()

    // MARK: Self-sizing height constraint

    private var selfHeight: NSLayoutConstraint?
    private let heightAnimation = DisclosureHeightAnimation()

    // MARK: State

    private var isExpanded = false
    private var inspectionTheme: (any ThemeProtocol)?
    private let inspectionHeader = InspectorActivityHeaderSurface()
    private var currentWidth: CGFloat = 0
    /// Same-block guard so the chevron only animates on a real expand-state
    /// change, never on cell recycling (mirrors NativeThinkingView).
    private var configuredBlockId: String?
    /// Child views keyed by their block id, reused across reconfigures so
    /// streaming appends don't rebuild (and re-animate) existing children.
    private var childViews: [String: NSView] = [:]
    private var childOrder: [String] = []
    /// Last configured children/expansion — the expand-all action needs the
    /// per-step toggle ids and which of them are still collapsed.
    private var lastChildren: [ContentBlock] = []
    private var lastExpandedIds: Set<String> = []
    private var onToggleChild: ((String) -> Void)?
    /// Invalidates in-flight expand-all batches on collapse/teardown.
    private var expandAllGeneration = 0

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
        // Relayout resets view-managed layer geometry; reapply the chevron
        // state so it doesn't snap back mid-stream (see NativeThinkingView).
        updateChevron(expanded: isExpanded, animated: false)
    }

    // MARK: Configure

    func configure(
        children: [ContentBlock],
        expandedIds: Set<String>,
        width: CGFloat,
        theme: any ThemeProtocol,
        isStreaming: Bool,
        blockId: String,
        sessionRedactions: [String: String],
        onToggleChild: @escaping (String) -> Void,
        onToggle: @escaping () -> Void,
        onHeightChanged: @escaping () -> Void
    ) {
        let theme = theme.catalogFamily(34)
        heightAnimation.isConfiguring = true
        inspectionTheme = theme
        self.onToggle = onToggle
        self.onHeightChanged = onHeightChanged
        self.onToggleChild = onToggleChild
        self.currentWidth = width
        self.lastChildren = children
        self.lastExpandedIds = expandedIds

        let tint = NSColor(theme.text.primary)
        let titleFont = theme.assignedNativeFont(ActivityInspectionStyle.key + "heading", fallback: theme.nsFont(.caption, weight: .semibold))
        titleLabel.font = titleFont
        titleLabel.textColor = tint
        iconView.contentTintColor = tint
        iconNode.layer?.backgroundColor = NSColor(theme.surface.hover).cgColor
        iconNode.layer?.borderColor = NSColor(theme.border.default).cgColor
        iconNode.layer?.borderWidth = theme.stroke.default
        expandAllButton.font = theme.nsFont(.footnote, weight: .medium)
        chevronView.contentTintColor = NSColor(theme.text.tertiary)
        separatorView.layer?.backgroundColor = NSColor(theme.border.subtle).cgColor

        // A group is "live" when its own children say so — a thinking child
        // still streaming, or an unresolved tool call while the table streams.
        // Gating the tool side on `isStreaming` keeps loaded chats (which can
        // carry never-resolved calls) static.
        let live = children.contains { child in
            switch child.kind {
            case let .thinking(_, _, streaming, _): return streaming
            case let .toolCallGroup(calls): return isStreaming && calls.contains { $0.result == nil }
            default: return false
            }
        }

        if live {
            let titleTracking = theme.assignedTracking(ActivityInspectionStyle.key + "heading")
            let titleLineHeight: CGFloat? = theme.assignedLineHeight(ActivityInspectionStyle.key + "heading", fallback: titleFont.pointSize)
            shimmerLabel.configure(
                text: L("Working"),
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
            let total = Self.totalDuration(of: children)
            titleLabel.stringValue =
                total > 0
                ? "\(L("Worked for")) \(Self.formatDuration(total))"
                : L("Worked")
            titleLabel.isHidden = false
        }

        let expanded = expandedIds.contains(blockId)

        let steps = ContentBlock.activityStepCount(of: children)
        configureStepChips(
            children: children,
            stepCount: steps,
            hidden: expanded || steps == 0,
            theme: theme,
            isStreaming: isStreaming
        )

        let isSameBlock = configuredBlockId == blockId
        if !isSameBlock { heightAnimation.cancel() }
        // Same-block collapsed → expanded: fade the children in instead of
        // popping (cell recycling and streaming reconfigures must not fade).
        let expandTransition = isSameBlock && expanded && !self.isExpanded
        let toggled = isSameBlock && expanded != self.isExpanded
        updateChevron(expanded: expanded, animated: toggled)
        self.isExpanded = expanded
        ActivityInspectionStyle.label(titleLabel, property: "heading", theme: theme)
        ActivityInspectionStyle.label(stepCountLabel, property: "caption", theme: theme)
        inspectionHeader.configure(theme: theme, selected: expanded, element: "activityHeader")
        applyAssignedLayout(theme)
        configuredBlockId = blockId

        // A collapse in motion keeps the children drawn until it finishes.
        let showsContent = expanded || toggled || heightAnimation.isRunning
        contentContainer.isHidden = !showsContent
        separatorView.isHidden = !showsContent

        // Expand All / Collapse All while the group is open: expand when any
        // step is still collapsed, collapse once everything is open.
        let toggleIds = Self.stepToggleIds(of: children)
        expandAllButton.isHidden = !expanded || toggleIds.isEmpty
        let allStepsExpanded =
            !toggleIds.isEmpty && toggleIds.allSatisfy { expandedIds.contains($0) }
        expandAllButton.title = allStepsExpanded ? L("Collapse All") : L("Expand All")
        expandAllButton.image = SymbolImageCache.image(
            allStepsExpanded
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right",
            accessibilityDescription: nil, pointSize: 10, weight: .semibold)
        expandAllButton.toolTip =
            allStepsExpanded ? L("Collapse all steps") : L("Expand all steps")
        expandAllButton.setAccessibilityLabel(expandAllButton.toolTip ?? "")
        expandAllButton.contentTintColor = NSColor(theme.text.tertiary)
        // NSButton draws a leading image flush against its title.
        let expandTitle = NSTextField(labelWithString: "\u{2009}" + expandAllButton.title)
        expandTitle.textColor = NSColor(theme.text.tertiary)
        ActivityInspectionStyle.label(expandTitle, property: "caption", theme: theme)
        expandAllButton.attributedTitle = expandTitle.attributedStringValue
        expandAllButton.constraints.first { $0.firstAttribute == .height }?.constant = max(20, ActivityInspectionStyle.fieldHeight("caption", theme))

        if expanded {
            configureChildren(
                children,
                expandedIds: expandedIds,
                theme: theme,
                isStreaming: isStreaming,
                sessionRedactions: sessionRedactions,
                onToggleChild: onToggleChild
            )
        } else if !showsContent {
            // Collapsed: drop child views so a huge expanded run doesn't keep
            // its markdown/tool layers alive off-screen.
            tearDownChildren()
        }

        // After the children are (re)built — the ripple walks the child
        // stack, which is empty until configureChildren above has run.
        // Tighter cadence than the in-step reveal: each part here is a whole
        // step, and a long run at the default interval feels sluggish.
        if expandTransition { ExpandFade.run(childStack, interval: 0.05, duration: 0.2) }

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
                    self.tearDownChildren()
                }
            )
        } else {
            applyHeight()
        }
    }

    private func applyAssignedLayout(_ theme: any ThemeProtocol) {
        let pad = ActivityInspectionStyle.layout("headerPaddingX", "padding", theme.space.s14, theme)
        let contentPad = ActivityInspectionStyle.layout("contentPaddingX", "padding", theme.space.s14, theme)
        let gap = ActivityInspectionStyle.layout("headerIconGap", "gap", theme.space.s8, theme)
        let height = ActivityInspectionStyle.headerHeight(theme, fallback: 44, property: "heading")
        headerButton.constraints.first { $0.firstAttribute == .height }?.constant = height
        separatorView.constraints.first { $0.firstAttribute == .height }?.constant = ActivityInspectionStyle.metric("borderWidth", 1, theme)
        childStack.spacing = ActivityInspectionStyle.layout("childGap", "gap", theme.space.s8, theme)
        headerButton.catalogAssignmentTarget(["headerPaddingX", "headerPaddingY", "headerIconGap"].map { ActivityInspectionStyle.key + "elements.layout." + $0 }, name: "Grouped activity header", theme: theme)
        contentContainer.catalogAssignmentTarget(["contentPaddingX", "contentTopGap", "contentBottomPadding", "childGap"].map { ActivityInspectionStyle.key + "elements.layout." + $0 } + [AgentContentSurfaceAssignments.key(34, "activityContent")], name: "Grouped activity content", theme: theme)
        layer?.backgroundColor = NSColor(AgentContentSurfaceAssignments.color(34, "activityCard", theme)).cgColor
        catalogAssignmentTarget([AgentContentSurfaceAssignments.key(34, "activityCard")], name: "Grouped activity card", theme: theme)
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor(AgentContentSurfaceAssignments.color(34, "activityContent", theme)).cgColor
        layer?.borderColor = NSColor(theme.border.subtle).cgColor
        layer?.borderWidth = ActivityInspectionStyle.metric("borderWidth", 0, theme)
        layer?.cornerRadius = theme.radius.medium
        iconNode.layer?.backgroundColor = NSColor(theme.surface.raised).cgColor
        iconNode.layer?.borderColor = NSColor(theme.border.default).cgColor
        separatorView.layer?.backgroundColor = NSColor(theme.border.subtle).cgColor
        for c in constraints {
            let view = c.firstItem as? NSView
            if view === iconNode, c.firstAttribute == .leading { c.constant = pad }
            if view === iconNode, c.firstAttribute == .centerY { c.constant = height / 2 }
            if (view === titleLabel || view === shimmerLabel), c.firstAttribute == .leading { c.constant = gap }
            if view === chevronView, c.firstAttribute == .trailing { c.constant = -pad }
            if view === separatorView, c.firstAttribute == .top { c.constant = height }
            if (view === separatorView || view === contentContainer), c.firstAttribute == .leading { c.constant = contentPad }
            if (view === separatorView || view === contentContainer), c.firstAttribute == .trailing { c.constant = -contentPad }
            if view === contentContainer, c.firstAttribute == .top { c.constant = ActivityInspectionStyle.layout("contentTopGap", "gap", theme.space.s8, theme) }
        }
    }

    // MARK: Measured height (used by cell coordinator)

    func measuredHeight() -> CGFloat {
        let theme = inspectionTheme ?? CustomizableTheme.light()
        let headerH = ActivityInspectionStyle.headerHeight(theme, fallback: 44, property: "heading")
        // Header height already includes vertical padding; keep its center
        // aligned with the collapsed card instead of reserving empty content.
        guard isExpanded, !childOrder.isEmpty else { return headerH }
        var contentH: CGFloat = 0
        for id in childOrder {
            guard let v = childViews[id] else { continue }
            if let tv = v as? NativeThinkingView {
                contentH += tv.displayedHeight()
            } else if let gv = v as? NativeToolCallGroupView {
                contentH += gv.measuredHeight()
            }
        }
        contentH += childStack.spacing * CGFloat(max(0, childOrder.count - 1))
        return headerH + ActivityInspectionStyle.metric("borderWidth", 1, theme) + ActivityInspectionStyle.layout("contentTopGap", "gap", theme.space.s8, theme) + contentH + ActivityInspectionStyle.layout("contentBottomPadding", "padding", theme.space.s10, theme)
    }

    // MARK: - Children

    private func configureChildren(
        _ children: [ContentBlock],
        expandedIds: Set<String>,
        theme: any ThemeProtocol,
        isStreaming: Bool,
        sessionRedactions: [String: String],
        onToggleChild: @escaping (String) -> Void
    ) {
        let childWidth = max(currentWidth - 2 * ActivityInspectionStyle.layout("contentPaddingX", "padding", theme.space.s14, theme), 100)
        let newOrder = children.map(\.id)

        // Rebuild the stack arrangement only when membership/order changed;
        // per-token reconfigures keep the existing arranged views.
        if newOrder != childOrder {
            for v in childStack.arrangedSubviews {
                childStack.removeArrangedSubview(v)
                v.removeFromSuperview()
            }
            var kept: [String: NSView] = [:]
            for child in children {
                let view: NSView
                if let existing = childViews[child.id] {
                    view = existing
                } else {
                    switch child.kind {
                    case .thinking: view = NativeThinkingView()
                    case .toolCallGroup: view = NativeToolCallGroupView()
                    default: continue
                    }
                }
                view.translatesAutoresizingMaskIntoConstraints = false
                childStack.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: childStack.widthAnchor).isActive = true
                kept[child.id] = view
            }
            childViews = kept
            childOrder = children.filter { childViews[$0.id] != nil }.map(\.id)
        }

        for child in children {
            guard let view = childViews[child.id] else { continue }
            switch child.kind {
            case let .thinking(_, text, streaming, duration):
                (view as? NativeThinkingView)?.configure(
                    thinking: text,
                    thinkingLength: text.count,
                    width: childWidth,
                    isStreaming: streaming,
                    isExpanded: expandedIds.contains(child.id),
                    duration: duration,
                    theme: theme,
                    blockId: child.id,
                    sessionRedactions: sessionRedactions,
                    onToggle: { onToggleChild(child.id) },
                    onHeightChanged: { [weak self] in self?.applyHeight() }
                )
            case let .toolCallGroup(calls):
                (view as? NativeToolCallGroupView)?.configure(
                    calls: calls,
                    expandedIds: expandedIds,
                    width: childWidth,
                    theme: theme,
                    isStreaming: isStreaming,
                    onToggle: { id in onToggleChild(id) },
                    onHeightChanged: { [weak self] in self?.applyHeight() }
                )
            default:
                break
            }
        }
    }

    // MARK: - Step chips

    /// One rendered circle in the collapsed step preview.
    private struct StepChip: Equatable {
        /// SF Symbol shown in the circle; nil for the "+N" overflow chip.
        var glyph: String?
        /// Overflow text ("+4"); nil for icon chips.
        var text: String?
        var colorKey: ChipColor

        enum ChipColor: String {
            case neutral, running, success, error
        }
    }

    /// Flattened per-step descriptors in run order — thinking segments count
    /// as one step each, tool calls one each (mirrors `activityStepCount`).
    private static func stepChips(
        for children: [ContentBlock], stepCount: Int, isStreaming: Bool
    ) -> [StepChip] {
        var all: [StepChip] = []
        for child in children {
            switch child.kind {
            case .thinking:
                all.append(StepChip(glyph: "brain", text: nil, colorKey: .neutral))
            case let .toolCallGroup(calls):
                for call in calls {
                    let name = call.call.function.name
                    let glyph =
                        SubagentCapabilityRegistry.iconName(forToolName: name)
                        ?? ToolCategory.from(toolName: name).icon
                    let colorKey: StepChip.ChipColor
                    if call.result == nil {
                        // Unresolved: running while the table streams; a
                        // loaded chat's never-resolved call reads neutral.
                        colorKey = isStreaming ? .running : .neutral
                    } else if ToolEnvelope.isError(call.result ?? "") {
                        colorKey = .error
                    } else {
                        colorKey = .success
                    }
                    all.append(StepChip(glyph: glyph, text: nil, colorKey: colorKey))
                }
            default:
                break
            }
        }
        guard all.count > 3 else { return all }
        return Array(all.prefix(2)) + [
            StepChip(glyph: nil, text: "+\(stepCount - 2)", colorKey: .neutral)
        ]
    }

    private func chipColor(_ key: StepChip.ChipColor, theme: any ThemeProtocol) -> NSColor {
        switch key {
        case .neutral: return NSColor(theme.text.tertiary)
        case .running: return NSColor(theme.status.info.foreground)
        case .success: return NSColor(theme.status.success.foreground)
        case .error: return NSColor(theme.status.error.foreground)
        }
    }

    private func configureStepChips(
        children: [ContentBlock],
        stepCount: Int,
        hidden: Bool,
        theme: any ThemeProtocol,
        isStreaming: Bool
    ) {
        stepChipsStack.isHidden = hidden
        stepCountLabel.isHidden = hidden
        if hidden { return }

        // With an overflow chip the "+N" already carries the number, so the
        // label is just the word; small groups spell out the full count.
        stepCountLabel.stringValue =
            stepCount > 3
            ? L("steps")
            : (stepCount == 1 ? L("1 step") : "\(stepCount) \(L("steps"))")
        stepCountLabel.font = theme.nsFont(.micro, weight: .medium)
        stepCountLabel.textColor = NSColor(theme.text.tertiary)

        let chips = Self.stepChips(for: children, stepCount: stepCount, isStreaming: isStreaming)
        let signature =
            chips.map { "\($0.glyph ?? $0.text ?? "")/\($0.colorKey.rawValue)" }
            .joined(separator: ",") + "|dark:\(theme.isDark)|style:\(theme.renderFingerprint)"
        guard signature != stepChipsSignature else { return }
        stepChipsSignature = signature

        for v in stepChipsStack.arrangedSubviews {
            stepChipsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        // Opaque backing so overlapped circles don't show through each other.
        let backing = NSColor(theme.surface.raised)
        for chip in chips {
            let color = chipColor(chip.colorKey, theme: theme)
            stepChipsStack.addArrangedSubview(makeChipView(chip, color: color, backing: backing, theme: theme))
        }
        // Trailing "steps" word (overflow case only — hidden views are
        // detached from the stack's layout). Positive gap after the
        // negatively-spaced circles.
        stepChipsStack.addArrangedSubview(stepCountLabel)
        if let lastChip = stepChipsStack.arrangedSubviews.dropLast().last {
            stepChipsStack.setCustomSpacing(ActivityInspectionStyle.metric("gap", theme.space.s6, theme), after: lastChip)
        }
    }

    private static let chipSize: CGFloat = 20
    private static let iconNodeSize: CGFloat = 28

    private func makeChipView(
        _ chip: StepChip, color: NSColor, backing: NSColor, theme: any ThemeProtocol
    ) -> NSView {
        let circle = NSView()
        circle.translatesAutoresizingMaskIntoConstraints = false
        circle.wantsLayer = true
        circle.layer?.cornerRadius = Self.chipSize / 2
        circle.layer?.borderWidth = theme.stroke.default
        circle.layer?.borderColor = NSColor(theme.border.default).cgColor
        circle.layer?.backgroundColor =
            (backing.blended(withFraction: 0.14, of: color) ?? backing).cgColor
        let chipHeight = max(Self.chipSize, ActivityInspectionStyle.fieldHeight("caption", theme, fallback: Self.chipSize))
        circle.layer?.cornerRadius = chipHeight / 2
        circle.heightAnchor.constraint(equalToConstant: chipHeight).isActive = true

        if let glyph = chip.glyph {
            circle.widthAnchor.constraint(equalToConstant: chipHeight).isActive = true
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.image = SymbolImageCache.image(
                glyph, accessibilityDescription: nil, pointSize: 9, weight: .semibold)
            icon.contentTintColor = color
            icon.imageScaling = .scaleProportionallyDown
            circle.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 10),
                icon.heightAnchor.constraint(equalToConstant: 10),
            ])
        } else {
            // Overflow "+N": capsule that widens with the text but never
            // shrinks below a circle.
            let label = NSTextField(labelWithString: chip.text ?? "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = theme.nsFont(.micro, weight: .semibold)
            label.textColor = color
            ActivityInspectionStyle.label(label, property: "caption", theme: theme)
            circle.addSubview(label)
            circle.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.chipSize).isActive = true
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
                label.leadingAnchor.constraint(
                    greaterThanOrEqualTo: circle.leadingAnchor, constant: 5),
            ])
        }
        return circle
    }

    private func tearDownChildren() {
        // Collapsing the group cancels any in-flight expand-all batches.
        expandAllGeneration += 1
        for v in childStack.arrangedSubviews {
            childStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        childViews = [:]
        childOrder = []
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
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.clear.cgColor

        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.title = ""; headerButton.isBordered = false; headerButton.bezelStyle = .inline
        headerButton.isTransparent = true
        headerButton.focusRingType = .none
        headerButton.target = self; headerButton.action = #selector(headerTapped)
        addSubview(headerButton)

        iconNode.translatesAutoresizingMaskIntoConstraints = false
        iconNode.wantsLayer = true
        iconNode.layer?.cornerRadius = Self.iconNodeSize / 2
        addSubview(iconNode)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = SymbolImageCache.image("sparkles", accessibilityDescription: nil)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconNode.addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.isEditable = false; titleLabel.isBordered = false; titleLabel.drawsBackground = false
        addSubview(titleLabel)

        shimmerLabel.translatesAutoresizingMaskIntoConstraints = false
        shimmerLabel.isHidden = true
        addSubview(shimmerLabel)

        stepChipsStack.translatesAutoresizingMaskIntoConstraints = false
        stepChipsStack.orientation = .horizontal
        stepChipsStack.alignment = .centerY
        // Negative spacing overlaps the circles into an avatar-style stack.
        stepChipsStack.spacing = -6
        addSubview(stepChipsStack)

        stepCountLabel.translatesAutoresizingMaskIntoConstraints = false
        stepCountLabel.isEditable = false; stepCountLabel.isBordered = false
        stepCountLabel.drawsBackground = false

        expandAllButton.translatesAutoresizingMaskIntoConstraints = false
        expandAllButton.image = SymbolImageCache.image(
            "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil,
            pointSize: 10, weight: .semibold)
        expandAllButton.title = L("Expand All")
        expandAllButton.imagePosition = .imageLeading
        expandAllButton.isBordered = false
        expandAllButton.focusRingType = .none
        expandAllButton.contentTintColor = .tertiaryLabelColor
        expandAllButton.toolTip = L("Expand all steps")
        expandAllButton.setAccessibilityLabel(L("Expand all steps"))
        expandAllButton.target = self
        expandAllButton.action = #selector(expandAllTapped)
        expandAllButton.isHidden = true
        addSubview(expandAllButton)

        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.wantsLayer = true
        chevronView.image = SymbolImageCache.image(
            "chevron.right", accessibilityDescription: nil, pointSize: 10, weight: .semibold)
        chevronView.imageScaling = .scaleProportionallyDown
        addSubview(chevronView)

        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.wantsLayer = true
        separatorView.isHidden = true
        addSubview(separatorView)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.isHidden = true
        addSubview(contentContainer)

        childStack.translatesAutoresizingMaskIntoConstraints = false
        childStack.orientation = .vertical
        childStack.spacing = 2
        childStack.alignment = .leading
        contentContainer.addSubview(childStack)

        let headerH: CGFloat = 44

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

            shimmerLabel.leadingAnchor.constraint(equalTo: iconNode.trailingAnchor, constant: 10),
            shimmerLabel.centerYAnchor.constraint(equalTo: iconNode.centerYAnchor),

            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            chevronView.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.heightAnchor.constraint(equalToConstant: 12),

            stepChipsStack.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -8),
            stepChipsStack.centerYAnchor.constraint(equalTo: chevronView.centerYAnchor),

            // Occupies the chips' slot — chips show collapsed, this shows expanded.
            expandAllButton.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -8),
            expandAllButton.centerYAnchor.constraint(equalTo: chevronView.centerYAnchor),
            expandAllButton.heightAnchor.constraint(equalToConstant: 20),

            separatorView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            separatorView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            separatorView.topAnchor.constraint(equalTo: topAnchor, constant: headerH),
            separatorView.heightAnchor.constraint(equalToConstant: 1),

            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            contentContainer.topAnchor.constraint(equalTo: separatorView.bottomAnchor, constant: 8),

            childStack.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            childStack.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            childStack.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            // Bottom pin sizes the container to its children — without it the
            // container's frame resolves to zero height and hit testing culls
            // clicks on the (still-drawn) child rows.
            childStack.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])

        inspectionHeader.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inspectionHeader, positioned: .below, relativeTo: iconNode)
        NSLayoutConstraint.activate([inspectionHeader.leadingAnchor.constraint(equalTo: leadingAnchor), inspectionHeader.trailingAnchor.constraint(equalTo: trailingAnchor), inspectionHeader.topAnchor.constraint(equalTo: topAnchor), inspectionHeader.heightAnchor.constraint(equalTo: headerButton.heightAnchor)])
        // Front of Z-order like the tool rows' header overlay, so clicks on
        // the title / step-count text toggle the same as the empty header
        // area. Transparent, and only 44pt tall, so it never paints over or
        // intercepts the expanded children below.
        addSubview(headerButton, positioned: .above, relativeTo: nil)
        // The expand-all control must sit above the transparent header
        // overlay or its clicks would toggle the group instead.
        addSubview(expandAllButton, positioned: .above, relativeTo: headerButton)
    }

    // MARK: - Expand all

    /// Toggle ids of every step in the group, in display order: a thinking
    /// child expands by its block id, a tool-call child by each call id.
    private static func stepToggleIds(of children: [ContentBlock]) -> [String] {
        children.flatMap { child -> [String] in
            switch child.kind {
            case .thinking: return [child.id]
            case let .toolCallGroup(calls): return calls.map { $0.call.id }
            default: return []
            }
        }
    }

    /// Expands every still-collapsed step, or — when everything is already
    /// open — collapses them all. Batched: each toggle triggers a cell
    /// reconfigure + row re-measure, so a run with dozens of steps would
    /// stutter if flipped in one burst. A few per tick keeps the table
    /// responsive and reads as a quick top-to-bottom cascade.
    @objc private func expandAllTapped() {
        let allIds = Self.stepToggleIds(of: lastChildren)
        let collapsed = allIds.filter { !lastExpandedIds.contains($0) }
        // Any collapsed step → expand those; none → collapse everything.
        let expanding = !collapsed.isEmpty
        let pending = expanding ? collapsed : allIds
        guard !pending.isEmpty, let toggle = onToggleChild else { return }

        expandAllGeneration += 1
        let generation = expandAllGeneration
        let batchSize = 3
        let batchInterval = 0.12

        for (batchIndex, start) in stride(from: 0, to: pending.count, by: batchSize).enumerated() {
            let batch = Array(pending[start ..< min(start + batchSize, pending.count)])
            DispatchQueue.main.asyncAfter(
                deadline: .now() + batchInterval * Double(batchIndex)
            ) { [weak self] in
                guard let self, self.expandAllGeneration == generation, self.isExpanded
                else { return }
                // Re-check against the latest expansion state — a step the
                // user flipped since the tap must not be toggled back the
                // other way.
                for id in batch
                where self.lastExpandedIds.contains(id) != expanding {
                    toggle(id)
                }
            }
        }
    }

    private func updateChevron(expanded: Bool, animated: Bool) {
        chevronView.image =
            expanded
            ? SymbolImageCache.rotatedDownChevron(pointSize: 10, weight: .semibold)
            : SymbolImageCache.image(
                "chevron.right", accessibilityDescription: nil, pointSize: 10, weight: .semibold)
    }

    @objc private func headerTapped() { onToggle?() }

    // MARK: - Aggregates

    /// Sum of the known child durations (thinking + tool calls). Children
    /// without a recorded duration contribute nothing.
    static func totalDuration(of children: [ContentBlock]) -> TimeInterval {
        children.reduce(0) { acc, child in
            switch child.kind {
            case let .thinking(_, _, _, duration): return acc + (duration ?? 0)
            case let .toolCallGroup(calls):
                return acc + calls.reduce(0) { $0 + ($1.duration ?? 0) }
            default: return acc
            }
        }
    }

    /// Compact duration matching NativeThinkingView's format.
    private static func formatDuration(_ t: TimeInterval) -> String {
        if t < 1 { return "\(Int((t * 1000).rounded()))ms" }
        if t < 10 { return String(format: "%.1fs", t) }
        if t < 60 { return "\(Int(t.rounded()))s" }
        return "\(Int(t) / 60)m \(Int(t) % 60)s"
    }
}
