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

    // MARK: State

    private var isExpanded = false
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
        self.onToggle = onToggle
        self.onHeightChanged = onHeightChanged
        self.onToggleChild = onToggleChild
        self.currentWidth = width
        self.lastChildren = children
        self.lastExpandedIds = expandedIds

        let tint = NSColor(theme.primaryText)
        let titleFont = NSFont.systemFont(ofSize: CGFloat(theme.captionSize), weight: .semibold)
        titleLabel.font = titleFont
        titleLabel.textColor = tint
        iconView.contentTintColor = tint
        iconNode.layer?.backgroundColor = tint.withAlphaComponent(0.15).cgColor
        iconNode.layer?.borderColor = tint.withAlphaComponent(0.55).cgColor

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
            shimmerLabel.configure(
                text: L("Working"),
                font: titleFont,
                baseColor: tint.withAlphaComponent(0.45),
                highlightColor: tint
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
        // Same-block collapsed → expanded: fade the children in instead of
        // popping (cell recycling and streaming reconfigures must not fade).
        let expandTransition = isSameBlock && expanded && !self.isExpanded
        updateChevron(
            expanded: expanded,
            animated: isSameBlock && expanded != self.isExpanded
        )
        self.isExpanded = expanded
        configuredBlockId = blockId

        contentContainer.isHidden = !expanded
        separatorView.isHidden = !expanded

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
        expandAllButton.contentTintColor = NSColor(theme.tertiaryText)

        if expanded {
            configureChildren(
                children,
                expandedIds: expandedIds,
                theme: theme,
                isStreaming: isStreaming,
                sessionRedactions: sessionRedactions,
                onToggleChild: onToggleChild
            )
        } else {
            // Collapsed: drop child views so a huge expanded run doesn't keep
            // its markdown/tool layers alive off-screen.
            tearDownChildren()
        }

        // After the children are (re)built — the ripple walks the child
        // stack, which is empty until configureChildren above has run.
        // Tighter cadence than the in-step reveal: each part here is a whole
        // step, and a long run at the default interval feels sluggish.
        if expandTransition { ExpandFade.run(childStack, interval: 0.05, duration: 0.2) }

        applyHeight()
    }

    // MARK: Measured height (used by cell coordinator)

    func measuredHeight() -> CGFloat {
        let headerH: CGFloat = 44
        let collapsedBottomInset: CGFloat = 4
        guard isExpanded, !childOrder.isEmpty else { return headerH + collapsedBottomInset }
        var contentH: CGFloat = 0
        for id in childOrder {
            guard let v = childViews[id] else { continue }
            if let tv = v as? NativeThinkingView {
                contentH += tv.measuredHeight()
            } else if let gv = v as? NativeToolCallGroupView {
                contentH += gv.measuredHeight()
            }
        }
        contentH += childStack.spacing * CGFloat(max(0, childOrder.count - 1))
        return headerH + 1 + 8 + contentH + 10
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
        let childWidth = max(currentWidth - 28, 100)
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
        case .neutral: return NSColor(theme.tertiaryText)
        case .running: return NSColor(theme.accentColor)
        case .success: return NSColor(theme.successColor)
        case .error: return NSColor(theme.errorColor)
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
        stepCountLabel.font = NSFont.systemFont(ofSize: CGFloat(theme.captionSize) - 2, weight: .medium)
        stepCountLabel.textColor = NSColor(theme.tertiaryText)

        let chips = Self.stepChips(for: children, stepCount: stepCount, isStreaming: isStreaming)
        let signature =
            chips.map { "\($0.glyph ?? $0.text ?? "")/\($0.colorKey.rawValue)" }
            .joined(separator: ",") + "|dark:\(theme.isDark)"
        guard signature != stepChipsSignature else { return }
        stepChipsSignature = signature

        for v in stepChipsStack.arrangedSubviews {
            stepChipsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        // Opaque backing so overlapped circles don't show through each other.
        let backing = NSColor(theme.primaryBackground)
        for chip in chips {
            let color = chipColor(chip.colorKey, theme: theme)
            stepChipsStack.addArrangedSubview(makeChipView(chip, color: color, backing: backing))
        }
        // Trailing "steps" word (overflow case only — hidden views are
        // detached from the stack's layout). Positive gap after the
        // negatively-spaced circles.
        stepChipsStack.addArrangedSubview(stepCountLabel)
        if let lastChip = stepChipsStack.arrangedSubviews.dropLast().last {
            stepChipsStack.setCustomSpacing(6, after: lastChip)
        }
    }

    private static let chipSize: CGFloat = 20

    private func makeChipView(_ chip: StepChip, color: NSColor, backing: NSColor) -> NSView {
        let circle = NSView()
        circle.translatesAutoresizingMaskIntoConstraints = false
        circle.wantsLayer = true
        circle.layer?.cornerRadius = Self.chipSize / 2
        circle.layer?.borderWidth = 1.5
        circle.layer?.borderColor = color.withAlphaComponent(0.55).cgColor
        circle.layer?.backgroundColor =
            (backing.blended(withFraction: 0.14, of: color) ?? backing).cgColor
        circle.heightAnchor.constraint(equalToConstant: Self.chipSize).isActive = true

        if let glyph = chip.glyph {
            circle.widthAnchor.constraint(equalToConstant: Self.chipSize).isActive = true
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
            label.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
            label.textColor = color
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
        headerButton.title = ""; headerButton.isBordered = false; headerButton.bezelStyle = .inline
        headerButton.isTransparent = true
        headerButton.focusRingType = .none
        headerButton.target = self; headerButton.action = #selector(headerTapped)
        addSubview(headerButton)

        iconNode.translatesAutoresizingMaskIntoConstraints = false
        iconNode.wantsLayer = true
        iconNode.layer?.cornerRadius = 14
        iconNode.layer?.borderWidth = 1.5
        iconNode.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.15).cgColor
        iconNode.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.55).cgColor
        addSubview(iconNode)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = SymbolImageCache.image("sparkles", accessibilityDescription: nil)
        iconView.contentTintColor = NSColor.labelColor
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
        expandAllButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
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
        chevronView.contentTintColor = .tertiaryLabelColor
        chevronView.imageScaling = .scaleProportionallyDown
        addSubview(chevronView)

        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.wantsLayer = true
        separatorView.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
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

        let h = heightAnchor.constraint(equalToConstant: headerH + 4)
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
            iconNode.widthAnchor.constraint(equalToConstant: 28),
            iconNode.heightAnchor.constraint(equalToConstant: 28),

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
